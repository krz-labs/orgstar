import Foundation
import Testing
@testable import OrgCore

/// Dragging an entry on the agenda timeline: `MoveTimestampTime` at the item's marker, the
/// days worked out as `AgendaReschedule` does for the month grid.
struct TimelineMoveTests {
    static let today = Days.absolute(year: 2026, month: 10, day: 5)
    static func day(_ day: Int) -> Int { Days.absolute(year: 2026, month: 10, day: day) }
    static func t(_ hour: Int, _ minute: Int = 0) -> Int { hour * 60 + minute }

    /// The item for heading `title` (of `kind`) on `day` given `start` to `end` on `target`.
    static func move(_ text: String, _ title: String, kind: AgendaItem.Kind? = nil, on day: Int, to target: Int, start: Int, end: Int?,
                     options: EditingOptions = .org) -> (text: String, message: String?) {
        let source = AgendaSource(path: "/n/a.org", text: text)
        let items = Agenda.list([source], start: day, days: 1, today: today, now: (9, 0))[0].items
        guard let item = items.first(where: { $0.text.contains(title) && (kind == nil || $0.kind == kind) }) else { return (text, "no item") }
        #expect(AgendaReschedule.canMoveTime(item))
        let days = AgendaReschedule.days(item, shownOn: day, to: target)
        return DateCommandTests.run(MoveTimestampTime(days: days, start: start, end: end), text, caret: item.markerOffset!, answers: [:], options: options)
    }

    @Test func scheduledTimeChangesWithItsDate() {
        let text = "* TODO Call\nSCHEDULED: <2026-10-05 Mon 10:00-11:30 +1w>\n"
        #expect(Self.move(text, "Call", on: Self.day(5), to: Self.day(6), start: Self.t(14), end: Self.t(15, 30)).text
            == "* TODO Call\nSCHEDULED: <2026-10-06 Tue 14:00-15:30 +1w>\n")
        // The same day: only the time.
        #expect(Self.move(text, "Call", on: Self.day(5), to: Self.day(5), start: Self.t(9, 15), end: Self.t(10, 45)).text
            == "* TODO Call\nSCHEDULED: <2026-10-05 Mon 09:15-10:45 +1w>\n")
    }

    /// An untimed schedule dropped on the timeline gets a time; a move without an end drops the range.
    @Test func timeAddedOrRangeDropped() {
        #expect(Self.move("* TODO Call\nSCHEDULED: <2026-10-05 Mon>\n", "Call", on: Self.day(5), to: Self.day(5), start: Self.t(9), end: nil).text
            == "* TODO Call\nSCHEDULED: <2026-10-05 Mon 09:00>\n")
        #expect(Self.move("* Standup\n<2026-10-05 Mon 09:00-09:15 +1d>\n", "Standup", on: Self.day(5), to: Self.day(5), start: Self.t(8), end: nil).text
            == "* Standup\n<2026-10-05 Mon 08:00 +1d>\n")
    }

    /// Resizing writes a time range; the start stays.
    @Test func resizeWritesARange() {
        let text = "* Dentist <2026-10-05 Mon 13:50>\n"
        #expect(Self.move(text, "Dentist", on: Self.day(5), to: Self.day(5), start: Self.t(13, 50), end: Self.t(15)).text
            == "* Dentist <2026-10-05 Mon 13:50-15:00>\n")
    }

    @Test func deadlineKeepsWarningAndRepeater() {
        let text = "* TODO Report\nDEADLINE: <2026-10-07 Wed 17:00 +1m -3d>\n"
        #expect(Self.move(text, "Report", kind: .deadline, on: Self.day(7), to: Self.day(8), start: Self.t(15), end: Self.t(16)).text
            == "* TODO Report\nDEADLINE: <2026-10-08 Thu 15:00-16:00 +1m -3d>\n")
    }

    /// Timestamps keep repeater and warning; a repeat's occurrence moves the base by the days
    /// between, as `org-agenda-date-later` does.
    @Test func timestampsKeepRepeaterAndWarning() {
        let text = "* Standup\n<2026-10-05 Mon 09:00-09:15 +1d -1d>\n"
        #expect(Self.move(text, "Standup", on: Self.day(5), to: Self.day(7), start: Self.t(13), end: Self.t(13, 30)).text
            == "* Standup\n<2026-10-07 Wed 13:00-13:30 +1d -1d>\n")
        let weekly = "* Review\n<2026-10-05 Mon 16:00 +1w>\n"
        #expect(Self.move(weekly, "Review", on: Self.day(12), to: Self.day(13), start: Self.t(10), end: nil).text
            == "* Review\n<2026-10-06 Tue 10:00 +1w>\n")
    }

    /// A range never crosses midnight: an end past 23:59, or not after the start, is refused and
    /// the file is left alone.
    @Test func midnightIsTheLimit() {
        let text = "* Late\n<2026-10-05 Mon 22:00>\n"
        let caret = 8
        #expect(DateCommandTests.run(MoveTimestampTime(start: Self.t(23), end: Self.t(23, 59)), text, caret: caret, answers: [:]).text
            == "* Late\n<2026-10-05 Mon 23:00-23:59>\n")
        for (start, end) in [(Self.t(23), 24 * 60), (Self.t(23), Self.t(23)), (Self.t(23), Self.t(22)), (24 * 60, nil), (-15, nil)] as [(Int, Int?)] {
            let run = DateCommandTests.run(MoveTimestampTime(start: start, end: end), text, caret: caret, answers: [:])
            #expect(run.text == text)
            #expect(run.message == "failed: A time range can't cross midnight", "\(start) \(String(describing: end))")
        }
    }

    @Test func reschedulesAreLogged() {
        let text = "* TODO Call\nSCHEDULED: <2026-10-05 Mon 10:00>\n"
        let timed = Self.move(text, "Call", on: Self.day(5), to: Self.day(5), start: Self.t(11), end: Self.t(12), options: EditingOptions(logReschedule: .time))
        #expect(timed.text.hasPrefix("* TODO Call\nSCHEDULED: <2026-10-05 Mon 11:00-12:00>\n- Rescheduled from \"[2026-10-05 Mon 10:00]\" on ["))
        let note = Self.move("* TODO Report\nDEADLINE: <2026-10-07 Wed>\n", "Report", kind: .deadline, on: Self.day(7), to: Self.day(7),
                             start: Self.t(9), end: nil, options: EditingOptions(logIntoDrawer: "LOGBOOK", logRedeadline: .note))
        #expect(note.text.contains("DEADLINE: <2026-10-07 Wed 09:00>\n:LOGBOOK:\n- New deadline from \"[2026-10-07 Wed]\" on ["))
        #expect(note.text.contains("\\\\\n  moved\n:END:"))
    }

    @Test func rangesOfDaysAndDiarySexpsDontChangeTime() {
        let range = AgendaSource(path: "/n/a.org", text: "* Trip\n<2026-10-05 Mon 18:00>--<2026-10-07 Wed 09:00>\n")
        let trip = Agenda.list([range], start: Self.day(6), days: 1, today: Self.today, now: (9, 0))[0].items[0]
        #expect(AgendaReschedule.canMove(trip))
        #expect(!AgendaReschedule.canMoveTime(trip))
        #expect(DateCommandTests.run(MoveTimestampTime(start: Self.t(9), end: nil), range.text, caret: 8, answers: [:]).message
            == "failed: A range of days can't change its time")
        let sexp = "* Anniversary\n<%%(diary-anniversary 10 5 2000)>\n"
        #expect(DateCommandTests.run(MoveTimestampTime(start: Self.t(9), end: nil), sexp, caret: 15, answers: [:]).message?.hasPrefix("failed") == true)
    }

    /// Planning matches `org-schedule` and `org-deadline` given the new date and time; a
    /// timestamp matches `org-timestamp-change` by minutes, which keeps a range's length, and
    /// on a range's end changes only the end, as a resize does.
    @Test(.enabled(if: DateCommandTests.oracle))
    func matchesOrg() throws {
        let cases: [(text: String, caret: Int, command: MoveTimestampTime, form: String)] = [
            ("* TODO a\nSCHEDULED: <2026-10-05 Mon 10:00-11:30 +1w>\n", 20, MoveTimestampTime(days: 3, start: Self.t(14), end: Self.t(15, 30)),
             "(org-schedule nil \"2026-10-08 14:00-15:30\")"),
            ("* TODO a\nSCHEDULED: <2026-10-05 Mon>\n", 20, MoveTimestampTime(days: 0, start: Self.t(9), end: nil), "(org-schedule nil \"2026-10-05 09:00\")"),
            ("* TODO a\nDEADLINE: <2026-10-07 Wed +1m -3d>\n", 19, MoveTimestampTime(days: -2, start: Self.t(15), end: Self.t(16)),
             "(org-deadline nil \"2026-10-05 15:00-16:00\")"),
            ("* DONE a\nCLOSED: [2026-10-05 Mon 12:00] SCHEDULED: <2026-10-05 Mon 08:00>\n", 53, MoveTimestampTime(days: 1, start: Self.t(8), end: nil),
             "(org-schedule nil \"2026-10-06 08:00\")"),
            ("* a\n<2026-10-05 Mon 09:00-10:00 +1d>\n", 4, MoveTimestampTime(start: Self.t(10, 30), end: Self.t(11, 30)), "(org-timestamp-change 90 'minute)"),
            ("* a\n<2026-10-05 Mon 09:00-10:00>\n", 30, MoveTimestampTime(start: Self.t(9), end: Self.t(10, 30)), "(org-timestamp-change 30)"),
        ]
        let options = EditingOptions(logReschedule: .time, logRedeadline: .time)
        let lisp = { (form: String) in "(let ((org-log-reschedule 'time) (org-log-redeadline 'time)) \(form) (run-hooks 'post-command-hook))" }
        let emacs = try EmacsOracle.run(cases.map { EmacsOracle.Case(text: $0.text, point: EmacsOracle.point($0.caret, in: $0.text), form: frozenClock(DateCommandTests.seconds, lisp($0.form))) })
        for (c, theirs) in zip(cases, emacs) {
            let run = DateCommandTests.run(c.command, c.text, caret: c.caret, answers: [:], options: options)
            #expect(run.text == theirs.text, "\(c.form) \(run.message ?? "")\nours:  \(run.text.debugDescription)\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
        }
    }
}
