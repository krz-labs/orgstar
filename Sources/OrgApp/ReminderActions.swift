import Foundation
import OrgCore

/// The buttons on a reminder's notification. They run without bringing the app forward.
public enum ReminderAction: String, CaseIterable, Sendable {
    case done = "sh.krz.orgstar.reminder.done"
    case snoozeTenMinutes = "sh.krz.orgstar.reminder.snooze-10m"
    case snoozeHour = "sh.krz.orgstar.reminder.snooze-1h"
    case snoozeTomorrow = "sh.krz.orgstar.reminder.snooze-tomorrow"
    case clockIn = "sh.krz.orgstar.reminder.clock-in"

    /// The notification category of a reminder for an entry with a TODO keyword, which has
    /// Mark Done, and of one for an entry without.
    public static let todoCategory = "sh.krz.orgstar.reminder.todo"
    public static let entryCategory = "sh.krz.orgstar.reminder.entry"

    /// `reminder`'s category; nil for one that isn't at a heading, which has no actions.
    public static func category(for reminder: Reminder) -> String? {
        guard reminder.headingLine != nil, reminder.headingOffset != nil else { return nil }
        return reminder.doneKeyword != nil ? todoCategory : entryCategory
    }

    /// The actions of `category`, in the order shown.
    public static func actions(in category: String) -> [ReminderAction] {
        category == todoCategory ? allCases : allCases.filter { $0 != .done }
    }

    public var title: String {
        switch self {
        case .done: String(localized: "Mark Done", comment: "A reminder notification's action")
        case .snoozeTenMinutes: String(localized: "Snooze 10 Minutes", comment: "A reminder notification's action")
        case .snoozeHour: String(localized: "Snooze 1 Hour", comment: "A reminder notification's action")
        case .snoozeTomorrow: String(localized: "Snooze Until Tomorrow", comment: "A reminder notification's action")
        case .clockIn: String(localized: "Clock In", comment: "A reminder notification's action")
        }
    }

    /// How far Snooze moves the reminder, in minutes; nil for the other actions.
    public var snoozeMinutes: Int? {
        switch self {
        case .snoozeTenMinutes: 10
        case .snoozeHour: 60
        case .snoozeTomorrow: 1440
        case .done, .clockIn: nil
        }
    }
}

extension Reminder {
    /// What the notification carries to find the entry again.
    public var userInfo: [String: Any] {
        var info: [String: Any] = ["path": path, "offset": offset, "event": eventDate.timeIntervalSince1970]
        if let headingLine { info["heading"] = headingLine }
        if let headingOffset { info["headingOffset"] = headingOffset }
        if let doneKeyword { info["done"] = doneKeyword }
        if let kind { info["kind"] = kind }
        if let folder { info["folder"] = folder }
        return info
    }

    /// The reminder a delivered notification was made from; nil without a path and offset.
    public init?(identifier: String, title: String, body: String, userInfo: [AnyHashable: Any]) {
        guard let path = userInfo["path"] as? String, let offset = userInfo["offset"] as? Int else { return nil }
        let event = (userInfo["event"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        self.init(id: identifier, fireDate: event, eventDate: event, title: title, body: body, path: path, offset: offset)
        headingLine = userInfo["heading"] as? String
        headingOffset = userInfo["headingOffset"] as? Int
        doneKeyword = userInfo["done"] as? String
        kind = userInfo["kind"] as? String
        folder = userInfo["folder"] as? String
    }
}

/// What a reminder's action came to.
public enum ReminderActionOutcome: Equatable, Sendable {
    /// The file was changed, or the clock started.
    case changed
    /// The notification comes again at this time.
    case snoozed(Date)
    /// The entry isn't where the reminder was set any more; open the file instead.
    case notFound
    case failed(String)
}

/// Runs a reminder's actions on its entry: Mark Done and Clock In as the agenda does, through
/// `DocumentSession.perform` and `ClockModel`, and Snooze on the notification, or with
/// `snoozeInFile` on the entry's timestamp. Changed files are saved at once.
@MainActor
public struct ReminderActions {
    /// Where a notification-only snooze is set.
    public let center: ReminderCenter
    public let session: DocumentSession
    public let clock: ClockModel
    /// The org files whose dangling clocks Clock In looks for.
    public var paths: () -> [String] = { [] }
    /// `reminders-snooze-timestamp`: Snooze moves the timestamp in the file.
    public var snoozeInFile: () -> Bool = { OrgPreferences.remindersSnoozeTimestamp() }
    public var handled = HandledReminders()
    public var calendar = Calendar.current

    /// The identifier a snoozed notification has: its reminder's with this in front, so that
    /// the scheduler, which owns identifiers starting `orgstar.`, leaves it alone.
    public static let snoozePrefix = "sh.krz.orgstar.snoozed."

    public init(center: ReminderCenter, session: DocumentSession, clock: ClockModel) {
        self.center = center
        self.session = session
        self.clock = clock
    }

    /// The scheduler's identifier for the reminder a notification is, or was snoozed from.
    public static func reminderID(_ identifier: String) -> String {
        identifier.hasPrefix(snoozePrefix) ? String(identifier.dropFirst(snoozePrefix.count)) : identifier
    }

    public func run(_ action: ReminderAction, on reminder: Reminder, now: Date = Date()) async -> ReminderActionOutcome {
        // Once acted on, the reminder isn't set again when its notification has gone.
        handled.insert(Self.reminderID(reminder.id))
        if let minutes = action.snoozeMinutes, !snoozeInFile() || !Self.movable(reminder) {
            return await snooze(reminder, minutes: minutes, now: now)
        }
        guard let line = reminder.headingLine, let near = reminder.headingOffset,
              let start = session.locateHeading(path: reminder.path, line: line, near: near) else { return .notFound }
        let outcome: ReminderActionOutcome
        switch action {
        case .done:
            guard let keyword = reminder.doneKeyword else { return .notFound }
            // A note `org-log-done` asks for is left empty.
            outcome = Self.outcome(session.perform(SetTodo(keyword: keyword), path: reminder.path, at: start, expect: (start, line), answers: ["note": ""], now: now))
        case .clockIn:
            // Questions about dangling clocks go unanswered, which leaves those clocks alone.
            let result = await clock.clockIn(session, target: .entry(path: reminder.path, offset: start), paths: paths(), ask: { _ in nil }, now: { now })
            let message = result.messages.last ?? ""
            outcome = message.hasPrefix("Clock starts") || message.hasPrefix("Clock continues") ? .changed : .failed(message)
        case .snoozeTenMinutes, .snoozeHour, .snoozeTomorrow:
            let marker = start + reminder.offset - near
            outcome = Self.outcome(session.perform(ShiftTimestampBy(minutes: action.snoozeMinutes ?? 0), path: reminder.path, at: marker,
                                                   expect: (start, line), now: now))
        }
        for path in session.dirtyPaths { _ = session.save(path) }
        return outcome
    }

    /// Whether Snooze can move the entry's timestamp: a plain, SCHEDULED or DEADLINE one, not
    /// a range of days.
    static func movable(_ reminder: Reminder) -> Bool {
        guard let kind = reminder.kind.flatMap(AgendaItem.Kind.init(rawValue:)) else { return false }
        return [.timestamp, .scheduled, .deadline].contains(kind)
    }

    private func snooze(_ reminder: Reminder, minutes: Int, now: Date) async -> ReminderActionOutcome {
        let until = minutes == 1440 ? calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86400) : now.addingTimeInterval(Double(minutes * 60))
        var snoozed = Reminder(id: Self.snoozePrefix + Self.reminderID(reminder.id), fireDate: until, eventDate: reminder.eventDate,
                               title: reminder.title, body: reminder.body, path: reminder.path, offset: reminder.offset)
        snoozed.headingLine = reminder.headingLine
        snoozed.headingOffset = reminder.headingOffset
        snoozed.doneKeyword = reminder.doneKeyword
        snoozed.kind = reminder.kind
        snoozed.folder = reminder.folder
        do {
            try await center.add(snoozed)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .snoozed(until)
    }

    private static func outcome(_ step: CommandStep) -> ReminderActionOutcome {
        switch step {
        case .commit: .changed
        case .failed(let message): .failed(message)
        case .prompt(let prompt): .failed(prompt.message)
        case .external: .failed(String(localized: "This can't be done from a notification.", comment: "A reminder's action that needs the app"))
        }
    }

    /// A notification, without actions, telling what happened when an action couldn't be done;
    /// tapping it opens the file. Nil when there is nothing to tell.
    public static func notice(_ outcome: ReminderActionOutcome, for reminder: Reminder, now: Date = Date()) -> Reminder? {
        let body: String
        switch outcome {
        case .changed, .snoozed: return nil
        case .notFound:
            let name = (reminder.path as NSString).lastPathComponent
            body = String(localized: "This entry isn't in \(name) as it was. Tap to open the file.", comment: "A reminder's action whose entry moved or changed")
        case .failed(let message): body = message
        }
        return Reminder(id: "sh.krz.orgstar.reminder-notice", fireDate: now.addingTimeInterval(1), eventDate: now,
                        title: reminder.title, body: body, path: reminder.path, offset: 0)
    }
}
