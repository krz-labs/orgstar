import Foundation
import OrgCore

/// A heading's tags and the spaces before them, which `org-tags-column` pads to line the tags
/// up. The editors and the reader draw the spaces as one gap so the line never wraps inside
/// the padding or the tags; the file keeps its spaces.
public struct TagGap: Sendable, Equatable {
    /// The spaces between the title and the tags.
    public let gap: Range<Int>
    public let tags: Range<Int>

    public init(gap: Range<Int>, tags: Range<Int>) {
        self.gap = gap
        self.tags = tags
    }
}

extension Presentation {
    /// The spaces before `tags`, when there are two or more. A gap with a tab is left as written.
    public static func tagGap(tags: Range<Int>, in text: NSString) -> TagGap? {
        var start = tags.lowerBound
        while start > 0, text.character(at: start - 1) == 0x20 { start -= 1 }
        guard tags.lowerBound - start > 1, start > 0, text.character(at: start - 1) != 0x09 else { return nil }
        return TagGap(gap: start..<tags.lowerBound, tags: tags)
    }

    /// Every heading's tag gap, in document order.
    public static func tagGaps(_ tree: OrgTree) -> [TagGap] {
        var gaps: [TagGap] = []
        let text = tree.text as NSString
        func visit(_ node: SyntaxNode) {
            for section in node.children where section.kind == .section {
                if let tags = section.firstChild(.heading)?.tokens.first(where: { $0.kind == .tags }),
                   tags.range.upperBound <= text.length, let gap = tagGap(tags: tags.range, in: text) {
                    gaps.append(gap)
                }
                visit(section)
            }
        }
        visit(tree.root)
        return gaps
    }

    /// The width to draw a tag gap at, on a line `available` wide whose text before the gap is
    /// `title` wide: nil, as written, when the line fits; else the tags at the right edge when
    /// they fit after one space; else one space, and the line wraps before the tags.
    public static func tagGapWidth(title: CGFloat, gap: CGFloat, space: CGFloat, tags: CGFloat, available: CGFloat) -> CGFloat? {
        if title + gap + tags <= available { return nil }
        if title + space + tags <= available { return available - title - tags }
        return space
    }
}
