import Foundation
import OrgConfig
import OrgCore
import OrgDocument
import OrgPresentation
import Testing
@testable import OrgApp

@MainActor
struct AgendaTimelineTests {
    static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
    static func day(_ day: Int) -> Int { Days.absolute(year: 2026, month: 10, day: day) }

    /// The week's agenda over the folder, with the TODO entries without a date.
    static func agenda(_ folder: Folder, open: [String: String] = [:]) async throws -> AgendaModel {
        let model = try WorkspaceModel(directory: nil)
        try await model.addRoot(folder.url)
        let agenda = AgendaModel(workspace: model)
        agenda.mode = .agenda(span: 7, startOffset: nil)
        agenda.start = day(12)
        agenda.listsUnscheduled = true
        await agenda.refresh(open: open, now: now)
        return agenda
    }

    static func row(_ agenda: AgendaModel, _ title: String, on day: Int) throws -> AgendaRow {
        try #require(agenda.groups(showAllDates: true).first { $0.day == day }?.rows.first { $0.title == title })
    }

    @Test func retimesEntriesInOpenAndClosedFiles() async throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* TODO Call\nSCHEDULED: <2026-10-12 Mon 10:00-11:00>\n")
        let b = try notes.write("b.org", "* Dentist <2026-10-13 Tue 14:00>\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(a.path)
        let agenda = try await Self.agenda(notes, open: session.openTexts)

        // Moved to the next day in the open buffer, as one change to undo; the disk is as it was.
        let call = try Self.row(agenda, "Call", on: Self.day(12))
        let step = session.retime(call, shownOn: Self.day(12), to: Self.day(13), start: 13 * 60 + 30, end: 14 * 60 + 30, now: Self.now)
        guard case .commit = step else { Issue.record("\(String(describing: step))"); return }
        #expect(session.document?.text == "* TODO Call\nSCHEDULED: <2026-10-13 Tue 13:30-14:30>\n")
        #expect(try String(contentsOf: a, encoding: .utf8) == "* TODO Call\nSCHEDULED: <2026-10-12 Mon 10:00-11:00>\n")
        var undone = try #require(session.document(of: a.path))
        _ = undone.undo()
        #expect(undone.text == "* TODO Call\nSCHEDULED: <2026-10-12 Mon 10:00-11:00>\n")

        // Resized in a closed file: a range is written.
        let dentist = try Self.row(agenda, "Dentist", on: Self.day(13))
        guard case .commit = session.retime(dentist, shownOn: Self.day(13), to: Self.day(13), start: 14 * 60, end: 15 * 60, now: Self.now) else {
            Issue.record("not resized")
            return
        }
        #expect(try String(contentsOf: b, encoding: .utf8) == "* Dentist <2026-10-13 Tue 14:00-15:00>\n")

        // Dropped where it is, nothing runs.
        #expect(session.retime(dentist, shownOn: Self.day(13), to: Self.day(13), start: 14 * 60, end: nil, now: Self.now) == nil)
    }

    @Test func todoEntriesWithoutADateAreListedAndScheduled() async throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* TODO Write report\n:PROPERTIES:\n:Effort: 0:45\n:END:\n* TODO Dated\nSCHEDULED: <2026-10-20 Tue>\n* Note\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        let agenda = try await Self.agenda(notes)
        #expect(agenda.unscheduled.map(\.title) == ["Write report"])
        let rows = agenda.unscheduled.compactMap { AgendaRow(item: $0, day: Self.day(12), today: Self.day(12)) }
        #expect(Timeline.length(rows[0], defaultLength: 60) == 45)

        // Dropped on Wednesday at 10:00: scheduled there, with only a start; its Effort gives the length.
        let drag = try #require(AgendaTodoDrag(rows[0]))
        let drops = AgendaTimelineDrop.resolve([drag.payload], groups: agenda.groups(showAllDates: true), todos: rows, start: 600, step: 15)
        guard case .schedule(let item, let start)? = drops.first else { Issue.record("\(drops)"); return }
        guard case .commit = session.schedule(item, on: Self.day(14), at: start, now: Self.now) else { Issue.record("not scheduled"); return }
        #expect(try String(contentsOf: a, encoding: .utf8).hasPrefix("* TODO Write report\nSCHEDULED: <2026-10-14 Wed 10:00>\n:PROPERTIES:"))

        // Without the TODO list, none are computed.
        agenda.listsUnscheduled = false
        await agenda.refresh(open: [:], now: Self.now)
        #expect(agenda.unscheduled.isEmpty)
    }

    /// Rows dropped on a column keep the length of a time range, and stay without one when
    /// they had none; on the all-day strip only the day moves. Events don't drop.
    @Test func dropsResolveToMoves() async throws {
        let notes = try Folder()
        try notes.write("a.org", "* TODO Call\nSCHEDULED: <2026-10-12 Mon 10:00-11:30>\n* TODO Untimed\nSCHEDULED: <2026-10-12 Mon>\n")
        let agenda = try await Self.agenda(notes)
        let groups = agenda.groups(showAllDates: true)
        let call = try Self.row(agenda, "Call", on: Self.day(12))
        let untimed = try Self.row(agenda, "Untimed", on: Self.day(12))
        let payloads = [call, untimed].compactMap { AgendaDrag($0, day: Self.day(12))?.payload }
        #expect(AgendaTimelineDrop.resolve(payloads, groups: groups, todos: [], start: 14 * 60, step: 15)
            == [.move(call, from: Self.day(12), start: 840, end: 930), .move(untimed, from: Self.day(12), start: 840, end: nil)])
        // Late in the day, the range stays before midnight.
        #expect(AgendaTimelineDrop.resolve([payloads[0]], groups: groups, todos: [], start: 23 * 60, step: 15)
            == [.move(call, from: Self.day(12), start: 1349, end: 1439)])
        #expect(AgendaTimelineDrop.resolve(payloads, groups: groups, todos: [], start: nil, step: 15)
            == [.move(call, from: Self.day(12), start: nil, end: nil), .move(untimed, from: Self.day(12), start: nil, end: nil)])
        #expect(AgendaTimelineDrop.resolve(["something else"], groups: groups, todos: [], start: 600, step: 15).isEmpty)
    }

    @Test func settings() {
        let defaults = TestDefaults("orgstar-agenda-timeline")
        #expect(OrgPreferences.agendaTimelineSnap(defaults) == 15)
        #expect(OrgPreferences.agendaTimelineDefaultLength(defaults) == 60)
        #expect(OrgPreferences.agendaTimelineSecondZone(defaults) == nil)
        defaults.set("Europe/Berlin", forKey: "agendaTimelineSecondZone")
        #expect(OrgPreferences.agendaTimelineSecondZone(defaults)?.identifier == "Europe/Berlin")
        defaults.set("Not/AZone", forKey: "agendaTimelineSecondZone")
        #expect(OrgPreferences.agendaTimelineSecondZone(defaults) == nil)
        let names = UserConfig.settings.filter { $0.key.hasPrefix("agenda-timeline-") }.map(\.path)
        #expect(names == ["orgstar.agenda-timeline-snap", "orgstar.agenda-timeline-default-length", "orgstar.agenda-timeline-second-zone"])
    }
}
