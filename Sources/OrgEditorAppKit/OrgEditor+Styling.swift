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
        for change in changes {
            switch change {
            case .indent(let line): storage.addAttribute(.paragraphStyle, value: paragraphStyle(line.firstLine, line.wrapped), range: NSRange(line.range))
            case .role(let role, let range): theme.apply(role, to: storage, range: NSRange(range))
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
