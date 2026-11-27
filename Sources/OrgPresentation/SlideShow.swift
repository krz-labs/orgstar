import Foundation
import OrgCore

/// The open file as slides, as org-tree-slide shows it: one heading at a time with its text but
/// not its children, which are slides of their own; a title slide first from `#+TITLE`,
/// `#+AUTHOR` and `#+DATE` and the text before the first heading. Headings tagged with an
/// excluded tag (`noexport`) and COMMENT headings are left out with their children. Planning
/// lines, drawers, keywords and comments don't show; `#+BEGIN_NOTES` blocks are the slide's
/// speaker notes.
public enum SlideShow {
    public struct Slide: Sendable, Equatable {
        public enum Piece: Sendable, Equatable {
            /// File text, shown as the editor styles it.
            case text(Range<Int>)
            /// An image link alone on its line: the image's path as written.
            case image(String, width: Int?)
        }

        /// The heading line from its keyword to the end of its title; nil on the title slide.
        public var heading: Range<Int>?
        public var level: Int
        /// Where the heading starts; nil on the title slide.
        public var start: Int?
        public var pieces: [Piece]
        /// The text of the slide's notes blocks.
        public var notes: String
        /// The title slide's title, author and date.
        public var title: String?
        public var byline: [String] = []
    }

    public static func slides(_ tree: OrgTree, settings: OrgSettings = .default) -> [Slide] {
        let text = tree.text as NSString
        let options = ExportOptions.parse(settings.setupKeywords + tree.text)
        let meta = HTMLExport.metadata(tree.text, settings: settings)
        var slides: [Slide] = []
        if let zeroth = tree.root.children.first(where: { $0.kind == .zerothSection }) {
            let (pieces, notes) = content(zeroth.children, tree)
            let byline = [meta.author, meta.date].compactMap { $0 }.filter { !$0.isEmpty }
            if meta.title != nil || !byline.isEmpty || !pieces.isEmpty {
                slides.append(Slide(level: 0, pieces: pieces, notes: notes, title: meta.title, byline: byline))
            }
        }
        func visit(_ section: SyntaxNode) {
            guard let heading = section.firstChild(.heading) else { return }
            let tags = heading.tokens.first { $0.kind == .tags }?.text.split(separator: ":").map(String.init) ?? []
            let title = heading.firstChild(.title)?.text.trimmingCharacters(in: .whitespaces) ?? ""
            if tags.contains(where: options.excludeTags.contains) || title == "COMMENT" || title.hasPrefix("COMMENT ") { return }
            let level = heading.tokens.first { $0.kind == .stars }?.text.count ?? 1
            let stars = heading.tokens.first { $0.kind == .stars }?.range ?? heading.range.lowerBound..<heading.range.lowerBound
            let lineEnd = heading.tokens.first { $0.kind == .tags }?.range.lowerBound
                ?? NSMaxRange(text.lineRange(for: NSRange(location: heading.range.lowerBound, length: 0)))
            var end = lineEnd
            while end > stars.upperBound, let scalar = Unicode.Scalar(text.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
            let start = min(stars.upperBound + 1, end)
            let (pieces, notes) = content(section.children.filter { $0.kind != .heading && $0.kind != .section }, tree)
            slides.append(Slide(heading: start..<end, level: level, start: heading.range.lowerBound, pieces: pieces, notes: notes))
            for child in section.children where child.kind == .section { visit(child) }
        }
        for section in tree.root.children where section.kind == .section { visit(section) }
        return slides
    }

    /// What `nodes` show on a slide, image links on lines of their own as images, and the text
    /// of their notes blocks.
    static func content(_ nodes: [SyntaxNode], _ tree: OrgTree) -> (pieces: [Slide.Piece], notes: String) {
        let text = tree.text as NSString
        var pieces: [Slide.Piece] = []
        var notes: [String] = []
        for node in nodes {
            switch node.kind {
            case .planning, .propertyDrawer, .drawer, .clock, .keyword, .affiliatedKeyword, .comment:
                continue
            case .block:
                let first = node.text.prefix { $0 != "\n" }.lowercased().trimmingCharacters(in: .whitespaces)
                if first.hasPrefix("#+begin_notes") {
                    let lines = node.text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                    let body = lines.prefix { !$0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("#+end_notes") }
                    notes.append(body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                    continue
                }
                if first.hasPrefix("#+begin_comment") { continue }
            default: break
            }
            var from = node.range.lowerBound
            let images = Presentation.imagePlacements(InlineImages.links(tree, in: node.range), in: text).filter(\.ownLine)
            for placement in images where placement.link.range.lowerBound >= from {
                let line = text.lineRange(for: NSRange(location: placement.link.range.lowerBound, length: 0))
                if line.location > from { pieces.append(.text(from..<line.location)) }
                pieces.append(.image(placement.link.image.path, width: placement.link.image.width))
                from = min(NSMaxRange(line), node.range.upperBound)
            }
            if from < node.range.upperBound { pieces.append(.text(from..<node.range.upperBound)) }
        }
        // Blank lines at the end of the slide's text.
        while case .text(let range)? = pieces.last {
            var end = range.upperBound
            while end > range.lowerBound, let scalar = Unicode.Scalar(text.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
            if end > range.lowerBound {
                pieces[pieces.count - 1] = .text(range.lowerBound..<end)
                break
            }
            pieces.removeLast()
        }
        return (pieces, notes.filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }
}
