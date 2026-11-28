import Foundation

/// What the watch shows, sent by the phone over WatchConnectivity: today's agenda, the running
/// clock and the entry Clock In Last would take. The watch keeps the last one it got.
public struct WatchAgenda: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// The agenda's gutter: the time or a short status.
        public var gutter: String
        public var category: String
        public var todo: String?
        /// `AgendaRow.Status`'s raw value: `overdue`, `due-soon`, `normal`, `done`.
        public var status: String
        public var isDone: Bool
        public var isEvent: Bool
        public var start: Date?
        public var end: Date?
        /// Where the entry is, and its heading line, for the phone to find it again.
        public var path: String?
        public var offset: Int?
        public var headingLine: String?
        /// The keyword marking it done takes: the first done keyword of its sequence.
        public var doneKeyword: String?

        public init(
            id: String, title: String, gutter: String, category: String, todo: String?, status: String, isDone: Bool, isEvent: Bool,
            start: Date?, end: Date?, path: String?, offset: Int?, headingLine: String?, doneKeyword: String?
        ) {
            self.id = id
            self.title = title
            self.gutter = gutter
            self.category = category
            self.todo = todo
            self.status = status
            self.isDone = isDone
            self.isEvent = isEvent
            self.start = start
            self.end = end
            self.path = path
            self.offset = offset
            self.headingLine = headingLine
            self.doneKeyword = doneKeyword
        }

        /// An open TODO entry the phone can find.
        public var canBeDone: Bool {
            !isDone && !isEvent && todo != nil && doneKeyword != nil && path != nil && offset != nil && headingLine != nil
        }

        /// The action marking it done.
        public var done: WatchAction? {
            guard canBeDone, let path, let offset, let headingLine, let doneKeyword else { return nil }
            return .done(path: path, offset: offset, headingLine: headingLine, keyword: doneKeyword)
        }
    }

    public struct Clock: Codable, Equatable, Sendable {
        public var heading: String
        public var startedAt: Date

        public init(heading: String, startedAt: Date) {
            self.heading = heading
            self.startedAt = startedAt
        }
    }

    /// A flashcard position due for review: a normal or double card's two sides as text.
    public struct Card: Codable, Equatable, Sendable, Identifiable {
        public var path: String
        /// The card's ID.
        public var card: String
        public var position: String
        /// The front's title; nil while it is hidden.
        public var title: String?
        public var front: String
        public var backTitle: String
        public var back: String

        public var id: String { path + "\n" + card + "\n" + position }

        public init(path: String, card: String, position: String, title: String?, front: String, backTitle: String, back: String) {
            self.path = path
            self.card = card
            self.position = position
            self.title = title
            self.front = front
            self.backTitle = backTitle
            self.back = back
        }

        /// The action rating it `rating` (`again`, `hard`, `good` or `easy`).
        public func rate(_ rating: String) -> WatchAction { .rate(path: path, card: card, position: position, rating: rating) }
    }

    /// A habit of today's, with the last week of its consistency graph.
    public struct Habit: Codable, Equatable, Sendable, Identifiable {
        /// A day of the graph: org-habit's face (`clear`, `readyFuture`, …) and whether the
        /// habit was done that day.
        public struct Day: Codable, Equatable, Sendable {
            public var face: String
            public var isDone: Bool

            public init(face: String, isDone: Bool) {
                self.face = face
                self.isDone = isDone
            }
        }

        public var path: String
        public var offset: Int
        public var headingLine: String
        public var title: String
        /// The keyword marking it done takes; nil when it has none.
        public var doneKeyword: String?
        /// Oldest first, today last.
        public var days: [Day]

        public var id: String { "\(path):\(offset)" }

        public init(path: String, offset: Int, headingLine: String, title: String, doneKeyword: String?, days: [Day]) {
            self.path = path
            self.offset = offset
            self.headingLine = headingLine
            self.title = title
            self.doneKeyword = doneKeyword
            self.days = days
        }

        public var isDoneToday: Bool { days.last?.isDone ?? false }

        /// The action marking it done, while it isn't done today.
        public var done: WatchAction? {
            guard !isDoneToday, let doneKeyword else { return nil }
            return .done(path: path, offset: offset, headingLine: headingLine, keyword: doneKeyword)
        }
    }

    /// Flashcard positions due, in review order; nil from a phone without them.
    public var cards: [Card]?
    /// Today's habits; nil from a phone without them.
    public var habits: [Habit]?

    public var generated: Date
    /// Midnight starting today.
    public var day: Date
    /// Deadlines and scheduled entries from before today.
    public var overdue: [Entry]
    public var rows: [Entry]
    public var clock: Clock?
    /// The most recently clocked entry, `org-clock-in-last`'s.
    public var lastClocked: String?
    /// True when the phone hasn't got orgstar+, which the Watch app needs.
    public var locked: Bool?

    /// What the phone sends without Pro: no entries.
    public static func locked(generated: Date) -> WatchAgenda {
        var agenda = WatchAgenda(generated: generated, day: generated, overdue: [], rows: [], clock: nil, lastClocked: nil)
        agenda.locked = true
        return agenda
    }

    public init(generated: Date, day: Date, overdue: [Entry], rows: [Entry], clock: Clock?, lastClocked: String?) {
        self.generated = generated
        self.day = day
        self.overdue = overdue
        self.rows = rows
        self.clock = clock
        self.lastClocked = lastClocked
    }

    /// What's left of today at `now`, as the Up Next widget counts it: entries that aren't
    /// done, without timed ones that have ended (or started, with no end), then the overdue.
    public func upcoming(at now: Date, calendar: Calendar = .current) -> [Entry] {
        guard calendar.isDate(day, inSameDayAs: now) else { return [] }
        let left = rows.filter { row in
            guard !row.isDone else { return false }
            if let end = row.end ?? row.start { return end > now }
            return true
        }
        return left + overdue.filter { !$0.isDone }
    }

    /// The first of `upcoming`.
    public func next(at now: Date, calendar: Calendar = .current) -> Entry? { upcoming(at: now, calendar: calendar).first }

    /// Open TODO entries today and overdue, as the complication counts them.
    public func openCount(at now: Date, calendar: Calendar = .current) -> Int {
        guard calendar.isDate(day, inSameDayAs: now) else { return 0 }
        return (rows + overdue).filter { !$0.isDone && !$0.isEvent && $0.todo != nil }.count
    }

    /// `card` rated here before the phone sends the agenda again: gone, or with Again, last.
    public func rating(_ card: Card, again: Bool) -> WatchAgenda {
        var copy = self
        copy.cards?.removeAll { $0.id == card.id }
        if again { copy.cards?.append(card) }
        return copy
    }

    /// `entry` marked done here before the phone sends the agenda again.
    public func markingDone(_ id: String) -> WatchAgenda {
        var copy = self
        func mark(_ rows: inout [Entry]) {
            for i in rows.indices where rows[i].id == id {
                rows[i].isDone = true
                rows[i].todo = rows[i].doneKeyword
                rows[i].status = "done"
            }
        }
        mark(&copy.rows)
        mark(&copy.overdue)
        return copy
    }

    /// The habit with `id` marked done here before the phone sends the agenda again.
    public func markingHabitDone(_ id: String) -> WatchAgenda {
        var copy = self
        if let i = copy.habits?.firstIndex(where: { $0.id == id }), let last = copy.habits?[i].days.indices.last {
            copy.habits?[i].days[last].isDone = true
        }
        return copy
    }

    // MARK: - Transfer

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The application context key the agenda travels under.
    public static let contextKey = "agenda"

    public func data() throws -> Data { try Self.encoder.encode(self) }

    public static func decode(_ data: Data) -> WatchAgenda? { try? decoder.decode(WatchAgenda.self, from: data) }

    /// `Widgets/watch.json` in the app group's container, which the complications read; nil
    /// without the group.
    public static func file(group: String = "group.sh.krz.orgstar") -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Widgets").appendingPathComponent("watch.json")
    }

    public static func read(from file: URL? = file()) -> WatchAgenda? {
        file.flatMap { try? Data(contentsOf: $0) }.flatMap(decode)
    }

    /// Writes unless the file holds the same; true when it wrote.
    @discardableResult
    public func write(to file: URL? = WatchAgenda.file()) throws -> Bool {
        guard let file, Self.read(from: file) != self else { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data().write(to: file, options: .atomic)
        return true
    }
}

/// What the watch asks the phone to do.
public enum WatchAction: Codable, Equatable, Sendable {
    /// Sets the entry's keyword to `keyword`, if its heading line is still `headingLine`.
    case done(path: String, offset: Int, headingLine: String, keyword: String)
    case clockOut
    /// `org-clock-in-last`.
    case clockInLast
    /// Dictated text for the capture inbox.
    case capture(text: String)
    /// Rates a flashcard position, found by its card's ID.
    case rate(path: String, card: String, position: String, rating: String)

    /// The user info key an action travels under.
    public static let key = "action"

    public var userInfo: [String: Any] {
        guard let data = try? WatchAgenda.encoder.encode(self) else { return [:] }
        return [Self.key: data]
    }

    public init?(userInfo: [String: Any]) {
        guard let data = userInfo[Self.key] as? Data, let action = try? WatchAgenda.decoder.decode(WatchAction.self, from: data) else { return nil }
        self = action
    }
}
