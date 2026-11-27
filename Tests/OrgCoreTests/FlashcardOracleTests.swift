import Foundation
import Testing
@testable import OrgCore

/// org-fc itself, run in Emacs, when it's installed: the load-path directory in
/// `ORGSTAR_ORG_FC`, else a Doom or package.el install.
struct FlashcardOracleTests {
    static let loadPath: String? = {
        if let path = ProcessInfo.processInfo.environment["ORGSTAR_ORG_FC"] { return path }
        let fm = FileManager.default, home = NSHomeDirectory()
        let roots = ["\(home)/.config/emacs/.local/straight", "\(home)/.emacs.d/.local/straight"].flatMap { root in
            ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasPrefix("build-") }.sorted().reversed().map { "\(root)/\($0)" }
        } + ["\(home)/.emacs.d/elpa", "\(home)/.config/emacs/elpa"]
        for root in roots {
            let names = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            if let name = names.filter({ $0 == "org-fc" || ($0.hasPrefix("org-fc-") && $0.dropFirst(7).first?.isNumber == true) }).sorted().last {
                return "\(root)/\(name)"
            }
        }
        return nil
    }()

    static var enabled: Bool { loadPath != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil }

    static let now = 1_795_000_000.25

    /// Loads org-fc, with the clock at `now` (or `nows`, one per call to `time-to-seconds`), IDs
    /// `id-1`, `id-2`, … and `cl-random` returning `randoms` in turn as fractions of its limit.
    static func prelude(history: String = "/dev/null") -> String {
        """
        (setq load-path (cons \(loadPath!.debugDescription) load-path) make-backup-files nil auto-save-default nil create-lockfiles nil
              org-id-track-globally nil org-fc-review-history-file \(history.debugDescription))
        (require 'org-fc)
        (defvar oracle-now \(now))
        (defvar oracle-randoms nil)
        (defvar oracle-ids 0)
        """
    }

    static func form(_ body: String) -> String {
        """
        (cl-letf (((symbol-function 'time-to-seconds) (lambda (&optional _) oracle-now))
                  ((symbol-function 'org-id-new) (lambda (&rest _) (format "id-%d" (setq oracle-ids (1+ oracle-ids)))))
                  ((symbol-function 'cl-random) (lambda (limit &optional _) (* limit (pop oracle-randoms)))))
          \(body))
        """
    }

    /// Runs `command` on `text` with the caret at the start of the heading `title`.
    static func run(_ command: any OrgCommand, on title: String, in text: String, now: Double = now, answers: [String: String] = [:]) -> (text: String, failed: String?) {
        let found = (text as NSString).range(of: "(?m)^\\*+ " + NSRegularExpression.escapedPattern(for: title), options: .regularExpression).location
        let caret = found == NSNotFound ? 0 : found
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], now: Date(timeIntervalSince1970: now), answers: answers)
        switch command.run(in: context) {
        case .commit(let result):
            var new = text
            for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
            return (new, nil)
        case .failed(let message): return (text, message)
        default: return (text, "other")
        }
    }

    static let cards = """
        #+title: Cards
        #+filetags: :lang:

        * Capital of France
        Paris
        * Hund :german:
        SCHEDULED: <2026-11-20 Fri>
        :PROPERTIES:
        :CUSTOM: kept
        :END:
        dog
        ** Notes
        masculine
        * Two sided
        Front text
        ** Back
        Back text
        * Animals
        The {{cat}{animal}} sat on the {{mat}}, and $x^{2}$ is {{$x^{2}$}{math}@4}.
        * Enumerate {{one}}
        - {{two}}
        - {{three}{hint}}
        * Type it
        *Answer*
        * Typed back
        Question
        ** Back
        =exact=
        * Not typed
        ** Child
        * Context
        {{a}} {{b}} {{c}} {{d}}
        * Already :fc:
        :PROPERTIES:
        :ID: kept-id
        :END:
        """

    static let steps: [(title: String, command: any OrgCommand, answers: [String: String], form: String)] = [
        ("Capital of France", MakeFlashcard(.normal), [:], "(org-fc-type-normal-init)"),
        ("Hund", MakeFlashcard(.double), [:], "(org-fc-type-double-init)"),
        ("Two sided", MakeFlashcard(.double), [:], "(org-fc-type-double-init)"),
        ("Animals", MakeFlashcard(.cloze), ["cloze-type": "deletion"], "(org-fc-type-cloze-init 'deletion)"),
        ("Enumerate", MakeFlashcard(.cloze), ["cloze-type": "enumeration"], "(org-fc-type-cloze-init 'enumeration)"),
        ("Type it", MakeFlashcard(.textInput), [:], "(org-fc-type-text-input-init)"),
        ("Typed back", MakeFlashcard(.textInput), [:], "(org-fc-type-text-input-init)"),
        ("Not typed", MakeFlashcard(.textInput), [:], "(org-fc-type-text-input-init)"),
        ("Context", MakeFlashcard(.cloze), ["cloze-type": "context"], "(org-fc-type-cloze-init 'context)"),
        ("Already", MakeFlashcard(.normal), [:], "(org-fc-type-normal-init)"),
    ]

    /// Each `org-fc-type-*-init` on headings with and without drawers, planning, subheadings,
    /// a `Back` heading, cloze holes with hints, positions and math, and on a heading that is
    /// already a card or has no answer line (both refused, nothing changed).
    @Test(.enabled(if: enabled)) func makingCardsMatchesOrgFc() throws {
        let calls = Self.steps.map { step in
            "(goto-char (point-min)) (re-search-forward \(("^\\*+ " + step.title).debugDescription)) (beginning-of-line) (ignore-errors \(step.form))"
        }.joined(separator: "\n")
        let theirs = try EmacsOracle.evaluate(Self.cards, Self.form("(progn \(calls) (list (buffer-substring-no-properties (point-min) (point-max))))"), prelude: Self.prelude())
        let ids = Counter()
        var ours = Self.cards
        var refused: [String] = []
        for step in Self.steps {
            let result = Self.run(Self.numbered(step.command, ids), on: step.title, in: ours, answers: step.answers)
            ours = result.text
            if result.failed != nil { refused.append(step.title) }
        }
        #expect(refused == ["Not typed", "Already"])
        #expect(ours.contains("{{cat}{animal}@0}") && ours.contains("| front    | 2.50 |   0 |     0.00 | 2026-11-18T11:06:40Z |"))
        #expect(ours == theirs.first, "\(theirs.first ?? "")")
    }

    final class Counter: @unchecked Sendable {
        var count = 0
        func next() -> String {
            count += 1
            return "id-\(count)"
        }
    }

    /// `command`, giving IDs `id-1`, `id-2`, … as the oracle's `org-id-new` does.
    static func numbered(_ command: any OrgCommand, _ ids: Counter) -> any OrgCommand {
        (command as? MakeFlashcard).map { made in MakeFlashcard(made.type) { ids.next() } } ?? command
    }

    static func initialized() throws -> String {
        let ids = Counter()
        var text = Self.cards
        for step in Self.steps {
            text = Self.run(Self.numbered(step.command, ids), on: step.title, in: text, answers: step.answers).text
        }
        return text
    }

    static let ratings: [(id: String, position: String, rating: Flashcards.Rating, days: Double, random: Double)] = [
        ("id-1", "front", .good, 0, 0.5),
        ("id-1", "front", .good, 0.02, 0.5),
        ("id-1", "front", .good, 1.1, 0.5),
        ("id-1", "front", .good, 7.5, 0.13),
        ("id-1", "front", .hard, 25, 0.97),
        ("id-1", "front", .easy, 60, 0.0),
        ("id-1", "front", .again, 140, 0.4),
        ("id-2", "back", .easy, 0, 0.5),
        ("id-2", "back", .hard, 1.5, 0.5),
        ("id-2", "back", .hard, 8, 0.71),
        ("id-2", "front", .again, 8, 0.5),
        ("id-4", "1", .easy, 0, 0.5),
        ("id-4", "4", .good, 0, 0.5),
        ("id-5", "2", .hard, 0, 0.5),
    ]

    /// Ratings through every box and branch of SM2 (learning boxes, easy from box 0, fuzzed
    /// intervals, ease clamped, again back to box 0), written to the drawer and to the review
    /// history as `org-fc-review-rate` writes them.
    @Test(.enabled(if: enabled)) func ratingsMatchOrgFc() throws {
        let start = try Self.initialized()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-fc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = folder.appendingPathComponent("reviews.tsv")
        let calls = Self.ratings.map { r in
            """
            (setq oracle-now \(Self.now + r.days * 86400) oracle-randoms (list \(r.random)))
            (goto-char (point-min)) (re-search-forward "^:ID: +\(r.id)$") (org-back-to-heading)
            (org-fc-review-update-data
              (org-fc-position :name "\(r.position)" :card (org-fc-card :id "\(r.id)" :file (org-fc-file :path "/cards.org") :algo (org-fc-algo-sm2)))
              '\(r.rating.rawValue) 3.25)
            """
        }.joined(separator: "\n")
        let theirs = try EmacsOracle.evaluate(start, Self.form("(progn \(calls) (list (buffer-substring-no-properties (point-min) (point-max))))"), prelude: Self.prelude(history: history.path))
        let theirHistory = try String(contentsOf: history, encoding: .utf8)
        var ours = start
        var ourHistory = ""
        for r in Self.ratings {
            let now = Self.now + r.days * 86400
            let card = Flashcards.cards(in: ours).first { $0.id == r.id }!
            let position = card.positions.first { $0.name == r.position }!
            ourHistory += Flashcards.historyLine(at: Date(timeIntervalSince1970: now), path: "/cards.org", id: r.id, position: position, rating: r.rating, seconds: 3.25)
            let result = Self.run(RateFlashcard(card: r.id, position: r.position, rating: r.rating, random: r.random), on: "Cards", in: ours, now: now)
            #expect(result.failed == nil)
            ours = result.text
        }
        #expect(ourHistory.split(separator: "\n").count == Self.ratings.count)
        #expect(ours != start)
        #expect(ours == theirs.first, "\(theirs.first ?? "")")
        #expect(ourHistory == theirHistory)
    }

    /// `org-fc-update` on a cloze card given new holes, `org-fc-suspend-card` and
    /// `org-fc-unsuspend-card`.
    @Test(.enabled(if: enabled)) func updatingAndSuspendingMatchOrgFc() throws {
        var start = try Self.initialized()
        start = start.replacingOccurrences(of: "sat on the {{mat}@1}", with: "sat on the {{mat}@1} by the {{door}{where}}")
        let form = """
            (progn
              (goto-char (point-min)) (re-search-forward "^\\\\* Animals") (org-fc-update)
              (goto-char (point-min)) (re-search-forward "^\\\\*\\\\* Notes") (org-fc-suspend-card)
              (goto-char (point-min)) (re-search-forward "^\\\\* Capital") (org-fc-suspend-card)
              (goto-char (point-min)) (re-search-forward "^\\\\* Capital") (org-fc-unsuspend-card)
              (list (buffer-substring-no-properties (point-min) (point-max))))
            """
        let theirs = try EmacsOracle.evaluate(start, Self.form(form), prelude: Self.prelude())
        var ours = Self.run(UpdateFlashcard(), on: "Animals", in: start).text
        ours = Self.run(SuspendFlashcard(), on: "Notes", in: ours).text
        ours = Self.run(SuspendFlashcard(), on: "Capital", in: ours).text
        ours = Self.run(SuspendFlashcard(suspend: false), on: "Capital", in: ours).text
        #expect(ours.contains("{{door}{where}@2}") && ours.contains(":suspended:fc:german:"))
        #expect(ours == theirs.first, "\(theirs.first ?? "")")
    }

    /// The positions a review shows: org-fc's own filters (`org-fc-index-filter-due` and the
    /// sibling burying) over cards whose positions `org-fc-review-data-parse` reads, against
    /// `Flashcards.due` over the cards orgstar reads.
    @Test(.enabled(if: enabled)) func dueCardsMatchOrgFc() throws {
        var text = try Self.initialized()
        // Some positions due later, one card suspended.
        for (id, position, rating) in [("id-1", "front", Flashcards.Rating.easy), ("id-4", "0", .good), ("id-5", "1", .easy), ("id-2", "front", .easy)] {
            text = Self.run(RateFlashcard(card: id, position: position, rating: rating, random: 0.5), on: "Cards", in: text).text
        }
        text = Self.run(SuspendFlashcard(), on: "Context", in: text).text
        let now = Self.now + 3600
        let form = """
            (let (cards)
              (org-fc-map-cards
               (lambda ()
                 ;; As org-fc's indexer, only headings with review data.
                 (when-let* ((_ (org-fc-review-data-position))
                        (card (org-fc-card :id (org-id-get) :type (intern (org-entry-get nil "FC_TYPE"))
                                           :cloze-type (let ((c (org-entry-get nil "FC_CLOZE_TYPE"))) (and c (intern c)))
                                           :suspended (and (org-fc-suspended-entry-p) t) :algo (org-fc-algo-sm2)))
                        (data (org-fc-review-data-parse '(position ease box interval due))))
                   (oset card positions
                         (mapcar (lambda (row) (org-fc-position :card card :name (car row) :due (parse-iso8601-time-string (plist-get (cdr row) 'due)))) (oref data rows)))
                   (push card cards))))
              (setq cards (nreverse cards))
              (cl-letf (((symbol-function 'current-time) (lambda () (seconds-to-time \(now)))))
                (dolist (filter org-fc-review-card-filters) (setq cards (funcall filter cards))))
              (mapcan (lambda (card) (mapcar (lambda (pos) (concat (oref card id) " " (oref pos name))) (oref card positions))) cards))
            """
        let theirs = try EmacsOracle.evaluate(text, form, prelude: Self.prelude())
        let ours = Flashcards.due(Flashcards.cards(in: text).map { (path: "", card: $0) }, at: Date(timeIntervalSince1970: now), shuffle: false)
            .map { "\($0.card.id) \($0.position)" }
        #expect(ours.count >= 5 && !ours.contains { $0.hasPrefix("id-1 ") } && !ours.contains { $0.hasPrefix("id-8 ") })
        #expect(ours == theirs)
    }
}
