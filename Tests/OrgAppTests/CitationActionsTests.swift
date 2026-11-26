import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// Insert Citation… and following citations, with the questions answered here.
@MainActor
struct CitationActionsTests {
    static let bib = #"""
        @book{smith1999,
          author = {Smith, John},
          title = {The Book},
          publisher = {Pub House},
          year = 1999,
          url = {https://example.org/book},
          doi = {10.1000/book},
          file = {:papers/smith.pdf:PDF}
        }
        @article{doe2020,
          author = {Doe, Jane},
          title = {A Study},
          year = {2020}
        }
        """#

    final class Log {
        var prompts: [Prompt] = []
        var messages: [String] = []
    }

    func setUp(_ text: String, caret: Int? = nil) throws -> (Folder, DocumentSession, () -> EditContext) {
        let folder = try Folder()
        try folder.write("refs.bib", Self.bib)
        let doc = try folder.write("doc.org", text)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.url.appendingPathComponent(".r")))
        session.open(doc.path)
        let context = {
            let caret = caret ?? text.utf16.count
            return EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
        }
        return (folder, session, context)
    }

    /// The text after `command` runs in `context`.
    func applying(_ command: any OrgCommand, _ context: EditContext) -> String? {
        guard case .commit(let result) = command.run(in: context) else { return nil }
        var text = context.text
        for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { text = edit.apply(to: text) }
        return text
    }

    @Test func insertsAKeyChosenFromTheBibliography() async throws {
        let (folder, session, context) = try setUp("#+bibliography: refs.bib\nSee ")
        defer { withExtendedLifetime(folder) {} }
        let log = Log()
        let command: (any OrgCommand)? = await withCheckedContinuation { done in
            let actions = CitationActions(
                session: session, context: { context() }, perform: { done.resume(returning: $0) }, show: { log.messages.append($0) },
                ask: { prompt, reply in
                    log.prompts.append(prompt)
                    switch prompt.key {
                    case "key": reply(prompt.choices.first { $0.hasPrefix("smith1999") })
                    case "prefix": reply("see")
                    case "suffix": reply("p. 5")
                    default: reply("t")
                    }
                }, present: { _ in })
            actions.insert()
        }
        #expect(log.prompts.map(\.key) == ["key", "prefix", "suffix", "style"])
        #expect(log.prompts[0].choices == ["doe2020  Doe, Jane  2020  A Study", "smith1999  Smith, John  1999  The Book"])
        #expect(log.prompts[3].choices == ["author", "noauthor", "nocite", "note", "numeric", "text", "nil"])
        #expect(applying(try #require(command), context()) == "#+bibliography: refs.bib\nSee [cite/t:see @smith1999 p. 5]")
    }

    @Test func onAKeyReplacesItWithoutAskingMore() async throws {
        let text = "#+bibliography: refs.bib\nSee [cite:@doe2020]"
        let (folder, session, context) = try setUp(text, caret: text.utf16.count - 3)
        defer { withExtendedLifetime(folder) {} }
        let log = Log()
        let command: (any OrgCommand)? = await withCheckedContinuation { done in
            CitationActions(
                session: session, context: { context() }, perform: { done.resume(returning: $0) }, show: { log.messages.append($0) },
                ask: { prompt, reply in
                    log.prompts.append(prompt)
                    reply(prompt.choices.first { $0.hasPrefix("smith1999") })
                }, present: { _ in }).insert()
        }
        #expect(log.prompts.map(\.key) == ["key"])
        #expect(applying(try #require(command), context()) == "#+bibliography: refs.bib\nSee [cite:@smith1999]")
    }

    @Test func withoutABibliographySaysSo() throws {
        let (folder, session, context) = try setUp("No keywords here ")
        defer { withExtendedLifetime(folder) {} }
        let log = Log()
        CitationActions(session: session, context: { context() }, perform: { _ in }, show: { log.messages.append($0) },
                        ask: { prompt, _ in log.prompts.append(prompt) }, present: { _ in }).insert()
        #expect(log.messages == ["No bibliography set"])
        #expect(log.prompts.isEmpty)
    }

    @Test func followingShowsTheEntryAndWhatItOffers() async throws {
        let (folder, session, context) = try setUp("#+bibliography: refs.bib\nSee [cite:@smith1999; @doe2020]")
        let log = Log()
        let entry: CitationEntry = await withCheckedContinuation { done in
            CitationActions(session: session, context: { context() }, perform: { _ in }, show: { log.messages.append($0) },
                            ask: { prompt, reply in
                                log.prompts.append(prompt)
                                reply("smith1999")
                            }, present: { done.resume(returning: $0) }).follow(["smith1999", "doe2020"])
        }
        #expect(log.prompts.map(\.choices) == [["smith1999", "doe2020"]])
        #expect(entry.key == "smith1999")
        #expect(entry.summary == "Smith, John (1999). The Book. Pub House.")
        let bib = folder.url.appendingPathComponent("refs.bib").path
        #expect(entry.links.map(\.label) == ["Open smith.pdf", "Open DOI", "Open URL", "Show in Bibliography"])
        #expect(entry.links.map(\.link) == [
            OrgLink(type: "file", path: folder.url.appendingPathComponent("papers/smith.pdf").path, raw: "file:" + folder.url.appendingPathComponent("papers/smith.pdf").path),
            OrgLink(type: "doi", path: "10.1000/book", raw: "doi:10.1000/book"),
            Links.parse(plain: "https://example.org/book"),
            OrgLink(type: "file", path: bib, searchOption: "1", raw: "file:" + bib),
        ])
        #expect(session.follow(entry.links[1].link, workspace: nil, isText: { _ in false }) == .openExternally(URL(string: "https://doi.org/10.1000/book")!))

        let missing: String = await withCheckedContinuation { done in
            CitationActions(session: session, context: { context() }, perform: { _ in }, show: { done.resume(returning: $0) },
                            ask: { _, _ in }, present: { _ in }).follow(["nope"])
        }
        #expect(missing == "Cannot find citation key: nope")
    }

    @Test func completionAnswersWithTheKeys() async throws {
        let folder = try Folder()
        defer { withExtendedLifetime(folder) {} }
        let bib = try folder.write("refs.bib", Self.bib)
        let workspace = try WorkspaceModel(directory: nil)
        let result = await CompletionSources.answer(.citationKeys([bib.path]), index: workspace.index, excluding: nil)
        #expect(result.strings == ["doe2020", "smith1999"])
        #expect(result.annotations["smith1999"] == "Smith, John  1999  The Book")
    }
}
