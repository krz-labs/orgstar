import Foundation
import OrgCore
import OrgPresentation

/// What the widgets and controls show besides the agenda, written by the app into the app
/// group's container as `AgendaSnapshot` is.
public protocol WidgetData: Codable, Equatable, Sendable {
    static var name: String { get }
}

extension WidgetData {
    /// `Widgets/<name>` in the app group's container; nil without the group.
    public static func file(group: String = CaptureInbox.group) -> URL? {
        AgendaSnapshot.file(group: group)?.deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func read(from file: URL? = Self.file()) -> Self? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? AgendaSnapshot.decoder.decode(Self.self, from: data)
    }

    /// Writes unless the file holds the same; true when it wrote.
    @discardableResult
    public func write(to file: URL? = Self.file()) throws -> Bool {
        guard let file, Self.read(from: file) != self else { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AgendaSnapshot.encoder.encode(self).write(to: file, options: .atomic)
        return true
    }
}

/// The agenda files' habits, whose consistency graphs the widget draws for its own day.
public struct HabitSnapshot: WidgetData {
    public static let name = "habits.json"

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var title: String
        public var path: String
        public var offset: Int
        /// The heading line and the keyword marking the habit done takes, for its checkbox.
        public var headingLine: String?
        public var doneKeyword: String?
        public var habit: Habit
        public var id: String { "\(path):\(offset)" }

        public init(title: String, path: String, offset: Int, headingLine: String? = nil, doneKeyword: String? = nil, habit: Habit) {
            self.title = title
            self.path = path
            self.offset = offset
            self.headingLine = headingLine
            self.doneKeyword = doneKeyword
            self.habit = habit
        }

        public var link: AppLink { .entry(path: path, offset: offset) }

        public func isDone(on day: Int) -> Bool { habit.doneDates.contains(day) }

        /// In `day`'s habits: scheduled then or before, or done that day, which moved it on.
        public func isDue(on day: Int) -> Bool { habit.scheduled <= day || isDone(on: day) }

        /// What its checkbox marks done.
        public var done: EntryDone? {
            guard let headingLine, let doneKeyword else { return nil }
            return EntryDone(path: path, offset: offset, headingLine: headingLine, keyword: doneKeyword)
        }
    }

    public var habits: [Entry]
    /// `habit-clear`, `habit-ready`, `habit-alert` and `habit-overdue`.
    public var colors: [String: AgendaSnapshot.Hex]

    public init(habits: [Entry], colors: [String: AgendaSnapshot.Hex]) {
        self.habits = habits
        self.colors = colors
    }

    /// The habits of `day` (a `Days` number), as the widget and the watch list them.
    public func habits(on day: Int) -> [Entry] { habits.filter { $0.isDue(on: day) } }

    /// `habits`, colored by `theme`.
    public init(habits: [Entry], theme: ThemeSpec) {
        var colors: [String: AgendaSnapshot.Hex] = [:]
        for key in ["habit-clear", "habit-ready", "habit-alert", "habit-overdue"] {
            colors[key] = AgendaSnapshot.Hex { theme.color(key, dark: $0) }
        }
        self.init(habits: habits, colors: colors)
    }
}

/// When the flashcard positions a review would show fall due, for the Flashcards widget to
/// count at each of its times.
public struct FlashcardSnapshot: WidgetData {
    public static let name = "flashcards.json"

    public var due: [Date]

    public init(due: [Date]) {
        self.due = due.sorted()
    }

    public init(cards: [Flashcards.Card]) {
        self.init(due: cards.flatMap(Flashcards.dueDates))
    }

    /// Positions due before `date`.
    public func count(at date: Date) -> Int { due.prefix { $0 < date }.count }

    /// The times after `date` the count goes up, at most `limit` of them.
    public func changes(after date: Date, limit: Int = 24) -> [Date] {
        Array(Set(due.filter { $0 >= date }.map { $0.addingTimeInterval(1) })).sorted().prefix(limit).map { $0 }
    }
}

/// The running clock and the entry Clock In Last would clock into, for the clock control.
public struct ClockSnapshot: WidgetData {
    public static let name = "clock.json"

    public var running: String?
    public var startedAt: Date?
    /// The most recent entry clocked, `org-clock-in-last`'s.
    public var last: String?

    public init(running: String?, startedAt: Date?, last: String?) {
        self.running = running
        self.startedAt = startedAt
        self.last = last
    }
}

/// The capture templates' keys and names, for choosing one in a widget's or control's settings.
public struct TemplateList: WidgetData {
    public static let name = "templates.json"

    public struct Template: Codable, Equatable, Sendable {
        public var key: String
        public var name: String

        public init(key: String, name: String) {
            self.key = key
            self.name = name
        }
    }

    public var templates: [Template]

    public init(templates: [Template]) {
        self.templates = templates
    }
}
