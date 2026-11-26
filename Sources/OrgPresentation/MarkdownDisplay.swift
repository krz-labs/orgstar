import Foundation
import OrgCore

/// A Markdown file's text and structure at one revision, with what the editors build from
/// them: the outline, and the tree the fold commands work on.
public final class MarkdownDocument: @unchecked Sendable {
    public let units: [UInt16]
    public let structure: Markdown.Structure

    public init(_ text: String) {
        units = Array(text.utf16)
        structure = Markdown.structure(units)
    }

    init(units: [UInt16], structure: Markdown.Structure) {
        self.units = units
        self.structure = structure
    }

    /// The document after `edit`, read again only where the edit needs it.
    public func applying(_ edit: TextEdit) -> MarkdownDocument {
        var new = units
        new.replaceSubrange(edit.range, with: Array(edit.replacement.utf16))
        return MarkdownDocument(units: new, structure: Markdown.structure(structure, old: units, new: new, after: edit) ?? Markdown.structure(new))
    }

    public private(set) lazy var outline: [OutlineEntry] = Presentation.markdownOutline(structure, length: units.count)

    /// An org tree whose headings are the Markdown headings, at the same offsets: the text with
    /// each heading's `#`s as stars and everything else but newlines as spaces. The org fold
    /// code (cycling, hidden ranges, Doom's fold keys) works on it unchanged.
    public private(set) lazy var foldTree: OrgTree = {
        var skeleton = units.map { $0 == 10 ? UInt16(10) : UInt16(32) }
        for heading in structure.headings {
            for k in 0..<heading.level { skeleton[heading.start + k] = 42 }
        }
        return OrgParser.parse(String(decoding: skeleton, as: UTF16.self))
    }()
}

extension Presentation {
    /// Every Markdown heading in document order: a section runs to the next heading of its
    /// level or higher.
    public static func markdownOutline(_ structure: Markdown.Structure, length: Int) -> [OutlineEntry] {
        let headings = structure.headings
        var entries: [OutlineEntry] = []
        var open: [Int] = []
        for (index, heading) in headings.enumerated() {
            while let last = open.last, headings[last].level >= heading.level { open.removeLast() }
            let end = headings[(index + 1)...].first { $0.level <= heading.level }?.start ?? length
            entries.append(OutlineEntry(start: heading.start, level: heading.level, title: heading.title, end: end, parent: open.last, isTopLevel: open.isEmpty))
            open.append(index)
        }
        return entries
    }

    /// What folding the Markdown headings at `folds` (whole sections) and `bodyFolds` (their
    /// text before the first subheading) hides, as `hiddenRanges` does for org headings.
    public static func markdownHiddenRanges(_ document: MarkdownDocument, folds: Set<Int>, bodyFolds: Set<Int>) -> [Range<Int>] {
        guard !folds.isEmpty || !bodyFolds.isEmpty else { return [] }
        let outline = document.outline
        let headings = document.structure.headings
        var ranges: [Range<Int>] = []
        var hiddenUntil = 0
        for (index, entry) in outline.enumerated() where entry.start >= hiddenUntil {
            let lineEnd = headings[index].lineEnd
            if folds.contains(entry.start) {
                if lineEnd < entry.end { ranges.append(lineEnd..<entry.end) }
                hiddenUntil = entry.end
            } else if bodyFolds.contains(entry.start) {
                let bodyEnd = index + 1 < outline.count && outline[index + 1].parent == index ? outline[index + 1].start : entry.end
                if lineEnd < bodyEnd { ranges.append(lineEnd..<bodyEnd) }
            }
        }
        return ranges
    }

    /// The display a file that isn't org opens with: nothing folded, indented or shown inline.
    public static func textStartupDisplay(options: EditingOptions) -> StartupDisplay {
        StartupDisplay(folds: FoldState(), wrappers: [], indented: false, hideStars: false, inlineImages: false, alignTables: false, truncated: options.startupTruncated)
    }

    /// Style runs for the Markdown lines overlapping `range`: front matter and fences as
    /// blocks, highlighted as YAML, TOML or the fence's language; other lines by their
    /// markup. Outer runs come before the runs inside them.
    public static func markdownStyles(_ document: MarkdownDocument, in range: Range<Int>, highlighter: (any CodeHighlighter)? = nil) -> [StyleRun] {
        let u = document.units
        let structure = document.structure
        guard !range.isEmpty, range.lowerBound < u.count else { return [] }
        var runs: [StyleRun] = []
        func code(_ language: String?, _ body: Range<Int>) {
            guard let highlighter, let language, !body.isEmpty else { return }
            let text = String(decoding: u[body], as: UTF16.self)
            for run in highlighter.highlights(language: language, code: text) {
                runs.append(StyleRun(range: (run.range.lowerBound + body.lowerBound)..<(run.range.upperBound + body.lowerBound), role: .syntax(run.category)))
            }
        }
        if let front = structure.frontMatter, front.range.overlaps(range) {
            runs.append(StyleRun(range: front.opening, role: .blockDelimiter))
            if !front.body.isEmpty { runs.append(StyleRun(range: front.body, role: .metadata)) }
            code(front.format.rawValue, front.body)
            runs.append(StyleRun(range: front.closing, role: .blockDelimiter))
        }
        let fences = structure.fences
        var first = firstIndex(fences) { $0.range.upperBound > range.lowerBound }
        while first < fences.count, fences[first].range.lowerBound < range.upperBound {
            let fence = fences[first]
            runs.append(StyleRun(range: fence.opening, role: .blockDelimiter))
            if !fence.body.isEmpty { runs.append(StyleRun(range: fence.body, role: .block)) }
            code(fence.language, fence.body)
            if let closing = fence.closing { runs.append(StyleRun(range: closing, role: .blockDelimiter)) }
            first += 1
        }
        let blocks = structure.blocks
        var block = firstIndex(blocks) { $0.upperBound > range.lowerBound }
        var i = range.lowerBound
        while i > 0, u[i - 1] != 10 { i -= 1 }
        let upper = min(range.upperBound, u.count)
        while i < upper {
            if block < blocks.count, blocks[block].lowerBound <= i {
                i = max(i, blocks[block].upperBound)
                block += 1
                continue
            }
            var end = i
            while end < u.count, u[end] != 10 { end += 1 }
            for span in Markdown.lineSpans(u, i, end) { runs.append(StyleRun(range: span.range, role: role(span.kind))) }
            i = end + 1
        }
        return runs
    }

    /// The first index whose element satisfies `test`, which holds from some index to the end.
    static func firstIndex<T>(_ items: [T], where test: (T) -> Bool) -> Int {
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if test(items[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }

    static func role(_ kind: Markdown.Span.Kind) -> StyleRole {
        switch kind {
        case .heading(let level): .heading(level: level)
        case .code: .code
        case .bold: .bold
        case .italic, .quote: .italic
        case .strikeThrough: .strikeThrough
        case .marker: .markup
        case .link: .link
        case .linkMarkup: .linkMarkup
        case .comment: .comment
        case .rule: .rule
        case .table: .table
        case .checkbox: .cookie
        }
    }

    /// The lines an edit to a Markdown file restyles: the edited lines, and every front matter
    /// or fence that the edit made, unmade or moved the end of.
    public static func markdownRestyleRange(for edit: TextEdit, oldBlocks: [Range<Int>], new document: MarkdownDocument, newText: NSString) -> Range<Int> {
        let newEnd = edit.range.lowerBound + edit.replacement.utf16.count
        let lines = newText.lineRange(for: NSRange(location: edit.range.lowerBound, length: newEnd - edit.range.lowerBound))
        var lower = lines.location
        var upper = NSMaxRange(lines)
        let delta = newEnd - edit.range.upperBound
        func map(_ offset: Int) -> Int {
            offset < edit.range.lowerBound ? offset : offset >= edit.range.upperBound ? offset + delta : newEnd
        }
        let mapped = Set(oldBlocks.map { map($0.lowerBound)..<map($0.upperBound) })
        for changed in mapped.symmetricDifference(document.structure.blocks) {
            lower = min(lower, changed.lowerBound)
            upper = max(upper, changed.upperBound)
        }
        return lower..<min(upper, newText.length)
    }
}
