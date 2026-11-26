import Foundation

/// One change that Replace in Files or a rename proposes in a file: the line it is on, the part
/// of the line that changes, what takes its place, and the edit to the whole text.
public struct ProposedChange: Sendable, Equatable, Identifiable {
    /// Its index among the file's changes.
    public let id: Int
    /// 1-based.
    public let line: Int
    /// The line as it is, without its line break.
    public let lineText: String
    /// The part of `lineText` that changes, in UTF-16 offsets; for a match that runs past the
    /// line, from its start to the end of the line.
    public let changed: Range<Int>
    /// What replaces `changed`.
    public let replacement: String
    public let edit: TextEdit

    public init(id: Int, line: Int, lineText: String, changed: Range<Int>, replacement: String, edit: TextEdit) {
        self.id = id
        self.line = line
        self.lineText = lineText
        self.changed = changed
        self.replacement = replacement
        self.edit = edit
    }

    /// `text` with `changes` applied.
    public static func apply(_ changes: [ProposedChange], to text: String) -> String {
        var result = text
        for change in changes.sorted(by: { $0.edit.range.lowerBound > $1.edit.range.lowerBound }) { result = change.edit.apply(to: result) }
        return result
    }
}

/// Where each line of a text starts, to describe an offset by its line.
struct LineStarts {
    let text: NSString
    private let starts: [Int]

    init(_ text: NSString) {
        self.text = text
        var starts = [0]
        for at in 0..<text.length where text.character(at: at) == 10 { starts.append(at + 1) }
        self.starts = starts
    }

    /// The 0-based line holding `offset`.
    func line(of offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The line's text without its line break.
    func content(ofLine index: Int) -> Range<Int> {
        let start = starts[index]
        var end = index + 1 < starts.count ? starts[index + 1] : text.length
        while end > start, [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
        return start..<end
    }

    /// A change for `edit`, described on the line it starts on.
    /// `shown`, when given, is what the list shows changing, in place of `edit`.
    func change(id: Int, _ edit: TextEdit, shown: TextEdit? = nil) -> ProposedChange {
        let index = line(of: edit.range.lowerBound)
        let content = content(ofLine: index)
        let lineText = text.substring(with: NSRange(content))
        let display = shown ?? edit
        let start = display.range.lowerBound - content.lowerBound
        let end = min(display.range.upperBound, content.upperBound) - content.lowerBound
        return ProposedChange(id: id, line: index + 1, lineText: lineText, changed: start..<max(start, end), replacement: display.replacement, edit: edit)
    }

    /// `edit` (from `edit(lineStart:from:to:)`) widened to whole words of the line, for showing.
    func wholeWords(_ edit: TextEdit) -> TextEdit {
        func blank(_ at: Int) -> Bool { [32, 9, 10, 13].contains(text.character(at: at)) }
        var start = edit.range.lowerBound, end = edit.range.upperBound
        var before = "", after = ""
        while start > 0, !blank(start - 1) {
            start -= 1
            before = text.substring(with: NSRange(location: start, length: 1)) + before
        }
        while end < text.length, !blank(end) {
            after += text.substring(with: NSRange(location: end, length: 1))
            end += 1
        }
        return TextEdit(range: start..<end, replacement: before + edit.replacement + after)
    }

    /// The edit that turns the line at `lineStart` from `old` into `new`, the parts both
    /// share left out, at whole characters.
    static func edit(lineStart: Int, from old: String, to new: String) -> TextEdit? {
        guard old != new else { return nil }
        let a = Array(old.unicodeScalars), b = Array(new.unicodeScalars)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        func utf16(_ scalars: ArraySlice<Unicode.Scalar>) -> Int { scalars.reduce(0) { $0 + $1.utf16.count } }
        let start = lineStart + utf16(a[..<prefix])
        let removed = utf16(a[prefix..<(a.count - suffix)])
        var replacement = String.UnicodeScalarView()
        replacement.append(contentsOf: b[prefix..<(b.count - suffix)])
        return TextEdit(range: start..<(start + removed), replacement: String(replacement))
    }
}

/// org-crypt's encrypted entries and encrypted files, which searches and renames leave alone.
public enum EncryptedText {
    /// A file encrypted as a whole (`notes.org.gpg`), by its extension.
    public static func isEncryptedFile(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".gpg")
    }

    /// The armored PGP messages (`-----BEGIN PGP MESSAGE-----` to `-----END PGP MESSAGE-----`)
    /// in the entries of headings tagged `tag`, their own tag or inherited: the entries
    /// org-crypt encrypted. Whole lines.
    public static func ranges(in text: String, tag: String = "crypt") -> [Range<Int>] {
        guard text.contains("-----BEGIN PGP MESSAGE-----") else { return [] }
        let ns = text as NSString
        var ranges: [Range<Int>] = []
        // Levels of the headings above the line, with whether each has the tag.
        var stack: [(level: Int, tagged: Bool)] = []
        var begin: Int?
        var at = 0
        while at < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: at, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            at = NSMaxRange(lineRange)
            if let match = line.firstMatch(of: /^(\*+)[ \t]/) {
                if let open = begin {
                    ranges.append(open..<lineRange.location)
                    begin = nil
                }
                let level = match.1.count
                while let last = stack.last, last.level >= level { stack.removeLast() }
                let tags = line.firstMatch(of: /[ \t]:([\p{L}\p{N}_@#%:]+):[ \t]*$/).map { $0.1.split(separator: ":").map(String.init) } ?? []
                stack.append((level, tags.contains(tag) || (stack.last?.tagged ?? false)))
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if begin == nil, trimmed == "-----BEGIN PGP MESSAGE-----", stack.last?.tagged == true {
                begin = lineRange.location
            } else if let open = begin, trimmed == "-----END PGP MESSAGE-----" {
                ranges.append(open..<NSMaxRange(lineRange))
                begin = nil
            }
        }
        if let open = begin { ranges.append(open..<ns.length) }
        return ranges
    }

    /// Whether `range` touches one of `ranges`.
    static func overlaps(_ range: Range<Int>, _ ranges: [Range<Int>]) -> Bool {
        ranges.contains { $0.overlaps(range) || ($0.contains(range.lowerBound) && range.isEmpty) }
    }
}
