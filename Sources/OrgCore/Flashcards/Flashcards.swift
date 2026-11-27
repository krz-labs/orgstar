import Foundation

/// Flashcards in org-fc's format (github.com/l3kn/org-fc), so cards and their review data
/// carry over to Emacs: a heading tagged `fc` with `FC_CREATED`, `FC_TYPE`, `FC_ALGO` and an
/// `ID`, and a `REVIEW_DATA` drawer holding a table with a row per position (position, ease,
/// box, interval, due). `suspended` leaves a card out of reviews.
public enum Flashcards {
    public static let tag = "fc"
    public static let suspendedTag = "suspended"
    public static let drawer = "REVIEW_DATA"
    /// `FC_ALGO` of new cards: org-fc's SM2, the only algorithm `org-fc` loads by default.
    public static let algorithm = "sm2"
    /// `org-fc-algorithm`, written to the review history.
    public static let historyAlgorithm = "sm2-v1"
    /// `org-fc-back-heading-titles`.
    public static let backTitles = ["Back"]
    /// `org-fc-type-cloze-context`.
    public static let clozeContext = 1

    public enum CardType: String, CaseIterable, Sendable {
        case normal, double, cloze
        case textInput = "text-input"
    }

    /// `org-fc-type-cloze-types`.
    public enum ClozeType: String, CaseIterable, Sendable {
        case deletion, enumeration, context, single
    }

    public enum Rating: String, CaseIterable, Sendable {
        case again, hard, good, easy
    }

    /// One row of the review data table.
    public struct Position: Sendable, Equatable {
        public var name: String
        /// The row's cells by column name, as written.
        public var values: [String: String]

        public init(name: String, values: [String: String]) {
            self.name = name
            self.values = values
        }

        public var due: Date? { values["due"].flatMap(Flashcards.date) }
        public var ease: Double { Flashcards.number(values["ease"]) }
        public var box: Int { Int(Flashcards.number(values["box"])) }
        public var interval: Double { Flashcards.number(values["interval"]) }
    }

    /// A heading tagged `fc` with a `REVIEW_DATA` drawer after its property drawer, as org-fc's
    /// indexer finds them.
    public struct Card: Sendable, Equatable {
        public var id: String
        public var title: String
        /// `FC_TYPE` as written.
        public var type: String
        public var clozeType: ClozeType?
        /// `FC_ALGO`; nil for cards from before org-fc 0.6, which are SM2's.
        public var algorithm: String?
        public var created: Date?
        public var suspended: Bool
        /// Inherited tags first, then the heading's own.
        public var tags: [String]
        public var positions: [Position]
        /// Where the heading starts, and its line.
        public var headingOffset: Int
        public var headingLine: String
        /// The entry's text before its first subheading, without planning lines and drawers.
        public var body: String
        /// The subheadings, without planning lines and drawers.
        public var children: String
        /// The text of the `Back` subheading, if there is one.
        public var back: String?
        /// The first line of the answer, as text-input cards compare it: the line after the
        /// `Back` heading's metadata, or the entry's.
        public var answerLine: String?

        public var cardType: CardType? { CardType(rawValue: type) }

        /// Positions due before `now`, unless the card is suspended.
        public func due(at now: Date) -> [Position] {
            suspended ? [] : positions.filter { ($0.due ?? .distantFuture) < now }
        }
    }

    // MARK: - Reading

    /// The cards in `text`.
    public static func cards(in text: String, defaults: OrgSettings = .default) -> [Card] {
        guard text.contains(":" + tag + ":") else { return [] }
        let tree = OrgParser.parse(text, defaults: defaults)
        let model = DocumentModel(tree: tree)
        let ns = text as NSString
        var cards: [Card] = []
        for (index, heading) in model.headings.enumerated() where heading.localTags.contains(tag) {
            let lineEnd = ns.lineRange(for: NSRange(location: heading.headingRange.lowerBound, length: 0))
            let bodyStart = NSMaxRange(lineEnd)
            let childIndexes = model.headings.indices.filter { model.headings[$0].parent == index }
            let bodyEnd = childIndexes.first.map { model.headings[$0].sectionRange.lowerBound } ?? heading.sectionRange.upperBound
            let entry = ns.substring(with: NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart)))
            guard let positions = reviewData(entry) else { continue }
            func property(_ key: String) -> String? { heading.properties.last { $0.key.uppercased() == key && !$0.additive }?.value }
            let backIndex = childIndexes.last { model.headings[$0].level == heading.level + 1 && backTitles.contains(model.headings[$0].title) }
            let backRange = backIndex.map { model.headings[$0].sectionRange }
            let back = backRange.map { ns.substring(with: NSRange(location: $0.lowerBound, length: $0.upperBound - $0.lowerBound)) }
            let children = ns.substring(with: NSRange(location: bodyEnd, length: heading.sectionRange.upperBound - bodyEnd))
            let headingLine = ns.substring(with: NSRange(location: lineEnd.location, length: lineEnd.length)).trimmingCharacters(in: .newlines)
            cards.append(Card(
                id: property("ID") ?? "", title: heading.title, type: property("FC_TYPE") ?? "",
                clozeType: property("FC_CLOZE_TYPE").flatMap(ClozeType.init(rawValue:)), algorithm: property("FC_ALGO"),
                created: property("FC_CREATED").flatMap(date), suspended: heading.localTags.contains(suspendedTag),
                tags: model.tags(of: index).map(\.value), positions: positions,
                headingOffset: heading.headingRange.lowerBound, headingLine: headingLine,
                body: readable(entry), children: readable(children), back: back.map { readable(lines($0).dropFirst().joined(separator: "\n")) },
                answerLine: back.map { firstContentLine($0, followedByHeading: backRange!.upperBound < ns.length) }
                    ?? firstContentLine(headingLine + "\n" + entry, followedByHeading: bodyEnd < ns.length)
            ))
        }
        return cards
    }

    /// The rows of the `REVIEW_DATA` drawer in an entry's text, if it has one after its
    /// property drawer.
    static func reviewData(_ entry: String) -> [Position]? {
        let all = lines(entry)
        guard let properties = all.firstIndex(where: { isDrawerLine($0, "PROPERTIES") }),
              let propertiesEnd = all[properties...].firstIndex(where: { isDrawerLine($0, "END") }),
              let start = all[(propertiesEnd + 1)...].firstIndex(where: { isDrawerLine($0, drawer) }),
              let end = all[(start + 1)...].firstIndex(where: { isDrawerLine($0, "END") }) else { return nil }
        var headers: [String] = []
        var positions: [Position] = []
        var separated = false
        for line in all[(start + 1)..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { continue }
            if trimmed.range(of: "^\\|[-+]+\\|$", options: .regularExpression) != nil {
                separated = true
                continue
            }
            let cells = trimmed.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if !separated {
                headers = cells
            } else if cells.count == headers.count {
                let values = Dictionary(zip(headers, cells), uniquingKeysWith: { a, _ in a })
                positions.append(Position(name: values["position"] ?? "", values: values))
            }
        }
        return positions
    }

    static func isDrawerLine(_ line: String, _ name: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(":" + name + ":") == .orderedSame
    }

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// `text` without planning lines and drawers, and without blank lines at either end.
    public static func readable(_ text: String) -> String {
        var kept: [String] = []
        var inDrawer = false
        for line in lines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inDrawer {
                if trimmed.caseInsensitiveCompare(":END:") == .orderedSame { inDrawer = false }
                continue
            }
            if trimmed.range(of: "^:[\\w-]+:$", options: .regularExpression) != nil {
                inDrawer = true
                continue
            }
            if trimmed.range(of: "^(SCHEDULED|DEADLINE|CLOSED):", options: .regularExpression) != nil { continue }
            kept.append(line)
        }
        while kept.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeFirst() }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    /// `org-fc-text-input-content`: the line after a heading's planning and drawers, unless
    /// it is a heading. `text` starts with the heading line and runs to the next heading.
    static func firstContentLine(_ text: String, followedByHeading: Bool) -> String? {
        var lines = lines(text)
        if text.hasSuffix("\n") { lines.removeLast() }
        var i = 1
        while i < lines.count, lines[i].range(of: "^(SCHEDULED|DEADLINE): *<[^>]+>", options: .regularExpression) != nil { i += 1 }
        while i < lines.count, lines[i].range(of: "^[ \\t]*:[\\w-]+:[ \\t]*$", options: .regularExpression) != nil {
            guard let end = lines[(i + 1)...].firstIndex(where: { $0.contains(":END:") }) else { return nil }
            i = end + 1
        }
        guard i < lines.count else { return followedByHeading ? nil : "" }
        return lines[i].range(of: "^\\*+ ", options: .regularExpression) != nil ? nil : lines[i]
    }

    // MARK: - Values

    /// `string-to-number`.
    static func number(_ string: String?) -> Double {
        guard let string else { return 0 }
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let value = Double(trimmed) { return value }
        let prefix = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        return Double(prefix) ?? 0
    }

    /// `org-fc-timestamp-in`: `%FT%TZ` in UTC, `days` after `now`.
    public static func timestamp(_ now: Date, plus days: Double = 0) -> String {
        let seconds = now.timeIntervalSince1970 + days * 60 * 60 * 24
        var time = time_t(seconds.rounded(.down))
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday),
                      Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec))
    }

    /// A `%FT%TZ` timestamp.
    public static func date(_ string: String) -> Date? {
        let parts = string.split(whereSeparator: { "-T:Z".contains($0) }).compactMap { Int($0) }
        guard string.hasSuffix("Z"), parts.count == 6 else { return nil }
        var t = tm()
        t.tm_year = Int32(parts[0] - 1900)
        t.tm_mon = Int32(parts[1] - 1)
        t.tm_mday = Int32(parts[2])
        t.tm_hour = Int32(parts[3])
        t.tm_min = Int32(parts[4])
        t.tm_sec = Int32(parts[5])
        return Date(timeIntervalSince1970: TimeInterval(timegm(&t)))
    }

    // MARK: - Review history

    /// A line of `org-fc-review-history-file`, as `org-fc-algo-log-review` appends it: the
    /// position's values before the rating, and the seconds between showing and rating it.
    public static func historyLine(at now: Date, path: String, id: String, position: Position, rating: Rating, seconds: Double) -> String {
        [timestamp(now), path, id, position.name, position.values["ease"] ?? "", position.values["box"] ?? "", position.values["interval"] ?? "",
         rating.rawValue, String(format: "%.2f", seconds), historyAlgorithm].joined(separator: "\t") + "\n"
    }

    // MARK: - Review sessions

    /// A position to review.
    public struct Item: Sendable, Equatable {
        public var path: String
        public var card: Card
        public var position: String

        public init(path: String, card: Card, position: String) {
            self.path = path
            self.card = card
            self.position = position
        }
    }

    /// The positions due at `now`, as `org-fc-review` queues them with its default filters:
    /// suspended cards and positions not yet due left out, and one position for each card
    /// other than single and enumeration cloze cards. Shuffled as `org-fc-shuffle-positions`
    /// does: each card's positions keep their order.
    public static func due<G: RandomNumberGenerator>(_ cards: [(path: String, card: Card)], at now: Date, shuffle: Bool = true, using generator: inout G) -> [Item] {
        var keyed: [(Double, Item)] = []
        for (path, card) in cards {
            var due = card.due(at: now)
            guard !due.isEmpty else { continue }
            if !(card.cardType == .cloze && [.single, .enumeration].contains(card.clozeType)) { due = [due[0]] }
            let keys = due.map { _ in Double.random(in: 0..<1, using: &generator) }.sorted(by: >)
            keyed += zip(keys, due).map { ($0, Item(path: path, card: card, position: $1.name)) }
        }
        guard shuffle else { return keyed.map(\.1) }
        return keyed.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }.map(\.element.1)
    }

    public static func due(_ cards: [(path: String, card: Card)], at now: Date, shuffle: Bool = true) -> [Item] {
        var generator = SystemRandomNumberGenerator()
        return due(cards, at: now, shuffle: shuffle, using: &generator)
    }

    /// When each position a review would show falls due: every position of single and
    /// enumeration cloze cards, the earliest of the others' (a review shows one of them).
    public static func dueDates(_ card: Card) -> [Date] {
        guard !card.suspended else { return [] }
        let dates = card.positions.compactMap(\.due)
        if card.cardType == .cloze && [.single, .enumeration].contains(card.clozeType) { return dates }
        return dates.min().map { [$0] } ?? []
    }

    /// How many positions a review started at `now` would show.
    public static func dueCount(_ cards: [Card], at now: Date) -> Int {
        cards.reduce(0) { $0 + dueDates($1).filter { $0 < now }.count }
    }
}
