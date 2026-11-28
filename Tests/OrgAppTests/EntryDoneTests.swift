import Foundation
import OrgCore
import OrgDocument
import OrgPresentation
import OrgWatchData
import Testing
@testable import OrgApp

/// The widgets' checkboxes and the watch: marking an entry or a habit done from what the app
/// wrote for them, and the habits they list.
@MainActor
struct EntryDoneTests {
    let notes: Folder
    let session: DocumentSession
    let calendar = Calendar.current
    let now: Date
    let today: Int

    init() throws {
        notes = try Folder()
        session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 9, minute: 50))!
        today = Days.absolute(now, calendar: calendar)
    }

    static let habits = """
        * TODO Stretch
        SCHEDULED: <2026-11-28 Sat .+1d>
        :PROPERTIES:
        :STYLE: habit
        :END:
        :LOGBOOK:
        - State "DONE"       from "TODO"       [2026-11-27 Fri 08:00]
        :END:
        * TODO Review the week
        SCHEDULED: <2026-11-30 Mon .+1w>
        :PROPERTIES:
        :STYLE: habit
        :END:
        * TODO Water plants
        SCHEDULED: <2026-11-26 Thu .+3d>
        :PROPERTIES:
        :STYLE: habit
        :END:
        """

    func text(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

    func habitEntries(_ file: URL) throws -> [HabitSnapshot.Entry] {
        let source = AgendaSource(path: file.path, text: try text(file))
        return source.habits.map {
            HabitSnapshot.Entry(title: $0.title, path: source.path, offset: $0.offset, headingLine: $0.line, doneKeyword: $0.doneKeyword, habit: $0.habit)
        }
    }

    /// The agenda snapshot's rows of today, as the Today widget gets them.
    func todayRows(_ file: URL) throws -> [AgendaSnapshot.Row] {
        let source = AgendaSource(path: file.path, text: try text(file))
        let days = Agenda.list([source], start: today, days: 1, today: today, now: (9, 50))
        let snapshot = AgendaSnapshot(groups: AgendaRows.groups(days, today: today, calendar: calendar), today: today, theme: .default, generated: now)
        return snapshot.days.flatMap { $0.rows + $0.overdue }
    }

    @Test func widgetRowMarksItsEntryDone() throws {
        let file = try notes.write("a.org", "* Notes\n* TODO Call\nSCHEDULED: <2026-11-28 Sat>\n* Meeting\nSCHEDULED: <2026-11-28 Sat>\n")
        let rows = try todayRows(file)
        #expect(rows.first { $0.title == "Meeting" }?.done == nil)
        let done = try #require(rows.first { $0.title == "Call" }?.done)
        #expect(done == EntryDone(path: file.path, offset: 8, headingLine: "* TODO Call", keyword: "DONE"))
        #expect(session.markDone(done, now: now) == .changed)
        #expect(try text(file).hasPrefix("* Notes\n* DONE Call\n"))
        #expect(try todayRows(file).first { $0.title == "Call" }?.done == nil)
    }

    @Test func repeaterMovesOnAndLogsAsTheEditorDoes() throws {
        let original = "#+STARTUP: logrepeat\n* TODO Call\nSCHEDULED: <2026-11-28 Sat +1w>\n"
        let file = try notes.write("a.org", original)
        let done = try #require(try todayRows(file).first?.done)
        #expect(session.markDone(done, now: now) == .changed)
        var expected = DocumentState(bytes: Array(original.utf8))
        _ = try expected.run(SetTodo(keyword: "DONE"), selection: [done.offset..<done.offset], now: now, answers: ["note": ""], options: session.options)
        #expect(try text(file) == expected.text)
        #expect(try text(file).contains("* TODO Call\nSCHEDULED: <2026-12-05 Sat +1w>\n"))
    }

    @Test func habitIsLoggedAndShowsDoneToday() throws {
        let file = try notes.write("habits.org", Self.habits)
        let stretch = try #require(try habitEntries(file).first { $0.title == "Stretch" })
        #expect(!stretch.isDone(on: today))
        #expect(session.markDone(try #require(stretch.done), now: now) == .changed)
        let written = try text(file)
        #expect(written.contains("SCHEDULED: <2026-11-29 Sun .+1d>"))
        #expect(written.contains("- State \"DONE\"       from \"TODO\"       [2026-11-28 Sat 09:50]"))
        // Still one of today's habits, now done.
        let after = HabitSnapshot(habits: try habitEntries(file), colors: [:])
        let again = try #require(after.habits(on: today).first { $0.title == "Stretch" })
        #expect(again.isDone(on: today) && again.habit.scheduled == today + 1)
        #expect(again.habit.graph(today: today).first { $0.day == today }?.glyph == "*")
    }

    @Test func todaysHabits() throws {
        let file = try notes.write("habits.org", Self.habits)
        let snapshot = HabitSnapshot(habits: try habitEntries(file), colors: [:])
        // Review the week is scheduled for Monday.
        #expect(snapshot.habits(on: today).map(\.title) == ["Stretch", "Water plants"])
        #expect(snapshot.habits(on: today + 2).map(\.title) == ["Stretch", "Review the week", "Water plants"])
        #expect(snapshot.habits.allSatisfy { $0.done?.keyword == "DONE" })
        // A snapshot written before the checkboxes has no heading lines: no checkbox.
        #expect(HabitSnapshot.Entry(title: "x", path: "/a.org", offset: 0, habit: snapshot.habits[0].habit).done == nil)
    }

    @Test func watchHabits() throws {
        let file = try notes.write("habits.org", Self.habits)
        let habits = WatchAgenda.Habit.today(try habitEntries(file), today: today)
        #expect(habits.map(\.title) == ["Stretch", "Water plants"])
        let stretch = habits[0]
        #expect(stretch.days.count == 7 && !stretch.isDoneToday)
        // Done yesterday, the day before today.
        #expect(stretch.days.map(\.isDone) == [false, false, false, false, false, true, false])
        #expect(stretch.days.last?.face == "alert")
        #expect(stretch.done == .done(path: file.path, offset: 0, headingLine: "* TODO Stretch", keyword: "DONE"))

        var agenda = WatchAgenda(generated: now, day: now, overdue: [], rows: [], clock: nil, lastClocked: nil)
        agenda.habits = habits
        let marked = agenda.markingHabitDone(stretch.id)
        #expect(marked.habits?[0].isDoneToday == true && marked.habits?[0].done == nil && marked.habits?[1] == habits[1])

        // What the watch sends back marks it done on the phone.
        guard case .done(let path, let offset, let line, let keyword)? = stretch.done else { Issue.record(); return }
        #expect(session.markDone(EntryDone(path: path, offset: offset, headingLine: line, keyword: keyword), now: now) == .changed)
        #expect(WatchAgenda.Habit.today(try habitEntries(file), today: today)[0].isDoneToday)
    }

    @Test func entryMovedOrGone() throws {
        let file = try notes.write("a.org", "* TODO Call\nSCHEDULED: <2026-11-28 Sat>\n")
        let done = try #require(try todayRows(file).first?.done)
        // Moved down by an edit elsewhere: found by its heading line.
        try notes.write("a.org", "* Inbox\n* TODO Call\nSCHEDULED: <2026-11-28 Sat>\n")
        #expect(session.markDone(done, now: now) == .changed)
        #expect(try text(file).hasPrefix("* Inbox\n* DONE Call\n"))
        // Renamed, then deleted.
        try notes.write("a.org", "* TODO Call Bob\n")
        #expect(session.markDone(done, now: now) == .notFound)
        #expect(try text(file) == "* TODO Call Bob\n")
        try FileManager.default.removeItem(at: file)
        #expect(session.markDone(done, now: now) == .notFound)
    }

    @Test func openBufferIsSaved() throws {
        let file = try notes.write("a.org", "* TODO Call\n")
        session.open(file.path)
        #expect(session.markDone(EntryDone(path: file.path, offset: 0, headingLine: "* TODO Call", keyword: "DONE"), now: now) == .changed)
        #expect(try text(file).hasPrefix("* DONE Call\n"))
        #expect(session.dirtyPaths.isEmpty)
    }

    @Test func macCheckboxLink() throws {
        let done = EntryDone(path: "/notes/a b&c+d/ünï.org", offset: 42, headingLine: "* TODO Pay & file? #1", keyword: "DONE")
        let link = AppLink.done(done, key: "k")
        #expect(AppLink(url: link.url) == link)
        #expect(AppLink(url: URL(string: "orgstar://done?path=/a.org&offset=0&heading=*%20TODO%20x&keyword=DONE")!) == nil)
        let defaults = TestDefaults("orgstar-widget-action-key")
        let key = WidgetActionKey.current(defaults: defaults)
        #expect(!key.isEmpty && WidgetActionKey.current(defaults: defaults) == key)
    }
}
