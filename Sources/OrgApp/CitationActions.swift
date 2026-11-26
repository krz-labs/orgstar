import OrgCore
import SwiftUI

/// A followed citation's bibliography entry and what it offers to open.
public struct CitationEntry: Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var summary: String
    /// The entry's files, its DOI and URL, then the entry in its bibliography file.
    public var links: [(label: String, link: OrgLink)]

    public init(_ entry: BibEntry, text: String? = nil) {
        key = entry.key
        summary = entry.summary
        var links: [(String, OrgLink)] = entry.files.map { file in
            (String(localized: "Open \((file as NSString).lastPathComponent)", comment: "Opens a citation's file"), OrgLink(type: "file", path: file, raw: "file:" + file))
        }
        if let doi = entry.doi { links.append((String(localized: "Open DOI", comment: "Opens a citation's DOI"), OrgLink(type: "doi", path: doi, raw: "doi:" + doi))) }
        if let url = entry.url, url.contains(":") { links.append((String(localized: "Open URL", comment: "Opens a citation's URL"), Links.parse(plain: url))) }
        let line = text.flatMap { Bibliography.line(of: entry.key, in: $0, json: (entry.file as NSString).pathExtension.lowercased() == "json") }
        links.append((String(localized: "Show in Bibliography", comment: "Opens the bibliography file at a citation's entry"),
                      OrgLink(type: "file", path: entry.file, searchOption: line.map(String.init), raw: "file:" + entry.file)))
        self.links = links
    }
}

/// Insert Citation… and following citations, as `org-cite-insert` and `org-cite-follow` with
/// the basic processor, with the platform's questions. Bibliography files are read off the
/// main thread.
@MainActor
public struct CitationActions {
    public var session: DocumentSession
    /// The editor's text and caret.
    public var context: () -> EditContext?
    /// Runs a command in the editor.
    public var perform: (any OrgCommand) -> Void
    public var show: (String) -> Void
    public var ask: (Prompt, @escaping (String?) -> Void) -> Void
    /// Shows a followed citation's entry.
    public var present: (CitationEntry) -> Void
    /// In the Mac sandbox, asks for access to bibliography files outside the sidebar's
    /// folders. False when one is still out of reach.
    public var reach: ([String]) -> Bool = { _ in true }
    public var cache = BibliographyCache.shared

    public init(
        session: DocumentSession, context: @escaping () -> EditContext?, perform: @escaping (any OrgCommand) -> Void, show: @escaping (String) -> Void,
        ask: @escaping (Prompt, @escaping (String?) -> Void) -> Void, present: @escaping (CitationEntry) -> Void
    ) {
        self.session = session
        self.context = context
        self.perform = perform
        self.show = show
        self.ask = ask
        self.present = present
    }

    /// `org-cite-basic`'s styles, as `org-cite-basic--complete-style` offers them.
    nonisolated static let styles = ["author", "noauthor", "nocite", "note", "numeric", "text", "nil"]

    /// The bibliography files of `text`, a file at `path`: its `#+bibliography:` files, then
    /// `org-cite-global-bibliography`'s.
    nonisolated static func files(_ text: String, path: String?) -> [String] {
        Bibliography.files(in: text, directory: path.map { ($0 as NSString).deletingLastPathComponent }, global: OrgPreferences.citeGlobalBibliography())
    }

    /// Insert Citation…: on a citation's style a new style; otherwise a key from the
    /// bibliography, and for a new citation a style; for a new reference a prefix and suffix.
    public func insert() {
        guard let context = context() else { return show(String(localized: "No file is open")) }
        let place = Citations.place(at: context.caret, tree: context.tree)
        let stylePrompt = Prompt(key: "style", message: String(localized: "Style (empty for default): ", comment: "Insert Citation… asks for a citation style"),
                                 choices: Self.styles, requireMatch: false)
        if place == .style {
            return ask(stylePrompt) { style in
                guard let style else { return }
                perform(InsertCitation(key: nil, style: style))
            }
        }
        let files = Self.files(context.text, path: session.path)
        guard !files.isEmpty else { return show(String(localized: "No bibliography set", comment: "Insert Citation… in a file without #+bibliography")) }
        guard reach(files) else { return }
        let cache = cache
        Task {
            let entries = await cache.load(files)
            guard !entries.isEmpty else { return show(String(localized: "No bibliography set", comment: "Insert Citation… in a file without #+bibliography")) }
            let labels = entries.map(\.label)
            ask(Prompt(key: "key", message: String(localized: "Key: ", comment: "Insert Citation… asks for a bibliography entry"), choices: labels)) { answer in
                guard let answer, let index = labels.firstIndex(of: answer) else { return }
                let key = entries[index].key
                guard place != .key else { return perform(InsertCitation(key: key)) }
                affixes { prefix, suffix in
                    guard place == .new else { return perform(InsertCitation(key: key, prefix: prefix, suffix: suffix)) }
                    ask(stylePrompt) { style in
                        guard let style else { return }
                        perform(InsertCitation(key: key, style: style, prefix: prefix, suffix: suffix))
                    }
                }
            }
        }
    }

    /// Asks for the new reference's prefix and suffix, either of which may be empty.
    private func affixes(_ then: @escaping (String, String) -> Void) {
        ask(Prompt(key: "prefix", message: String(localized: "Prefix (empty for none): ", comment: "Insert Citation… asks for text before the key"), requireMatch: false)) { prefix in
            guard let prefix else { return }
            ask(Prompt(key: "suffix", message: String(localized: "Suffix (empty for none): ", comment: "Insert Citation… asks for text after the key"), requireMatch: false)) { suffix in
                guard let suffix else { return }
                then(prefix, suffix)
            }
        }
    }

    /// Following a citation: its entry, from the file's bibliographies, with its file, DOI,
    /// URL and place in the bibliography file. Of several keys, one is asked for first, as
    /// `org-cite-basic-goto` does.
    public func follow(_ keys: [String]) {
        guard keys.count == 1 else {
            return ask(Prompt(key: "key", message: String(localized: "Select citation key: ", comment: "Following a citation with several keys"), choices: keys)) { key in
                guard let key else { return }
                follow([key])
            }
        }
        let key = keys[0]
        guard let document = session.document else { return show(String(localized: "No file is open")) }
        let files = Self.files(document.text, path: session.path)
        guard reach(files) else { return }
        let cache = cache
        Task {
            let found = await Self.find(key, in: files, cache: cache)
            guard let found else { return show(String(localized: "Cannot find citation key: \(key)", comment: "Following a citation whose key no bibliography has")) }
            present(found)
        }
    }

    @concurrent
    nonisolated static func find(_ key: String, in files: [String], cache: BibliographyCache) async -> CitationEntry? {
        guard let entry = cache.entries(files).first(where: { $0.key == key }) else { return nil }
        return CitationEntry(entry, text: (try? String(contentsOfFile: entry.file, encoding: .utf8)))
    }
}

extension View {
    /// Shows a followed citation's entry with a button for each thing it offers to open.
    public func citationAlert(_ entry: Binding<CitationEntry?>, open: @escaping (OrgLink) -> Void) -> some View {
        alert(entry.wrappedValue.map { "@" + $0.key } ?? "", isPresented: Binding(get: { entry.wrappedValue != nil }, set: { if !$0 { entry.wrappedValue = nil } }),
              presenting: entry.wrappedValue) { shown in
            ForEach(shown.links.indices, id: \.self) { index in
                Button(shown.links[index].label) { open(shown.links[index].link) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { shown in
            Text(shown.summary)
        }
    }
}
