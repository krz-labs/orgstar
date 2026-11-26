import Foundation

extension Markdown {
    /// What a range of a Markdown line is, for highlighting.
    public struct Span: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case heading(level: Int)
            case code, bold, italic, strikeThrough
            /// Emphasis and code delimiters, list bullets and block quote markers.
            case marker
            case link
            /// A link's brackets and destination.
            case linkMarkup
            case comment, rule, table, quote, checkbox
        }

        public let kind: Kind
        public let range: Range<Int>

        public init(_ kind: Kind, _ range: Range<Int>) {
            self.kind = kind
            self.range = range
        }
    }

    static let backslash: UInt16 = 92
    static let lessThan: UInt16 = 60
    static let greaterThan: UInt16 = 62
    static let openBracket: UInt16 = 91
    static let closeBracket: UInt16 = 93
    static let openParen: UInt16 = 40
    static let closeParen: UInt16 = 41
    static let bang: UInt16 = 33
    static let star: UInt16 = 42
    static let underscore: UInt16 = 95
    static let dash: UInt16 = 45
    static let plus: UInt16 = 43
    static let pipe: UInt16 = 124
    static let colon: UInt16 = 58

    /// Spans of the Markdown line from `start` to `end` (its newline excluded), which is
    /// outside front matter and fences. Outer spans come before the spans inside them.
    public static func lineSpans(_ u: [UInt16], _ start: Int, _ end: Int) -> [Span] {
        var spans: [Span] = []
        lineSpans(u, start, end, into: &spans)
        return spans.sorted { $0.range.lowerBound != $1.range.lowerBound ? $0.range.lowerBound < $1.range.lowerBound : $0.range.upperBound > $1.range.upperBound }
    }

    static func lineSpans(_ u: [UInt16], _ start: Int, _ end: Int, into spans: inout [Span]) {
        if let heading = atxHeading(u, start, end) {
            spans.append(Span(.heading(level: heading.level), start..<end))
            inline(u, heading.title, line: start..<end, into: &spans)
            return
        }
        if isThematicBreak(u, start, end) {
            spans.append(Span(.rule, start..<end))
            return
        }
        var i = start
        // Block quote markers, nested or not.
        var quoted = false
        while true {
            var j = i
            var indent = 0
            while j < end, u[j] == space, indent < 3 { j += 1; indent += 1 }
            guard j < end, u[j] == greaterThan else { break }
            spans.append(Span(.marker, j..<(j + 1)))
            i = j + 1
            if i < end, u[i] == space || u[i] == tab { i += 1 }
            quoted = true
        }
        if quoted, i < end { spans.append(Span(.quote, i..<end)) }
        // A list item's bullet or number, and a task's box.
        var j = i
        while j < end, u[j] == space || u[j] == tab { j += 1 }
        if let marker = listMarker(u, j, end) {
            spans.append(Span(.marker, j..<marker))
            var k = marker
            while k < end, u[k] == space || u[k] == tab { k += 1 }
            if k + 2 < end, u[k] == openBracket, u[k + 2] == closeBracket, [space, 120, 88].contains(u[k + 1]), k + 3 == end || isBlank(u[k + 3]) {
                spans.append(Span(.checkbox, k..<(k + 3)))
                k += 3
            }
            i = k
        } else if j < end, u[j] == pipe {
            spans.append(Span(.table, j..<trimmedEnd(u, j, end)))
        } else if let definition = linkDefinition(u, j, end) {
            spans.append(Span(.linkMarkup, j..<definition.lowerBound))
            spans.append(Span(.link, definition))
            return
        }
        inline(u, i..<end, line: start..<end, into: &spans)
    }

    /// Three or more `-`, `*` or `_`, the same one, with only spaces between.
    static func isThematicBreak(_ u: [UInt16], _ start: Int, _ end: Int) -> Bool {
        var i = start
        var indent = 0
        while i < end, u[i] == space, indent < 3 { i += 1; indent += 1 }
        guard i < end, [dash, star, underscore].contains(u[i]) else { return false }
        let char = u[i]
        var count = 0
        while i < end {
            if u[i] == char { count += 1 } else if !isBlank(u[i]) { return false }
            i += 1
        }
        return count >= 3
    }

    /// The end of a list marker at `i`: `-`, `*` or `+`, or up to nine digits and `.` or `)`,
    /// followed by a space, a tab or the end of the line.
    static func listMarker(_ u: [UInt16], _ i: Int, _ end: Int) -> Int? {
        guard i < end else { return nil }
        var j = i
        if u[i] == dash || u[i] == star || u[i] == plus {
            j += 1
        } else {
            while j < end, j - i < 9, u[j] >= 48, u[j] <= 57 { j += 1 }
            guard j > i, j < end, u[j] == 46 || u[j] == closeParen else { return nil }
            j += 1
        }
        return j == end || u[j] == space || u[j] == tab ? j : nil
    }

    /// `[label]: destination`: the destination's range.
    static func linkDefinition(_ u: [UInt16], _ i: Int, _ end: Int) -> Range<Int>? {
        guard i < end, u[i] == openBracket else { return nil }
        var j = i + 1
        while j < end, u[j] != closeBracket { j += 1 }
        guard j > i + 1, j + 1 < end, u[j + 1] == colon else { return nil }
        var k = j + 2
        while k < end, isBlank(u[k]) { k += 1 }
        var e = k
        while e < end, !isBlank(u[e]) { e += 1 }
        return e > k ? k..<e : nil
    }

    // MARK: - Inline

    /// Code spans, comments, autolinks and links first, as they hide what's inside them from
    /// emphasis; then bare URLs and emphasis in the text between.
    static func inline(_ u: [UInt16], _ range: Range<Int>, line: Range<Int>, into spans: inout [Span]) {
        let upper = range.upperBound
        var plain: [Range<Int>] = []
        var segment = range.lowerBound
        var i = range.lowerBound
        func take(_ end: Int) {
            plain.append(segment..<i)
            i = end
            segment = end
        }
        while i < upper {
            let c = u[i]
            if c == backslash {
                i += 2
                continue
            }
            if c == backtick {
                var runEnd = i
                while runEnd < upper, u[runEnd] == backtick { runEnd += 1 }
                if let close = backtickRun(u, from: runEnd, to: upper, count: runEnd - i) {
                    let end = close + runEnd - i
                    spans.append(Span(.code, i..<end))
                    spans.append(Span(.marker, i..<runEnd))
                    spans.append(Span(.marker, close..<end))
                    take(end)
                } else {
                    i = runEnd
                }
                continue
            }
            if c == lessThan {
                if starts(u, i, upper, "<!--"), let close = find(u, from: i + 4, to: upper, "-->") {
                    spans.append(Span(.comment, i..<(close + 3)))
                    take(close + 3)
                    continue
                }
                if let close = autolink(u, i, upper) {
                    spans.append(Span(.linkMarkup, i..<(i + 1)))
                    spans.append(Span(.link, (i + 1)..<close))
                    spans.append(Span(.linkMarkup, close..<(close + 1)))
                    take(close + 1)
                    continue
                }
            }
            if c == openBracket || (c == bang && i + 1 < upper && u[i + 1] == openBracket) {
                let open = c == bang ? i + 1 : i
                if let link = link(u, open, upper) {
                    spans.append(Span(.linkMarkup, i..<(open + 1)))
                    spans.append(Span(.link, (open + 1)..<link.textEnd))
                    spans.append(Span(.linkMarkup, link.textEnd..<link.end))
                    plain.append(segment..<i)
                    inline(u, (open + 1)..<link.textEnd, line: line, into: &spans)
                    i = link.end
                    segment = link.end
                    continue
                }
            }
            i += 1
        }
        plain.append(segment..<upper)
        for part in plain where !part.isEmpty {
            var from = part.lowerBound
            for url in bareURLs(u, part) {
                spans.append(Span(.link, url))
                emphasis(u, from..<url.lowerBound, line: line, into: &spans)
                from = url.upperBound
            }
            emphasis(u, from..<part.upperBound, line: line, into: &spans)
        }
    }

    static func starts(_ u: [UInt16], _ i: Int, _ upper: Int, _ prefix: String) -> Bool {
        let p = Array(prefix.utf16)
        return i + p.count <= upper && Array(u[i..<(i + p.count)]) == p
    }

    static func find(_ u: [UInt16], from: Int, to upper: Int, _ needle: String) -> Int? {
        var i = from
        while i < upper {
            if starts(u, i, upper, needle) { return i }
            i += 1
        }
        return nil
    }

    /// The start of the next run of exactly `count` backticks.
    static func backtickRun(_ u: [UInt16], from: Int, to upper: Int, count: Int) -> Int? {
        var i = from
        while i < upper {
            guard u[i] == backtick else {
                i += 1
                continue
            }
            var e = i
            while e < upper, u[e] == backtick { e += 1 }
            if e - i == count { return i }
            i = e
        }
        return nil
    }

    /// `<scheme:…>` or `<name@host>`: the offset of the closing `>`.
    static func autolink(_ u: [UInt16], _ i: Int, _ upper: Int) -> Int? {
        var j = i + 1
        var sawScheme = false
        var sawAt = false
        while j < upper, u[j] != greaterThan {
            let c = u[j]
            if c == space || c == tab || c == lessThan { return nil }
            if c == colon, j > i + 2 { sawScheme = true }
            if c == 64 { sawAt = true }
            j += 1
        }
        guard j < upper, j > i + 1, sawScheme || sawAt else { return nil }
        let first = u[i + 1]
        guard (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || (first >= 48 && first <= 57) else { return nil }
        return j
    }

    /// `[text](destination)` or `[text][label]` from the `[` at `open`: the `]` closing the
    /// text, and the end of the link.
    static func link(_ u: [UInt16], _ open: Int, _ upper: Int) -> (textEnd: Int, end: Int)? {
        var depth = 0
        var j = open
        while j < upper {
            let c = u[j]
            if c == backslash {
                j += 2
                continue
            }
            if c == openBracket { depth += 1 }
            if c == closeBracket {
                depth -= 1
                if depth == 0 { break }
            }
            j += 1
        }
        guard j < upper, j + 1 < upper else { return nil }
        let textEnd = j
        if u[j + 1] == openParen {
            var parens = 0
            var k = j + 1
            while k < upper {
                let c = u[k]
                if c == backslash {
                    k += 2
                    continue
                }
                if c == openParen { parens += 1 }
                if c == closeParen {
                    parens -= 1
                    if parens == 0 { return (textEnd, k + 1) }
                }
                k += 1
            }
            return nil
        }
        if u[j + 1] == openBracket {
            var k = j + 2
            while k < upper, u[k] != closeBracket, u[k] != openBracket { k += 1 }
            return k < upper && u[k] == closeBracket ? (textEnd, k + 1) : nil
        }
        return nil
    }

    /// `http://` and `https://` URLs, without trailing punctuation.
    static func bareURLs(_ u: [UInt16], _ range: Range<Int>) -> [Range<Int>] {
        var urls: [Range<Int>] = []
        var i = range.lowerBound
        while i < range.upperBound {
            guard u[i] == 104, starts(u, i, range.upperBound, "http://") || starts(u, i, range.upperBound, "https://"),
                  i == range.lowerBound || !isWordCharacter(u[i - 1]) else {
                i += 1
                continue
            }
            var e = i
            while e < range.upperBound, !isBlank(u[e]), u[e] != lessThan { e += 1 }
            while e > i, [46, 44, 58, 59, 33, 63, 39, 34, closeParen, star, underscore].contains(u[e - 1]) { e -= 1 }
            if e > i + 8 { urls.append(i..<e) }
            i = max(e, i + 1)
        }
        return urls
    }

    static func isWordCharacter(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c > 127
    }

    static func isPunctuation(_ c: UInt16) -> Bool {
        (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126)
    }

    struct Delimiter {
        var position: Int
        let char: UInt16
        var count: Int
        let canOpen: Bool
        let canClose: Bool
    }

    /// `**bold**`, `__bold__`, `*italic*`, `_italic_` and `~~strike~~`, matched as
    /// CommonMark's delimiter runs are, within `range`. Characters outside `line` count as
    /// whitespace.
    static func emphasis(_ u: [UInt16], _ range: Range<Int>, line: Range<Int>, into spans: inout [Span]) {
        guard !range.isEmpty else { return }
        var delimiters: [Delimiter] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let c = u[i]
            if c == backslash {
                i += 2
                continue
            }
            guard c == star || c == underscore || c == tilde else {
                i += 1
                continue
            }
            var e = i
            while e < range.upperBound, u[e] == c { e += 1 }
            let before: UInt16 = i > line.lowerBound ? u[i - 1] : space
            let after: UInt16 = e < line.upperBound ? u[e] : space
            let left = !isBlank(after) && (!isPunctuation(after) || isBlank(before) || isPunctuation(before))
            let right = !isBlank(before) && (!isPunctuation(before) || isBlank(after) || isPunctuation(after))
            let canOpen = c == underscore ? left && (!right || isPunctuation(before)) : left
            let canClose = c == underscore ? right && (!left || isPunctuation(after)) : right
            if c != tilde || e - i <= 2 {
                delimiters.append(Delimiter(position: i, char: c, count: e - i, canOpen: canOpen, canClose: canClose))
            }
            i = e
        }
        guard delimiters.count > 1 else { return }
        for closer in delimiters.indices where delimiters[closer].canClose {
            while delimiters[closer].count > 0 {
                guard let opener = delimiters[..<closer].lastIndex(where: {
                    $0.count > 0 && $0.canOpen && $0.char == delimiters[closer].char
                        && ($0.char != tilde || $0.count == delimiters[closer].count)
                }) else { break }
                let char = delimiters[closer].char
                let use = char == tilde ? delimiters[closer].count : (delimiters[opener].count >= 2 && delimiters[closer].count >= 2 ? 2 : 1)
                let openEnd = delimiters[opener].position + delimiters[opener].count
                let closeStart = delimiters[closer].position
                let kind: Span.Kind = char == tilde ? .strikeThrough : use == 2 ? .bold : .italic
                spans.append(Span(kind, (openEnd - use)..<(closeStart + use)))
                spans.append(Span(.marker, (openEnd - use)..<openEnd))
                spans.append(Span(.marker, closeStart..<(closeStart + use)))
                delimiters[opener].count -= use
                delimiters[closer].count -= use
                delimiters[closer].position += use
                for between in (opener + 1)..<closer { delimiters[between].count = 0 }
            }
        }
    }
}
