import Foundation
import Testing
@testable import OrgCore

/// Dragging an agenda entry to another day: `MoveTimestampDays` at the item's marker by the
/// days `AgendaReschedule` works out.
struct RescheduleTests {
    static let today = Days.absolute(year: 2026, month: 9, day: 9)
    static func day(_ month: Int, _ day: Int) -> Int { Days.absolute(year: 2026, month: month, day: day) }

    /// The item for heading `title` of `kind` on `day`, moved to `target`.
    static func move(_ text: String, _ title: String, kind: AgendaItem.Kind? = nil, on day: Int, to target: Int, options: EditingOptions = .org) -> (text: String, message: String?) {
        let source = AgendaSource(path: "/n/a.org", text: text)
        let items = Agenda.list([source], start: day, days: 1, today: today, now: (9, 0))[0].items
        guard let item = items.first(where: { $0.text.contains(title) && (kind == nil || $0.kind == kind) }) else {
            return (text, "no item")
        }
        #expect(AgendaReschedule.canMove(item))
        let days = AgendaReschedule.days(item, shownOn: day, to: target)
        return DateCommandTests.run(MoveTimestampDays(days: days), text, caret: item.markerOffset!, answers: [:], options: options)
    }

    @Test func scheduledKeepsTimeAndRepeater() {
        let text = "* TODO Call\nSCHEDULED: <2026-10-05 Mon 10:00-11:30 +1w>\n"
        #expect(Self.move(text, "Call", on: Self.day(10, 5), to: Self.day(10, 8)).text == "* TODO Call\nSCHEDULED: <2026-10-08 Thu 10:00-11:30 +1w>\n")
        #expect(Self.move(text, "Call", on: Self.day(10, 5), to: Self.day(10, 1)).text == "* TODO Call\nSCHEDULED: <2026-10-01 Thu 10:00-11:30 +1w>\n")
        let untimed = "* TODO Call\nSCHEDULED: <2026-10-05 Mon>\n"
        #expect(Self.move(untimed, "Call", on: Self.day(10, 5), to: Self.day(10, 6)).text == "* TODO Call\nSCHEDULED: <2026-10-06 Tue>\n")
    }

    /// A repeat's occurrence moves the timestamp by the days between, as
    /// `org-agenda-date-later` does, so every occurrence moves with it.
    @Test func repeatOccurrenceMovesByTheDifference() {
        let text = "* TODO Review\nSCHEDULED: <2026-10-05 Mon +1w>\n"
        #expect(Self.move(text, "Review", on: Self.day(10, 19), to: Self.day(10, 21)).text == "* TODO Review\nSCHEDULED: <2026-10-07 Wed +1w>\n")
    }

    @Test func deadlineKeepsWarningAndRepeater() {
        let text = "* TODO Report\nDEADLINE: <2026-10-07 Wed 17:00 +1m -3d>\n"
        #expect(Self.move(text, "Report", on: Self.day(10, 7), to: Self.day(10, 9)).text == "* TODO Report\nDEADLINE: <2026-10-09 Fri 17:00 +1m -3d>\n")
    }

    /// An entry with both moves only the timestamp of the item dragged; `org-schedule` puts
    /// the timestamp it sets first on the line.
    @Test func entryWithBothMovesTheOneDragged() {
        let text = "* TODO Both\nDEADLINE: <2026-10-09 Fri> SCHEDULED: <2026-10-05 Mon>\n"
        #expect(Self.move(text, "Both", kind: .scheduled, on: Self.day(10, 5), to: Self.day(10, 6)).text
            == "* TODO Both\nSCHEDULED: <2026-10-06 Tue> DEADLINE: <2026-10-09 Fri>\n")
        #expect(Self.move(text, "Both", kind: .deadline, on: Self.day(10, 9), to: Self.day(10, 12)).text
            == "* TODO Both\nDEADLINE: <2026-10-12 Mon> SCHEDULED: <2026-10-05 Mon>\n")
    }

    /// Shown on today as overdue or as a warning, an entry lands on the day it is dropped on.
    @Test func carriedEntriesLandOnTheTarget() {
        let overdue = "* TODO Late\nSCHEDULED: <2026-09-01 Tue>\n"
        #expect(Self.move(overdue, "Late", on: Self.today, to: Self.day(9, 11)).text == "* TODO Late\nSCHEDULED: <2026-09-11 Fri>\n")
        let warning = "* TODO Soon\nDEADLINE: <2026-09-14 Mon>\n"
        #expect(Self.move(warning, "Soon", kind: .upcomingDeadline, on: Self.today, to: Self.day(9, 10)).text == "* TODO Soon\nDEADLINE: <2026-09-10 Thu>\n")
    }

    @Test func timestampsKeepTimeAndRepeater() {
        let text = "* Standup\n<2026-10-05 Mon 09:00-09:15 +1d>\n"
        #expect(Self.move(text, "Standup", on: Self.day(10, 5), to: Self.day(10, 7)).text == "* Standup\n<2026-10-07 Wed 09:00-09:15 +1d>\n")
    }

    /// A range moves whole: both ends by the days between the day dragged from and the target.
    @Test func rangesMoveBothEnds() {
        let text = "* Trip\n<2026-10-05 Mon>--<2026-10-07 Wed>\n"
        #expect(Self.move(text, "Trip", on: Self.day(10, 6), to: Self.day(10, 13)).text == "* Trip\n<2026-10-12 Mon>--<2026-10-14 Wed>\n")
        let timed = "* Trip\n<2026-10-05 Mon 18:00>--<2026-10-07 Wed 09:00>\n"
        #expect(Self.move(timed, "Trip", on: Self.day(10, 5), to: Self.day(10, 4)).text == "* Trip\n<2026-10-04 Sun 18:00>--<2026-10-06 Tue 09:00>\n")
    }

    @Test func reschedulesAreLogged() {
        let text = "* TODO Call\nSCHEDULED: <2026-10-05 Mon 10:00>\n"
        let timed = Self.move(text, "Call", on: Self.day(10, 5), to: Self.day(10, 6), options: EditingOptions(logReschedule: .time))
        #expect(timed.text.hasPrefix("* TODO Call\nSCHEDULED: <2026-10-06 Tue 10:00>\n- Rescheduled from \"[2026-10-05 Mon 10:00]\" on ["))
        let note = Self.move("* TODO Report\nDEADLINE: <2026-10-07 Wed>\n", "Report", on: Self.day(10, 7), to: Self.day(10, 8),
                             options: EditingOptions(logIntoDrawer: "LOGBOOK", logRedeadline: .note))
        #expect(note.text.contains("DEADLINE: <2026-10-08 Thu>\n:LOGBOOK:\n- New deadline from \"[2026-10-07 Wed]\" on ["))
        #expect(note.text.contains("\\\\\n  moved\n:END:"))
    }

    @Test func closedIsRemoved() {
        let text = "* DONE Call\nCLOSED: [2026-10-05 Mon 12:00] SCHEDULED: <2026-10-05 Mon>\n"
        #expect(Self.move(text, "Call", on: Self.day(10, 5), to: Self.day(10, 6)).text == "* DONE Call\nSCHEDULED: <2026-10-06 Tue>\n")
    }

    @Test func diarySexpsAndLogLinesDontMove() {
        let source = AgendaSource(path: "/n/a.org", text: "* Anniversary\n<%%(diary-anniversary 10 5 2000)>\n")
        let item = Agenda.list([source], start: Self.day(10, 5), days: 1, today: Self.today, now: (9, 0))[0].items[0]
        #expect(DateCommandTests.run(MoveTimestampDays(days: 1), source.text, caret: item.markerOffset!, answers: [:]).message?.hasPrefix("failed") == true)
        var options = AgendaOptions()
        options.logMode = true
        let log = AgendaSource(path: "/n/a.org", text: "* DONE Call\nCLOSED: [2026-10-05 Mon 12:00]\n")
        let closed = Agenda.list([log], start: Self.day(10, 5), days: 1, today: Self.today, now: (9, 0), options: options)[0].items
        #expect(closed.contains { $0.kind == .closed })
        #expect(!closed.contains(where: AgendaReschedule.canMove))
    }

    /// The planning case matches `org-schedule` and `org-deadline` given the new date and the
    /// old times; a timestamp matches `org-timestamp-change` by days, as `org-agenda-date-later`.
    @Test(.enabled(if: DateCommandTests.oracle))
    func matchesOrg() throws {
        let cases: [(text: String, caret: Int, days: Int, form: String)] = [
            ("* TODO a\nSCHEDULED: <2026-10-05 Mon 10:00-11:30 +1w>\n", 20, 3, "(org-schedule nil \"2026-10-08 10:00-11:30\")"),
            ("* TODO a\nDEADLINE: <2026-10-07 Wed +1m -3d>\n", 19, -2, "(org-deadline nil \"2026-10-05\")"),
            ("* DONE a\nCLOSED: [2026-10-05 Mon 12:00] SCHEDULED: <2026-10-05 Mon>\n", 53, 1, "(org-schedule nil \"2026-10-06\")"),
            ("* a\n<2026-10-05 Mon 09:00 +1d>\n", 4, 2, "(org-timestamp-change 2 'day)"),
        ]
        let options = EditingOptions(logReschedule: .time, logRedeadline: .time)
        let lisp = { (form: String) in "(let ((org-log-reschedule 'time) (org-log-redeadline 'time)) \(form) (run-hooks 'post-command-hook))" }
        let emacs = try EmacsOracle.run(cases.map { EmacsOracle.Case(text: $0.text, point: EmacsOracle.point($0.caret, in: $0.text), form: frozenClock(DateCommandTests.seconds, lisp($0.form))) })
        for (c, theirs) in zip(cases, emacs) {
            let run = DateCommandTests.run(MoveTimestampDays(days: c.days), c.text, caret: c.caret, answers: [:], options: options)
            let ours = run.text
            #expect(ours == theirs.text, "\(c.form) \(run.message ?? "")\nours:  \(ours.debugDescription)\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
        }
    }
}
