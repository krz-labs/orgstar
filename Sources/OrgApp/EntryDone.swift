import AppIntents
import Foundation
import OrgCore
#if os(macOS)
import AppKit
#endif

/// An entry to mark done from outside the editor: a widget's checkbox, the watch, a reminder's
/// Mark Done.
public struct EntryDone: Codable, Hashable, Sendable {
    public var path: String
    /// Where its heading line started when the widget or watch was given it.
    public var offset: Int
    public var headingLine: String
    /// The first done keyword of its sequence.
    public var keyword: String

    public init(path: String, offset: Int, headingLine: String, keyword: String) {
        self.path = path
        self.offset = offset
        self.headingLine = headingLine
        self.keyword = keyword
    }
}

extension DocumentSession {
    /// Sets the keyword of `done`'s entry, found by its heading line at its offset or the
    /// nearest copy of the line, as the agenda does, and saves the file at once. A note
    /// `org-log-done` or `org-log-repeat` asks for is left empty.
    public func markDone(_ done: EntryDone, now: Date = Date()) -> ReminderActionOutcome {
        guard let start = locateHeading(path: done.path, line: done.headingLine, near: done.offset) else { return .notFound }
        let step = perform(SetTodo(keyword: done.keyword), path: done.path, at: start, expect: (start, done.headingLine), answers: ["note": ""], now: now)
        if dirtyPaths.contains(done.path) { _ = save(done.path) }
        return ReminderActions.outcome(step)
    }
}

/// A random key the Mac app writes for its widgets, which their checkbox's `orgstar://done`
/// link carries, so that only the widgets can mark entries done through a link.
public struct WidgetActionKey: WidgetData {
    public static let name = "actions.json"

    public var key: String

    public init(key: String) {
        self.key = key
    }

    static let defaultsKey = "widgetActionKey"

    /// The app's key, made on first use.
    public static func current(defaults: UserDefaults = .standard) -> String {
        if let key = defaults.string(forKey: defaultsKey) { return key }
        let key = UUID().uuidString
        defaults.set(key, forKey: defaultsKey)
        return key
    }
}

/// A widget's checkbox: marks the entry done without opening the app. On iOS it runs in the
/// app's process, as a Live Activity's intent does, which sets `handler`. On the Mac it runs in
/// the widget extension, which can't write the folders: it hands the entry to the app with an
/// `orgstar://done` link opened in the background.
public struct CompleteEntryIntent: AppIntent {
    public static let title: LocalizedStringResource = "Mark Done"
    public static let description = IntentDescription("Marks an agenda entry or a habit done.")
    public static let isDiscoverable = false

    @Parameter(title: "File")
    public var path: String
    @Parameter(title: "Position")
    public var offset: Int
    @Parameter(title: "Heading")
    public var headingLine: String
    @Parameter(title: "Keyword")
    public var keyword: String

    /// Marks the entry done and updates the widgets; set by the app at launch.
    @MainActor public static var handler: (@MainActor @Sendable (EntryDone) async -> Void)?

    public init() {}

    public init(_ done: EntryDone) {
        path = done.path
        offset = done.offset
        headingLine = done.headingLine
        keyword = done.keyword
    }

    public func perform() async throws -> some IntentResult {
        let done = EntryDone(path: path, offset: offset, headingLine: headingLine, keyword: keyword)
        if let handler = await MainActor.run(body: { Self.handler }) {
            guard ProAccess.isUnlockedNow else { return .result() }
            await handler(done)
        } else {
            // The Mac app checks orgstar+ when the link comes.
            #if os(macOS)
            guard let key = WidgetActionKey.read()?.key else { return .result() }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.open(AppLink.done(done, key: key).url, configuration: configuration)
            #endif
        }
        return .result()
    }
}

#if os(iOS)
extension CompleteEntryIntent: LiveActivityIntent {}
#endif

/// OrgApp's App Intents, for the app and the widget extension to include.
public struct OrgAppIntents: AppIntentsPackage {}
