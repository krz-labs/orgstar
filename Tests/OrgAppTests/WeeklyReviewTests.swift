import Foundation
@testable import OrgConfig
import OrgCore
import Testing
@testable import OrgApp

/// The built-in Weekly Review against fixture files on Saturday 2026-11-28.
@MainActor
struct WeeklyReviewTests {
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 9))!
    let defaults = UserDefaults(suiteName: "weekly-review-\(UUID().uuidString)")!

    static let projects = """
        * Projects
        ** Kitchen
        *** Measure the walls
        ** Garden
        *** TODO Buy seeds

        """

    static let tasks = """
        #+TODO: TODO WAITING | DONE
        * TODO Old errand
        SCHEDULED: <2026-11-20 Fri>
        * TODO Today's errand
        SCHEDULED: <2026-11-28 Sat>
        * DONE Finished this week
        CLOSED: [2026-11-25 Wed 10:00] SCHEDULED: <2026-11-10 Tue>
        * TODO Taxes
        DEADLINE: <2026-12-20 Sun>
        * TODO Report
        DEADLINE: <2026-12-03 Thu>
        * TODO Overdue bill
        DEADLINE: <2026-11-26 Thu>
        * WAITING Reply from Ada
        * DONE Old win
        CLOSED: [2026-11-10 Tue 10:00]
        * Meeting notes
        :LOGBOOK:
        CLOCK: [2026-11-24 Tue 14:00]--[2026-11-24 Tue 15:00] =>  1:00
        :END:
        * Long ago
        :LOGBOOK:
        CLOCK: [2026-10-01 Thu 14:00]--[2026-10-01 Thu 15:00] =>  1:00
        :END:

        """

    func review(_ views: [AgendaViewDefinition]) throws -> AgendaViewDefinition {
        try #require(views.first { $0.name == AgendaViewLoader.weeklyReviewName })
    }

    @Test func theBlocksListWhatAReviewLooksAt() async throws {
        let notes = try Folder()
        try notes.write("projects.org", Self.projects)
        try notes.write("tasks.org", Self.tasks)
        let workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        let agenda = AgendaModel(workspace: workspace)
        agenda.agendaFiles = []
        agenda.hiddenFolders = []
        let view = try review(AgendaViewLoader.builtIn(defaults))
        #expect(view.triage)
        agenda.mode = view.mode
        await agenda.refresh(open: [:], now: now)

        let blocks = agenda.blocks.map { ($0.header, $0.list.map(\.text)) }
        #expect(blocks.map(\.0) == [
            "Stuck projects", "Scheduled in the past", "Deadlines up to a week ahead", "Waiting for", "Completed in the last 7 days", "Clocked in the last 7 days",
        ])
        #expect(blocks.map(\.1) == [
            ["Kitchen"],
            ["TODO Old errand"],
            ["TODO Overdue bill", "TODO Report"],
            ["WAITING Reply from Ada"],
            ["DONE Finished this week"],
            ["Meeting notes"],
        ])
    }

    @Test func theWaitingKeywordIsASetting() throws {
        defaults.set("WAIT", forKey: "weeklyReviewWaiting")
        guard case .blocks(let blocks) = try review(AgendaViewLoader.builtIn(defaults)).mode else { Issue.record("not a block agenda"); return }
        #expect(blocks.contains { $0.mode == .todo(keywords: "WAIT") })
        #expect(AgendaViewLoader.parse(AgendaViewLoader.weeklyReview(waiting: "WAIT"), defaults: defaults).problems.isEmpty)
    }

    @Test func viewsTomlReplacesItAndCanLinkToTriage() throws {
        let folder = try Folder()
        let file = try folder.write("views.toml", """
            [[view]]
            name = "Weekly Review"
            type = "todo"
            keywords = "WAIT"

            [[view]]
            name = "Inbox"
            type = "query"
            query = "path:inbox"
            triage = true

            """)
        let loaded = AgendaViewLoader.load(userFile: file, defaults: defaults)
        #expect(loaded.problems.isEmpty)
        #expect(loaded.views.map(\.name) == ["Agenda", "TODO List", "Stuck Projects", "Weekly Review", "Inbox"])
        #expect(try review(loaded.views).mode == .todo(keywords: "WAIT"))
        #expect(try review(loaded.views).triage == false)
        #expect(loaded.views.last?.triage == true)
    }
}
