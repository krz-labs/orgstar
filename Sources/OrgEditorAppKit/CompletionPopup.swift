#if os(macOS)
import AppKit
import OrgCore

/// The candidate list under the caret, as corfu shows it: at most 16 rows, nothing selected
/// until C-n or an arrow picks one.
@MainActor
final class CompletionPopup {
    static let rows = 16
    let window: NSPanel
    private let stack = NSStackView()
    private(set) var list: CompletionList

    var completion: Completion { list.completion }
    var selected: String? { list.selected }

    init(_ completion: Completion, selection: Int? = nil) {
        list = CompletionList(completion, selection: selection)
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 20), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier("completion")
        window.hasShadow = true
        window.backgroundColor = .controlBackgroundColor
        window.isReleasedWhenClosed = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        window.contentView = stack
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.borderColor = NSColor.separatorColor.cgColor
        window.contentView?.layer?.borderWidth = 1
    }

    func update(_ completion: Completion) { list.update(completion) }

    func move(_ delta: Int) { list.move(delta) }

    func key(_ chord: KeyChord) -> CompletionList.Action { list.key(chord) }

    /// Lays the rows out and puts the list under `caret`, a rectangle in screen coordinates.
    func show(under caret: NSRect, in parent: NSWindow?, font: NSFont) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let candidates = completion.candidates
        var width: CGFloat = 80
        for index in list.visible(rows: Self.rows) {
            let candidate = candidates[index]
            let label = NSTextField(labelWithString: " " + completion.label(candidate) + (completion.kind == .snippet ? "  " + String(localized: "snippet", comment: "Marks a snippet in the completion list") : "") + " ")
            label.font = font
            label.drawsBackground = index == list.selection
            label.backgroundColor = .selectedContentBackgroundColor
            label.textColor = index == list.selection ? .alternateSelectedControlTextColor : .labelColor
            label.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(label)
            width = max(width, label.intrinsicContentSize.width)
        }
        width = min(width, 120 * font.maximumAdvancement.width)
        for label in stack.arrangedSubviews { label.widthAnchor.constraint(equalToConstant: width).isActive = true }
        let height = stack.fittingSize.height
        window.setContentSize(NSSize(width: width, height: height))
        window.setFrameTopLeftPoint(NSPoint(x: caret.minX, y: caret.minY - 2))
        if window.parent == nil { parent?.addChildWindow(window, ordered: .above) }
        window.orderFront(nil)
    }

    func close() {
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }
}

extension OrgEditor {
    /// `completion-at-point`: one candidate is inserted, several are listed. Candidates from
    /// the index join the list when it answers.
    func completeAtPoint() {
        guard let completion = OrgCompletion.at(context()), !completion.candidates.isEmpty || completion.query != nil else {
            closeCompletion()
            onMessage?("No match")
            return
        }
        if completion.query == nil, completion.candidates.count == 1 {
            closeCompletion()
            insertCompletion(completion, completion.candidates[0])
            return
        }
        openCompletion(completion)
    }

    /// Words from the buffers and the index in a list, the first chosen, or with `last` the
    /// last (Doom's C-n and C-p in insert state).
    func completeWord(last: Bool) {
        guard let completion = Dabbrev.completion(context(), others: otherBuffers()) else {
            closeCompletion()
            return fail("No possible abbreviation preceding point")
        }
        if completion.candidates.isEmpty, completionSource == nil { return fail("No dynamic expansion for `\(completion.typed)' found") }
        openCompletion(completion, select: last ? completion.candidates.count - 1 : 0)
    }

    /// Shows `completion` when it has candidates, and asks the index for more.
    func openCompletion(_ completion: Completion, select: Int? = nil) {
        completionFetched = nil
        if !completion.candidates.isEmpty { showCompletion(completion, select: select) }
        guard let query = completion.query, let source = completionSource else {
            if completion.candidates.isEmpty { closeCompletion() }
            return
        }
        let start = completion.range.lowerBound, kind = completion.kind
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            let result = await source(query)
            guard !Task.isCancelled, let self else { return }
            self.completionFetched = (kind, start, result)
            self.fetchedCompletion(kind: kind, start: start, select: select)
        }
    }

    /// The index answered: the list shows what it adds, or opens with it.
    private func fetchedCompletion(kind: Completion.Kind, start: Int, select: Int?) {
        guard textView.selectedRange().length == 0 else { return }
        let open = completionPopup?.completion
        guard open == nil || (open?.kind == kind && open?.range.lowerBound == start) else { return }
        let words = kind == .word
        guard let current = CompletionFlow.current(context(), open: nil, words: words, others: otherBuffers, fetched: completionFetched),
              current.kind == kind, current.range.lowerBound == start, !current.candidates.isEmpty else { return }
        showCompletion(current, select: open == nil ? select.map { $0 < 0 || $0 >= current.candidates.count ? current.candidates.count - 1 : $0 } : nil)
    }

    func showCompletion(_ completion: Completion, select: Int? = nil) {
        if let popup = completionPopup { popup.update(completion) } else { completionPopup = CompletionPopup(completion, selection: select) }
        let screen = textView.firstRect(forCharacterRange: NSRange(location: completion.range.lowerBound, length: 0), actualRange: nil)
        completionPopup?.show(under: screen, in: textView.window, font: theme.font)
    }

    func closeCompletion() {
        completionTimer?.cancel()
        completionTask?.cancel()
        completionPopup?.close()
        completionPopup = nil
    }

    /// After typing: the open list follows the text; otherwise, as the completion settings
    /// say, a list opens after a pause once enough is typed (corfu-auto).
    func textTyped() {
        completionTimer?.cancel()
        if completionPopup != nil {
            refreshCompletion()
            return
        }
        guard let delay = CompletionAuto.delay(options.completion, modal: modal, insertState: vim.mode == .insert, isOrg: isOrg) else { return }
        let work = DispatchWorkItem { [weak self] in self?.autoComplete() }
        completionTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func autoComplete() {
        guard completionPopup == nil, textView.selectedRange().length == 0 else { return }
        let context = context()
        var completion = isOrg ? OrgCompletion.at(context) : nil
        if options.completion.words, completion.map({ $0.candidates.isEmpty && $0.query == nil }) ?? true {
            completion = Dabbrev.completion(context, others: otherBuffers())
        }
        guard CompletionAuto.opens(completion, options.completion), let completion else { return }
        openCompletion(completion)
    }

    func refreshCompletion() {
        guard let popup = completionPopup else { return }
        guard textView.selectedRange().length == 0,
              let completion = CompletionFlow.current(context(), open: popup.completion, words: false, others: otherBuffers, fetched: completionFetched),
              completion.range.lowerBound == popup.completion.range.lowerBound, !completion.candidates.isEmpty else {
            closeCompletion()
            return
        }
        showCompletion(completion)
    }

    func insertCompletion(_ completion: Completion, _ candidate: String) {
        defer { completionTimer?.cancel() }
        if completion.kind == .snippet { return expandCompleted(completion, candidate) }
        if completion.kind == .idLink || completion.kind == .denoteLink { return insertLink(completion, candidate) }
        let (text, caret) = completion.insertion(candidate)
        let range = NSRange(location: completion.range.lowerBound, length: completion.range.count)
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        setCaret(completion.range.lowerBound + caret)
    }

    /// A link to the chosen heading or note, its title the description. A heading without an
    /// ID gets one first, here or in its file, as `org-id-get-create` would.
    func insertLink(_ completion: Completion, _ candidate: String) {
        guard let item = completion.item(candidate) else { return }
        var created: [TextEdit] = []
        var id = item.id
        if id == nil, completion.kind == .idLink {
            if item.path == (options.filePath ?? "") {
                let newID = UUID().uuidString.lowercased()
                if let edits = CompletionFlow.createID(item, in: context(), newID: newID) {
                    applyEdits(edits)
                    created = edits
                    id = newID
                }
            } else {
                id = createID?(item)
            }
        }
        guard let id else { return fail("Can't give \(item.title) an ID") }
        let edit = CompletionFlow.linkEdit(completion, item, id: id, after: created)
        let range = NSRange(edit.range)
        guard textView.shouldChangeText(in: range, replacementString: edit.replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: edit.replacement)
        textView.didChangeText()
        setCaret(edit.range.lowerBound + edit.replacement.utf16.count)
    }

    /// `dabbrev-expand`: the word before the caret completed from the buffers, then the
    /// index; again right after, the next expansion in its place.
    func dabbrevExpand() {
        closeCompletion()
        let caret = textView.selectedRange().location
        let repeated = lastCommand?.id == "editor.dabbrev-expand" && lastCommand?.revision == document.revision && dabbrev?.end == caret
        if !repeated {
            guard let expansion = DabbrevExpansion(context(), others: otherBuffers()) else { return fail("No possible abbreviation preceding point") }
            dabbrev = expansion
            if let source = completionSource {
                let abbrev = expansion.abbrev, start = expansion.start
                completionTask = Task { [weak self] in
                    let result = await source(.words(abbrev))
                    guard !Task.isCancelled, let self, self.dabbrev?.start == start else { return }
                    self.dabbrev?.add(result.strings)
                }
            }
        }
        guard var expansion = dabbrev else { return }
        let (edit, exhausted) = expansion.advance()
        dabbrev = expansion
        let range = NSRange(edit.range)
        if (document.text as NSString).substring(with: range) != edit.replacement, textView.shouldChangeText(in: range, replacementString: edit.replacement) {
            textView.textStorage?.replaceCharacters(in: range, with: edit.replacement)
            textView.didChangeText()
        }
        setCaret(expansion.end)
        completionTimer?.cancel()
        if exhausted { fail(expansion.failure) }
    }

    /// Keys while the list is open. Nil lets the key through.
    func completionKey(_ chord: KeyChord) -> Bool? {
        guard let popup = completionPopup else { return nil }
        let completion = popup.completion
        switch popup.key(chord) {
        case .shown:
            showCompletion(popup.completion)
            return true
        case .insert(let candidate):
            closeCompletion()
            insertCompletion(completion, candidate)
            return true
        case .common(let common):
            insertCompletion(completion, common)
            refreshCompletion()
            return true
        case .close:
            closeCompletion()
            return true
        case .closeAndPass:
            closeCompletion()
            return nil
        case .pass:
            return nil
        }
    }
}
#endif
