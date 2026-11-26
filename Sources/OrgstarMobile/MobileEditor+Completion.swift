#if os(iOS)
import OrgApp
import GameController
import OrgCore
import UIKit

/// The completion list under the caret, as on the Mac: keys on a hardware keyboard pick a
/// row, and a tap inserts one.
final class CompletionListView: UIView {
    static let rows = 8
    private(set) var list: CompletionList
    private let stack = UIStackView()
    var onChoose: ((String) -> Void)?

    init(_ completion: Completion, selection: Int?) {
        list = CompletionList(completion, selection: selection)
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        layer.borderColor = UIColor.separator.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 6
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 6
        stack.axis = .vertical
        stack.alignment = .fill
        addSubview(stack)
        accessibilityIdentifier = "completion"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var completion: Completion { list.completion }

    func update(_ completion: Completion) { list.update(completion) }

    func key(_ chord: KeyChord) -> CompletionList.Action { list.key(chord) }

    /// Lays the rows out under `caret`, or above it when there isn't room below, kept inside
    /// `bounds`: the part of the text view not under the keyboard and the key bar.
    func show(under caret: CGRect, within bounds: CGRect, font: UIFont) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var width: CGFloat = 80
        for index in list.visible(rows: Self.rows) {
            let candidate = completion.candidates[index]
            let label = UILabel()
            label.text = " " + completion.label(candidate) + (completion.kind == .snippet ? "  " + String(localized: "snippet", comment: "Marks a snippet in the completion list") : "") + " "
            label.font = font
            label.lineBreakMode = .byTruncatingTail
            label.isUserInteractionEnabled = true
            label.backgroundColor = index == list.selection ? .tintColor : .clear
            label.textColor = index == list.selection ? .white : .label
            label.tag = index
            label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
            label.heightAnchor.constraint(equalToConstant: max(28, font.lineHeight + 6)).isActive = true
            stack.addArrangedSubview(label)
            width = max(width, label.intrinsicContentSize.width)
        }
        width = min(width, bounds.width - 16)
        let height = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
        let x = min(max(bounds.minX + 8, caret.minX), bounds.maxX - width - 8)
        let below = caret.maxY + 2
        let y = below + height <= bounds.maxY || caret.minY - 2 - height < bounds.minY ? below : caret.minY - 2 - height
        frame = CGRect(x: x, y: y, width: width, height: height)
        stack.frame = CGRect(origin: .zero, size: frame.size)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let index = gesture.view?.tag, completion.candidates.indices.contains(index) else { return }
        onChoose?(completion.candidates[index])
    }
}

extension MobileEditor {
    /// Org files complete Org's positions; other files only words.
    var completesOrg: Bool { fileName.map(DocumentSession.isOrgPath) ?? true }

    /// `completion-at-point`: one candidate is inserted, several are listed.
    func completeAtPoint() {
        guard completesOrg, let completion = OrgCompletion.at(editContext()), !completion.candidates.isEmpty || completion.query != nil else {
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

    /// Words in a list, the first chosen, or with `last` the last.
    func completeWord(last: Bool) {
        guard let completion = Dabbrev.completion(editContext(), others: otherBuffers()) else {
            closeCompletion()
            return fail("No possible abbreviation preceding point")
        }
        if completion.candidates.isEmpty, completionSource == nil { return fail("No dynamic expansion for `\(completion.typed)' found") }
        openCompletion(completion, select: last ? completion.candidates.count - 1 : 0)
    }

    func openCompletion(_ completion: Completion, select: Int? = nil) {
        completionFetched = nil
        suggestions.dismissed = false
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

    private func fetchedCompletion(kind: Completion.Kind, start: Int, select: Int?) {
        guard textView.selectedRange.length == 0 else { return }
        let open = completionList?.completion
        guard open == nil || (open?.kind == kind && open?.range.lowerBound == start) else { return }
        guard let current = CompletionFlow.current(editContext(), open: nil, words: kind == .word, others: otherBuffers, fetched: completionFetched),
              current.kind == kind, current.range.lowerBound == start, !current.candidates.isEmpty else { return }
        showCompletion(current, select: open == nil ? select.map { $0 < 0 || $0 >= current.candidates.count ? current.candidates.count - 1 : $0 } : nil)
    }

    func showCompletion(_ completion: Completion, select: Int? = nil) {
        let view: CompletionListView
        if let open = completionList {
            open.update(completion)
            view = open
        } else {
            view = CompletionListView(completion, selection: select)
            view.onChoose = { [weak self, weak view] candidate in
                guard let self, let view else { return }
                let completion = view.completion
                self.closeCompletion()
                self.insertCompletion(completion, candidate)
            }
            completionList = view
            textView.addSubview(view)
        }
        let row = SuggestionRow.usesRow(hardwareKeyboard: GCKeyboard.coalesced != nil)
        view.isHidden = row
        suggestions.completion = row ? view.completion : nil
        guard !row, let position = textView.position(from: textView.beginningOfDocument, offset: completion.range.lowerBound) else { return }
        let caret = textView.caretRect(for: position)
        let insets = textView.adjustedContentInset
        let visible = CGRect(x: textView.contentOffset.x, y: textView.contentOffset.y + insets.top,
                             width: textView.bounds.width, height: textView.bounds.height - insets.top - insets.bottom)
        view.show(under: caret, within: visible, font: theme.font)
    }

    func closeCompletion() {
        completionTimer?.invalidate()
        completionTimer = nil
        completionTask?.cancel()
        completionList?.removeFromSuperview()
        completionList = nil
        suggestions.completion = nil
        suggestions.dismissed = false
    }

    /// A candidate tapped in the suggestion row, inserted as one chosen from the list.
    func chooseSuggestion(_ candidate: String) {
        guard let completion = completionList?.completion else { return }
        closeCompletion()
        insertCompletion(completion, candidate)
    }

    /// After typing: the open list follows the text; otherwise, as the settings say, a list
    /// opens after a pause once enough is typed.
    func textTyped() {
        completionTimer?.invalidate()
        completionTimer = nil
        if completionList != nil { return refreshCompletion() }
        guard let delay = CompletionAuto.delay(options.completion, modal: modal, insertState: vim.mode == .insert, isOrg: completesOrg) else { return }
        completionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoComplete() }
        }
    }

    func autoComplete() {
        guard completionList == nil, textView.selectedRange.length == 0, textView.markedTextRange == nil else { return }
        let context = editContext()
        var completion = completesOrg ? OrgCompletion.at(context) : nil
        if options.completion.words, completion.map({ $0.candidates.isEmpty && $0.query == nil }) ?? true {
            completion = Dabbrev.completion(context, others: otherBuffers())
        }
        guard CompletionAuto.opens(completion, options.completion), let completion else { return }
        openCompletion(completion)
    }

    func refreshCompletion() {
        guard let open = completionList else { return }
        guard textView.selectedRange.length == 0,
              let completion = CompletionFlow.current(editContext(), open: open.completion, words: false, others: otherBuffers, fetched: completionFetched),
              completion.range.lowerBound == open.completion.range.lowerBound, !completion.candidates.isEmpty else {
            closeCompletion()
            return
        }
        showCompletion(completion)
    }

    func insertCompletion(_ completion: Completion, _ candidate: String) {
        defer {
            completionTimer?.invalidate()
            completionTimer = nil
        }
        if completion.kind == .snippet {
            textView.selectedRange = NSRange(location: completion.range.lowerBound, length: completion.range.count)
            _ = perform(ExpandNamedSnippet(trigger: candidate))
            return
        }
        if completion.kind == .idLink || completion.kind == .denoteLink { return insertLink(completion, candidate) }
        let (text, caret) = completion.insertion(candidate)
        applyEdits([TextEdit(range: completion.range, replacement: text)])
        textView.selectedRange = NSRange(location: completion.range.lowerBound + caret, length: 0)
    }

    /// A link to the chosen heading or note, with an ID given to a heading without one.
    func insertLink(_ completion: Completion, _ candidate: String) {
        guard let item = completion.item(candidate) else { return }
        var created: [TextEdit] = []
        var id = item.id
        if id == nil, completion.kind == .idLink {
            if item.path == (options.filePath ?? "") {
                let newID = UUID().uuidString.lowercased()
                if let edits = CompletionFlow.createID(item, in: editContext(), newID: newID) {
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
        applyEdits([edit])
        textView.selectedRange = NSRange(location: edit.range.lowerBound + edit.replacement.utf16.count, length: 0)
    }

    /// `dabbrev-expand`, repeated right after for the next expansion.
    func dabbrevExpand() {
        closeCompletion()
        let caret = textView.selectedRange.location
        let repeated = dabbrevRevision == document.revision && dabbrev?.end == caret
        if !repeated {
            guard let expansion = DabbrevExpansion(editContext(), others: otherBuffers()) else { return fail("No possible abbreviation preceding point") }
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
        if (document.text as NSString).substring(with: NSRange(edit.range)) != edit.replacement { applyEdits([edit]) }
        textView.selectedRange = NSRange(location: expansion.end, length: 0)
        dabbrevRevision = document.revision
        if exhausted { fail(expansion.failure) }
    }

    /// Keys while the list is open; nil lets the key through.
    func completionKey(_ chord: KeyChord) -> Bool? {
        guard let open = completionList else { return nil }
        let completion = open.completion
        switch open.key(chord) {
        case .shown:
            showCompletion(open.completion)
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
