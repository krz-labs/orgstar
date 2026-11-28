import Foundation
import OrgCore
import OrgDocument

/// What a swipe on one edge of an agenda row shows, as `agenda-swipe-leading` and
/// `agenda-swipe-trailing` set it.
public enum AgendaSwipe: String, CaseIterable, Sendable {
    case done, reschedule, refile, none

    public static func leading(_ defaults: UserDefaults = .standard) -> AgendaSwipe {
        AgendaSwipe(rawValue: OrgPreferences.agendaSwipeLeading(defaults)) ?? .reschedule
    }

    public static func trailing(_ defaults: UserDefaults = .standard) -> AgendaSwipe {
        AgendaSwipe(rawValue: OrgPreferences.agendaSwipeTrailing(defaults)) ?? .done
    }
}

/// Mark Done and Reschedule on an agenda entry, as the rows' swipes and context menus run them
/// through `DocumentSession.perform(_:on:)`.
extension AgendaItem {
    /// Mark Done: the first done keyword of the entry's sequence; nil for an entry without a
    /// TODO keyword or already done.
    public var markDone: SetTodo? {
        guard todo != nil, !isDone, let doneKeyword else { return nil }
        return SetTodo(keyword: doneKeyword)
    }

    /// Whether Reschedule applies: an entry under a heading, not done, with a TODO keyword or
    /// listed for its schedule or deadline.
    public var canReschedule: Bool {
        guard path != nil, headingLine != nil, !isDone else { return false }
        return todo != nil || [.scheduled, .pastScheduled, .deadline, .upcomingDeadline].contains(kind)
    }

    /// Whether a line for this entry is for its deadline, which Reschedule moves instead of
    /// the schedule.
    public var isDeadline: Bool { kind == .deadline || kind == .upcomingDeadline }

    /// Reschedule to `day`: the deadline on a deadline line, else the schedule, keeping its
    /// time of day and repeater, as `org-agenda-schedule` and `org-agenda-deadline` do with a
    /// date typed after the time they pre-fill.
    public func reschedule(to day: Int) -> (command: SetPlanning, answers: [String: String]) {
        let date = Days.date(day)
        return (SetPlanning(deadline: isDeadline, keepTime: true), ["date": String(format: "%04d-%02d-%02d", date.year, date.month, date.day)])
    }
}

extension DocumentSession {
    /// Runs `command` at the agenda entry's heading, found again by its heading line in case
    /// other edits moved it, through `perform(_:path:at:expect:answers:now:)`: in the buffer
    /// when the file is open, as an edit its editor can undo, otherwise on the file.
    public func perform(_ command: any OrgCommand, on item: AgendaItem, answers: [String: String] = [:], now: Date = Date()) -> CommandStep {
        guard let path = item.path, let line = item.headingLine, let near = item.headingOffset,
              let offset = locateHeading(path: path, line: line, near: near) else {
            return .failed("The entry changed; the agenda has been refreshed.")
        }
        return perform(command, path: path, at: offset, expect: (offset, line), answers: answers, now: now)
    }

    /// Refiles the agenda entry under the target labelled `label`. `targets` lists the targets
    /// for the entry's file and its text now, since targets in that file move with earlier
    /// edits. Returns a message for the echo area.
    public func refile(_ item: AgendaItem, to label: String, targets: (_ path: String, _ document: DocumentState?) -> [RefileTarget],
                       now: Date = Date()) -> String? {
        guard let path = item.path, let line = item.headingLine, let near = item.headingOffset,
              let offset = locateHeading(path: path, line: line, near: near) else {
            return "The entry changed; the agenda has been refreshed."
        }
        let document = openDocuments.first { $0.path == path }?.document
            ?? FileManager.default.contents(atPath: path).map { DocumentState(bytes: [UInt8]($0)) }
        guard let target = targets(path, document).first(where: { $0.label == label }) else { return "Can't find \(label) any more." }
        return refile(to: target, from: (path, offset), now: now)
    }
}
