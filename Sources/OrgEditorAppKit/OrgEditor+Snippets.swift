#if os(macOS)
import AppKit
import OrgCore

/// Snippets: TAB after a trigger where TAB means nothing else expands it, then TAB and S-TAB
/// move between its fields until the last is left, Escape is pressed, or the caret or an edit
/// leaves the snippet. The active field has a band behind it, the others a fainter one.
extension OrgEditor {
    /// TAB with no binding that runs here: expands the trigger before the caret, if any.
    func snippetTab(_ chord: KeyChord) -> Bool {
        guard isOrg, chord == KeyChord("TAB"), !textView.hasMarkedText() else { return false }
        let expand = ExpandSnippet()
        guard expand.applies(in: context()) else { return false }
        perform(expand)
        return true
    }

    /// Keys while a snippet's fields are filled in; nil lets the key through.
    func snippetKey(_ chord: KeyChord) -> Bool? {
        guard snippetSession != nil else { return nil }
        switch chord {
        case KeyChord("TAB"):
            nextSnippetField()
            return true
        case KeyChord("TAB", .shift):
            previousSnippetField()
            return true
        case KeyChord("ESC"):
            endSnippet()
            // Doom leaves insert state as well.
            return modal ? nil : true
        default:
            return nil
        }
    }

    func nextSnippetField() {
        guard var session = snippetSession else { return }
        switch session.next() {
        case .field(let range):
            snippetSession = session
            select(range)
        case .exit(let range):
            endSnippet()
            select(range)
        }
    }

    func previousSnippetField() {
        guard var session = snippetSession else { return }
        let range = session.previous()
        snippetSession = session
        select(range)
    }

    func startSnippet(_ session: SnippetSession) {
        snippetSession = session
        highlightSnippet()
    }

    func endSnippet() {
        snippetSession = nil
        highlightSnippet()
    }

    private func select(_ range: Range<Int>) {
        if hidden.containing(range.lowerBound) != nil { unfold(around: range.lowerBound) }
        setCaret(range.lowerBound)
        if !range.isEmpty { textView.setSelectedRange(NSRange(range)) }
        highlightSnippet()
    }

    /// An edit of the buffer; one outside the snippet ends it.
    func snippetEdited(_ edit: TextEdit) {
        guard var session = snippetSession else { return }
        snippetSession = session.map(edit) ? session : nil
    }

    /// After a change: mirrors take their field's new text.
    func updateSnippetMirrors() {
        guard let session = snippetSession, !updatingMirrors, !textView.hasMarkedText() else { return highlightSnippet() }
        let edits = session.mirrorEdits(in: document.text)
        if !edits.isEmpty {
            updatingMirrors = true
            let selected = textView.selectedRange()
            let caret = selected.location
            applyEdits(edits)
            updatingMirrors = false
            // The caret stays in the field, moved by mirrors before it.
            let shift = edits.filter { $0.range.upperBound <= caret }.reduce(0) { $0 + $1.replacement.utf16.count - $1.range.count }
            textView.setSelectedRange(NSRange(location: caret + shift, length: selected.length))
        }
        highlightSnippet()
    }

    /// The caret moved: outside the snippet, it ends.
    func snippetSelectionChanged() {
        guard let session = snippetSession, !updatingMirrors else { return }
        let selected = textView.selectedRange()
        if !session.contains(selected.location) || !session.contains(NSMaxRange(selected)) { endSnippet() }
    }

    /// Draws the fields of the session, and removes what was drawn for the last one.
    func highlightSnippet() {
        let length = utf16Length
        var covered = snippetHighlight.flatMap { $0.upperBound <= length ? $0 : $0.lowerBound < length ? $0.lowerBound..<length : nil }
        if let extent = snippetSession?.extent, extent.upperBound <= length {
            covered = covered.map { min($0.lowerBound, extent.lowerBound)..<max($0.upperBound, extent.upperBound) } ?? extent
        }
        for manager in layoutManagers {
            if let covered, let range = textRange(covered) {
                manager.removeRenderingAttribute(.backgroundColor, for: range)
            }
            guard let session = snippetSession else { continue }
            for (index, field) in session.fields.enumerated() {
                for (n, r) in field.ranges.enumerated() where !r.isEmpty && r.upperBound <= length {
                    guard let range = textRange(r) else { continue }
                    if index == session.active, n == 0 {
                        manager.addRenderingAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.35), for: range)
                    } else {
                        manager.addRenderingAttribute(.backgroundColor, value: NSColor.gray.withAlphaComponent(0.2), for: range)
                    }
                }
            }
        }
        snippetHighlight = snippetSession?.extent
    }

    private func textRange(_ r: Range<Int>) -> NSTextRange? {
        let manager = textContentStorage
        guard let start = manager.location(manager.documentRange.location, offsetBy: r.lowerBound),
              let end = manager.location(start, offsetBy: r.count) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// Chosen from the completion list: the trigger typed so far becomes the snippet.
    func expandCompleted(_ completion: Completion, _ trigger: String) {
        textView.setSelectedRange(NSRange(location: completion.range.lowerBound, length: completion.range.count))
        perform(ExpandNamedSnippet(trigger: trigger))
    }
}
#endif
