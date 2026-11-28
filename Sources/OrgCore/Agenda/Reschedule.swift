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
            let before = buffer.substring(buffer.lineStart(whole.lowerBound), whole.lowerBound)
            let kind: EmacsBuffer.PlanningKind? = before.range(of: "\\bDEADLINE: *$", options: .regularExpression) != nil ? .deadline
                : before.range(of: "\\bSCHEDULED: *$", options: .regularExpression) != nil ? .scheduled : nil
            if let kind {
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
