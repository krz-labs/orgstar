#if os(iOS)
import OrgCore
import UIKit

/// Snippets, as on the Mac: TAB on a hardware keyboard after a trigger where TAB means nothing
/// else expands it, then TAB and S-TAB (or `org.snippet.next-field` and
/// `org.snippet.previous-field`) move between its fields. Leaving the last field, Escape, or
/// the caret or an edit leaving the snippet ends it.
extension MobileEditor {
    /// TAB with no binding that runs here: expands the trigger before the caret, if any.
    func snippetTab(_ chord: KeyChord) -> Bool {
        guard isOrg, chord == KeyChord("TAB"), textView.markedTextRange == nil else { return false }
        let expand = ExpandSnippet()
        guard expand.applies(in: editContext()) else { return false }
        _ = perform(expand)
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
            selectSnippet(range)
        case .exit(let range):
            endSnippet()
            selectSnippet(range)
        }
    }

    func previousSnippetField() {
        guard var session = snippetSession else { return }
        let range = session.previous()
        snippetSession = session
        selectSnippet(range)
    }

    func startSnippet(_ session: SnippetSession) {
        snippetSession = session
        highlightSnippet()
    }

    func endSnippet() {
        snippetSession = nil
        highlightSnippet()
    }

    private func selectSnippet(_ range: Range<Int>) {
        unfold(around: range.lowerBound)
        textView.selectedRange = NSRange(range)
        textView.scrollRangeToVisible(textView.selectedRange)
        highlightSnippet()
    }

    /// An edit of the buffer; one outside the snippet ends it.
    func snippetEdited(_ edit: TextEdit) {
        guard var session = snippetSession else { return }
        snippetSession = session.map(edit) ? session : nil
    }

    /// After typing: mirrors take their field's new text.
    func updateSnippetMirrors() {
        guard let session = snippetSession, !updatingMirrors, textView.markedTextRange == nil else { return highlightSnippet() }
        let edits = session.mirrorEdits(in: document.text)
        if !edits.isEmpty {
            updatingMirrors = true
            let selected = textView.selectedRange
            applyEdits(edits)
            updatingMirrors = false
            let shift = edits.filter { $0.range.upperBound <= selected.location }.reduce(0) { $0 + $1.replacement.utf16.count - $1.range.count }
            textView.selectedRange = NSRange(location: selected.location + shift, length: selected.length)
        }
        highlightSnippet()
    }

    /// The caret moved: outside the snippet, it ends.
    func snippetSelectionChanged() {
        guard let session = snippetSession, !updatingMirrors else { return }
        let selected = textView.selectedRange
        if !session.contains(selected.location) || !session.contains(NSMaxRange(selected)) { endSnippet() }
    }

    /// Draws the active field with a band and the others with a fainter one.
    func highlightSnippet() {
        let length = (textView.textStorage.string as NSString).length
        var covered = snippetHighlight.flatMap { $0.upperBound <= length ? $0 : $0.lowerBound < length ? $0.lowerBound..<length : nil }
        if let extent = snippetSession?.extent, extent.upperBound <= length {
            covered = covered.map { min($0.lowerBound, extent.lowerBound)..<max($0.upperBound, extent.upperBound) } ?? extent
        }
        for manager in layoutManagers {
            func textRange(_ r: Range<Int>) -> NSTextRange? {
                guard let content = manager.textContentManager,
                      let start = content.location(content.documentRange.location, offsetBy: r.lowerBound),
                      let end = content.location(start, offsetBy: r.count) else { return nil }
                return NSTextRange(location: start, end: end)
            }
            if let covered, let range = textRange(covered) {
                manager.removeRenderingAttribute(.backgroundColor, for: range)
            }
            guard let session = snippetSession else { continue }
            for (index, field) in session.fields.enumerated() {
                for (n, r) in field.ranges.enumerated() where !r.isEmpty && r.upperBound <= length {
                    guard let range = textRange(r) else { continue }
                    if index == session.active, n == 0 {
                        manager.addRenderingAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.3), for: range)
                    } else {
                        manager.addRenderingAttribute(.backgroundColor, value: UIColor.systemGray.withAlphaComponent(0.2), for: range)
                    }
                }
            }
        }
        snippetHighlight = snippetSession?.extent
    }
}

extension MobileEditor {
    func textViewDidChange(_ textView: UITextView) {
        guard textView === self.textView else { return }
        updateSnippetMirrors()
        textTyped()
    }
}
#endif
