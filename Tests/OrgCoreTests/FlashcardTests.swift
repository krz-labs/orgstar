import Foundation
import Testing
@testable import OrgCore

struct FlashcardTests {
    static let now = Date(timeIntervalSince1970: 1_795_000_000.25)

    static func run(_ command: any OrgCommand, _ text: String, caret: Int = 0, now: Date = now, answers: [String: String] = [:]) -> (text: String, failed: String?) {
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], now: now, answers: answers)
        switch command.run(in: context) {
        case .commit(let result):
            var new = text
            for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
            return (new, nil)
        case .failed(let message): return (text, message)
        case .prompt(let prompt): return (text, "prompt \(prompt.key)")
        default: return (text, "other")
        }
    }

    /// What `org-fc-type-normal-init` and `org-fc-type-cloze-init` wrote in Emacs 31.1 with
    /// Org 9.8.7 and org-fc at fce1cb2, the clock at 1795000000.25.
    @Test func makesCardsAsOrgFcDoes() {
        let text = "* Q :x:\n\nans\n* Cloze\nThe {{cat}{animal}} sat on {{mat}}.\n** Back\nb\n"
        var result = Self.run(MakeFlashcard(.normal) { "the-id" }, text)
        #expect(result.failed == nil)
        let cloze = (result.text as NSString).range(of: "* Cloze").location
        #expect(Self.run(MakeFlashcard(.cloze) { "the-id" }, result.text, caret: cloze).failed == "prompt cloze-type")
        result = Self.run(MakeFlashcard(.cloze) { "the-id" }, result.text, caret: cloze, answers: ["cloze-type": "deletion"])
        #expect(result.failed == nil)
        #expect(result.text == """
            * Q                                                                    :fc:x:
            :PROPERTIES:
            :FC_CREATED: 2026-11-18T11:06:40Z
            :FC_TYPE:  normal
            :FC_ALGO:  sm2
            :ID:       the-id
            :END:
            :REVIEW_DATA:
            | position | ease | box | interval | due                  |
            |----------+------+-----+----------+----------------------|
            | front    | 2.50 |   0 |     0.00 | 2026-11-18T11:06:40Z |
            :END:

            ans
            * Cloze                                                                  :fc:
            :PROPERTIES:
            :FC_CREATED: 2026-11-18T11:06:40Z
            :FC_TYPE:  cloze
            :FC_ALGO:  sm2
            :ID:       the-id
            :FC_CLOZE_MAX: 1
            :FC_CLOZE_TYPE: deletion
            :END:
            :REVIEW_DATA:
            | position | ease | box | interval | due                  |
            |----------+------+-----+----------+----------------------|
            |        0 | 2.50 |   0 |     0.00 | 2026-11-18T11:06:40Z |
            |        1 | 2.50 |   0 |     0.00 | 2026-11-18T11:06:40Z |
            :END:
            The {{cat}{animal}@0} sat on {{mat}@1}.
            ** Back
            b

            """)
        #expect(Self.run(MakeFlashcard(.normal), result.text).failed == "Headline is already a flashcard")
    }

    @Test func sm2FollowsOrgFc() {
        let sm2 = Flashcards.SM2()
        func next(_ ease: String, _ box: String, _ interval: String, _ rating: Flashcards.Rating, random: Double = 0.5) -> [String] {
            let row = sm2.next(["ease": ease, "box": box, "interval": interval], rating: rating, now: Self.now, random: random)
            return [row["ease"]!, row["box"]!, row["interval"]!]
        }
        // Learning boxes keep the ease and take fixed intervals.
        #expect(next("2.50", "0", "0.00", .good) == ["2.50", "1", "0.01"])
        #expect(next("2.50", "0", "0.00", .easy) == ["2.50", "2", "1.00"])
        #expect(next("2.50", "1", "0.01", .again) == ["2.50", "0", "0.00"])
        #expect(next("2.50", "2", "1.00", .good) == ["2.50", "3", "6.00"])
        // Then the ease changes, and the interval is ease times the last, fuzzed.
        #expect(next("2.50", "3", "6.00", .good, random: 0.5) == ["2.50", "4", "15.00"])
        #expect(next("2.50", "3", "6.00", .hard, random: 0) == ["2.35", "4", "12.69"])
        #expect(next("2.50", "3", "6.00", .easy, random: 1) == ["2.65", "4", "17.49"])
        #expect(next("1.40", "5", "20.00", .again) == ["1.30", "0", "0.00"])
        #expect(next("4.95", "5", "20.00", .easy) == ["5.00", "6", "100.00"])
        #expect(sm2.next(["ease": "2.50", "box": "1", "interval": "0.01"], rating: .good, now: Self.now, random: 0)["due"] == "2026-11-19T11:06:40Z")
    }

    static let deck = """
        * Normal :fc:
        :PROPERTIES:
        :FC_CREATED: 2026-11-01T00:00:00Z
        :FC_TYPE:  normal
        :FC_ALGO:  sm2
        :ID:       n
        :END:
        :REVIEW_DATA:
        | position | ease | box | interval | due                  |
        |----------+------+-----+----------+----------------------|
        | front    | 2.50 |   0 |     0.00 | 2026-11-18T00:00:00Z |
        :END:
        Answer text
        * Double :fc:
        :PROPERTIES:
        :FC_TYPE:  double
        :ID:       d
        :END:
        :REVIEW_DATA:
        | position | ease | box | interval | due                  |
        |----------+------+-----+----------+----------------------|
        | front    | 2.50 |   0 |     0.00 | 2026-11-19T00:00:00Z |
        | back     | 2.50 |   0 |     0.00 | 2026-11-18T00:00:00Z |
        :END:
        Hund
        * Cloze {{one}@0} :fc:
        :PROPERTIES:
        :FC_TYPE:  cloze
        :FC_CLOZE_TYPE: enumeration
        :ID:       c
        :END:
        :REVIEW_DATA:
        | position | ease | box | interval | due                  |
        |----------+------+-----+----------+----------------------|
        | 0        | 2.50 |   0 |     0.00 | 2026-11-18T00:00:00Z |
        | 1        | 2.50 |   0 |     0.00 | 2026-11-18T00:00:00Z |
        | 2        | 2.50 |   0 |     0.00 | 2026-12-30T00:00:00Z |
        :END:
        {{two}{hint}@1} and {{three}@2}, not {{four}}.
        ** More
        extra
        * Suspended :suspended:fc:
        :PROPERTIES:
        :FC_TYPE:  normal
        :ID:       s
        :END:
        :REVIEW_DATA:
        | position | ease | box | interval | due                  |
        |----------+------+-----+----------+----------------------|
        | front    | 2.50 |   0 |     0.00 | 2026-11-18T00:00:00Z |
        :END:
        * No drawer :fc:
        :PROPERTIES:
        :ID:       x
        :END:
        """

    @Test func readsCardsAndDuePositions() {
        let cards = Flashcards.cards(in: Self.deck)
        #expect(cards.map(\.id) == ["n", "d", "c", "s"])
        #expect(cards[0].positions.map(\.name) == ["front"] && cards[0].positions[0].ease == 2.5 && cards[0].body == "Answer text")
        #expect(cards[2].clozeType == .enumeration && cards[2].children == "** More\nextra")
        #expect(cards[3].suspended)
        let due = Flashcards.due(cards.map { (path: "/a.org", card: $0) }, at: Self.now, shuffle: false).map { "\($0.card.id) \($0.position)" }
        // One position of the double card (the first due), every due one of the enumeration.
        #expect(due == ["n front", "d back", "c 0", "c 1"])
        #expect(Flashcards.dueCount(cards, at: Self.now) == 4)
        #expect(Flashcards.dueCount(cards, at: Date(timeIntervalSince1970: 0)) == 0)
        var generator = SeededGenerator(state: testSeed(7))
        let shuffled = Flashcards.due(cards.map { (path: "/a.org", card: $0) }, at: Self.now, using: &generator).map { "\($0.card.id) \($0.position)" }
        #expect(Set(shuffled) == Set(due))
        #expect(shuffled.firstIndex(of: "c 0")! < shuffled.firstIndex(of: "c 1")!)
    }

    @Test func facesHideWhatOrgFcHides() throws {
        let cards = Flashcards.cards(in: Self.deck)
        let normal = try #require(Flashcards.face(cards[0], position: "front"))
        #expect(normal.front == .init(title: "Normal", text: "") && normal.back.text == "Answer text")
        let back = try #require(Flashcards.face(cards[1], position: "back"))
        #expect(back.front.title == nil && back.front.text == "Hund" && back.back.title == "Double")
        let first = try #require(Flashcards.face(cards[2], position: "1"))
        #expect(first.front.title == "Cloze one" && first.front.text == "[...hint] and ..., not {{four}}.")
        #expect(first.back.text == "two and ..., not {{four}}.\n\n** More\nextra")
        let marked = ("Cloze one\n" + first.back.text) as NSString
        #expect(marked.substring(with: NSRange(first.back.marks[0])) == "two")
        var context = cards[2]
        context.clozeType = .context
        #expect(Flashcards.face(context, position: "0")?.front.title == "Cloze [...]")
        #expect(Flashcards.face(context, position: "0")?.front.text == "two and ..., not {{four}}.")
        context.clozeType = .single
        #expect(Flashcards.face(context, position: "2")?.front.text == "... and [...], not {{four}}.")
        #expect(Flashcards.face(cards[2], position: "9") == nil)
    }

    @Test func textInputComparesTheFirstLine() {
        let text = "* Q :fc:\n:PROPERTIES:\n:FC_TYPE:  text-input\n:ID:       t\n:END:\n:REVIEW_DATA:\n| position | due |\n|-+-|\n| front | 2026-11-18T00:00:00Z |\n:END:\nThe *answer* here\nmore\n"
        let card = Flashcards.cards(in: text)[0]
        #expect(card.answerLine == "The *answer* here")
        #expect(Flashcards.face(card, position: "front")?.expected == "answer")
        #expect(Self.run(MakeFlashcard(.textInput), "* Q\n** Child\n").failed == "The card has no answer line")
    }

    @Test func historyLinesAsOrgFcWritesThem() {
        let position = Flashcards.Position(name: "front", values: ["ease": "2.50", "box": "1", "interval": "0.01"])
        #expect(Flashcards.historyLine(at: Self.now, path: "/n/a.org", id: "x", position: position, rating: .hard, seconds: 4.567)
            == "2026-11-18T11:06:40Z\t/n/a.org\tx\tfront\t2.50\t1\t0.01\thard\t4.57\tsm2-v1\n")
    }

    @Test func ratingFindsTheCardByID() {
        let rated = Self.run(RateFlashcard(card: "d", position: "back", rating: .easy, random: 0.5), Self.deck)
        #expect(rated.failed == nil)
        let card = Flashcards.cards(in: rated.text).first { $0.id == "d" }!
        #expect(card.positions[1].values["box"] == "2" && card.positions[1].values["due"] == "2026-11-19T11:06:40Z")
        #expect(Self.run(RateFlashcard(card: "gone", position: "front", rating: .good), Self.deck).failed == "The card is no longer in the file")
        #expect(Self.run(RateFlashcard(card: "n", position: "back", rating: .good), Self.deck).failed == "No review data row found for this position")
    }
}
