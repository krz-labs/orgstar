import Foundation

/// Moving agenda entries to another day, as dragging them in the month grid and the day list
/// does.
public enum AgendaReschedule {
    /// Whether dragging can move `item`: an entry's deadline, schedule, timestamp or range, not
    /// a diary sexp, a log line or an entry without a heading.
    public static func canMove(_ item: AgendaItem) -> Bool {
        guard item.path != nil, item.headingOffset != nil, item.headingLine != nil, item.markerOffset != nil else { return false }
        switch item.kind {
        case .deadline, .upcomingDeadline, .scheduled, .pastScheduled, .timestamp, .block: return true
        default: return false
        }
    }

    /// The day `item` stands for when shown on `day`: a deadline's or schedule's own day (the
    /// repeat's for a repeated one), which differs from `day` for warnings and overdue entries
    /// shown on today; for timestamps and ranges, `day`.
    public static func day(of item: AgendaItem, shownOn day: Int) -> Int {
        switch item.kind {
        case .deadline, .upcomingDeadline, .scheduled, .pastScheduled: item.planningDay ?? day
        default: day
        }
    }

    /// How many days `item`, shown on `day`, moves to land on `target`.
    public static func days(_ item: AgendaItem, shownOn day: Int, to target: Int) -> Int {
        target - self.day(of: item, shownOn: day)
    }

    /// Whether the timeline can change `item`'s time: as `canMove`, but not a range of days.
    public static func canMoveTime(_ item: AgendaItem) -> Bool {
        canMove(item) && item.kind != .block
    }
}

/// Moves the timestamp at the caret, where the agenda's marker for an entry points, by `days`.
/// A `SCHEDULED` or `DEADLINE` timestamp is set as `org-schedule` and `org-deadline` set a typed
/// date: the new date with the old time (and end time), the repeater and warning kept, `CLOSED`
/// removed, and `org-log-reschedule` / `org-log-redeadline` noted. Any other timestamp moves as
/// `org-agenda-date-later` moves it, time and repeater kept; a range `<a>--<b>` moves both ends.
public struct MoveTimestampDays: OrgCommand {
    public let days: Int
    public init(days: Int) { self.days = days }
    public var id: String { "org.agenda.move-days" }
    public var title: String { "Move to Day" }
    public func applies(in context: EditContext) -> Bool {
        EmacsBuffer(context.text, point: context.caret).atTimestamp() != nil
    }

    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            guard let match = buffer.atTimestamp()?.match else { throw EmacsBuffer.UserError(message: "Not at a timestamp") }
            let whole = match[0]!
            if buffer.substring(whole.lowerBound, whole.upperBound).hasPrefix("<%%") {
                throw EmacsBuffer.UserError(message: "A diary sexp can't move")
            }
            if let kind = planningKind(buffer, at: whole) {
                buffer.point = whole.lowerBound
                guard let old = buffer.planningValue(kind), let answer = Self.answer(old, days: days, calendar: buffer.calendar) else {
                    throw EmacsBuffer.UserError(message: "Not at a timestamp")
                }
                try buffer.schedule(kind, answer: answer, answers: context.answers)
                return
            }
            buffer.point = whole.lowerBound + 1
            if let range = buffer.atDateRange() {
                // The end first, so the start's offset holds.
                for stamp in [range[2]!, range[1]!] {
                    buffer.point = stamp.lowerBound
                    try buffer.changeTimestamp(days, what: .day, updateClock: false)
                }
            } else {
                try buffer.changeTimestamp(days, what: .day, updateClock: false)
            }
        }
    }

    /// The date prompt's answer for `old` (a planning time string) moved by `days`:
    /// `2026-12-05`, with `10:00` or `10:00-11:00` when `old` has times.
    static func answer(_ old: String, days: Int, calendar: Calendar) -> String? {
        guard let components = EmacsBuffer.parseTimeString(old),
              let date = calendar.date(from: DateComponents(year: components.year, month: components.month, day: components.day)),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        let d = calendar.dateComponents([.year, .month, .day], from: moved)
        var answer = String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
        if let time = old.firstMatch(of: /\ ([012]?[0-9]:[0-5][0-9](-[012]?[0-9]:[0-5][0-9])?)/) {
            answer += " " + time.output.1
        }
        return answer
    }
}

/// `DEADLINE` or `SCHEDULED` when the timestamp at `whole` follows that keyword.
private func planningKind(_ buffer: EmacsBuffer, at whole: Range<Int>) -> EmacsBuffer.PlanningKind? {
    let before = buffer.substring(buffer.lineStart(whole.lowerBound), whole.lowerBound)
    return before.range(of: "\\bDEADLINE: *$", options: .regularExpression) != nil ? .deadline
        : before.range(of: "\\bSCHEDULED: *$", options: .regularExpression) != nil ? .scheduled : nil
}

/// Sets the time of the timestamp at the caret and moves its date by `days`, as dragging an
/// entry on the agenda timeline does. `start` and `end` are minutes after midnight, written as
/// `10:00` or, with `end`, the range `10:00-11:30`. A range never crosses midnight: `end` is
/// after `start` and at most 23:59. A `SCHEDULED` or `DEADLINE` timestamp is set as
/// `org-schedule` and `org-deadline` set a typed date and time: repeater and warning kept,
/// `CLOSED` removed, `org-log-reschedule` / `org-log-redeadline` noted. Any other timestamp is
/// written with the new date and time, its repeater and warning kept. A range of days and a
/// diary sexp are refused.
public struct MoveTimestampTime: OrgCommand {
    public let days: Int
    public let start: Int
    public let end: Int?
    public init(days: Int = 0, start: Int, end: Int?) {
        self.days = days
        self.start = start
        self.end = end
    }
    public var id: String { "org.agenda.move-time" }
    public var title: String { "Move to Time" }
    public func applies(in context: EditContext) -> Bool {
        EmacsBuffer(context.text, point: context.caret).atTimestamp() != nil
    }

    /// The latest end of a time range, 23:59, in minutes.
    public static let latestEnd = 24 * 60 - 1

    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            guard (0..<Self.latestEnd).contains(start), end.map({ $0 > start && $0 <= Self.latestEnd }) ?? true else {
                throw EmacsBuffer.UserError(message: "A time range can't cross midnight")
            }
            guard let match = buffer.atTimestamp()?.match else { throw EmacsBuffer.UserError(message: "Not at a timestamp") }
            let whole = match[0]!
            let stamp = buffer.substring(whole.lowerBound, whole.upperBound)
            if stamp.hasPrefix("<%%") { throw EmacsBuffer.UserError(message: "A diary sexp can't move") }
            let time = Self.clock(start) + (end.map { "-" + Self.clock($0) } ?? "")
            if let kind = planningKind(buffer, at: whole) {
                buffer.point = whole.lowerBound
                guard let old = buffer.planningValue(kind), let date = MoveTimestampDays.answer(old, days: days, calendar: buffer.calendar)?.prefix(10) else {
                    throw EmacsBuffer.UserError(message: "Not at a timestamp")
                }
                try buffer.schedule(kind, answer: date + " " + time, answers: context.answers)
                return
            }
            buffer.point = whole.lowerBound + 1
            if buffer.atDateRange() != nil { throw EmacsBuffer.UserError(message: "A range of days can't change its time") }
            guard var components = EmacsBuffer.parseTimeString(stamp) else { throw EmacsBuffer.UserError(message: "Not at a timestamp") }
            components.day! += days
            components.hour = start / 60
            components.minute = start % 60
            let normalized = buffer.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: buffer.calendar.date(from: components)!)
            // The repeater and warning, after the old end time if there is one.
            let cookies = stamp.firstMatch(of: /(?:-[012][0-9]:[0-5][0-9])?((?: +[.+]?-?[-+][0-9]+[hdwmy](?:\/[0-9]+[hdwmy])?)*)[\]>]$/)
                .map { String($0.output.1) } ?? ""
            buffer.replace(whole, with: "")
            buffer.point = whole.lowerBound
            buffer.insertTimestamp(normalized, withTime: true, inactive: stamp.hasPrefix("["), extra: (end.map { "-" + Self.clock($0) } ?? "") + cookies)
        }
    }

    /// `10:00`.
    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}
