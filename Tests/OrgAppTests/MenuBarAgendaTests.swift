import Foundation
import OrgCore
import OrgDocument
import OrgPresentation
import Testing
@testable import OrgApp

struct MenuBarClockTitleTests {
    let started = Date(timeIntervalSince1970: 1_800_000_000)

    func running(_ heading: String) -> ClockModel.Running {
        ClockModel.Running(path: "/notes/a.org", start: "2027-01-15 Fri 08:00", heading: heading, startedAt: started)
    }

    @Test func formatsAsTheModeLine() {
        let now = started.addingTimeInterval(25 * 60 + 59)
        #expect(MenuBarAgenda.clockTitle(running("Write the report"), effort: nil, style: .heading, now: now) == "[0:25] (Write the report)")
        #expect(MenuBarAgenda.clockTitle(running("Write the report"), effort: nil, style: .time, now: now) == "0:25")
        #expect(MenuBarAgenda.clockTitle(running("Write the report"), effort: nil, style: .none, now: now) == "")
        // A clock that starts after now, as an adopted one from another device may.
        #expect(MenuBarAgenda.clockTitle(running("Later"), effort: nil, style: .time, now: started.addingTimeInterval(-120)) == "0:00")
    }

    @Test func effortShowsTheEntrysTotalOverTheEffort() {
        let now = started.addingTimeInterval(130 * 60)
        #expect(MenuBarAgenda.clockTitle(running("Plan"), effort: (effort: 120, clocked: 45), style: .heading, now: now) == "[2:55/2:00] (Plan)")
        // The time-only title stays this clock's.
        #expect(MenuBarAgenda.clockTitle(running("Plan"), effort: (effort: 120, clocked: 45), style: .time, now: now) == "2:10")
    }

    @Test func longHeadingsAreCut() {
        let heading = String(repeating: "x", count: MenuBarAgenda.headingLimit + 5)
        let title = MenuBarAgenda.clockTitle(running(heading), effort: nil, style: .heading, now: started)
        #expect(title == "[0:00] (" + String(repeating: "x", count: MenuBarAgenda.headingLimit - 1) + "…)")
        let exact = String(repeating: "y", count: MenuBarAgenda.headingLimit)
        #expect(MenuBarAgenda.clockTitle(running(exact), effort: nil, style: .heading, now: started) == "[0:00] (\(exact))")
    }

    @Test func settingIsInTheRegistry() throws {
        let setting = try #require(UserConfig.settings.first { $0.key == "menu-bar-clock" })
        #expect(setting.fallback == .string(MenuBarAgenda.ClockTitle.heading.rawValue))
        guard case .choice(let choices) = setting.kind else { Issue.record("menu-bar-clock isn't a choice"); return }
        #expect(choices.map(\.stored) == MenuBarAgenda.ClockTitle.allCases.map(\.rawValue))
        #expect(UserConfig.settings.contains { $0.key == "menu-bar-capture-template" && $0.defaultsKey == "menuBarCaptureTemplate" })
    }
}

@MainActor
struct MenuBarAgendaTests {
    let notes: Folder
    let workspace: WorkspaceModel
    let session: DocumentSession
    let clock: ClockModel
    let calendar = Calendar.current
    let today = Days.absolute(year: 2026, month: 11, day: 28)
    let now: Date

    init() throws {
        notes = try Folder()
        workspace = try WorkspaceModel(directory: nil)
        session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        clock = ClockModel(file: notes.url.appendingPathComponent("clock.json"), defaults: TestDefaults("orgstar-menu-bar"))
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 9, minute: 50))!
    }

    func actions(_ templates: [CaptureTemplate] = [], defaultTemplate: String = "") -> MenuBarActions {
        var actions = MenuBarActions(workspace: workspace, session: session, clock: clock)
        actions.templates = { templates }
        actions.defaultTemplate = { defaultTemplate }
        return actions
    }

    /// Today's entries as the menu lists them from the agenda of `file`.
    func entries(_ file: URL) throws -> [MenuBarAgenda.Entry] {
        let source = AgendaSource(path: file.path, text: try text(file))
        let days = Agenda.list([source], start: today, days: 1, today: today, now: (9, 50))
        let event = AgendaEvent(
            id: "e1", title: "Lunch", calendarID: "c", calendarTitle: "Home", color: nil,
            start: calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: now))!,
            end: calendar.date(byAdding: .hour, value: 13, to: calendar.startOfDay(for: now))!, isAllDay: false
        )
        return MenuBarAgenda.today(AgendaRows.groups(days, events: [event], today: today, calendar: calendar), today: today)
    }

    func text(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

    static let file = """
        * TODO Call the bank
        SCHEDULED: <2026-11-28 Sat 10:00>
        * DONE Took out bins
        SCHEDULED: <2026-11-28 Sat>
        * TODO Send forms
        DEADLINE: <2026-11-25 Wed>
        * Standup
        <2026-11-28 Sat 08:30>

        """

    @Test func todayListsOpenEntriesOverdueFirst() throws {
        let file = try notes.write("a.org", Self.file)
        let entries = try entries(file)
        #expect(entries.map(\.title) == ["Send forms", "Standup", "Call the bank", "Lunch"])
        let call = try #require(entries.first { $0.title == "Call the bank" })
        #expect(call.label == "10:00  TODO  Call the bank")
        #expect(call.canBeDone && call.canClockIn)
        #expect(call.doneKeyword == "DONE")
        #expect(call.link == .entry(path: file.path, offset: (Self.file as NSString).range(of: "* TODO Call").location))
        let standup = try #require(entries.first { $0.title == "Standup" })
        #expect(!standup.canBeDone && standup.canClockIn)
        let lunch = try #require(entries.first { $0.title == "Lunch" })
        #expect(!lunch.canBeDone && !lunch.canClockIn && lunch.link == nil)
        #expect(MenuBarAgenda.today([], today: today).isEmpty)
    }

    @Test func markDoneRunsTheEditorsCommandAndSaves() throws {
        let original = "#+STARTUP: logrepeat\n* TODO Call the bank\nSCHEDULED: <2026-11-28 Sat 10:00 +1w>\n"
        let file = try notes.write("a.org", original)
        let entry = try #require(try entries(file).first)
        // An edit above moves the entry after the agenda was read.
        try ("* Note\n" + original).write(to: file, atomically: true, encoding: .utf8)
        session.open(file.path)
        #expect(actions().markDone(entry, now: now) == .changed)
        let written = try text(file)
        #expect(written.hasPrefix("* Note\n#+STARTUP: logrepeat\n* TODO Call the bank\n"))
        #expect(written.contains("SCHEDULED: <2026-12-05 Sat 10:00 +1w>"))
        #expect(written.contains("- State \"DONE\"       from \"TODO\""))
        #expect(session.dirtyPaths.isEmpty)
        // The open buffer can undo it.
        var undone = try #require(session.document(of: file.path))
        _ = undone.undo()
        #expect(undone.text == "* Note\n" + original)
    }

    @Test func markDoneOnAnEntryThatChanged() throws {
        let file = try notes.write("a.org", "* TODO Call the bank\nSCHEDULED: <2026-11-28 Sat 10:00>\n")
        let entry = try #require(try entries(file).first)
        try "* TODO Call the bank today\nSCHEDULED: <2026-11-28 Sat 10:00>\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(actions().markDone(entry, now: now) == .notFound)
    }

    @Test func clockInAndOutFromTheMenu() async throws {
        let file = try notes.write("a.org", Self.file)
        let entries = try entries(file)
        let standup = try #require(entries.first { $0.title == "Standup" })
        #expect(await actions().clockIn(standup, now: now) == .changed)
        #expect(clock.running?.heading == "Standup")
        #expect(try text(file).contains("* Standup\n:LOGBOOK:\nCLOCK: [2026-11-28 Sat 09:50]\n:END:\n"))
        // The clocked entry is known among today's entries, read again after the change.
        let clocked = clock.entry(session)
        #expect(try self.entries(file).filter { $0.isClocked(clocked) }.map(\.title) == ["Standup"])

        #expect(actions().clockOut(now: now.addingTimeInterval(600)) == "Clock stopped after 0:10")
        #expect(clock.running == nil)
        #expect(try text(file).contains("CLOCK: [2026-11-28 Sat 09:50]--[2026-11-28 Sat 10:00] =>  0:10\n"))
        #expect(!(try self.entries(file).contains { $0.isClocked(clock.entry(session)) }))
    }

    @Test func captureFilesWithTheDefaultTemplate() async throws {
        let todo = try notes.write("todo.org", "* Inbox\n")
        try await workspace.addRoot(notes.url)
        let templates = [
            CaptureTemplate(key: "t", name: "Todo", target: .headline(file: "todo.org", headline: "Inbox"), template: "* TODO %i"),
            CaptureTemplate(key: "n", name: "Note", target: .headline(file: "todo.org", headline: "Inbox"), template: "* %i :note:"),
            CaptureTemplate(key: "q", name: "Ask", target: .headline(file: "todo.org", headline: "Inbox"), template: "* %^{Who} %i"),
        ]
        #expect(await actions(templates).capture("  Buy milk\n") == .filed(template: "t", path: todo.path))
        #expect(await actions(templates, defaultTemplate: "n").capture("Idea") == .filed(template: "n", path: todo.path))
        #expect(await actions(templates, defaultTemplate: "n").capture("Call", template: "t") == .filed(template: "t", path: todo.path))
        #expect(try text(todo) == "* Inbox\n** TODO Buy milk\n** Idea :note:\n** TODO Call\n")
        #expect(session.dirtyPaths.isEmpty)
    }

    @Test func captureFallsBackToTheWindow() async throws {
        let todo = try notes.write("todo.org", "* Inbox\n")
        try await workspace.addRoot(notes.url)
        let templates = [
            CaptureTemplate(key: "q", name: "Ask", target: .headline(file: "todo.org", headline: "Inbox"), template: "* %^{Who} %i"),
            CaptureTemplate(key: "t", name: "Todo", target: .headline(file: "todo.org", headline: "Inbox"), template: "* TODO %i"),
        ]
        // Prompts, and no text, need the window.
        #expect(await actions(templates).capture("Lunch") == .window(template: "q"))
        #expect(await actions(templates).capture(" ", template: "t") == .window(template: "t"))
        #expect(await actions(templates, defaultTemplate: "z").capture("Lunch") == .failed("No capture template \"z\""))
        #expect(await actions([]).capture("Lunch") == .failed("No capture template \"\""))
        #expect(try text(todo) == "* Inbox\n")
    }
}
