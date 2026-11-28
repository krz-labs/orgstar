import Foundation
import OrgCore

/// The agenda's month as a grid of weeks: each day's rows as the month agenda (`v m`) lists
/// them, with repeats on each occurrence and a range on each of its days. Today has the overdue
/// entries first, as in the agenda, but not the warnings of deadlines to come, which show on
/// their own days. Days of the weeks around the month are in the grid without rows.
public struct MonthGrid: Sendable, Equatable {
    public struct Cell: Sendable, Equatable, Identifiable {
        /// As `Days` numbers it.
        public let day: Int
        public let inMonth: Bool
        public let isToday: Bool
        public let rows: [AgendaRow]

        public var id: Int { day }
    }

    /// Seven cells a week, from the first week holding the month's first day to the one
    /// holding its last.
    public let weeks: [[Cell]]

    /// `groups` are the month's days (`showAllDates`, so none is missing); `first` and `last`
    /// its first and last day; weeks start on `weekStart` (0 is Sunday).
    public init(groups: [AgendaDayGroup], first: Int, last: Int, today: Int, weekStart: Int) {
        let byDay = Dictionary(groups.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let start = Days.weekStart(first, on: weekStart)
        let end = Days.weekStart(last, on: weekStart) + 7
        weeks = stride(from: start, to: end, by: 7).map { week in
            (week..<(week + 7)).map { day in
                let inMonth = (first...last).contains(day)
                let group = byDay[day]
                let rows = inMonth ? ((group?.overdue ?? []) + (group?.rows ?? [])).filter { Self.shows($0, on: day) } : []
                return Cell(day: day, inMonth: inMonth, isToday: day == today, rows: rows)
            }
        }
    }

    /// Whether the grid shows `row` on `day`: not a warning on today of a deadline to come.
    public static func shows(_ row: AgendaRow, on day: Int) -> Bool {
        guard let item = row.item, item.kind == .deadline || item.kind == .upcomingDeadline else { return true }
        return (item.planningDay ?? day) <= day
    }
}
