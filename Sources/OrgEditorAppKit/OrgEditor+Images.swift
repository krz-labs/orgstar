#if os(macOS)
import AppKit
import OrgCore
import OrgPresentation

extension OrgEditor {
    // MARK: - Inline images

    private static let imageCache = NSCache<NSString, NSImage>()

    /// `includeLinked` as `org-toggle-inline-images` with a prefix argument: links with a
    /// description show their image too.
    func toggleImages(includeLinked: Bool = false) {
        showsImages.toggle()
        imagesIncludeLinked = showsImages && includeLinked
        refreshImages()
        if showsImages {
            let count = InlineImages.links(document.tree, in: 0..<utf16Length, includeLinked: imagesIncludeLinked, remote: remote, attachment: attachment)
                .count { loadImage($0.image.path) != nil }
            onMessage?("\(count) images displayed inline")
        } else {
            onMessage?("Inline image display turned off")
        }
    }

    public func refreshImages() {
        keepingTopLine {
            restyleOutsideEditing(0..<utf16Length)
            invalidateAllLayout()
        }
        redrawViews()
    }

    /// The widest an image shows: the text's width, less a margin.
    private var imageMaxWidth: CGFloat { max(80, (textView.textContainer?.size.width ?? 600) - 40) }

    /// Sizes images again once the view's width has changed, after the layout pass that changed it.
    func fitImages() {
        guard showsImages, !fittingImages else { return }
        fittingImages = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fittingImages = false
            if self.showsImages, self.imageWidth != self.imageMaxWidth { self.refreshImages() }
        }
    }

    /// `attachment:` links' files, for inline images.
    private var attachment: ((String, Int) -> String?)? {
        guard let attachmentPath else { return nil }
        let tree = document.tree
        return { attachmentPath($0, $1, tree) }
    }

    /// Whether http(s) links show, as `org-display-remote-inline-images` says.
    private var remote: Bool { options.remoteInlineImages != "skip" }

    private func loadImage(_ path: String) -> NSImage? {
        if path.contains("://") {
            guard let url = URL(string: path) else { return nil }
            let mode = RemoteImages.Mode(rawValue: options.remoteInlineImages) ?? .skip
            let data = RemoteImages.shared.data(for: url, mode: mode) { [weak self] in
                guard let self, self.showsImages else { return }
                self.refreshImages()
            }
            return data.flatMap(NSImage.init(data:))
        }
        let expanded = OrgPaths.expandingTilde(path)
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : (baseDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appendingPathComponent(expanded)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)" as NSString
        if let cached = Self.imageCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        Self.imageCache.setObject(image, forKey: key)
        return image
    }

    /// Image links in `range` show their image, and the link is hidden unless the caret is on
    /// its line. A link that is all its line holds keeps the line, with the image over it, or
    /// under it while the link shows. A link in a line's text is as wide and as tall as its
    /// image, which goes under the paragraph while the link shows.
    func applyImages(_ range: Range<Int>, in storage: NSTextStorage, revealed: NSRange) {
        guard showsImages, isOrg else { return }
        let text = storage.string as NSString
        let maxWidth = imageMaxWidth
        imageWidth = maxWidth
        let links = InlineImages.links(document.tree, in: range, includeLinked: imagesIncludeLinked, remote: remote, attachment: attachment)
        for placement in Presentation.imagePlacements(links, in: text) {
            guard let picture = loadImage(placement.link.image.path) else { continue }
            let size = Presentation.imageSize(natural: picture.size, width: placement.link.image.width, maxWidth: maxWidth)
            let link = NSRange(placement.link.range)
            let line = text.lineRange(for: link)
            let shown = NSLocationInRange(revealed.location, line)
            let style = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            defer { storage.addAttribute(.paragraphStyle, value: style, range: line) }
            guard placement.ownLine else {
                let first = NSRange(location: link.location, length: 1)
                storage.addAttribute(.orgImage, value: InlineImageBox(image: picture, size: size, below: shown, inText: true), range: first)
                if shown {
                    style.paragraphSpacing = max(style.paragraphSpacing, size.height + 4)
                    continue
                }
                // Pretty entities in the link would draw over the image.
                storage.removeAttribute(.orgEntityDisplay, range: link)
                storage.addAttributes(theme.hidden, range: link)
                storage.addAttribute(.underlineStyle, value: 0, range: link)
                let lineHeight = theme.font.ascender - theme.font.descender + theme.font.leading
                let font = NSFont(descriptor: theme.font.fontDescriptor, size: Presentation.imageFontSize(height: size.height, pointSize: theme.font.pointSize, lineHeight: lineHeight)) ?? theme.font
                let advance = text.substring(with: first).size(withAttributes: [.font: font]).width
                storage.addAttributes([.font: font, .kern: size.width - advance], range: first)
                continue
            }
            let content = NSRange(location: line.location, length: line.length - (text.substring(with: line).hasSuffix("\n") ? 1 : 0))
            // Invisible, keeping the line's height, so line numbers stay apart.
            if !shown {
                storage.addAttributes([.foregroundColor: NSColor.clear, .underlineStyle: 0], range: content)
            }
            storage.addAttribute(.orgImage, value: InlineImageBox(image: picture, size: size, below: shown), range: content)
            // The image sits where the line is, or under it while the link shows; the spacing
            // makes room for the rest of it.
            style.paragraphSpacing = shown ? size.height + 4 : max(0, size.height + 4 - theme.font.boundingRectForFont.height)
        }
    }
}
#endif
