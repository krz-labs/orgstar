#if os(macOS)
import AppKit
import OrgCore
import OrgPresentation

/// A slide of `SlideShow` as styled text: the editor's theme with its body at `size` points,
/// the heading at the size of a first-level heading, images on lines of their own.
public enum SlideText {
    @MainActor
    public static func attributed(
        _ slide: SlideShow.Slide, tree: OrgTree, spec: ThemeSpec, size: CGFloat, width: CGFloat, directory: URL?,
        options: EditingOptions = .org, highlighter: (any CodeHighlighter)? = nil
    ) -> NSAttributedString {
        var scaled = spec
        scaled.fontSize = max(6, Int(size.rounded()))
        scaled.headingSizeStep = max(1, Int((size * 0.2).rounded()))
        scaled.lineSpacing = max(0, Int((CGFloat(spec.lineSpacing) * size / CGFloat(max(6, spec.fontSize))).rounded()))
        let theme = Theme(scaled)
        let display = ReadingText.Display(options: options, highlighter: highlighter)
        let out = NSTextStorage()
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = size * 0.4

        func styled(_ range: Range<Int>, heading: Bool) -> NSAttributedString {
            let storage = NSTextStorage()
            for segment in ReadingText.segments(tree, in: range, display: display) {
                let start = storage.length
                storage.append(NSAttributedString(string: segment.text, attributes: theme.base))
                let r = NSRange(location: start, length: storage.length - start)
                guard r.length > 0 else { continue }
                if heading { theme.apply(.heading(level: 1), to: storage, range: r) }
                for role in segment.roles.sorted(by: { depth($0) < depth($1) }) {
                    if case .heading = role { continue }
                    theme.apply(role, to: storage, range: r)
                }
                if let superscript = segment.superscript, let font = storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont {
                    storage.addAttribute(.baselineOffset, value: (superscript ? 0.3 : -0.3) * font.pointSize, range: r)
                    storage.addAttribute(.font, value: font.withSize(font.pointSize * 0.7), range: r)
                }
            }
            return storage
        }
        func newline() {
            if out.length > 0, !out.string.hasSuffix("\n") { out.append(NSAttributedString(string: "\n", attributes: theme.base)) }
        }

        if let title = slide.title {
            let heading = NSMutableAttributedString(string: title + "\n", attributes: theme.base)
            let font = NSFontManager.shared.convert(theme.body.withSize(size * 2), toHaveTrait: .boldFontMask)
            heading.addAttributes([.font: font, .foregroundColor: theme.color("heading-1") ?? theme.foreground, .paragraphStyle: centered], range: NSRange(location: 0, length: heading.length))
            out.append(heading)
        }
        if !slide.byline.isEmpty {
            out.append(NSAttributedString(string: slide.byline.joined(separator: "\n") + "\n\n",
                                          attributes: [.font: theme.body, .foregroundColor: theme.color("metadata") ?? theme.foreground, .paragraphStyle: centered]))
        }
        if let heading = slide.heading {
            out.append(styled(heading, heading: true))
            out.append(NSAttributedString(string: "\n\n", attributes: theme.base))
        }
        for piece in slide.pieces {
            switch piece {
            case .text(let range):
                newline()
                out.append(styled(range, heading: false))
            case .image(let path, let wanted):
                newline()
                let url = path.hasPrefix("/") || path.hasPrefix("~") ? URL(fileURLWithPath: OrgPaths.expandingTilde(path))
                    : directory?.appendingPathComponent(path.hasPrefix("file:") ? String(path.dropFirst(5)) : path)
                guard let url, let image = NSImage(contentsOf: url) else {
                    out.append(NSAttributedString(string: path, attributes: theme.base))
                    continue
                }
                let natural = image.size
                let shown = Presentation.imageSize(natural: natural, width: wanted, maxWidth: width)
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(origin: .zero, size: shown)
                out.append(NSAttributedString(attachment: attachment))
            }
        }
        return out
    }

    /// The editor's background in `spec`.
    @MainActor
    public static func background(_ spec: ThemeSpec) -> NSColor {
        Theme(spec).color("background") ?? .textBackgroundColor
    }

    /// How deep a role's text usually nests, so inner roles are applied last.
    static func depth(_ role: StyleRole) -> Int {
        switch role {
        case .heading: 0
        case .metadata, .keyword, .comment, .block, .table, .rule: 1
        case .blockDelimiter, .link, .bold, .italic, .underline, .strikeThrough, .timestamp, .footnote, .target, .macro, .latex: 2
        default: 3
        }
    }
}
#endif
