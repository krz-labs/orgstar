import Foundation
import OrgCore
import OrgIndex

/// What completion takes from the index and the other files, for both apps' editors.
public enum CompletionSources {
    /// Answers `query` from `index`, leaving out `path`, whose buffer gives its own. Reads the
    /// index, so it runs off the main actor; a failed read answers nothing.
    @concurrent
    public nonisolated static func answer(_ query: CompletionQuery, index: IndexStore, excluding path: String?) async -> CompletionResult {
        switch query {
        case .linkTargets:
            return CompletionResult(items: (try? index.linkTargets(excluding: path)) ?? [])
        case .denoteNotes:
            let notes = ((try? index.denoteNodes()) ?? []).filter { $0.location.path != path }
            return CompletionResult(items: notes.map { CompletionItem(title: $0.title, id: $0.id, path: $0.location.path, start: 0, heading: false) })
        case .propertyValues(let name):
            guard let values = try? index.propertyValues(name, excluding: path) else { return CompletionResult() }
            return CompletionResult(strings: values.allowed + values.used)
        case .words(let prefix):
            return CompletionResult(strings: (try? index.words(prefix, excluding: path)) ?? [])
        }
    }

    /// `org-id-get-create` on a heading in another file, through its buffer when it's open:
    /// the new ID, or nil when the heading isn't where the index put it.
    @MainActor
    public static func createID(_ item: CompletionItem, session: DocumentSession, newID: String = UUID().uuidString.lowercased()) -> String? {
        guard item.heading, let text = session.text(of: item.path) else { return nil }
        let ns = text as NSString
        guard item.start < ns.length else { return nil }
        var end = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: item.start, length: 0))
        let line = ns.substring(with: NSRange(location: item.start, length: end - item.start))
        guard line.hasPrefix("*"), line.contains(item.title) else { return nil }
        guard case .commit = session.perform(CreateID(newID: { newID }), path: item.path, at: item.start, expect: (item.start, line)) else { return nil }
        return newID
    }

    /// The text of the open buffers other than `path`, for word completion.
    @MainActor
    public static func otherBuffers(_ session: DocumentSession, excluding path: String?) -> [String] {
        session.openPaths.filter { $0 != path }.compactMap { session.text(of: $0) }
    }
}
