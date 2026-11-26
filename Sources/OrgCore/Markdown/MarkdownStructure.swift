import Foundation

/// Markdown as far as highlighting, heading folding, the outline and the index need it: front
/// matter, fenced code and ATX headings line by line, and inline markup within a line. Not a
/// CommonMark parser: setext headings, indented code blocks, HTML blocks and emphasis across
/// lines aren't recognised, and fences may be indented by any amount. Offsets are UTF-16.
public enum Markdown {
    /// Whether `path` names a Markdown file (`.md`, `.markdown`).
    public static func isPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    /// Whether `path` names a plain text file (`.txt`).
    public static func isPlainTextPath(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "txt"
    }

    public struct Heading: Sendable, Equatable {
        /// Start of the heading line.
        public let start: Int
        /// Start of the line after it, or the end of the text.
        public let lineEnd: Int
        public let level: Int
        public let title: String
    }

    /// A fenced code block, from its opening line to after its closing line; an unclosed one
    /// runs to the end of the text.
    public struct Fence: Sendable, Equatable {
        public let range: Range<Int>
        /// The opening line, with its newline.
        public let opening: Range<Int>
        /// The closing line, with its newline.
        public let closing: Range<Int>?
        /// The first word of the info string.
        public let language: String?

        public var body: Range<Int> { opening.upperBound..<(closing?.lowerBound ?? range.upperBound) }
    }

    /// YAML front matter between `---` lines, or TOML between `+++` lines, on the first line.
    public struct FrontMatter: Sendable, Equatable {
        public enum Format: String, Sendable { case yaml, toml }
        public let format: Format
        public let range: Range<Int>
        public let opening: Range<Int>
        public let closing: Range<Int>

        public var body: Range<Int> { opening.upperBound..<closing.lowerBound }
    }

    public struct Structure: Sendable, Equatable {
        public var frontMatter: FrontMatter?
        public var fences: [Fence] = []
        public var headings: [Heading] = []

        public init() {}

        /// The ranges that aren't Markdown text: front matter and fences, in order.
        public var blocks: [Range<Int>] { (frontMatter.map { [$0.range] } ?? []) + fences.map(\.range) }
    }

    public static func structure(_ text: String) -> Structure {
        structure(Array(text.utf16))
    }

    public static func structure(_ u: [UInt16]) -> Structure {
        var result = Structure()
        let n = u.count
        var i = 0
        if let front = frontMatter(u) {
            result.frontMatter = front
            i = front.range.upperBound
        }
        var open: (start: Int, opening: Range<Int>, char: UInt16, count: Int, language: String?)?
        while i < n {
            let end = lineEnd(u, i)
            let next = end < n ? end + 1 : n
            if let fence = open {
                if isClosingFence(u, i, end, char: fence.char, count: fence.count) {
                    result.fences.append(Fence(range: fence.start..<next, opening: fence.opening, closing: i..<next, language: fence.language))
                    open = nil
                }
            } else if let fence = openingFence(u, i, end) {
                open = (i, i..<next, fence.char, fence.count, fence.language)
            } else if let heading = atxHeading(u, i, end) {
                result.headings.append(Heading(start: i, lineEnd: next, level: heading.level, title: string(u, heading.title)))
            }
            i = next
        }
        if let fence = open {
            result.fences.append(Fence(range: fence.start..<n, opening: fence.opening, closing: nil, language: fence.language))
        }
        return result
    }

    /// The structure of `new`, which is `old` with `edit` made, from `structure` without reading
    /// the whole text again: offsets after the edit move, and the edited lines are read for
    /// headings. Nil when the edit may start or end front matter or a fence, which needs a
    /// fresh read.
    public static func structure(_ structure: Structure, old: [UInt16], new: [UInt16], after edit: TextEdit) -> Structure? {
        let lower = edit.range.lowerBound
        let upper = edit.range.upperBound
        let delta = new.count - old.count
        var start = lower
        while start > 0, old[start - 1] != newline { start -= 1 }
        let oldEnd = lineEnd(old, upper)
        let newEnd = lineEnd(new, upper + delta)
        func mayFence(_ u: [UInt16], _ range: Range<Int>) -> Bool {
            var run = 0
            for c in u[range] {
                run = c == backtick || c == tilde ? run + 1 : 0
                if run >= 3 { return true }
            }
            return false
        }
        if start == 0 || mayFence(old, start..<oldEnd) || mayFence(new, start..<newEnd) { return nil }
        if let front = structure.frontMatter, start < front.range.upperBound { return nil }
        // An unclosed `---` or `+++` first line may be closed by the edit.
        let first = lineEnd(new, 0)
        if structure.frontMatter == nil, isLine(new, 0, first, "---") || isLine(new, 0, first, "+++") { return nil }
        // No front matter or fence line is edited, so their bounds are at or before the edited
        // lines' start, or after their end; an unclosed fence runs on to the end of the text.
        func map(_ offset: Int) -> Int { offset <= start ? offset : offset + delta }
        func map(_ range: Range<Int>) -> Range<Int> { map(range.lowerBound)..<map(range.upperBound) }
        var result = Structure()
        result.frontMatter = structure.frontMatter
        result.fences = structure.fences.map { fence in
            let range = fence.closing == nil ? map(fence.range.lowerBound)..<new.count : map(fence.range)
            return Fence(range: range, opening: map(fence.opening), closing: fence.closing.map(map), language: fence.language)
        }
        let inFence = result.fences.contains { $0.range.lowerBound < start && start < $0.range.upperBound }
        var headings = structure.headings.filter { $0.start < start }
        if !inFence {
            var i = start
            repeat {
                let end = lineEnd(new, i)
                if let heading = atxHeading(new, i, end) {
                    headings.append(Heading(start: i, lineEnd: end < new.count ? end + 1 : end, level: heading.level, title: string(new, heading.title)))
                }
                i = end + 1
            } while i <= newEnd && i < new.count
        }
        for heading in structure.headings where heading.start > oldEnd {
            headings.append(Heading(start: heading.start + delta, lineEnd: heading.lineEnd + delta, level: heading.level, title: heading.title))
        }
        result.headings = headings
        return result
    }

    /// The front matter's `title`, else the first heading's.
    public static func title(_ text: String) -> String? {
        let u = Array(text.utf16)
        return title(u, structure(u))
    }

    public static func title(_ u: [UInt16], _ structure: Structure) -> String? {
        if let front = structure.frontMatter {
            let body = string(u, front.body)
            let pattern = front.format == .yaml ? /(?m)^title[ \t]*:[ \t]*(.*?)[ \t\r]*$/ : /(?m)^title[ \t]*=[ \t]*(.*?)[ \t\r]*$/
            if let match = body.firstMatch(of: pattern) {
                var value = Substring(match.1)
                if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                    value = value.dropFirst().dropLast()
                }
                if !value.isEmpty { return String(value) }
            }
        }
        return structure.headings.first { !$0.title.isEmpty }?.title
    }

    // MARK: - Lines

    static let newline: UInt16 = 10
    static let space: UInt16 = 32
    static let tab: UInt16 = 9
    static let cr: UInt16 = 13
    static let hash: UInt16 = 35
    static let backtick: UInt16 = 96
    static let tilde: UInt16 = 126

    /// The offset of the newline ending the line at `start`, or the end of the text.
    static func lineEnd(_ u: [UInt16], _ start: Int) -> Int {
        var i = start
        while i < u.count, u[i] != newline { i += 1 }
        return i
    }

    static func isBlank(_ c: UInt16) -> Bool { c == space || c == tab || c == cr }

    static func string(_ u: [UInt16], _ range: Range<Int>) -> String {
        String(decoding: u[range], as: UTF16.self)
    }

    /// The line without trailing spaces, tabs and carriage return.
    static func trimmedEnd(_ u: [UInt16], _ start: Int, _ end: Int) -> Int {
        var e = end
        while e > start, isBlank(u[e - 1]) { e -= 1 }
        return e
    }

    static func isLine(_ u: [UInt16], _ start: Int, _ end: Int, _ marker: String) -> Bool {
        let e = trimmedEnd(u, start, end)
        return Array(marker.utf16) == Array(u[start..<e])
    }

    static func frontMatter(_ u: [UInt16]) -> FrontMatter? {
        let end = lineEnd(u, 0)
        let format: FrontMatter.Format
        if isLine(u, 0, end, "---") { format = .yaml } else if isLine(u, 0, end, "+++") { format = .toml } else { return nil }
        guard end < u.count else { return nil }
        let opening = 0..<(end + 1)
        var i = end + 1
        while i < u.count {
            let e = lineEnd(u, i)
            let next = e < u.count ? e + 1 : e
            if format == .yaml ? (isLine(u, i, e, "---") || isLine(u, i, e, "...")) : isLine(u, i, e, "+++") {
                return FrontMatter(format: format, range: 0..<next, opening: opening, closing: i..<next)
            }
            i = next
        }
        return nil
    }

    static func openingFence(_ u: [UInt16], _ start: Int, _ end: Int) -> (char: UInt16, count: Int, language: String?)? {
        var i = start
        while i < end, u[i] == space || u[i] == tab { i += 1 }
        guard i < end, u[i] == backtick || u[i] == tilde else { return nil }
        let char = u[i]
        var count = 0
        while i < end, u[i] == char { i += 1; count += 1 }
        guard count >= 3 else { return nil }
        let info = i..<trimmedEnd(u, i, end)
        if char == backtick, u[info].contains(backtick) { return nil }
        var word = info.lowerBound
        while word < info.upperBound, isBlank(u[word]) || u[word] == 123 || u[word] == 46 { word += 1 }  // `{`, `.`
        var wordEnd = word
        while wordEnd < info.upperBound, !isBlank(u[wordEnd]), u[wordEnd] != 125, u[wordEnd] != 44 { wordEnd += 1 }  // `}`, `,`
        return (char, count, wordEnd > word ? string(u, word..<wordEnd) : nil)
    }

    static func isClosingFence(_ u: [UInt16], _ start: Int, _ end: Int, char: UInt16, count: Int) -> Bool {
        var i = start
        while i < end, u[i] == space || u[i] == tab { i += 1 }
        var run = 0
        while i < end, u[i] == char { i += 1; run += 1 }
        return run >= count && trimmedEnd(u, i, end) == i
    }

    /// An ATX heading: up to three spaces, one to six `#`, then a space, a tab or the end of
    /// the line. The title leaves out a closing run of `#`.
    static func atxHeading(_ u: [UInt16], _ start: Int, _ end: Int) -> (level: Int, title: Range<Int>)? {
        var i = start
        var indent = 0
        while i < end, u[i] == space, indent < 4 { i += 1; indent += 1 }
        guard indent < 4, i < end, u[i] == hash else { return nil }
        var level = 0
        while i < end, u[i] == hash { i += 1; level += 1 }
        guard level <= 6, i == end || isBlank(u[i]) else { return nil }
        while i < end, isBlank(u[i]) { i += 1 }
        var e = trimmedEnd(u, i, end)
        var closing = e
        while closing > i, u[closing - 1] == hash { closing -= 1 }
        if closing == i {
            e = i
        } else if closing < e, isBlank(u[closing - 1]) {
            e = trimmedEnd(u, i, closing)
        }
        return (level, i..<e)
    }
}
