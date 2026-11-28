import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

@MainActor
struct AgendaEntryActionsTests {
    let notes: Folder
    let session: DocumentSession
    let today = Days.absolute(year: 2026, month: 11, day: 28)
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 9))!

    init() throws {
        notes = try Folder()
        session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
    }

    /// Today's agenda line for `title` in `file`, of `kind` when given.
    func item(_ title: String, in file: URL, kind: AgendaItem.Kind? = nil) throws -> AgendaItem {
        let source = AgendaSource(path: file.path, text: try text(file), defaults: .default)
        let items = Agenda.list([source], start: today, days: 1, today: today, now: (9, 0))[0].items
        return try #require(items.first { $0.text.hasSuffix(title) && (kind == nil || $0.kind == kind) })
    }

    func text(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

    func reschedule(_ item: AgendaItem, by days: Int) -> CommandStep {
        let (command, answers) = item.reschedule(to: today + days)
        return session.perform(command, on: item, answers: answers, now: now)
    }

    @Test func rescheduleKeepsTimeAndRepeaterInAFileNotOpen() throws {
        let file = try notes.write("a.org", "* Other\n* TODO Call\nSCHEDULED: <2026-11-28 Sat 10:00-11:30 +1w>\n")
        let call = try item("Call", in: file)
        #expect(call.canReschedule)
        guard case .commit = reschedule(call, by: 1) else { Issue.record("not rescheduled"); return }
        #expect(try text(file) == "* Other\n* TODO Call\nSCHEDULED: <2026-11-29 Sun 10:00-11:30 +1w>\n")
        #expect(!session.isOpen(file.path))
    }

    @Test func rescheduleWithoutATimeAddsNone() throws {
        let file = try notes.write("a.org", "* TODO Overdue\nSCHEDULED: <2026-11-25 Wed .+2d>\n")
        let overdue = try item("Overdue", in: file)
        #expect(overdue.kind == .pastScheduled)
        guard case .commit = reschedule(overdue, by: 0) else { Issue.record("not rescheduled"); return }
        #expect(try text(file) == "* TODO Overdue\nSCHEDULED: <2026-11-28 Sat .+2d>\n")
    }

    @Test func rescheduleOnADeadlineLineMovesTheDeadline() throws {
        let file = try notes.write("a.org", "* TODO Report\nDEADLINE: <2026-11-28 Sat 17:00> SCHEDULED: <2026-11-27 Fri>\n")
        let deadline = try item("Report", in: file, kind: .deadline)
        #expect(deadline.isDeadline)
        guard case .commit = reschedule(deadline, by: 2) else { Issue.record("not rescheduled"); return }
        #expect(try text(file) == "* TODO Report\nDEADLINE: <2026-11-30 Mon 17:00> SCHEDULED: <2026-11-27 Fri>\n")
    }

    @Test func rescheduleLogsAsTheEditorDoes() throws {
        let original = "#+STARTUP: logreschedule\n* TODO Call\nSCHEDULED: <2026-11-28 Sat 10:00>\n"
        let file = try notes.write("a.org", original)
        guard case .commit = reschedule(try item("Call", in: file), by: 1) else { Issue.record("not rescheduled"); return }

        // The editor's command with the time typed after the date gives the same file.
        var expected = DocumentState(bytes: Array(original.utf8))
        let offset = (original as NSString).range(of: "* TODO Call").location
        _ = try expected.run(SetPlanning(deadline: false), selection: [offset..<offset], now: now, answers: ["date": "2026-11-29 10:00"], options: session.options)
        #expect(try text(file) == expected.text)
        #expect(try text(file).contains("- Rescheduled from \"[2026-11-28 Sat 10:00]\""))
    }

    @Test func doneRepeatsAndLogs() throws {
        let file = try notes.write("a.org", "#+STARTUP: logrepeat\n* TODO Water\nSCHEDULED: <2026-11-28 Sat 08:00 +1d>\n")
        let water = try item("Water", in: file)
        let done = try #require(water.markDone)
        guard case .commit = session.perform(done, on: water, now: now) else { Issue.record("not done"); return }
        let written = try text(file)
        #expect(written.contains("* TODO Water\n"))
        #expect(written.contains("SCHEDULED: <2026-11-29 Sun 08:00 +1d>"))
        #expect(written.contains("- State \"DONE\"       from \"TODO\""))
    }

    @Test func doneInAnOpenBufferStaysInTheBuffer() throws {
        let original = "* TODO Call\nSCHEDULED: <2026-11-28 Sat>\n"
        let file = try notes.write("a.org", original)
        session.open(file.path)
        let call = try item("Call", in: file)
        guard case .commit = session.perform(try #require(call.markDone), on: call, now: now) else { Issue.record("not done"); return }
        #expect(session.document(of: file.path)?.text.hasPrefix("* DONE Call\n") == true)
        #expect(session.dirtyPaths.contains(file.path))
        #expect(try text(file) == original)
    }

    @Test func entriesWithoutAKeywordAreNotMarkedDone() throws {
        let file = try notes.write("a.org", "* Meeting\nSCHEDULED: <2026-11-28 Sat 11:00>\n* DONE Filed\nSCHEDULED: <2026-11-28 Sat>\n")
        #expect(try item("Meeting", in: file).markDone == nil)
        #expect(try item("Meeting", in: file).canReschedule)
        #expect(try item("Filed", in: file).markDone == nil)
        #expect(try !item("Filed", in: file).canReschedule)
    }

    @Test func aChangedEntryIsLeftAlone() throws {
        let file = try notes.write("a.org", "* TODO Call\nSCHEDULED: <2026-11-28 Sat>\n")
        let call = try item("Call", in: file)
        try notes.write("a.org", "* TODO Call Bob\nSCHEDULED: <2026-11-28 Sat>\n")
        #expect(reschedule(call, by: 1) == .failed("The entry changed; the agenda has been refreshed."))
        #expect(try text(file) == "* TODO Call Bob\nSCHEDULED: <2026-11-28 Sat>\n")
    }

    @Test func refileToAnotherFileNotOpen() throws {
        let file = try notes.write("a.org", "* Other\n* TODO Call\nSCHEDULED: <2026-11-28 Sat>\n")
        let target = try notes.write("b.org", "* Inbox\n* Projects\n")
        let call = try item("Call", in: file)
        let message = session.refile(call, to: "b.org/Projects", targets: { _, _ in
            [RefileTarget(label: "b.org/Projects", path: target.path, start: 8, title: "Projects", level: 1, contentHash: "")]
        }, now: now)
        #expect(message == "Refiled to b.org/Projects")
        #expect(try text(file) == "* Other\n")
        #expect(try text(target) == "* Inbox\n* Projects\n** TODO Call\nSCHEDULED: <2026-11-28 Sat>\n")
    }

    @Test func refileWithinTheFileTakesTargetsFromItsTextNow() throws {
        let file = try notes.write("a.org", "* TODO Call\nSCHEDULED: <2026-11-28 Sat>\n* Projects\n")
        let call = try item("Call", in: file)
        var asked: String?
        let message = session.refile(call, to: "a.org/Projects", targets: { path, document in
            asked = path
            let start = (document!.text as NSString).range(of: "* Projects").location
            return [RefileTarget(label: "a.org/Projects", path: path, start: start, title: "Projects", level: 1, contentHash: "")]
        }, now: now)
        #expect(message == "Refiled to a.org/Projects")
        #expect(asked == file.path)
        #expect(try text(file) == "* Projects\n** TODO Call\nSCHEDULED: <2026-11-28 Sat>\n")
        #expect(session.refile(call, to: "a.org/Gone", targets: { _, _ in [] }) != nil)
    }

    @Test func swipeSettings() {
        let defaults = TestDefaults("orgstar-agenda-swipe")
        #expect(AgendaSwipe.leading(defaults) == .reschedule)
        #expect(AgendaSwipe.trailing(defaults) == .done)
        defaults.set("refile", forKey: "agendaSwipeLeading")
        defaults.set("bogus", forKey: "agendaSwipeTrailing")
        #expect(AgendaSwipe.leading(defaults) == .refile)
        #expect(AgendaSwipe.trailing(defaults) == .done)
        let names = UserConfig.settings.filter { $0.key.hasPrefix("agenda-swipe-") }.map(\.key)
        #expect(names == ["agenda-swipe-leading", "agenda-swipe-trailing"])
    }
}
