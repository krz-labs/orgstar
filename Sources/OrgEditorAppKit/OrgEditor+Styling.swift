#if os(macOS)
import AppKit
import OrgCore
import OrgPresentation

extension OrgEditor {
    // MARK: - Styling

    func restyleOutsideEditing(_ range: Range<Int>) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        restyle(range, in: storage)
        storage.endEditing()
    }

    /// Sets attributes for whole lines in `range`. Safe inside `didProcessEditing`, where
    /// attribute changes are allowed and characters must not change.
    func restyle(_ range: Range<Int>, in storage: NSTextStorage) {
        guard !range.isEmpty else { return }
        let whole = NSRange(range)
        storage.setAttributes(theme.base, range: whole)
        guard isOrg else {
            for run in plainRuns() where run.range.overlaps(range) {
                guard let clipped = clip(run.range, to: range) else { continue }
                theme.apply(.syntax(run.category), to: storage, range: clipped)
            }
            return
        }
        let revealed = caretLine
        let (changes, scriptExclusions) = Presentation.styleChanges(
            document.tree, in: range, highlighter: highlighter, indented: indented, hideStars: hideStars,
            showMarkup: showMarkup, options: options, revealed: revealed.location..<NSMaxRange(revealed)
        )
        var tags: [Range<Int>] = []
        for change in changes {
            switch change {
            case .indent(let line): storage.addAttribute(.paragraphStyle, value: paragraphStyle(line.firstLine, line.wrapped), range: NSRange(line.range))
            case .role(let role, let range):
                theme.apply(role, to: storage, range: NSRange(range))
                if role == .tags { tags.append(range) }
            case .hidden(let range): storage.addAttributes(theme.hidden, range: NSRange(range))
            }
        }
        if theme.mixedPitch {
            for prefix in Presentation.fixedPitchPrefixes(storage.string as NSString, in: range) {
                guard let clipped = clip(prefix, to: range) else { continue }
                storage.addAttribute(.font, value: theme.fixedPitch(storage, clipped), range: clipped)
            }
        }
        if !showMarkup, options.prettyEntities { prettify(range, in: storage, revealed: revealed, scriptExclusions: scriptExclusions) }
        applyShrunk(range, in: storage)
        applyHighlights(range, in: storage)
        applyImages(range, in: storage, revealed: revealed)
        applyLatex(range, in: storage, revealed: revealed)
        fitTagGaps(tags, in: storage)
    }

    /// The text container's width, for tag gaps: the narrowest view's, as images are sized.
    var tagGapAvailableWidth: CGFloat {
        let widths = textViews.compactMap { view in view.textContainer.map { $0.size.width - 2 * $0.lineFragmentPadding } }
        return widths.filter { $0 > 0 }.min() ?? 0
    }

    /// Draws the spaces before each heading's tags in `tags` as one gap that fits the view
    /// (`Presentation.tagGapWidth`): all but the last space hidden, the last widened.
    func fitTagGaps(_ tags: [Range<Int>], in storage: NSTextStorage) {
        guard !tags.isEmpty else { return }
        let available = tagGapAvailableWidth
        guard available > 0 else { return }
        // The storage's own string: `string` copies the whole text.
        let text = storage.mutableString
        for range in tags where range.upperBound <= text.length {
            guard let gap = Presentation.tagGap(tags: range, in: text) else { continue }
            let line = text.lineRange(for: NSRange(location: gap.gap.lowerBound, length: 0))
            let indent = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
            // Without the paragraph style, whose indent is taken from the width apart.
            func width(_ range: Range<Int>) -> CGFloat {
                let part = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: NSRange(range)))
                part.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: part.length))
                return part.size().width
            }
            // Spaces measured before the tags: trailing spaces may not count.
            let last = gap.gap.upperBound - 1
            let title = width(line.location..<gap.gap.lowerBound), tagsWidth = width(gap.tags)
            let space = width(last..<gap.tags.upperBound) - tagsWidth
            // A point to spare, so rounding doesn't wrap the tags.
            guard let shown = Presentation.tagGapWidth(
                title: title, gap: width(line.location..<gap.tags.upperBound) - title - tagsWidth, space: space, tags: tagsWidth,
                available: available - indent - 1
            ) else { continue }
            storage.addAttributes(theme.hidden, range: NSRange(gap.gap.lowerBound..<last))
            storage.addAttribute(.kern, value: max(0, shown - space), range: NSRange(location: last, length: 1))
        }
    }

    /// Draws tag gaps again once the view's width has changed, after the layout pass that changed it.
    func refitTagGaps() {
        guard isOrg, !fittingTagGaps else { return }
        fittingTagGaps = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fittingTagGaps = false
            guard self.tagGapWidth != self.tagGapAvailableWidth else { return }
            let text = self.document.text as NSString
            for gap in Presentation.tagGaps(self.document.tree) where gap.tags.upperBound <= text.length {
                let line = text.lineRange(for: NSRange(location: gap.gap.lowerBound, length: 0))
                self.restyleOutsideEditing(line.location..<NSMaxRange(line))
            }
            self.tagGapWidth = self.tagGapAvailableWidth
        }
    }

    /// `org-pretty-entities`: entities drawn as their character over the entity's last
    /// character (the rest hidden), sub/superscripts raised without their markers.
    private func prettify(_ range: Range<Int>, in storage: NSTextStorage, revealed: NSRange, scriptExclusions: [Range<Int>]) {
        let runs = Presentation.prettyRuns(
            storage.string as NSString, in: range, revealedLine: revealed.location, inBlock: { shaded.containing($0) != nil },
            scriptExclusions: scriptExclusions, subSuperscriptsNeedBraces: options.subSuperscriptsNeedBraces
        )
        for (lineStart, run) in runs {
            switch run {
            case .entity(let r, let display):
                let start = lineStart + r.lowerBound
                let last = lineStart + r.upperBound - 1
                if last > start { storage.addAttributes(theme.hidden, range: NSRange(location: start, length: last - start)) }
                storage.addAttributes([.foregroundColor: NSColor.clear, .orgEntityDisplay: display], range: NSRange(location: last, length: 1))
            case .script(let markers, let body, let superscript):
                for marker in markers {
                    storage.addAttributes(theme.hidden, range: NSRange(location: lineStart + marker.lowerBound, length: marker.count))
                }
                let size = theme.font.pointSize
                storage.addAttributes([
                    .font: theme.mixedPitch ? theme.body.withSize(size * 0.7) : NSFont.monospacedSystemFont(ofSize: size * 0.7, weight: .regular),
                    .baselineOffset: (superscript ? 0.3 : -0.3) * size,
                ], range: NSRange(location: lineStart + body.lowerBound, length: body.count))
            }
        }
    }

    /// Moving to another line shows its markup and hides the last one's.
    func revealCaretLine() {
        // LaTeX previews and images show their source on the caret's line whether or not markup shows.
        guard !showMarkup || showsLatex || showsImages, isOrg else { return }
        let line = caretLine
        guard line != revealedLine else { return }
        let text = textView.string as NSString
        // The old line may have moved with edits since; restyle the line now at its start.
        let old = revealedLine.flatMap { $0.location <= text.length ? text.lineRange(for: NSRange(location: $0.location, length: 0)) : nil }
        revealedLine = line
        for range in [old, line].compactMap({ $0 }) where range.location < styledUpTo {
            restyleOutsideEditing(range.location..<NSMaxRange(range))
        }
    }

    /// Code highlights for the whole file in plain mode.
    private func plainRuns() -> [(range: Range<Int>, category: SyntaxCategory)] {
        guard case .plain(let language?) = mode, let highlighter else { return [] }
        if let codeRuns, codeRuns.revision == document.revision { return codeRuns.runs }
        let runs = highlighter.highlights(language: language, code: document.text)
        codeRuns = (document.revision, runs)
        return runs
    }

    private func paragraphStyle(_ firstLine: Int, _ wrapped: Int) -> NSParagraphStyle {
        let key = IndentKey(firstLine: firstLine, wrapped: wrapped)
        if let style = paragraphStyles[key] { return style }
        let style = theme.paragraphStyle(firstLine: firstLine, wrapped: wrapped)
        paragraphStyles[key] = style
        return style
    }

    private func clip(_ run: Range<Int>, to range: Range<Int>) -> NSRange? {
        let clipped = run.clamped(to: range)
        return clipped.isEmpty ? nil : NSRange(clipped)
    }
}
#endif
