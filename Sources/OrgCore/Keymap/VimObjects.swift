import Foundation

// Sentences (`(`, `)`, `is`, `as`) and XML tags (`it`, `at`).

extension Vim.Buffer {
    /// `sentence-end` with Doom's `sentence-end-double-space` off, and the blanks after it.
    private static let sentenceEnd = try! NSRegularExpression(pattern: "[.?!…‽][\\]\"'”’)}»›]*(?:$|[ \\t])[ \\t\\n]*", options: .anchorsMatchLines)
    private static let orgParagraphStart = try! NSRegularExpression(pattern: "^(?:\\*+ |[ \\t]*(?:[-+]|[0-9]+[.)])(?: |$)|[ \\t]+\\* )")

    private func isBlankLine(_ line: Int) -> Bool {
        (line..<lineEnd(line)).allSatisfy { Self.isBlank(char($0)!) }
    }

    /// Each line's start.
    private var lineStarts: [Int] {
        var lines = [0]
        var p = 0
        while p < length {
            if char(p) == 10, p + 1 < length { lines.append(p + 1) }
            p += 1
        }
        return lines
    }

    /// Where sentences begin, in order: after a sentence's end and at the start of a
    /// paragraph's text. Blank lines separate paragraphs; in Org, headings and list items
    /// start one too.
    func sentenceStarts(org: Bool) -> [Int] {
        var all: Set<Int> = []
        var previousSeparates = true
        for line in lineStarts {
            let text = substring(line..<lineEnd(line))
            let special = org && Self.orgParagraphStart.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
            if isBlankLine(line) {
                previousSeparates = true
                continue
            }
            if previousSeparates || special { all.insert(firstNonBlankOrEnd(line)) }
            previousSeparates = org && text.hasPrefix("*") && special
        }
        for match in Self.sentenceEnd.matches(in: ns as String, range: NSRange(location: 0, length: length)) where NSMaxRange(match.range) < length {
            all.insert(NSMaxRange(match.range))
        }
        return all.sorted()
    }

    /// `)` and `(`: the next sentence's beginning or the blank line after the paragraph; the
    /// previous sentence's beginning or the blank line before the paragraph.
    func sentence(_ c: Int, forward: Bool, org: Bool) -> Int {
        let starts = sentenceStarts(org: org)
        let lines = lineStarts
        if forward {
            var target = starts.first { $0 > c } ?? length
            for (i, line) in lines.enumerated() where line > c && line < target && i > 0 && isBlankLine(line) && !isBlankLine(lines[i - 1]) {
                target = line
                break
            }
            return target
        }
        var target = starts.last { $0 < c } ?? 0
        for (i, line) in lines.enumerated().reversed() where line < c && line > target && i + 1 < lines.count && isBlankLine(line) && !isBlankLine(lines[i + 1]) {
            target = line
            break
        }
        return target
    }

    /// `is` and `as`: sentences and the blanks between them count alike for `is`; `as` takes a
    /// sentence with the blanks after it on its line, or else the blanks before it on its
    /// line, and on blanks takes them with the sentence after.
    func sentenceObject(_ c: Int, inner: Bool, count: Int, org: Bool) -> Range<Int>? {
        let starts = sentenceStarts(org: org)
        guard c < length, !starts.isEmpty else { return nil }
        // Each sentence's text, without the blanks after it.
        var sentences: [Range<Int>] = []
        for (i, start) in starts.enumerated() {
            var end = i + 1 < starts.count ? starts[i + 1] : length
            while end > start, let ch = char(end - 1), Self.isSpace(ch) { end -= 1 }
            sentences.append(start..<end)
        }
        let n = max(1, count)
        let index = sentences.firstIndex { $0.contains(c) }
        if inner {
            // Sentences and gaps in order.
            var bounds = [0]
            for s in sentences { bounds += [s.lowerBound, s.upperBound] }
            bounds.append(length)
            let segments = zip(bounds, bounds.dropFirst()).filter { $0 < $1 }.map { $0..<$1 }
            guard let first = segments.firstIndex(where: { $0.contains(c) }) else { return nil }
            return segments[first].lowerBound..<segments[min(segments.count - 1, first + n - 1)].upperBound
        }
        func nextStart(_ i: Int) -> Int { i + 1 < sentences.count ? sentences[i + 1].lowerBound : length }
        var lower: Int
        var last: Int
        // Whether the range ends with the blanks after `last`.
        var blanksAfter = false
        if let index {
            last = index
            lower = sentences[index].lowerBound
            let end = sentences[index].upperBound
            let before = max(index > 0 ? sentences[index - 1].upperBound : 0, lineStart(lower))
            if min(nextStart(index), lineEnd(end)) > end {
                blanksAfter = true
                if n == 1 { return lower..<min(nextStart(index), lineEnd(end)) }
            } else if before < lower {
                lower = before
            }
        } else {
            guard let next = sentences.firstIndex(where: { $0.lowerBound > c }) else { return nil }
            lower = next > 0 ? sentences[next - 1].upperBound : 0
            last = next
        }
        for _ in 1..<n where last + 1 < sentences.count {
            last += 1
            if blanksAfter { blanksAfter = nextStart(last) > sentences[last].upperBound }
        }
        return lower..<(blanksAfter ? nextStart(last) : sentences[last].upperBound)
    }

    private static let tag = try! NSRegularExpression(pattern: "<(/?)([^\\s<>/]+)(?:\\s[^<>]*?)?(/?)>")

    /// `it` and `at`: the `count`th pair of XML tags around `c`, a tag itself counting as inside
    /// its pair; `inner` is the text between them.
    func tagObject(_ c: Int, inner: Bool, count: Int) -> Range<Int>? {
        var open: [(name: String, range: NSRange)] = []
        var pairs: [(open: NSRange, close: NSRange)] = []
        for match in Self.tag.matches(in: ns as String, range: NSRange(location: 0, length: length)) {
            guard match.range(at: 3).length == 0 else { continue }
            let name = ns.substring(with: match.range(at: 2))
            if match.range(at: 1).length == 0 {
                open.append((name, match.range))
            } else if let i = open.lastIndex(where: { $0.name == name }) {
                pairs.append((open[i].range, match.range))
                open.removeSubrange(i...)
            }
        }
        // Innermost first.
        let around = pairs.filter { $0.open.location <= c && c < NSMaxRange($0.close) }.sorted { $0.open.location > $1.open.location }
        guard around.count >= max(1, count) else { return nil }
        let pair = around[max(1, count) - 1]
        return inner ? NSMaxRange(pair.open)..<pair.close.location : pair.open.location..<NSMaxRange(pair.close)
    }

    /// Whether `range` is every character of two or more lines, which makes `at` take the lines.
    func coversLines(_ range: Range<Int>) -> Bool {
        range.lowerBound == lineStart(range.lowerBound) && range.upperBound == lineEnd(range.upperBound)
            && lineStart(range.upperBound) > range.lowerBound
    }
}
