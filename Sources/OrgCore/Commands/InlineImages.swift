import Foundation

/// Image links shown as images (`org-link-preview-region`, Org 9.8.7): `file:` and
/// `attachment:` links to an image, and the width `#+ATTR_ORG: :width` asks for.
public enum InlineImages {
    public struct Image: Sendable, Equatable {
        public let path: String
        public let width: Int?
    }

    /// A link shown as an image, and the text the image stands for.
    public struct Link: Sendable, Equatable {
        public let range: Range<Int>
        public let image: Image
    }

    static let extensions = "png|jpe?g|gif|svg|webp|tiff?|bmp|heic|avif"
    static let imagePath = try! NSRegularExpression(pattern: "^(?:file:)?([^\\]\\n]+\\.(?:\(extensions)))$", options: .caseInsensitive)
    static let bracketLink = try! NSRegularExpression(pattern: "\\[\\[([^\\]\\n]+)\\](?:\\[([^\\]\\n]+)\\])?\\]")

    /// The image links overlapping `range`, in order. A link without a description shows its
    /// path. One with a description shows the description, and the image stands for the
    /// description alone, when that is a single `file:` or `attachment:` link, plain or in
    /// angle brackets; with `includeLinked` (`org-toggle-inline-images` with a prefix
    /// argument) it shows its path instead. With `remote`, http and https paths too
    /// (`org-display-remote-inline-images` other than `skip`). `attachment` gives an
    /// `attachment:` link's file from its name and offset, as `org-attach-expand` does;
    /// without it those links don't show.
    public static func links(
        _ tree: OrgTree, in range: Range<Int>, includeLinked: Bool = false, remote: Bool = false, attachment: ((String, Int) -> String?)? = nil
    ) -> [Link] {
        var out: [Link] = []
        func add(_ target: String?, _ link: Range<Int>, widthFrom line: Int?) {
            guard let target, let m = imagePath.firstMatch(in: target, range: NSRange(location: 0, length: (target as NSString).length)) else { return }
            var path = (target as NSString).substring(with: m.range(at: 1))
            if path.hasPrefix("attachment:") {
                guard let file = attachment?(String(path.dropFirst("attachment:".count)), link.lowerBound) else { return }
                path = file
            }
            if path.contains("://") {
                guard remote, path.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil else { return }
            }
            out.append(Link(range: link, image: Image(path: path, width: line.flatMap { width(above: $0, in: tree.text as NSString) })))
        }
        func bracket(path: String, _ link: Range<Int>, description: String?, _ described: Range<Int>?, widthFrom line: Int?) {
            if let description, let described, !includeLinked {
                add(plainTarget(description), described, widthFrom: line)
            } else {
                add(path, link, widthFrom: line)
            }
        }
        // Org text the tree keeps as a line: its bracket links.
        func scan(_ line: SyntaxToken, widthFrom start: Int?) {
            let content = line.text as NSString
            for m in bracketLink.matches(in: line.text, range: NSRange(location: 0, length: content.length)) {
                let offset = line.range.lowerBound
                let described = m.range(at: 2).location == NSNotFound ? nil : m.range(at: 2)
                bracket(path: content.substring(with: m.range(at: 1)), (offset + m.range.location)..<(offset + NSMaxRange(m.range)),
                        description: described.map(content.substring(with:)), described.map { (offset + $0.location)..<(offset + NSMaxRange($0)) }, widthFrom: start)
            }
        }
        func walk(_ node: SyntaxNode, paragraph: Int?) {
            switch node.kind {
            case .link:
                if let path = node.linkPath {
                    let description = node.firstChild(.linkDescription)
                    bracket(path: path, node.range, description: description?.text, description?.range, widthFrom: paragraph)
                } else {
                    add(plainTarget(node.text), node.range, widthFrom: paragraph)
                }
            case .block:
                // Quote, center, verse and special blocks hold Org text.
                guard case .token(let opening)? = node.green.children.first,
                      opening.text.range(of: "^[ \\t]*#\\+begin_(?:src|example|export|comment)\\b", options: [.regularExpression, .caseInsensitive]) == nil else { return }
                let lines = node.tokens.filter { $0.kind == .text }
                for line in lines.dropFirst().dropLast() where line.range.overlaps(range) { scan(line, widthFrom: line.range.lowerBound) }
            case .affiliatedKeyword:
                // A caption is Org text too.
                for line in node.tokens where line.kind == .text && line.text.range(of: "^[ \\t]*#\\+CAPTION(?:\\[.*\\])?:", options: [.regularExpression, .caseInsensitive]) != nil {
                    scan(line, widthFrom: nil)
                }
            case .paragraph:
                // An item's first paragraph starts after the bullet and takes no affiliated keywords.
                let start = node.parent?.kind == .item ? nil : node.range.lowerBound
                for child in node.children(overlapping: range) { walk(child, paragraph: start) }
            default:
                for child in node.children(overlapping: range) { walk(child, paragraph: paragraph) }
            }
        }
        walk(tree.root, paragraph: nil)
        return out
    }

    /// A plain or angle link with an explicit `file:` or `attachment:` type.
    static func plainTarget(_ link: String) -> String? {
        var target = Substring(link)
        if target.hasPrefix("<"), target.hasSuffix(">") { target = target.dropFirst().dropLast() }
        guard target.hasPrefix("file:") || target.hasPrefix("attachment:"), !target.contains(where: { $0 == "\n" || $0 == "<" || $0 == ">" }),
              link.hasPrefix("<") || !target.contains(where: \.isWhitespace) else { return nil }
        return String(target)
    }

    /// `#+ATTR_ORG: :width N` in the affiliated keywords above the line at `lineStart`.
    static func width(above lineStart: Int, in text: NSString) -> Int? {
        var width: Int?
        var at = lineStart
        while at > 0 {
            let previous = text.lineRange(for: NSRange(location: at - 1, length: 0))
            let keyword = text.substring(with: previous)
            guard keyword.range(of: "^[ \\t]*#\\+[A-Za-z_]+:", options: .regularExpression) != nil else { break }
            if width == nil, let w = keyword.firstMatch(of: /(?i)^[ \t]*#\+ATTR_ORG:.*:width[ \t]+([0-9]+)/) { width = Int(w.1) }
            at = previous.location
        }
        return width
    }

    /// `#+STARTUP: inlineimages` or `noinlineimages`, if the file says.
    public static func startup(_ tree: OrgTree) -> Bool? {
        var shown: Bool?
        for word in tree.settings.startup {
            if word.lowercased() == "inlineimages" { shown = true }
            if word.lowercased() == "noinlineimages" { shown = false }
        }
        return shown
    }
}
