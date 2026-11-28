import Foundation
import OrgCore
import OrgDocument
import OrgPresentation
import Testing
@testable import OrgApp

@MainActor
struct AgendaDragTests {
    static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
    static func day(_ day: Int) -> Int { Days.absolute(year: 2026, month: 10, day: day) }

    /// The month agenda's groups over the folder, with `open` as the open buffers' text.
    static func groups(_ folder: Folder, open: [String: String] = [:]) async throws -> [AgendaDayGroup] {
        let model = try WorkspaceModel(directory: nil)
        try await model.addRoot(folder.url)
        let agenda = AgendaModel(workspace: model)
        agenda.mode = .agenda(span: 31, startOffset: nil)
        agenda.start = day(1)
        await agenda.refresh(open: open, now: now)
        return agenda.groups(showAllDates: true)
    }

    /// The row titled `title` on `day`, through its drag's text.
    static func dragged(_ groups: [AgendaDayGroup], _ title: String, on day: Int) throws -> AgendaRow {
        let row = try #require(groups.first { $0.day == day }?.rows.first { $0.title == title })
        let drag = try #require(AgendaDrag(row, day: day))
        let back = try #require(AgendaDrag(payload: drag.payload))
        return try #require(back.row(in: groups))
    }

    @Test func movesEntriesInOpenAndClosedFiles() async throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* TODO Call\nSCHEDULED: <2026-10-05 Mon 10:00 +1w>\n")
        let b = try notes.write("b.org", "* TODO Report\nDEADLINE: <2026-10-20 Tue>\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(a.path)
        let groups = try await Self.groups(notes, open: session.openTexts)

        // The open file changes in its buffer, as one change to undo; the disk is as it was.
        let call = try Self.dragged(groups, "Call", on: Self.day(19))
        let open = session.reschedule(call.item!, shownOn: Self.day(19), to: Self.day(22), now: Self.now)
        guard case .commit = open else { Issue.record("\(String(describing: open))"); return }
        #expect(session.document?.text == "* TODO Call\nSCHEDULED: <2026-10-08 Thu 10:00 +1w>\n")
        #expect(try String(contentsOf: a, encoding: .utf8) == "* TODO Call\nSCHEDULED: <2026-10-05 Mon 10:00 +1w>\n")
        var undone = try #require(session.document(of: a.path))
        _ = undone.undo()
        #expect(undone.text == "* TODO Call\nSCHEDULED: <2026-10-05 Mon 10:00 +1w>\n")

        // A closed file is written.
        let report = try Self.dragged(groups, "Report", on: Self.day(20))
        let closed = session.reschedule(report.item!, shownOn: Self.day(20), to: Self.day(23), now: Self.now)
        guard case .commit = closed else { Issue.record("\(String(describing: closed))"); return }
        #expect(try String(contentsOf: b, encoding: .utf8) == "* TODO Report\nDEADLINE: <2026-10-23 Fri>\n")

        // Dropped on its own day, nothing runs.
        #expect(session.reschedule(report.item!, shownOn: Self.day(20), to: Self.day(20), now: Self.now).map { _ in 0 } == nil)

        // A heading changed since the agenda read it is refused.
        try notes.write("b.org", "* DONE Report\nDEADLINE: <2026-10-23 Fri>\n")
        let stale = session.reschedule(report.item!, shownOn: Self.day(20), to: Self.day(21), now: Self.now)
        guard case .failed = stale else { Issue.record("\(String(describing: stale))"); return }
    }

    @Test func asksForTheRescheduleNote() async throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* TODO Call\nSCHEDULED: <2026-10-05 Mon>\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.options = EditingOptions(logReschedule: .note)
        let call = try Self.dragged(try await Self.groups(notes), "Call", on: Self.day(5))
        guard case .prompt(let prompt) = session.reschedule(call.item!, shownOn: Self.day(5), to: Self.day(6), now: Self.now) else {
            Issue.record("no prompt")
            return
        }
        #expect(try String(contentsOf: a, encoding: .utf8) == "* TODO Call\nSCHEDULED: <2026-10-05 Mon>\n")
        let step = session.reschedule(call.item!, shownOn: Self.day(5), to: Self.day(6), answers: [prompt.key: "later"], now: Self.now)
        guard case .commit = step else { Issue.record("\(String(describing: step))"); return }
        let text = try String(contentsOf: a, encoding: .utf8)
        #expect(text.hasPrefix("* TODO Call\nSCHEDULED: <2026-10-06 Tue>\n- Rescheduled from \"[2026-10-05 Mon]\" on ["))
        #expect(text.contains("\\\\\n  later"), "\(text)")
    }

    @Test func eventsAndContactDatesDontDrag() throws {
        let start = Date()
        let event = AgendaEvent(id: "e", title: "Lunch", calendarID: "c", calendarTitle: "Home", color: nil, start: start, end: start, isAllDay: true)
        let contact = AgendaEvent(id: "b", title: "Ann", calendarID: "c", calendarTitle: "Birthday", color: nil, start: start, end: start, isAllDay: true, isContact: true)
        let day = Days.absolute(start, calendar: .current)
        #expect(AgendaDrag(AgendaRow(event: event, day: day, calendar: .current), day: day) == nil)
        #expect(AgendaDrag(AgendaRow(event: contact, day: day, calendar: .current), day: day) == nil)
    }
}
