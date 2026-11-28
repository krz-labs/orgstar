import Foundation
import OrgCore
import Testing
@testable import OrgPresentation

struct TimelineTests {
    static let today = Days.absolute(year: 2026, month: 10, day: 5)
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func timeline(_ text: String, events: [AgendaEvent] = [], first: Int = today, count: Int = 1, defaultLength: Int = 60) -> Timeline {
        let days = Agenda.list([AgendaSource(path: "/n/a.org", text: text)], start: first, days: count, today: today, now: (9, 0))
        let groups = AgendaRows.groups(days, events: events, today: today, showAllDates: true, calendar: utc)
        return Timeline(groups: groups, first: first, count: count, today: today, defaultLength: defaultLength, calendar: utc)
    }

    static func block(_ timeline: Timeline, _ title: String, day: Int = 0) -> Timeline.Block? {
        timeline.days[day].blocks.first { $0.row.title == title }
    }

    /// A timed entry without an end lasts its Effort, else the default length; a time range
    /// gives the end.
    @Test func lengthsComeFromRangeEffortOrDefault() throws {
        let timeline = Self.timeline("""
            * TODO Write
            SCHEDULED: <2026-10-05 Mon 10:00>
            :PROPERTIES:
            :Effort:   1:30
            :END:
            * TODO Call
            SCHEDULED: <2026-10-05 Mon 13:00>
            * Dentist <2026-10-05 Mon 15:10-15:40>
            """, defaultLength: 45)
        let write = try #require(Self.block(timeline, "Write"))
        #expect((write.start, write.end, write.hasEnd) == (600, 690, false))
        let call = try #require(Self.block(timeline, "Call"))
        #expect((call.start, call.end, call.hasEnd) == (780, 825, false))
        let dentist = try #require(Self.block(timeline, "Dentist"))
        #expect((dentist.start, dentist.end, dentist.hasEnd) == (910, 940, true))
        #expect(write.canMove && call.canMove && dentist.canMove)
        // A length running past midnight ends at midnight.
        let late = Self.timeline("* TODO Late\nSCHEDULED: <2026-10-05 Mon 23:30>\n:PROPERTIES:\n:Effort: 2:00\n:END:\n")
        #expect(Self.block(late, "Late")?.end == 24 * 60)
    }

    /// Untimed entries, overdue ones carried to today and ranges of days go in the all-day strip.
    @Test func untimedRowsGoInTheAllDayStrip() {
        let timeline = Self.timeline("""
            * TODO Report
            DEADLINE: <2026-10-05 Mon>
            * TODO Late
            SCHEDULED: <2026-10-01 Thu 09:00>
            * Trip
            <2026-10-04 Sun>--<2026-10-06 Tue>
            * Lunch <2026-10-05 Mon 12:00>
            """)
        #expect(Set(timeline.days[0].allDay.map(\.title)) == ["Report", "Late", "Trip"])
        #expect(timeline.days[0].blocks.map(\.row.title) == ["Lunch"])
    }

    /// Overlapping blocks share the width: each takes the first free column, and every block
    /// of a group of overlapping ones has the group's number of columns.
    @Test func overlapsGetColumns() {
        let timeline = Self.timeline("""
            * A <2026-10-05 Mon 09:00-10:00>
            * B <2026-10-05 Mon 09:30-11:00>
            * C <2026-10-05 Mon 10:00-10:30>
            * D <2026-10-05 Mon 11:00-12:00>
            * E <2026-10-05 Mon 14:00-15:00>
            * F <2026-10-05 Mon 14:00-14:30>
            * G <2026-10-05 Mon 14:15-14:45>
            """)
        func place(_ title: String) -> [Int] {
            let block = Self.block(timeline, title)!
            return [block.column, block.columns]
        }
        #expect(place("A") == [0, 2])
        #expect(place("B") == [1, 2])
        #expect(place("C") == [0, 2])
        // Touching isn't overlapping.
        #expect(place("D") == [0, 1])
        // At the same start the longer goes first.
        #expect(place("E") == [0, 3])
        #expect(place("F") == [1, 3])
        #expect(place("G") == [2, 3])
    }

    @Test func eventsAndContactDates() throws {
        let utc = Self.utc
        func at(_ day: Int, _ hour: Int) -> Date { utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let events = [
            AgendaEvent(id: "m", title: "Meeting", calendarID: "c", calendarTitle: "Work", color: nil, start: at(5, 14), end: at(5, 15), isAllDay: false),
            AgendaEvent(id: "h", title: "Holiday", calendarID: "c", calendarTitle: "Home", color: nil, start: at(5, 0), end: at(6, 0), isAllDay: true),
            AgendaEvent(id: "f", title: "Flight", calendarID: "c", calendarTitle: "Home", color: nil, start: at(5, 20), end: at(7, 8), isAllDay: false),
            AgendaEvent(id: "b", title: "Ann", calendarID: "x", calendarTitle: "Birthday", color: nil, start: at(5, 0), end: at(5, 0), isAllDay: true, isContact: true),
        ]
        let timeline = Self.timeline("", events: events, count: 3)
        let meeting = try #require(Self.block(timeline, "Meeting"))
        #expect((meeting.start, meeting.end, meeting.hasEnd, meeting.canMove) == (840, 900, true, false))
        #expect(Set(timeline.days[0].allDay.map(\.title)) == ["Holiday", "Ann"])
        // A timed event over several days: to midnight, all day, then from midnight.
        #expect(Self.block(timeline, "Flight").map { [$0.start, $0.end] } == [1200, 1440])
        #expect(timeline.days[1].allDay.map(\.title) == ["Flight"])
        #expect(Self.block(timeline, "Flight", day: 2).map { [$0.start, $0.end] } == [0, 480])
    }

    @Test func dragsSnapAndStayInTheDay() {
        #expect(Timeline.snap(607, to: 15) == 600)
        #expect(Timeline.snap(608, to: 15) == 615)
        #expect(Timeline.snap(607, to: 0) == 607)
        // A move keeps the length and snaps the start.
        #expect(Timeline.moved(start: 600, end: 690, by: 37, step: 15) == (630, 720))
        #expect(Timeline.moved(start: 600, end: 690, by: -900, step: 15) == (0, 90))
        #expect(Timeline.moved(start: 1380, end: 1440, by: 60, step: 15) == (1379, 1439))
        // Edges snap, keep at least one step, and stop at 23:59.
        #expect(Timeline.resized(start: 600, end: 660, top: false, by: 52, step: 15) == (600, 705))
        #expect(Timeline.resized(start: 600, end: 660, top: false, by: -90, step: 15) == (600, 615))
        #expect(Timeline.resized(start: 600, end: 660, top: false, by: 900, step: 15) == (600, 1439))
        #expect(Timeline.resized(start: 600, end: 660, top: true, by: -38, step: 15) == (555, 660))
        #expect(Timeline.resized(start: 600, end: 660, top: true, by: 90, step: 15) == (645, 660))
        #expect(Timeline.resized(start: 30, end: 660, top: true, by: -90, step: 15) == (0, 660))
    }

    /// The second zone's labels follow its offset on the day shown, half hours and daylight
    /// saving time included.
    @Test func secondZoneLabels() throws {
        let chicago = try #require(TimeZone(identifier: "America/Chicago"))
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let november = Days.absolute(year: 2026, month: 11, day: 30)
        let labels = Timeline.zoneLabels(day: november, local: chicago, other: berlin)
        #expect(labels.count == 24)
        #expect(labels[0] == "07:00" && labels[9] == "16:00" && labels[17] == "00:00")
        #expect(Timeline.zoneLabels(day: november, local: chicago, other: kolkata)[9] == "20:30")
        // 10 March: Chicago is on daylight saving time, Berlin not yet.
        #expect(Timeline.zoneLabels(day: Days.absolute(year: 2026, month: 3, day: 10), local: chicago, other: berlin)[9] == "15:00")
        #expect(Timeline.zoneLabels(day: november, local: berlin, other: berlin) == (0..<24).map { String(format: "%02d:00", $0) })
        #expect(!Timeline.zoneName(berlin, day: november).isEmpty)
    }
}
