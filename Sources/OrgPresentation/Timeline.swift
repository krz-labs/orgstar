import Foundation
import OrgCore

/// The agenda's days laid out by time of day, as the timeline shows them. Timed rows become
/// blocks from their start to their end; a row with only a start lasts its `Effort`, or the
/// default length without one. Untimed rows (deadlines and schedules without a time, all-day
/// events, Contacts dates, overdue entries carried to today) go in the all-day strip. Blocks
/// that overlap share the day's width in columns. Times are minutes after midnight; a block
/// ends by midnight.
public struct Timeline: Sendable, Equatable {
    public struct Block: Sendable, Equatable, Identifiable {
        public let row: AgendaRow
        public let start: Int
        public let end: Int
        /// The end comes from the entry (a time range, or the event's end), not from `Effort` or
        /// the default length.
        public let hasEnd: Bool
        /// The block's column among those it overlaps, and how many there are.
        public internal(set) var column = 0
        public internal(set) var columns = 1

        public var id: String { row.id }
        /// An Org entry whose time dragging can change; events and ranges of days stay put.
        public var canMove: Bool { row.item.map(AgendaReschedule.canMoveTime) ?? false }
    }

    public struct Day: Sendable, Equatable, Identifiable {
        /// As `Days` numbers it.
        public let day: Int
        public let isToday: Bool
        public let allDay: [AgendaRow]
        public let blocks: [Block]

        public var id: Int { day }
    }

    public let days: [Day]

    /// The days from `first`, `count` of them, from the agenda's `groups` (missing days are
    /// empty). `defaultLength` is the minutes of a row with only a start and no `Effort`.
    public init(groups: [AgendaDayGroup], first: Int, count: Int, today: Int, defaultLength: Int, calendar: Calendar) {
        let byDay = Dictionary(groups.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        days = (first..<(first + count)).map { day in
            let rows = (byDay[day]?.overdue ?? []) + (byDay[day]?.rows ?? [])
            var allDay: [AgendaRow] = []
            var blocks: [Block] = []
            for row in rows {
                if let block = Self.block(row, day: day, defaultLength: defaultLength, calendar: calendar) {
                    blocks.append(block)
                } else {
                    allDay.append(row)
                }
            }
            return Day(day: day, isToday: day == today, allDay: allDay, blocks: Self.columns(blocks))
        }
    }

    /// The row's block on `day`, or nil for the all-day strip.
    static func block(_ row: AgendaRow, day: Int, defaultLength: Int, calendar: Calendar) -> Block? {
        if let event = row.event, !event.isReminder {
            guard !event.isAllDay else { return nil }
            let d = Days.date(day)
            guard let midnight = calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day)),
                  let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { return nil }
            let from = max(event.start, midnight)
            let to = min(event.end, next)
            // An event over the whole day goes with the all-day ones.
            guard from < next, to > midnight, !(from == midnight && to == next) else { return nil }
            let start = Self.minutes(from, calendar: calendar)
            let end = to == next ? 24 * 60 : Self.minutes(to, calendar: calendar)
            return Block(row: row, start: start, end: max(end, start + 1), hasEnd: true)
        }
        guard let hhmm = row.start else { return nil }
        let start = hhmm / 100 * 60 + hhmm % 100
        if let end = row.end {
            return Block(row: row, start: start, end: min(max(end / 100 * 60 + end % 100, start + 1), 24 * 60), hasEnd: true)
        }
        return Block(row: row, start: start, end: min(start + length(row, defaultLength: defaultLength), 24 * 60), hasEnd: false)
    }

    /// The minutes a row without an end lasts: its `Effort`, else `defaultLength`.
    public static func length(_ row: AgendaRow, defaultLength: Int) -> Int {
        if let effort = row.item?.effortMinutes, effort >= 1 { return Int(effort) }
        return max(defaultLength, 1)
    }

    /// The minutes after midnight of `date`'s time of day.
    public static func minutes(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// `blocks` with columns: those that overlap, directly or through others, form a group whose
    /// blocks each take the first column free at their start; every block of the group has the
    /// group's number of columns. Earlier starts first, longer first at the same start.
    static func columns(_ blocks: [Block]) -> [Block] {
        let sorted = blocks.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.end != b.element.end { return a.element.end > b.element.end }
            return a.offset < b.offset
        }.map(\.element)
        var result: [Block] = []
        var group: [Block] = []
        var columnEnds: [Int] = []
        var groupEnd = Int.min
        func close() {
            result += group.map { block in
                var block = block
                block.columns = columnEnds.count
                return block
            }
            group = []
            columnEnds = []
        }
        for var block in sorted {
            if block.start >= groupEnd { close() }
            if let free = columnEnds.firstIndex(where: { $0 <= block.start }) {
                block.column = free
                columnEnds[free] = block.end
            } else {
                block.column = columnEnds.count
                columnEnds.append(block.end)
            }
            groupEnd = group.isEmpty ? block.end : max(groupEnd, block.end)
            group.append(block)
        }
        close()
        return result
    }

    // MARK: - Dragging

    /// `minutes` to the nearest multiple of `step`; a step under 2 leaves it.
    public static func snap(_ minutes: Int, to step: Int) -> Int {
        guard step > 1 else { return minutes }
        return Int((Double(minutes) / Double(step)).rounded()) * step
    }

    /// The latest a block may end: 23:59, as a time range doesn't cross midnight.
    public static let latestEnd = MoveTimestampTime.latestEnd

    /// A block from `start` to `end` dragged by `delta` minutes: the start snapped to `step`,
    /// the length kept, and inside the day.
    public static func moved(start: Int, end: Int, by delta: Int, step: Int) -> (start: Int, end: Int) {
        let length = min(end - start, latestEnd)
        let new = min(max(snap(start + delta, to: step), 0), latestEnd - length)
        return (new, new + length)
    }

    /// The block from `start` to `end` with its top edge (`top`) or bottom edge dragged by
    /// `delta` minutes: that edge snapped to `step`, at least `step` (or one) minute from the
    /// other, and inside the day.
    public static func resized(start: Int, end: Int, top: Bool, by delta: Int, step: Int) -> (start: Int, end: Int) {
        let least = max(step, 1)
        if top {
            return (min(max(snap(start + delta, to: step), 0), end - least), end)
        }
        return (start, max(min(snap(end + delta, to: step), latestEnd), start + least))
    }

    // MARK: - Second time zone

    /// The hours of the scale, 0 to 23 on `day` in `local`, as clock times in `other`: `16:00`,
    /// `20:30`. Days as `Days` numbers them.
    public static func zoneLabels(day: Int, local: TimeZone, other: TimeZone) -> [String] {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = local
        var otherCalendar = Calendar(identifier: .gregorian)
        otherCalendar.timeZone = other
        let d = Days.date(day)
        return (0..<24).map { hour in
            guard let date = localCalendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: hour)) else { return "" }
            let c = otherCalendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
    }

    /// The zone's short name on `day`, as the scale's header shows it: `CET`, `GMT+5:30`.
    public static func zoneName(_ zone: TimeZone, day: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let d = Days.date(day)
        let date = calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12)) ?? Date()
        return zone.abbreviation(for: date) ?? zone.identifier
    }
}
