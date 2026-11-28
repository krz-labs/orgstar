import Foundation
import OrgConfig
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

@MainActor
struct TriageTests {
    let notes: Folder
    let session: DocumentSession
    let workspace: WorkspaceModel
    let agenda: AgendaModel
    let defaults: UserDefaults
    let today = Days.absolute(year: 2026, month: 11, day: 28)
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 9))!

    init() async throws {
        notes = try Folder()
        session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.saveMode = .explicit
        workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        agenda = AgendaModel(workspace: workspace)
        agenda.agendaFiles = []
        agenda.hiddenFolders = []
        defaults = UserDefaults(suiteName: "triage-\(UUID().uuidString)")!
    }

    static let inbox = """
        #+ARCHIVE: archive.org::
        * Projects
        ** TODO Garden
        * Inbox
        ** Call the plumber
        *** A note under it
        ** TODO Buy stamps :errand:
        ** Read the paper
        * Later

        """

    func text(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

    func template(_ target: CaptureTemplate.Target) -> CaptureTemplate {
        CaptureTemplate(key: "t", name: "Todo", target: target, template: "* TODO %?")
    }

    /// A model loaded with `templates`, or with the view `triage-view` names.
    func triage(_ templates: [CaptureTemplate], views: [AgendaViewDefinition] = []) async -> TriageModel {
        let model = TriageModel(session: session, workspace: workspace)
        await model.load(views: views, templates: templates, agenda: agenda, defaults: defaults, now: now)
        return model
    }

    func titles(_ model: TriageModel) -> [String] { model.items[model.position...].map(\.text) }

    // MARK: - The queue

    @Test func theHeadlineTargetsChildrenInFileOrder() async throws {
        let file = try notes.write("inbox.org", Self.inbox)
        let model = await triage([template(.headline(file: file.path, headline: "Inbox"))])
        #expect(titles(model) == ["Call the plumber", "TODO Buy stamps", "Read the paper"])
        #expect(model.remaining == 3)
        #expect(model.title == "inbox.org ▸ Inbox")
        #expect(model.problem == nil)
    }

    @Test func otherTargets() async throws {
        let file = try notes.write("inbox.org", Self.inbox)
        #expect(titles(await triage([template(.file(file.path))])) == ["Projects", "Inbox", "Later"])
        #expect(titles(await triage([template(.outline(file: file.path, path: ["Projects"]))])) == ["TODO Garden"])
        let tree = try notes.write("journal.org", """
            * 2026
            ** 2026-11 November
            *** 2026-11-27 Friday
            **** Met Ada
            ***** Her notes
            *** 2026-11-28 Saturday
            **** Idea
            * Elsewhere

            """)
        #expect(titles(await triage([template(.datetree(file: tree.path, path: [], tree: .day))])) == ["Met Ada", "Idea"])
        // A missing file has nothing to triage; the clock has no fixed place.
        #expect(await triage([template(.file(notes.url.appendingPathComponent("none.org").path))]).items.isEmpty)
        let clocked = await triage([template(.clock)])
        #expect(clocked.items.isEmpty)
        #expect(clocked.problem != nil)
        #expect(await triage([]).problem != nil)
    }

    @Test func theDefaultTemplateIsTheFirst() async throws {
        let file = try notes.write("inbox.org", Self.inbox)
        let model = await triage([template(.outline(file: file.path, path: ["Projects"])), template(.headline(file: file.path, headline: "Inbox"))])
        #expect(titles(model) == ["TODO Garden"])
    }

    @Test func aConfiguredViewListsItsEntriesOnce() async throws {
        try notes.write("a.org", "* TODO One\nSCHEDULED: <2026-11-27 Fri>\n* TODO Two\n* TODO Three :work:\n")
        await workspace.refresh()
        defaults.set("Work", forKey: "triageView")
        let views = [
            AgendaViewDefinition(name: "Work", mode: .blocks([
                AgendaBlock(mode: .query("(todo)", sort: [])),
                AgendaBlock(mode: .match("work", todoOnly: false)),
            ])),
        ]
        let model = await triage([], views: views)
        #expect(model.title == "Work")
        #expect(titles(model) == ["TODO One", "TODO Two", "TODO Three"])

        defaults.set("Nowhere", forKey: "triageView")
        let missing = await triage([], views: views)
        #expect(missing.items.isEmpty)
        #expect(missing.problem?.contains("Nowhere") == true)
    }

    @Test func entriesChangedElsewhereAreSkipped() async throws {
        let file = try notes.write("inbox.org", Self.inbox)
        let model = await triage([template(.headline(file: file.path, headline: "Inbox"))])
        try notes.write("inbox.org", Self.inbox.replacingOccurrences(of: "** TODO Buy stamps :errand:", with: "** DONE Buy stamps :errand:"))
        model.next()
        #expect(model.current?.text == "Read the paper")
        #expect(model.skipped == 1)
        #expect(model.remaining == 1)
        model.next()
        #expect(model.current == nil)
        #expect(model.remaining == 0)
    }

    @Test func anEntryThatMovedIsFollowed() async throws {
        let file = try notes.write("inbox.org", Self.inbox)
        let model = await triage([template(.headline(file: file.path, headline: "Inbox"))])
        try notes.write("inbox.org", "* Added above\n" + Self.inbox)
        guard case .commit = model.plan(day: today + 1, deadline: false, now: now) else { Issue.record("not scheduled"); return }
        #expect(try text(file).contains("** Call the plumber\nSCHEDULED: <2026-11-29 Sun>\n"))
    }

    // MARK: - Actions

    @Test func scheduleDeadlineTagsAndStateKeepTheEntry() async throws {
        let file = try notes.write("inbox.org", "#+STARTUP: logdone\n" + Self.inbox)
        let model = await triage([template(.headline(file: file.path, headline: "Inbox"))])
        guard case .commit = model.plan(day: today + 1, deadline: false, now: now) else { Issue.record("not scheduled"); return }
        guard case .commit = model.plan(day: today + 7, deadline: true, now: now) else { Issue.record("no deadline"); return }
        guard case .prompt(let prompt) = model.perform(SetTags(), now: now) else { Issue.record("no tags prompt"); return }
        guard case .commit = model.perform(SetTags(), answers: [prompt.key: ":home:"], now: now) else { Issue.record("not tagged"); return }
        guard case .commit = model.perform(SetTodo(keyword: "TODO"), now: now) else { Issue.record("no state"); return }
        #expect(model.current?.text == "TODO Call the plumber")
        #expect(model.current?.tags == ["home"])
        #expect(model.remaining == 3)
        let written = try text(file)
        #expect(written.contains("** TODO Call the plumber") && written.contains(":home:"))
        #expect(written.contains("DEADLINE: <2026-12-05 Sat> SCHEDULED: <2026-11-29 Sun>"))
        #expect(model.body().hasPrefix("DEADLINE: <2026-12-05 Sat> SCHEDULED: <2026-11-29 Sun>"))

        guard case .commit = model.perform(SetTodo(keyword: "DONE"), now: now) else { Issue.record("not done"); return }
        #expect(try text(file).contains("CLOSED: [2026-11-28 Sat 09:00]"))
        #expect(model.keywords() == ["TODO", "DONE"])
    }

    @Test func refileArchiveAndDeleteMoveOn() async throws {
        let file = try notes.write("inbox.org", Self.inbox)
        let other = try notes.write("work.org", "* Calls\n")
        await workspace.refresh()
        let model = await triage([template(.headline(file: file.path, headline: "Inbox"))])

        #expect(model.refile(to: "work.org/Calls", now: now) == "Refiled to work.org/Calls")
        #expect(try text(other) == "* Calls\n** Call the plumber\n*** A note under it\n")
        #expect(model.current?.text == "TODO Buy stamps")
        #expect(model.remaining == 2)

        _ = model.archive(now: now)
        #expect(try text(notes.url.appendingPathComponent("archive.org")).contains("* TODO Buy stamps"))
        #expect(model.current?.text == "Read the paper")

        #expect(model.delete(now: now) == "Deleted")
        let left = try text(file)
        #expect(left == "#+ARCHIVE: archive.org::\n* Projects\n** TODO Garden\n* Inbox\n* Later\n")
        #expect(model.current == nil)
        #expect(model.remaining == 0)
    }

    @Test func actionsGoThroughAnOpenBuffer() async throws {
        let file = try notes.write("inbox.org", Self.inbox)
        session.open(file.path)
        let model = await triage([template(.headline(file: file.path, headline: "Inbox"))])
        guard case .commit = model.perform(SetTodo(keyword: "TODO"), now: now) else { Issue.record("no state"); return }
        #expect(session.document?.text.contains("** TODO Call the plumber") == true)
        #expect(try text(file) == Self.inbox)
        #expect(model.delete(now: now) == "Deleted")
        #expect(session.document?.text.contains("plumber") == false)
        #expect(model.undo(now: now) == "Undone")
        #expect(session.document?.text.contains("** TODO Call the plumber\n*** A note under it\n") == true)
        #expect(model.current?.text == "TODO Call the plumber")
    }

    // MARK: - Undo

    @Test func undoTakesBackTheLastAction() async throws {
        let file = try notes.write("inbox.org", Self.inbox)
        let other = try notes.write("work.org", "* Calls\n")
        await workspace.refresh()
        let model = await triage([template(.headline(file: file.path, headline: "Inbox"))])
        #expect(!model.canUndo)
        #expect(model.undo(now: now) == "Nothing to undo")

        guard case .commit = model.plan(day: today, deadline: false, now: now) else { Issue.record("not scheduled"); return }
        #expect(model.undo(now: now) == "Undone")
        #expect(try text(file) == Self.inbox)
        #expect(model.current?.text == "Call the plumber")
        #expect(!model.canUndo)

        _ = model.refile(to: "work.org/Calls", now: now)
        #expect(model.current?.text == "TODO Buy stamps")
        #expect(model.undo(now: now) == "Undone")
        #expect(try text(file) == Self.inbox)
        #expect(try text(other) == "* Calls\n")
        #expect(model.current?.text == "Call the plumber")
        #expect(model.remaining == 3)

        _ = model.archive(now: now)
        #expect(model.undo(now: now) == "Undone")
        #expect(try text(file) == Self.inbox)
        #expect(try text(notes.url.appendingPathComponent("archive.org")) == "")
    }

    @Test func undoIsRefusedAfterTheFileChanged() async throws {
        let file = try notes.write("inbox.org", Self.inbox)
        let model = await triage([template(.headline(file: file.path, headline: "Inbox"))])
        _ = model.delete(now: now)
        let changed = try text(file) + "* Added\n"
        try notes.write("inbox.org", changed)
        #expect(model.undo(now: now)?.contains("changed since") == true)
        #expect(try text(file) == changed)
        #expect(model.canUndo)
    }
}
