#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import OrgHighlight
import OrgPresentation
import UIKit

extension MobileEditor {
    // MARK: - Shrunk table columns

    /// C-c TAB in a table: `org-table-toggle-column-width`; `shrink` for `org-table-shrink`,
    /// `expand` for `org-table-expand`.
    func tableColumnWidth(_ id: String) {
        switch shrunk.change(for: id, at: textView.selectedRange.location, in: textView.textStorage.string) {
        case .notInTable: onMessage?("Not in a table")
        case .set(let columns, let table): setShrunk(columns, in: table)
        case .ask(let table, let current, let max):
            ask(Prompt(key: "columns", message: "Column ranges (e.g. 2-4 6-):")) { [weak self] answer in
                guard let self, let answer else { return }
                self.setShrunk(ShrunkColumns.toggled(current, TableShrink.columns(answer, max: max)), in: table)
            }
        }
    }

    /// Narrows `columns` of `table` and widens its others.
    private func setShrunk(_ columns: [Int], in table: Range<Int>) {
        shrunk.set(columns, in: table, text: textView.textStorage.string)
        restyle(table)
        invalidateLayout(lines: [table])
    }

    /// Hides each shrunk segment's text and draws its display where the text was, as pretty
    /// entities draw theirs.
    func applyShrunk(_ range: Range<Int>, in storage: NSTextStorage) {
        guard !shrunk.isEmpty else { return }
        let cell = theme.column
        for segment in shrunk.segments where segment.range.overlaps(range) && segment.range.upperBound <= storage.length {
            let r = segment.range
            let shown = segment.display.count
            let kept = min(shown, r.count)
            if r.count > kept { storage.addAttributes(theme.hidden, range: NSRange(location: r.lowerBound, length: r.count - kept)) }
            guard kept > 0 else { continue }
            let visible = NSRange(location: r.upperBound - kept, length: kept)
            let color = storage.attribute(.foregroundColor, at: visible.location, effectiveRange: nil) as? UIColor ?? theme.foreground
            storage.addAttribute(.foregroundColor, value: UIColor.clear, range: visible)
            storage.addAttributes([.orgEntityDisplay: segment.display, .orgEntityColor: color], range: NSRange(location: visible.location, length: 1))
            if shown > kept { storage.addAttribute(.kern, value: CGFloat(shown - kept) * cell, range: NSRange(location: NSMaxRange(visible) - 1, length: 1)) }
        }
    }

    // MARK: - Inline images

    /// `includeLinked` as `org-toggle-inline-images` with a prefix argument: links with a
    /// description show their image too.
    func toggleImages(includeLinked: Bool = false) {
        showsImages.toggle()
        imagesIncludeLinked = showsImages && includeLinked
        restyleAll()
        if showsImages {
            let count = InlineImages.links(document.tree, in: 0..<textView.textStorage.length, includeLinked: imagesIncludeLinked,
                                           remote: options.remoteInlineImages != "skip", attachment: attachment)
                .count { loadImage($0.image.path) != nil }
            onMessage?("\(count) images displayed inline")
        } else {
            onMessage?("Inline image display turned off")
        }
    }

    /// `attachment:` links' files, for inline images.
    private var attachment: ((String, Int) -> String?)? {
        guard let attachmentPath else { return nil }
        let tree = document.tree
        return { attachmentPath($0, $1, tree) }
    }

    /// An image link's image here: remote ones as `org-display-remote-inline-images` says,
    /// restyled when they come.
    func loadImage(_ path: String) -> UIImage? {
        Self.loadImage(path, relativeTo: baseDirectory, remote: RemoteImages.Mode(rawValue: options.remoteInlineImages) ?? .skip) { [weak self] in
            guard let self, self.showsImages else { return }
            self.restyleAll()
        }
    }

    /// An image link's image, by its path or one relative to `baseDirectory`; an http(s)
    /// link's when `remote` allows it and it has come, `loaded` running when it does.
    static func loadImage(_ path: String, relativeTo baseDirectory: URL?, remote: RemoteImages.Mode = .skip, loaded: @escaping @MainActor () -> Void = {}) -> UIImage? {
        if path.contains("://") {
            guard let url = URL(string: path) else { return nil }
            return RemoteImages.shared.data(for: url, mode: remote, loaded: loaded).flatMap(UIImage.init(data:))
        }
        let expanded = OrgPaths.expandingTilde(path)
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if let baseDirectory {
            url = baseDirectory.appendingPathComponent(expanded)
        } else {
            return nil
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)" as NSString
        if let cached = Self.imageCache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        Self.imageCache.setObject(image, forKey: key)
        return image
    }

    /// Image links in `range` show their image, and the link is hidden unless the caret is on
    /// its line. A link that is all its line holds keeps the line, with the image over it, or
    /// under it while the link shows. A link in a line's text is as wide and as tall as its
    /// image, which goes under the paragraph while the link shows.
    func applyImages(_ range: Range<Int>, in storage: NSTextStorage, revealed: NSRange) {
        guard showsImages else { return }
        let text = storage.string as NSString
        let inset = textView.textContainerInset
        let maxWidth = max(80, textView.bounds.width - inset.left - inset.right - 40)
        let links = InlineImages.links(document.tree, in: range, includeLinked: imagesIncludeLinked, remote: options.remoteInlineImages != "skip", attachment: attachment)
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
                storage.removeAttribute(.orgEntityColor, range: link)
                storage.addAttributes(theme.hidden, range: link)
                storage.addAttribute(.underlineStyle, value: 0, range: link)
                let font = theme.font.withSize(Presentation.imageFontSize(height: size.height, pointSize: theme.font.pointSize, lineHeight: theme.font.lineHeight))
                let advance = text.substring(with: first).size(withAttributes: [.font: font]).width
                storage.addAttributes([.font: font, .kern: size.width - advance], range: first)
                continue
            }
            let content = NSRange(location: line.location, length: line.length - (text.substring(with: line).hasSuffix("\n") ? 1 : 0))
            // Invisible, keeping the line's height.
            if !shown {
                storage.addAttributes([.foregroundColor: UIColor.clear, .underlineStyle: 0], range: content)
            }
            storage.addAttribute(.orgImage, value: InlineImageBox(image: picture, size: size, below: shown), range: content)
            // The image sits where the line is, or under it while the link shows; the spacing
            // makes room for the rest of it.
            style.paragraphSpacing = shown ? size.height + 4 : max(0, size.height + 4 - theme.font.lineHeight)
        }
    }

    // MARK: - Truncation

    /// `toggle-truncate-lines`: long lines run off the right edge, scrolling sideways, instead
    /// of wrapping.
    var truncatesLines: Bool {
        get { (textView as? KeyedTextView)?.truncates ?? false }
        set {
            guard newValue != truncatesLines else { return }
            keepingTopLine {
                for case let view as KeyedTextView in textViews { view.truncates = newValue }
                for manager in layoutManagers { manager.invalidateLayout(for: manager.documentRange) }
            }
        }
    }

    // MARK: - Folding

    func setFolds(_ state: FoldState) {
        fold = state
        updateHidden()
    }

    func updateHidden() {
        let tree = document.tree
        let wrappers = fold.wrapperFolds.compactMap { Wrappers.starting(at: $0, in: tree)?.hidden }
        let before = hidden.folded
        let oldHidden = hidden.all
        hidden.set(
            isMarkdown
                ? Presentation.markdownHiddenRanges(markdown, folds: fold.folds, bodyFolds: fold.bodyFolds)
                : Presentation.hiddenRanges(tree, folds: fold.folds, bodyFolds: fold.bodyFolds, wrapperRanges: wrappers),
            folded: fold.folds.union(fold.bodyFolds).union(fold.wrapperFolds)
        )
        // Lines that gain or lose their `…` are made again: TextKit keeps a shown line's fragment.
        let storage = textView.textStorage
        let changed = before.symmetricDifference(hidden.folded).filter { $0 < storage.length }
        if !changed.isEmpty {
            let text = storage.string as NSString
            storage.beginEditing()
            for start in changed { storage.edited(.editedAttributes, range: text.lineRange(for: NSRange(location: start, length: 0)), changeInLength: 0) }
            storage.endEditing()
        }
        invalidateLayout(lines: Array(Set(oldHidden).symmetricDifference(hidden.all)))
        textView.setNeedsDisplay()
    }

    /// TAB at the caret: a heading cycles, a drawer or block opens or closes.
    @discardableResult
    func cycleAtCaret() -> Bool {
        guard let next = Presentation.cycle(at: textView.selectedRange.location, in: foldTree, fold) else { return false }
        setFolds(next)
        return true
    }

    /// Shift-TAB: overview, contents, show all.
    func cycleGlobal() {
        let (visibility, state) = Presentation.cycleGlobal(from: globalVisibility, in: foldTree, wrapperFolds: fold.wrapperFolds)
        globalVisibility = visibility
        setFolds(state)
    }

    /// Doom's `za`, `zo` (on a heading line), `zc` and `zO` (anywhere in a subtree), and `zR`,
    /// `zM`, `zr` and `zm` for the whole buffer.
    func foldCommand(_ id: String) {
        let caret = textView.selectedRange.location
        let tree = foldTree
        let length = (document.text as NSString).length
        let next: FoldState?
        if id == "org.fold.close" || id == "org.fold.open-subtree" {
            next = Presentation.outline(tree).last { $0.start <= caret && (caret < $0.end || $0.end == length) }
                .map { id == "org.fold.close" ? Presentation.hideSubtree($0.start, fold) : Presentation.showSubtree($0.start, in: tree, fold) }
        } else if id == "org.fold.open-all" {
            next = Presentation.showAllHeadings(fold)
        } else if id == "org.fold.close-all" {
            next = Presentation.hideSublevels(1, in: tree, fold)
        } else if id == "org.fold.more" || id == "org.fold.less" {
            let level = Presentation.foldLevel(in: tree, fold)
            next = Presentation.hideSublevels(id == "org.fold.more" ? level + 1 : max(1, level - 1), in: tree, fold)
        } else {
            next = Presentation.heading(containing: caret, in: tree).map {
                id == "org.fold.open" ? Presentation.openFold($0, in: tree, fold) : Presentation.toggleFold($0, in: tree, fold)
            }
        }
        if let next, next != fold { setFolds(next) }
    }

    /// Opens the folds hiding `offset`.
    func unfold(around offset: Int) {
        var state = fold
        for entry in Presentation.outline(foldTree) where entry.start < offset && offset < entry.end {
            state.folds.remove(entry.start)
            state.bodyFolds.remove(entry.start)
        }
        for start in state.wrapperFolds where Wrappers.starting(at: start, in: foldTree)?.hidden.contains(offset) == true {
            state.wrapperFolds.remove(start)
        }
        if state != fold { setFolds(state) }
    }

    /// Shows the heading at `offset`, unfolded, at the top.
    func reveal(_ offset: Int) {
        let length = textView.textStorage.length
        let target = min(max(0, offset), length)
        unfold(around: target)
        textView.selectedRange = NSRange(location: target, length: 0)
        textView.scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    /// The caret in hidden text: an arrow key moving forward into a fold jumps past it and
    /// moving back jumps to the end of the heading line, as on the Mac; a tap past a fold
    /// opens it.
    func selectionChanged() {
        let interval = Perf.begin("editor.selection")
        defer { interval.end() }
        snippetSelectionChanged()
        redrawSelectedBlocks()
        let caret = textView.selectedRange.location
        defer {
            previousCaret = textView.selectedRange.location
            movedByArrow = false
        }
        if let range = hidden.containing(caret) {
            if movedByArrow, textView.selectedRange.length == 0 {
                textView.selectedRange = NSRange(location: caret >= previousCaret ? range.upperBound : range.lowerBound - 1, length: 0)
            } else {
                unfold(around: caret)
            }
        }
        revealCaretLine()
    }
}
#endif
