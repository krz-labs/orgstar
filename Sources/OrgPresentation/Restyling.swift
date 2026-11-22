import Foundation
import OrgCore

/// Styling done in passes from the start of the text: before `end` the text is styled, after
/// it the text waits for a pass. Always at a line start.
public struct StyledExtent: Sendable, Equatable {
    public private(set) var end = 0

    public init() {}

    public mutating func reset() { end = 0 }

    /// The whole lines from `end`, about `size` units, now counted as styled; nil when all are.
    public mutating func next(_ size: Int, in text: NSString) -> Range<Int>? {
        guard end < text.length else { return nil }
        let target = min(text.length, end + size)
        let upper = target == text.length ? target : NSMaxRange(text.lineRange(for: NSRange(location: target, length: 0)))
        defer { end = upper }
        return end..<upper
    }

    /// Keeps `end` on unstyled text: shifted past `edit`, or pulled back to the edited line when
    /// the edit reaches into unstyled text. `text` is the text after the edit.
    public mutating func map(through edit: TextEdit, in text: NSString) {
        if end >= edit.range.upperBound {
            end += edit.replacement.utf16.count - edit.range.count
        } else if end > edit.range.lowerBound {
            end = text.lineRange(for: NSRange(location: edit.range.lowerBound, length: 0)).location
        }
    }
}

/// An attribute change styling makes, in the order `Presentation.styleChanges` gives.
public enum StyleChange: Sendable, Equatable {
    /// org-indent's paragraph style for a line.
    case indent(Presentation.LineIndent)
    /// A role over a range.
    case role(StyleRole, Range<Int>)
    /// Markup hidden off the revealed line.
    case hidden(Range<Int>)
}

extension Presentation {
    /// The indents and roles for `range`, clipped to it, in ascending order of where they start,
    /// so each change lands at the end of the attribute runs made so far instead of moving the
    /// ones after it. Leading stars that `indented` and `hideStars` skip are left out; with
    /// `showMarkup` off, markup that `options` hides is hidden except on `revealed`. Also the
    /// ranges of runs that exclude sub- and superscripts, unclipped.
    public static func styleChanges(
        _ tree: OrgTree, in range: Range<Int>, highlighter: (any CodeHighlighter)?,
        indented: Bool, hideStars: Bool, showMarkup: Bool, options: EditingOptions, revealed: Range<Int>
    ) -> (changes: [StyleChange], scriptExclusions: [Range<Int>]) {
        var changes: [StyleChange] = []
        var scriptExclusions: [Range<Int>] = []
        var indents = (indented ? lineIndents(tree, in: range) : [])[...]
        func indent(before offset: Int) {
            while let line = indents.first, line.range.lowerBound <= offset {
                changes.append(.indent(line))
                indents.removeFirst()
            }
        }
        // Outer before inner still: an outer role never starts after an inner one, and the
        // index keeps the order of roles that start together. A src block's code runs come in
        // the highlighter's order, where later wins, so they sort as one.
        let runs = styles(tree, in: range, highlighter: highlighter)
        var starts: [Int] = []
        for (index, run) in runs.enumerated() {
            if case .syntax = run.role, index > 0, case .syntax = runs[index - 1].role {
                starts.append(starts[index - 1])
            } else {
                starts.append(run.range.lowerBound)
            }
        }
        for index in runs.indices.sorted(by: { (starts[$0], $0) < (starts[$1], $1) }) {
            let run = runs[index]
            indent(before: run.range.lowerBound)
            let clipped = run.range.clamped(to: range)
            guard !clipped.isEmpty else { continue }
            if skipsLeadingStars(run.role, indented: indented, hideStars: hideStars) { continue }
            if !showMarkup, hidesWithMarkup(run.role, options: options), !clipped.overlaps(revealed) {
                changes.append(.hidden(clipped))
            } else {
                changes.append(.role(run.role, clipped))
            }
            if excludesScripts(run.role) { scriptExclusions.append(run.range) }
        }
        indent(before: range.upperBound)
        return (changes, scriptExclusions)
    }

    /// The region an edit affects in one version of the tree: inside the innermost section
    /// holding the edited lines (plus the line after), every element that overlaps them or the
    /// line on either side. A changed heading line, or an added or removed heading, widens it
    /// to that section's whole own body; outside a section with a heading, the elements around
    /// the edit already cover what changes. Run on the old and the new tree, the union covers
    /// elements that grew and elements that shrank.
    public static func affectedRange(_ tree: OrgTree, _ text: NSString, _ start: Int, _ end: Int, touchedHeadings: Bool) -> Range<Int> {
        let lines = text.lineRange(for: NSRange(location: start, length: min(end + 1, text.length) - start))
        let lineRange = lines.location..<(lines.location + lines.length)
        let around = max(0, lineRange.lowerBound - 1)..<min(text.length, lineRange.upperBound + 1)
        var container = tree.root
        while let child = container.child(containing: lineRange.lowerBound),
              child.kind == .section || child.kind == .zerothSection,
              lineRange.upperBound <= child.range.upperBound {
            container = child
        }
        var lower = lineRange.lowerBound
        var upper = lineRange.upperBound
        // Tables and lists carry no styling of their own, so inside them only the rows or
        // items around the edit change, however large they are.
        func overlapping(_ nodes: [SyntaxNode]) -> [SyntaxNode] {
            nodes.filter { $0.range.overlaps(around) }.flatMap { node -> [SyntaxNode] in
                guard [.table, .plainList, .item].contains(node.kind) else { return [node] }
                let inner = overlapping(node.children(overlapping: around))
                return inner.isEmpty ? [node] : inner
            }
        }
        for child in overlapping(container.children(overlapping: around)) {
            lower = min(lower, child.range.lowerBound)
            upper = max(upper, child.range.upperBound)
        }
        if let heading = container.firstChild(.heading), touchedHeadings || heading.range.overlaps(lineRange) {
            lower = min(lower, container.range.lowerBound)
            upper = max(upper, container.firstChild(.section)?.range.lowerBound ?? container.range.upperBound)
        }
        return lower..<min(upper, text.length)
    }

    /// Whether a heading line touches `start..<end` or starts right after it, where joining
    /// lines could take it away.
    public static func headingLineNear(_ start: Int, _ end: Int, in text: NSString) -> Bool {
        let length = min(end + 1, text.length) - start
        guard length >= 0 else { return false }
        let lines = text.substring(with: text.lineRange(for: NSRange(location: start, length: length)))
        return lines.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let stars = line.prefix { $0 == "*" }
            let after = line.dropFirst(stars.count)
            return !stars.isEmpty && (after.isEmpty || after.first == " " || after.first == "\t" || after.first == "\r")
        }
    }

    /// What `edit` makes style again: the region it affects in the old tree, mapped through it,
    /// and in the new one. Not clamped to the new text.
    public static func restyleRange(for edit: TextEdit, old: (tree: OrgTree, text: NSString), new: (tree: OrgTree, text: NSString)) -> Range<Int> {
        let newEnd = edit.range.lowerBound + edit.replacement.utf16.count
        let touchedHeadings = headingLineNear(edit.range.lowerBound, edit.range.upperBound, in: old.text)
            || headingLineNear(edit.range.lowerBound, newEnd, in: new.text)
        let oldAffected = affectedRange(old.tree, old.text, edit.range.lowerBound, edit.range.upperBound, touchedHeadings: touchedHeadings)
        let newAffected = affectedRange(new.tree, new.text, edit.range.lowerBound, newEnd, touchedHeadings: touchedHeadings)
        let delta = edit.replacement.utf16.count - edit.range.count
        let oldMapped = oldAffected.lowerBound..<(oldAffected.upperBound >= edit.range.upperBound ? oldAffected.upperBound + delta : newEnd)
        return min(oldMapped.lowerBound, newAffected.lowerBound)..<max(oldMapped.upperBound, newAffected.upperBound)
    }

    /// Whether the lines around `range`, and the line after it (a deleted newline joins it to
    /// them), hold a block delimiter or a fixed-width line.
    public static func mayChangeBlocks(_ text: NSString, _ range: Range<Int>) -> Bool {
        let start = min(range.lowerBound, text.length)
        let end = min(range.upperBound + 1, text.length)
        let lines = text.lineRange(for: NSRange(location: start, length: end - start))
        let content = text.substring(with: lines)
        return content.contains("#+") || content.range(of: "(^|\\n)([ \\t]*:|\\*)", options: .regularExpression) != nil
    }
}
