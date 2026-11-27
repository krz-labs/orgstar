import Foundation

// org-fc's commands on a heading (org-fc 0.7, with `org-fc-algorithm` sm2-v1): making a card of
// each type, updating a cloze card's holes, suspending, and rating a position, writing what
// org-fc writes.

/// `org-fc-type-normal-init`, `org-fc-type-double-init`, `org-fc-type-text-input-init` and
/// `org-fc-type-cloze-init`: the heading at point becomes a card.
public struct MakeFlashcard: OrgCommand {
    public let type: Flashcards.CardType
    let newID: @Sendable () -> String

    public init(_ type: Flashcards.CardType, newID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.type = type
        self.newID = newID
    }

    public var id: String { "org.fc.\(type.rawValue)" }
    public var title: String {
        switch type {
        case .normal: "Make Normal Flashcard"
        case .double: "Make Double Flashcard"
        case .cloze: "Make Cloze Flashcard…"
        case .textInput: "Make Text-Input Flashcard"
        }
    }

    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }

    public func run(in context: EditContext) -> CommandStep {
        guard entryHeading(at: context.caret, in: context.tree) != nil else { return .failed("Before first headline") }
        var cloze: Flashcards.ClozeType?
        if type == .cloze {
            guard let answer = context.answers["cloze-type"] else {
                return .prompt(Prompt(key: "cloze-type", message: "Cloze Type: ", choices: Flashcards.ClozeType.allCases.map(\.rawValue)))
            }
            guard let chosen = Flashcards.ClozeType(rawValue: answer) else { return .failed("Invalid cloze card type: \(answer)") }
            cloze = chosen
        }
        return commitBuffer(context) { buffer in
            try buffer.saveExcursion {
                try buffer.backToHeading()
                switch type {
                case .normal:
                    try buffer.fcInitCard("normal", newID: newID)
                    try buffer.fcReviewDataUpdate(["front"])
                case .double:
                    try buffer.fcInitCard("double", newID: newID)
                    try buffer.fcReviewDataUpdate(["front", "back"])
                case .textInput:
                    guard buffer.fcHasAnswerLine() else { throw EmacsBuffer.UserError(message: "The card has no answer line") }
                    try buffer.fcInitCard("text-input", newID: newID)
                    try buffer.fcReviewDataUpdate(["front"])
                case .cloze:
                    try buffer.fcInitCard("cloze", newID: newID)
                    try buffer.fcClozeUpdate()
                    buffer.entryPut("FC_CLOZE_TYPE", cloze!.rawValue)
                }
            }
        }
    }
}

/// `org-fc-update`: a cloze card's new holes get positions and review data; other types
/// have nothing to update.
public struct UpdateFlashcard: OrgCommand {
    public init() {}
    public var id: String { "org.fc.update" }
    public var title: String { "Update Flashcard" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            try buffer.saveExcursion {
                try buffer.fcGotoEntryHeading()
                if buffer.entryProperty("FC_TYPE") == "cloze" { try buffer.fcClozeUpdate() }
            }
        }
    }
}

/// `org-fc-suspend-card` and `org-fc-unsuspend-card`.
public struct SuspendFlashcard: OrgCommand {
    public let suspend: Bool
    public init(suspend: Bool = true) { self.suspend = suspend }
    public var id: String { suspend ? "org.fc.suspend" : "org.fc.unsuspend" }
    public var title: String { suspend ? "Suspend Flashcard" : "Unsuspend Flashcard" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            try buffer.saveExcursion {
                try buffer.fcGotoEntryHeading()
                let tags = try SetTags.tags(in: buffer)
                if suspend {
                    try buffer.fcAddTag(Flashcards.suspendedTag)
                } else {
                    try SetTags.set(tags.filter { $0 != Flashcards.suspendedTag }, in: buffer)
                }
            }
        }
    }
}

/// `org-fc-review-rate`: the review data of the card with ID `card` at `position` updated
/// for `rating` by SM2. `random` stands for the interval fuzz's `cl-random`, as a fraction
/// of its limit. The caret may be anywhere: the card is found by its ID, so a review can rate
/// cards whose offsets moved.
public struct RateFlashcard: OrgCommand {
    public let card: String
    public let position: String
    public let rating: Flashcards.Rating
    public let random: Double

    public init(card: String, position: String, rating: Flashcards.Rating, random: Double = Double.random(in: 0..<1)) {
        self.card = card
        self.position = position
        self.rating = rating
        self.random = random
    }

    public var id: String { "internal.fc.rate" }
    public var title: String { "Rate Flashcard" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            try buffer.saveExcursion {
                buffer.point = 0
                let id = NSRegularExpression.escapedPattern(for: card)
                while let match = buffer.searchForward("^[ \\t]*:ID:[ \\t]+" + id + "[ \\t]*$", caseInsensitive: true) {
                    try buffer.backToHeading()
                    if try SetTags.tags(in: buffer).contains(Flashcards.tag), buffer.entryID() == card {
                        try buffer.fcRate(position, rating: rating, random: random)
                        return
                    }
                    buffer.point = match[0]!.upperBound
                }
                throw EmacsBuffer.UserError(message: "The card is no longer in the file")
            }
        }
    }
}

extension EmacsBuffer {
    /// `org-fc--init-card`, from point at the heading.
    func fcInitCard(_ type: String, newID: () -> String) throws {
        if try SetTags.tags(in: self).contains(Flashcards.tag) { throw UserError(message: "Headline is already a flashcard") }
        try backToHeading()
        entryPut("FC_CREATED", Flashcards.timestamp(now))
        entryPut("FC_TYPE", type)
        entryPut("FC_ALGO", Flashcards.algorithm)
        if entryID() == nil { entryPut("ID", newID()) }
        try fcAddTag(Flashcards.tag)
    }

    /// `org-fc--add-tag`: the tag goes first unless the heading has it.
    func fcAddTag(_ tag: String) throws {
        let tags = try SetTags.tags(in: self)
        if !tags.contains(tag) { try SetTags.set([tag] + tags, in: self) }
    }

    /// `org-fc-goto-entry-heading`.
    func fcGotoEntryHeading() throws {
        try backToHeading()
        while try !SetTags.tags(in: self).contains(Flashcards.tag) {
            guard upHeadingSafe() != nil else { throw UserError(message: "Not inside a flashcard entry") }
        }
    }

    /// Whether `org-fc-text-input-content` finds a line, from point at the heading.
    func fcHasAnswerLine() -> Bool {
        saveExcursion {
            func entry() -> (String, Bool) {
                let end = saveExcursion { () -> Int in outlineNextHeading(); return point }
                return (substring(lineStart(point), end), end < length)
            }
            let back = saveExcursion { () -> (String, Bool)? in
                let level = outlineLevel
                let end = endOfSubtree()
                var found: (String, Bool)?
                while outlineNextHeading(), point < end {
                    guard outlineLevel == level + 1, let match = lookingAt(complexHeadingPattern), let title = match[4],
                          Flashcards.backTitles.contains(substring(title.lowerBound, title.upperBound)) else { continue }
                    found = entry()
                }
                return found
            }
            let (text, followed) = back ?? entry()
            return Flashcards.firstContentLine(text, followedByHeading: followed) != nil
        }
    }

    private static let reviewDataPattern = "^[ \\t]*:" + Flashcards.drawer + ":[ \\t]*$"

    /// `org-fc-review-data-position`: the start of the drawer's first line and of its `:END:`
    /// line, from point at the heading; with `create`, a new drawer's.
    func fcReviewDataPosition(create: Bool) -> (Int, Int)? {
        endOfMetaData()
        let end = atHeading ? point : saveExcursion { outlineNextHeading(); return point }
        while let match = searchForward(Self.reviewDataPattern, bound: end, caseInsensitive: true) {
            let begin = lineEnd(match[0]!.upperBound) + 1
            let close = saveExcursion { () -> Int? in
                point = match[0]!.upperBound
                return searchForward("^[ \\t]*:END:[ \\t]*$", bound: end, caseInsensitive: true).map { lineStart($0[0]!.lowerBound) }
            }
            if let close, begin <= close { return (begin, close) }
        }
        guard create else { return nil }
        if !bolp { insert("\n") }
        insert(":" + Flashcards.drawer + ":\n:END:\n")
        let at = lineStart(point - 1)
        return (at, at)
    }

    /// `org-fc-review-data-parse`: the table's headers and rows by position name.
    func fcReviewDataParse() throws -> (headers: [String], rows: [(name: String, values: [String: String])]) {
        let algorithm = entryProperty("FC_ALGO") ?? Flashcards.algorithm
        guard algorithm == Flashcards.algorithm else { throw UserError(message: "orgstar schedules only SM2 cards, not \(algorithm)") }
        guard let (begin, _) = saveExcursion({ fcReviewDataPosition(create: false) }) else { return (Flashcards.SM2.headers, []) }
        return saveExcursion {
            point = begin
            let table = tableToLisp()
            guard let first = table.first, let headers = first else { return (Flashcards.SM2.headers, []) }
            let rows = table.dropFirst(2).compactMap { $0 }.map { cells -> (name: String, values: [String: String]) in
                let values = Dictionary(zip(headers, cells), uniquingKeysWith: { a, _ in a })
                return (values["position"] ?? "", values)
            }
            return (headers, rows)
        }
    }

    /// `org-fc-review-data-write`.
    func fcReviewDataWrite(headers: [String], rows: [[String: String]]) {
        saveExcursion {
            let lines = ["| " + headers.joined(separator: " | ") + " |\n", "|" + headers.map { _ in "-" }.joined(separator: "+") + "|\n"]
                + rows.map { row in "| " + headers.map { row[$0] ?? "nil" }.joined(separator: " | ") + " |\n" }
            let (begin, end) = fcReviewDataPosition(create: true)!
            deleteRegion(begin, end)
            point = begin
            insert(lines.joined())
            tableAlign()
        }
    }

    /// `org-fc-review-data-update`: rows for exactly `names`, new ones with SM2's initial data.
    func fcReviewDataUpdate(_ names: [String]) throws {
        let (headers, rows) = try fcReviewDataParse()
        let sm2 = Flashcards.SM2()
        let kept = names.map { name in rows.first { $0.name == name }?.values ?? sm2.initial(name, now: now) }
        fcReviewDataWrite(headers: headers, rows: kept)
    }

    /// `org-fc-type-cloze-update`, from point at the heading.
    func fcClozeUpdate() throws {
        var end = saveExcursion { () -> Int in outlineNextHeading(); return point - 1 }
        var hole = Int(Flashcards.number(entryProperty(Flashcards.clozeMaxProperty) ?? "-1")) + 1
        var ids: [String] = []
        saveExcursion {
            while let match = searchForward(Flashcards.holePattern, bound: end, caseInsensitive: false) {
                if let id = match[3] {
                    ids.append(substring(id.lowerBound, id.upperBound))
                } else {
                    let id = String(hole)
                    hole += 1
                    end += 1 + (id as NSString).length
                    point = match[0]!.upperBound - 1
                    insert("@" + id)
                    ids.append(id)
                }
            }
        }
        entryPut(Flashcards.clozeMaxProperty, String(hole - 1))
        try fcReviewDataUpdate(ids)
    }

    /// `org-fc-algo-update-review-data`, from point at the heading. Returns the row before.
    @discardableResult
    func fcRate(_ position: String, rating: Flashcards.Rating, random: Double) throws -> [String: String] {
        let (headers, rows) = try fcReviewDataParse()
        guard let current = rows.first(where: { $0.name == position })?.values else {
            throw UserError(message: "No review data row found for this position")
        }
        let next = Flashcards.SM2().next(current, rating: rating, now: now, random: random)
        let updated = rows.map { row -> [String: String] in
            guard row.name == position else { return row.values }
            var values = row.values
            for header in headers { values[header] = next[header] ?? row.values[header] }
            return values
        }
        fcReviewDataWrite(headers: headers, rows: updated)
        return current
    }
}

extension Flashcards {
    /// `org-fc-type-cloze-max-hole-property`.
    static let clozeMaxProperty = "FC_CLOZE_MAX"
}
