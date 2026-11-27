import Foundation
import OrgCore
import OrgDocument
@testable import OrgIndex
import Testing
@testable import OrgApp

@MainActor
struct FlashcardReviewTests {
    static func card(_ title: String, id: String, type: String = "normal", rows: [(String, String)], tags: String = ":fc:") -> String {
        """
        * \(title) \(tags)
        :PROPERTIES:
        :FC_CREATED: 2026-11-01T00:00:00Z
        :FC_TYPE:  \(type)
        :FC_ALGO:  sm2
        :ID:       \(id)
        :END:
        :REVIEW_DATA:
        | position | ease | box | interval | due                  |
        |----------+------+-----+----------+----------------------|
        \(rows.map { "| \($0.0) | 2.50 | 0 | 0.00 | \($0.1) |" }.joined(separator: "\n"))
        :END:
        Answer of \(title)

        """
    }

    static let now = Date(timeIntervalSince1970: 1_795_000_000)
    static let past = "2026-11-17T00:00:00Z", future = "2026-12-30T00:00:00Z"

    @Test func reviewRatesThroughTheSessionAndLogsTheHistory() async throws {
        let notes = try Folder()
        let deck = try notes.write("deck.org", Self.card("One", id: "one", rows: [("front", Self.past)])
                                   + Self.card("Two", id: "two", type: "double", rows: [("front", Self.past), ("back", Self.past)])
                                   + Self.card("Later", id: "later", rows: [("front", Self.future)]))
        _ = try notes.write("other.org", "* Not a card\n")
        _ = try notes.write("held.org", Self.card("Held", id: "held", rows: [("front", Self.past)], tags: ":suspended:fc:"))
        let workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        #expect(try workspace.index.files(withLocalTag: "fc") == [deck.path, notes.url.appendingPathComponent("held.org").path].sorted())

        let review = FlashcardReview(workspace: workspace, session: session)
        review.history = notes.url.appendingPathComponent("logs/reviews.tsv")
        await review.start(now: Self.now)
        // One position of the double card; not the card due later or the suspended one.
        #expect(review.queue.map(\.card.id).sorted() == ["one", "two"])
        let first = try #require(review.current)
        #expect(review.face?.front.title == first.card.title)
        review.flip()
        review.rate(.again, now: Self.now)
        #expect(review.queue.map(\.card.id) == [review.queue[0].card.id, first.card.id])
        let second = try #require(review.current)
        review.rate(.easy, now: Self.now)
        #expect(review.queue.map(\.card.id) == [first.card.id] && review.reviewed == 2)

        let text = try String(contentsOf: deck, encoding: .utf8)
        let cards = Flashcards.cards(in: text)
        let card = try #require(cards.first { $0.id == second.card.id })
        let rated = try #require(card.positions.first { $0.name == second.position })
        #expect(rated.values["box"] == "2" && rated.values["due"] == "2026-11-19T11:06:40Z")
        let history = try String(contentsOf: review.history, encoding: .utf8).split(separator: "\n")
        #expect(history.count == 2)
        #expect(history[0].hasPrefix("2026-11-18T11:06:40Z\t\(deck.path)\t\(first.card.id)\t\(first.position)\t2.50\t0\t0.00\tagain\t"))
        #expect(history[1].contains("\t\(second.card.id)\t\(second.position)\t2.50\t0\t0.00\teasy\t") && history[1].hasSuffix("\tsm2-v1"))

        review.suspend()
        #expect(review.queue.isEmpty && review.face == nil)
        #expect(Flashcards.cards(in: try String(contentsOf: deck, encoding: .utf8)).first { $0.id == first.card.id }?.suspended == true)
    }

    @Test func snapshotCountsAsTimePasses() {
        let snapshot = FlashcardSnapshot(due: [Self.now.addingTimeInterval(60), Self.now.addingTimeInterval(-60), Self.now.addingTimeInterval(60)])
        #expect(snapshot.count(at: Self.now) == 1)
        #expect(snapshot.count(at: Self.now.addingTimeInterval(61)) == 3)
        #expect(snapshot.changes(after: Self.now) == [Self.now.addingTimeInterval(61)])
    }
}
