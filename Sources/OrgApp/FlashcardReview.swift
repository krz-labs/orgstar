import Foundation
import Observation
import OrgCore
import OrgIndex

/// A review of the flashcards due across the workspace, as `org-fc-review` runs one over
/// `org-fc-directories`: each due position shown, flipped and rated, its review data written
/// back through the document session (an edit the buffer can undo when the file is open) and
/// a line added to the review history. A position rated Again comes back at the end.
@MainActor
@Observable
public final class FlashcardReview {
    /// Positions left, the one shown first.
    public private(set) var queue: [Flashcards.Item] = []
    /// What the first position shows, read from its file's current text.
    public private(set) var face: Flashcards.Face?
    public var flipped = false
    /// A text-input card's typed answer.
    public var typed = ""
    public private(set) var reviewed = 0
    public private(set) var isLoading = false
    /// Set once the first load finished.
    public private(set) var loaded = false
    /// Why the last action didn't happen, for the screen to show.
    public var message: String?

    private let workspace: WorkspaceModel
    private let session: DocumentSession
    @ObservationIgnored private var shownAt = Date()
    /// Where ratings are logged: `org-fc-review-history-file`.
    @ObservationIgnored public var history = OrgPreferences.fcReviewHistoryFile()

    public init(workspace: WorkspaceModel, session: DocumentSession) {
        self.workspace = workspace
        self.session = session
    }

    public var current: Flashcards.Item? { queue.first }

    /// The cards in the workspace's files, open files as their buffers have them. Only files
    /// whose index rows have a heading tagged `fc` are read.
    public static func cards(workspace: WorkspaceModel, session: DocumentSession) async -> [(path: String, card: Flashcards.Card)] {
        let open = session.openDocuments
        let overlay = workspace.overlay(open)
        let paths = (try? workspace.index.files(withLocalTag: Flashcards.tag, overlay: overlay)) ?? []
        let texts = session.openTexts
        let defaults = session.defaults
        return await read(paths: paths, texts: texts, defaults: defaults)
    }

    @concurrent
    private static func read(paths: [String], texts: [String: String], defaults: OrgSettings) async -> [(path: String, card: Flashcards.Card)] {
        paths.flatMap { path -> [(path: String, card: Flashcards.Card)] in
            guard path.hasSuffix(".org"), let text = texts[path] ?? (try? String(contentsOfFile: path, encoding: .utf8)) else { return [] }
            return Flashcards.cards(in: text, defaults: defaults).map { (path, $0) }
        }
    }

    /// Finds the positions due now and shows the first.
    public func start(now: Date = Date()) async {
        isLoading = true
        let cards = await Self.cards(workspace: workspace, session: session)
        queue = Flashcards.due(cards, at: now)
        reviewed = 0
        isLoading = false
        loaded = true
        show()
    }

    /// The first position's face, from its file as it is now.
    private func show() {
        flipped = false
        typed = ""
        face = nil
        while let item = queue.first {
            if let card = fresh(item), let face = Flashcards.face(card, position: item.position) {
                queue[0].card = card
                self.face = face
                shownAt = Date()
                return
            }
            queue.removeFirst()
        }
    }

    /// The item's card as its file has it now.
    private func fresh(_ item: Flashcards.Item) -> Flashcards.Card? {
        guard let text = session.exportText(of: item.path) else { return nil }
        return Flashcards.cards(in: text, defaults: session.defaults).first { $0.id == item.card.id }
    }

    public func flip() {
        guard face != nil else { return }
        flipped = true
    }

    /// Rates the shown position, writes its review data and the history line, and shows the next.
    public func rate(_ rating: Flashcards.Rating, now: Date = Date()) {
        guard let item = current else { return }
        switch Self.rate(path: item.path, card: item.card.id, position: item.position, rating: rating, seconds: now.timeIntervalSince(shownAt), session: session, history: history, now: now) {
        case .rated(let problem):
            message = problem
        case .gone:
            message = String(localized: "The card changed; it was skipped.", comment: "Flashcard review")
            queue.removeFirst()
            return show()
        case .failed(let reason):
            message = reason
            return
        }
        reviewed += 1
        queue.removeFirst()
        if rating == .again { queue.append(item) }
        show()
    }

    public enum Outcome: Equatable {
        /// Rated; with why the history line couldn't be added, if it couldn't.
        case rated(String?)
        /// The card or its position is no longer in the file.
        case gone
        case failed(String)
    }

    /// Rates a position of the card with ID `card` in `path`, through the session, and adds the
    /// line to the review history: for the review screen and for the watch.
    public static func rate(path: String, card id: String, position name: String, rating: Flashcards.Rating, seconds: Double, session: DocumentSession,
                            history: URL = OrgPreferences.fcReviewHistoryFile(), now: Date = Date()) -> Outcome {
        guard let text = session.exportText(of: path), let card = Flashcards.cards(in: text, defaults: session.defaults).first(where: { $0.id == id }),
              let position = card.positions.first(where: { $0.name == name }) else { return .gone }
        if case .failed(let reason) = session.perform(RateFlashcard(card: id, position: name, rating: rating), path: path, at: 0, expect: nil, now: now) {
            return .failed(reason)
        }
        let line = Flashcards.historyLine(at: now, path: path, id: id, position: position, rating: rating, seconds: seconds)
        do {
            try appendHistory(line, to: history)
            return .rated(nil)
        } catch {
            return .rated(String(localized: "Can't add to the review history: \(error.localizedDescription)", comment: "Flashcard review"))
        }
    }

    /// Tags the shown card `suspended` and leaves its positions out of the rest of the review.
    public func suspend() {
        guard let item = current, let card = fresh(item) else { return }
        let step = session.perform(SuspendFlashcard(), path: item.path, at: card.headingOffset, expect: (card.headingOffset, card.headingLine))
        if case .failed(let reason) = step {
            message = reason
            return
        }
        queue.removeAll { $0.path == item.path && $0.card.id == item.card.id }
        show()
    }

    static func appendHistory(_ line: String, to file: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: file.path) {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(line.utf8).write(to: file)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    /// Whether the typed answer is the expected one.
    public var typedIsRight: Bool {
        face?.expected.map { $0 == typed } ?? false
    }
}
