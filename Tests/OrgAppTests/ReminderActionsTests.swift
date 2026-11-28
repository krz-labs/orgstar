import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

@MainActor
struct ReminderActionsTests {
    let notes: Folder
    let session: DocumentSession
    let center = FakeReminderCenter()
    let defaults = TestDefaults("orgstar-reminder-actions")
    let calendar = Calendar.current
    let now: Date

    init() throws {
        notes = try Folder()
        session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 9, minute: 50))!
    }

    func actions(snoozeInFile: Bool = false) -> ReminderActions {
        var actions = ReminderActions(center: center, session: session, clock: ClockModel(file: notes.url.appendingPathComponent("clock.json"), defaults: defaults))
        actions.snoozeInFile = { snoozeInFile }
        actions.handled = HandledReminders(defaults: defaults)
        actions.calendar = calendar
        return actions
    }

    /// The reminder the agenda sets for `title` in `file`, as its notification hands it back.
    func reminder(_ title: String, in file: URL) throws -> Reminder {
        let source = AgendaSource(path: file.path, text: try String(contentsOf: file, encoding: .utf8))
        let set = try #require(Reminders.upcoming([source], now: now, calendar: calendar).first { $0.title == title })
        return try #require(Reminder(identifier: set.id, title: set.title, body: set.body, userInfo: set.userInfo))
    }

    func text(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

    @Test func categories() throws {
        let file = try notes.write("a.org", "* TODO Call\nSCHEDULED: <2026-11-28 Sat 10:00>\n* Meeting\n<2026-11-28 Sat 11:00>\n")
        #expect(ReminderAction.category(for: try reminder("Call", in: file)) == ReminderAction.todoCategory)
        #expect(ReminderAction.category(for: try reminder("Meeting", in: file)) == ReminderAction.entryCategory)
        #expect(ReminderAction.actions(in: ReminderAction.entryCategory) == [.snoozeTenMinutes, .snoozeHour, .snoozeTomorrow, .clockIn])
        // The effort reminder isn't an entry's.
        #expect(ReminderAction.category(for: Reminder(id: "x", fireDate: now, eventDate: now, title: "", body: "", path: "/a.org", offset: 0)) == nil)
    }

    @Test func doneRepeatsAndLogsAsTheEditorDoes() async throws {
        let original = "#+STARTUP: logrepeat\n* Other\n* TODO Call\nSCHEDULED: <2026-11-28 Sat 10:00 +1w>\n"
        let file = try notes.write("a.org", original)
        let reminder = try reminder("Call", in: file)
        #expect(await actions().run(.done, on: reminder, now: now) == .changed)

        // The editor's command on the same text gives the same file.
        var expected = DocumentState(bytes: Array(original.utf8))
        let offset = (original as NSString).range(of: "* TODO Call").location
        _ = try expected.run(SetTodo(keyword: "DONE"), selection: [offset..<offset], now: now, answers: ["note": ""], options: session.options)
        let written = try text(file)
        #expect(written == expected.text)
        #expect(written.contains("* TODO Call\n"))
        #expect(written.contains("SCHEDULED: <2026-12-05 Sat 10:00 +1w>"))
        #expect(written.contains("- State \"DONE\"       from \"TODO\""))
        #expect(HandledReminders(defaults: defaults).ids == [reminder.id])
    }

    @Test func doneInAnOpenBufferSaves() async throws {
        let file = try notes.write("a.org", "* TODO Call\nSCHEDULED: <2026-11-28 Sat 10:00>\n")
        session.open(file.path)
        let reminder = try reminder("Call", in: file)
        #expect(await actions().run(.done, on: reminder, now: now) == .changed)
        #expect(try text(file).hasPrefix("* DONE Call\n"))
        #expect(session.dirtyPaths.isEmpty)
    }

    @Test func snoozeMovesOnlyTheNotificationByDefault() async throws {
        let original = "* TODO Call\nSCHEDULED: <2026-11-28 Sat 10:00>\n"
        let file = try notes.write("a.org", original)
        let reminder = try reminder("Call", in: file)
        let actions = actions()
        #expect(await actions.run(.snoozeTenMinutes, on: reminder, now: now) == .snoozed(now.addingTimeInterval(600)))
        #expect(center.added == [ReminderActions.snoozePrefix + reminder.id])
        #expect(try text(file) == original)

        // Snoozing the snoozed notification replaces it.
        let snoozed = try #require(Reminder(identifier: center.added[0], title: reminder.title, body: reminder.body, userInfo: reminder.userInfo))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        #expect(await actions.run(.snoozeTomorrow, on: snoozed, now: now) == .snoozed(tomorrow))
        #expect(center.added.last == ReminderActions.snoozePrefix + reminder.id)
        #expect(HandledReminders(defaults: defaults).ids == [reminder.id])

        // The scheduler doesn't set the reminder again, though its notification has gone, until it no longer applies.
        let scheduler = ReminderScheduler(center: center, handled: HandledReminders(defaults: defaults))
        await scheduler.reconcile([reminder])
        #expect(!center.ids.contains(reminder.id))
        await scheduler.reconcile([])
        #expect(HandledReminders(defaults: defaults).ids.isEmpty)
    }

    @Test func snoozeCanMoveTheTimestamp() async throws {
        let file = try notes.write("a.org", "* TODO Call\nSCHEDULED: <2026-11-28 Sat 10:00 +1w>\n* Meeting\n<2026-11-28 Sat 11:00-11:30>\n")
        let actions = actions(snoozeInFile: true)
        #expect(await actions.run(.snoozeTenMinutes, on: try reminder("Call", in: file), now: now) == .changed)
        #expect(try text(file).contains("SCHEDULED: <2026-11-28 Sat 10:10 +1w>\n"))
        #expect(await actions.run(.snoozeHour, on: try reminder("Meeting", in: file), now: now) == .changed)
        #expect(try text(file).contains("<2026-11-28 Sat 12:00-12:30>\n"))
        #expect(await actions.run(.snoozeTomorrow, on: try reminder("Meeting", in: file), now: now) == .changed)
        #expect(try text(file) == "* TODO Call\nSCHEDULED: <2026-11-28 Sat 10:10 +1w>\n* Meeting\n<2026-11-29 Sun 12:00-12:30>\n")
        #expect(center.added.isEmpty)
    }

    @Test func clockIn() async throws {
        let file = try notes.write("a.org", "* Other\n* Meeting\n<2026-11-28 Sat 11:00>\n")
        let actions = actions()
        #expect(await actions.run(.clockIn, on: try reminder("Meeting", in: file), now: now) == .changed)
        #expect(actions.clock.running?.heading == "Meeting")
        #expect(try text(file) == "* Other\n* Meeting\n:LOGBOOK:\nCLOCK: [2026-11-28 Sat 09:50]\n:END:\n<2026-11-28 Sat 11:00>\n")
    }

    @Test func entryNotFound() async throws {
        let file = try notes.write("a.org", "* TODO Call\nSCHEDULED: <2026-11-28 Sat 10:00>\n")
        let reminder = try reminder("Call", in: file)
        try notes.write("a.org", "* TODO Call Bob\nSCHEDULED: <2026-11-28 Sat 10:00>\n")
        for action in [ReminderAction.done, .clockIn] {
            #expect(await actions(snoozeInFile: true).run(action, on: reminder, now: now) == .notFound)
        }
        #expect(await actions(snoozeInFile: true).run(.snoozeHour, on: reminder, now: now) == .notFound)
        #expect(try text(file) == "* TODO Call Bob\nSCHEDULED: <2026-11-28 Sat 10:00>\n")

        let notice = try #require(ReminderActions.notice(.notFound, for: reminder, now: now))
        #expect(notice.path == file.path && notice.offset == 0 && ReminderAction.category(for: notice) == nil)
        #expect(notice.body.contains("a.org"))
        #expect(ReminderActions.notice(.changed, for: reminder) == nil)

        // A file gone altogether.
        try FileManager.default.removeItem(at: file)
        #expect(await actions().run(.done, on: reminder, now: now) == .notFound)
    }
}
