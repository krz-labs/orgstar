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

extension DocumentSession {
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
