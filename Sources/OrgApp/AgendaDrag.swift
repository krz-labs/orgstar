import Foundation
import OrgCore
import OrgPresentation

/// An agenda row being dragged to another day: the day it was on and the row's id, as the
/// drag's text. Calendar events, Contacts dates and entries that can't move aren't dragged.
public struct AgendaDrag: Sendable, Equatable {
    public let day: Int
    public let rowID: String

    /// Nil for a row dragging can't move.
    public init?(_ row: AgendaRow, day: Int) {
        guard let item = row.item, AgendaReschedule.canMove(item) else { return nil }
        self.day = day
        self.rowID = row.id
    }

    public init?(payload: String) {
        let parts = payload.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == Self.prefix, let day = Int(parts[1]), let rowID = parts[2].removingPercentEncoding else { return nil }
        self.day = day
        self.rowID = rowID
    }

    /// `orgstar-agenda-row`, the day and the row's id percent-encoded: plain text, as the row id's
    /// control characters don't survive a drop.
    public var payload: String {
        "\(Self.prefix) \(day) " + (rowID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }

    static let prefix = "orgstar-agenda-row"

    /// The dragged row among `groups`, the days shown.
    public func row(in groups: [AgendaDayGroup]) -> AgendaRow? {
        groups.lazy.filter { $0.day == day }.compactMap { group in (group.overdue + group.rows).first { $0.id == rowID } }.first
    }
}

/// An entry of the timeline's TODO list being dragged onto the timeline to schedule it: the
/// row's id, as the drag's text.
public struct AgendaTodoDrag: Sendable, Equatable {
    public let rowID: String

    /// Nil for a row that isn't an entry under a heading.
    public init?(_ row: AgendaRow) {
        guard let item = row.item, item.path != nil, item.headingLine != nil, item.headingOffset != nil else { return nil }
        self.rowID = row.id
    }

    public init?(payload: String) {
        let parts = payload.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == Self.prefix, let rowID = parts[1].removingPercentEncoding else { return nil }
        self.rowID = rowID
    }

    /// `orgstar-agenda-todo` and the row's id percent-encoded.
    public var payload: String {
        "\(Self.prefix) " + (rowID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }

    static let prefix = "orgstar-agenda-todo"

    public func row(in rows: [AgendaRow]) -> AgendaRow? { rows.first { $0.id == rowID } }
}

extension DocumentSession {
    /// Gives `row`'s entry, shown on `day`, the time `start` (minutes after midnight) to `end`
    /// on `target`, with `MoveTimestampTime` at its marker through `perform`. Nil when nothing
    /// would change.
    public func retime(_ row: AgendaRow, shownOn day: Int, to target: Int, start: Int, end: Int?, answers: [String: String] = [:],
                       now: Date = Date()) -> CommandStep? {
        guard let item = row.item, AgendaReschedule.canMoveTime(item), let path = item.path, let offset = item.headingOffset,
              let line = item.headingLine, let marker = item.markerOffset else { return .failed("Only dated entries can move") }
        let days = AgendaReschedule.days(item, shownOn: day, to: target)
        func hhmm(_ minutes: Int) -> Int { minutes / 60 * 100 + minutes % 60 }
        if days == 0, row.start == hhmm(start), row.end == end.map(hhmm) { return nil }
        return perform(MoveTimestampTime(days: days, start: start, end: end), path: path, at: marker, expect: (offset, line), answers: answers, now: now)
    }

    /// Schedules `item`, an entry without a date, on `day` at `start` (minutes after midnight),
    /// as `org-schedule` with that date and time typed.
    public func schedule(_ item: AgendaItem, on day: Int, at start: Int, answers: [String: String] = [:], now: Date = Date()) -> CommandStep {
        let d = Days.date(day)
        let date = String(format: "%04d-%02d-%02d %02d:%02d", d.year, d.month, d.day, start / 60, start % 60)
        return perform(SetPlanning(deadline: false), on: item, answers: answers.merging(["date": date]) { $1 }, now: now)
    }

    /// Moves `item`, shown on `day`, to `target` with `MoveTimestampDays` at its marker, through
    /// `perform`: in its buffer when the file is open, else in the file. Nil when it is
    /// already there.
    public func reschedule(_ item: AgendaItem, shownOn day: Int, to target: Int, answers: [String: String] = [:], now: Date = Date()) -> CommandStep? {
        guard AgendaReschedule.canMove(item), let path = item.path, let start = item.headingOffset, let line = item.headingLine,
              let marker = item.markerOffset else { return .failed("Only dated entries can move") }
        let days = AgendaReschedule.days(item, shownOn: day, to: target)
        guard days != 0 else { return nil }
        return perform(MoveTimestampDays(days: days), path: path, at: marker, expect: (start, line), answers: answers, now: now)
    }
}
