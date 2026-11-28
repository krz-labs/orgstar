import Foundation
import OrgCore
import Testing
@testable import OrgPresentation

struct MonthGridTests {
    static let file = """
        * TODO Late
        SCHEDULED: <2026-10-02 Fri>
        * TODO Report
        DEADLINE: <2026-10-20 Tue>
        * TODO Review
        SCHEDULED: <2026-09-28 Mon +1w>
        * Conference
        <2026-10-30 Fri>--<2026-11-02 Mon>
        * Dentist <2026-10-14 Wed 13:50-14:30>
        * Rent
        <2026-10-01 Thu +1m>
        """
    static let today = Days.absolute(year: 2026, month: 10, day: 12)
    static let first = Days.absolute(year: 2026, month: 10, day: 1)
    static let last = Days.absolute(year: 2026, month: 10, day: 31)

    static var grid: MonthGrid {
        let days = Agenda.list([AgendaSource(path: "/n/a.org", text: file)], start: first, days: 31, today: today, now: (9, 0))
        let groups = AgendaRows.groups(days, today: today, showAllDates: true)
        return MonthGrid(groups: groups, first: first, last: last, today: today, weekStart: 1)
    }

    static func titles(_ grid: MonthGrid, _ day: Int) -> [String] {
        grid.weeks.joined().first { $0.day == Days.absolute(year: 2026, month: 10, day: day) }!.rows.map(\.title)
    }

    @Test func weeksCoverTheMonth() {
        let grid = Self.grid
        // 1 October 2026 is a Thursday: the first week starts on Monday 28 September.
        #expect(grid.weeks.count == 5)
        #expect(grid.weeks.allSatisfy { $0.count == 7 })
        #expect(grid.weeks[0][0].day == Days.absolute(year: 2026, month: 9, day: 28))
        #expect(!grid.weeks[0][0].inMonth && grid.weeks[0][3].inMonth)
        #expect(grid.weeks[4][6].day == Days.absolute(year: 2026, month: 11, day: 1))
        #expect(grid.weeks.joined().filter(\.isToday).map(\.day) == [Self.today])
        // Days outside the month have no rows, even the range's.
        #expect(grid.weeks[4][6].rows.isEmpty)
        let sunday = MonthGrid(groups: [], first: Self.first, last: Self.last, today: Self.today, weekStart: 0)
        #expect(sunday.weeks[0][0].day == Days.absolute(year: 2026, month: 9, day: 27))
    }

    /// Repeats show on each occurrence; a range on each of its days in the month.
    @Test func repeatsAndRangesExpand() {
        let grid = Self.grid
        // Past occurrences of a repeat don't show, as in the agenda: the entry is overdue on
        // today; later occurrences show.
        for day in [12, 19, 26] { #expect(Self.titles(grid, day).contains("Review"), "\(day)") }
        #expect(!Self.titles(grid, 5).contains("Review"))
        #expect(Self.titles(grid, 1).contains("Rent"))
        #expect(Self.titles(grid, 30).contains("Conference") && Self.titles(grid, 31).contains("Conference"))
        #expect(Self.titles(grid, 14) == ["Dentist"])
    }

    /// Overdue entries show on their day and, first, on today; a deadline's warning only on its day.
    @Test func overdueOnTodayWarningsOnTheirDay() {
        let grid = Self.grid
        #expect(Self.titles(grid, 2) == ["Late"])
        // Oldest first.
        #expect(Self.titles(grid, 12) == ["Review", "Late"])
        #expect(Self.titles(grid, 20) == ["Report"])
    }

    @Test func eventsShowOnTheirDays() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = utc.date(from: DateComponents(year: 2026, month: 10, day: 6))!
        let event = AgendaEvent(id: "e", title: "Holiday", calendarID: "c", calendarTitle: "Home", color: nil, start: start,
                                end: start.addingTimeInterval(2 * 86400), isAllDay: true)
        let days = Agenda.list([], start: Self.first, days: 31, today: Self.today, now: (9, 0))
        let groups = AgendaRows.groups(days, events: [event], today: Self.today, showAllDates: true, calendar: utc)
        let grid = MonthGrid(groups: groups, first: Self.first, last: Self.last, today: Self.today, weekStart: 1)
        #expect(Self.titles(grid, 6) == ["Holiday"] && Self.titles(grid, 7) == ["Holiday"] && Self.titles(grid, 8).isEmpty)
    }
}
