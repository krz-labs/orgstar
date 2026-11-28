import Foundation
import Observation
import OrgCore
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Where reminders are delivered: the system's notification center, or a fake in tests.
public protocol ReminderCenter: Sendable {
    /// Whether notifications may be shown, asking the user the first time.
    func authorize() async -> Bool
    /// IDs of pending requests.
    func pendingIDs() async -> [String]
    /// IDs of notifications shown and still in Notification Center.
    func deliveredIDs() async -> [String]
    func add(_ reminder: Reminder) async throws
    func remove(_ ids: [String])
}

/// Keeps the pending notifications equal to the reminders the agenda gives.
@MainActor
@Observable
public final class ReminderScheduler {
    /// The last event a reminder is set for, so the agenda can say how far ahead they go.
    public private(set) var scheduledThrough: Date?
    /// False when the user turned notifications off for the app.
    public private(set) var isAuthorized = true

    private let center: ReminderCenter
    /// What this run set; one no longer pending has fired and isn't set again.
    private var scheduled: Set<String> = []
    private let handled: HandledReminders

    public init(center: ReminderCenter, handled: HandledReminders = HandledReminders()) {
        self.center = center
        self.handled = handled
    }

    /// Adds reminders that are new, removes ours that no longer apply, leaves the rest.
    public func reconcile(_ reminders: [Reminder]) async {
        isAuthorized = await center.authorize()
        guard isAuthorized else {
            scheduledThrough = nil
            return
        }
        let wanted = Set(reminders.map(\.id))
        handled.keep(wanted)
        let acted = handled.ids
        let reminders = reminders.filter { !acted.contains($0.id) }
        let pending = Set(await center.pendingIDs().filter { $0.hasPrefix("orgstar.") })
        let stale = pending.subtracting(wanted)
        if !stale.isEmpty { center.remove(Array(stale)) }
        scheduled.subtract(stale)
        // A reminder whose warning time has passed fires at once; once shown, it stays shown.
        let delivered = Set(await center.deliveredIDs())
        for reminder in reminders where !pending.contains(reminder.id) && !scheduled.contains(reminder.id) && !delivered.contains(reminder.id) {
            try? await center.add(reminder)
            scheduled.insert(reminder.id)
        }
        scheduledThrough = reminders.map(\.eventDate).max()
    }

    /// Removes every reminder, when the user turns them off.
    public func clear() async {
        let ours = await center.pendingIDs().filter { $0.hasPrefix("orgstar.") }
        if !ours.isEmpty { center.remove(ours) }
        scheduled = []
        scheduledThrough = nil
    }
}

/// Reminders acted on from their notification, by identifier. One isn't set again while it
/// applies, though its notification has gone from Notification Center.
public struct HandledReminders: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "handledReminders"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var ids: Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    public func insert(_ id: String) {
        defaults.set(Array(ids.union([id])).sorted(), forKey: Self.key)
    }

    /// Forgets the ones not in `current`.
    func keep(_ current: Set<String>) {
        let kept = ids.intersection(current)
        if kept != ids { defaults.set(Array(kept).sorted(), forKey: Self.key) }
    }
}

#if canImport(UserNotifications)
/// `UNUserNotificationCenter`. Only usable from an app bundle.
public struct SystemReminderCenter: ReminderCenter {
    public init() {}

    /// The system center needs a bundle identifier; a bare debug binary has none.
    public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Registers reminders' actions, which run in the background.
    public static func registerCategories() {
        let categories = [ReminderAction.todoCategory, ReminderAction.entryCategory].map { category in
            UNNotificationCategory(identifier: category, actions: ReminderAction.actions(in: category).map {
                UNNotificationAction(identifier: $0.rawValue, title: $0.title, options: [])
            }, intentIdentifiers: [])
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
    }

    /// The reminder `response` is for, and the action chosen; nil action for a tap.
    public static func reminder(of response: UNNotificationResponse) -> (Reminder, ReminderAction?)? {
        let request = response.notification.request
        guard let reminder = Reminder(identifier: request.identifier, title: request.content.title, body: request.content.body,
                                      userInfo: request.content.userInfo) else { return nil }
        return (reminder, ReminderAction(rawValue: response.actionIdentifier))
    }

    public func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined:
            // iOS shows the overdue count on the icon.
            #if os(iOS)
            let options: UNAuthorizationOptions = [.alert, .sound, .badge]
            #else
            let options: UNAuthorizationOptions = [.alert, .sound]
            #endif
            return (try? await center.requestAuthorization(options: options)) ?? false
        default: return false
        }
    }

    public func pendingIDs() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }

    public func add(_ reminder: Reminder) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.userInfo = reminder.userInfo
        if let category = ReminderAction.category(for: reminder) { content.categoryIdentifier = category }
        if let folder = reminder.folder { content.filterCriteria = folder }
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
    }

    public func deliveredIDs() async -> [String] {
        await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier)
    }

    public func remove(_ ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}
#endif
