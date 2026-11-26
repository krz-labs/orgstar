import Foundation
import Testing
@testable import OrgCore

struct SnippetTests {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Wednesday 2026-11-25 09:30 UTC.
    static let now = Date(timeIntervalSince1970: 1_795_599_000)

    func capture() -> CaptureContext { CaptureContext(now: Self.now, calendar: Self.utc) }

    func expand(_ body: String, answers: [String] = [], indentation: String = "") throws -> SnippetExpansion {
        try Snippets.expand(Snippet(trigger: "t", body: body), context: capture(), answers: answers, indentation: indentation).get()
    }

    func text(_ expansion: SnippetExpansion, _ range: Range<Int>) -> String {
        (expansion.text as NSString).substring(with: NSRange(range))
    }

    // MARK: - snippets.toml

    @Test func readsAFile() throws {
        let (snippets, problems) = try Snippets.parse(#"""
            # Comments are fine.
            [[snippet]]
            trigger = "meet"
            description = "Meeting notes"
            body = """
            * Meeting with ${1:someone} %U
            - $0
            """

            [[snippet]]
            trigger = "day"
            body = '%<%A>'

            [[snippet]]
            trigger = "weekly"
            description = "Weekly review"
            file = true
            body = '''
            #+title: Week of %t
            '''
            """#)
        #expect(problems.isEmpty)
        #expect(snippets == [
            Snippet(trigger: "meet", name: "Meeting notes", body: "* Meeting with ${1:someone} %U\n- $0\n"),
            Snippet(trigger: "day", body: "%<%A>"),
            Snippet(trigger: "weekly", name: "Weekly review", body: "#+title: Week of %t\n", file: true),
        ])
        #expect(snippets[2].commandID == "org.snippet:weekly" && Snippets.trigger(ofCommand: "org.snippet:weekly") == "weekly")
    }

    @Test func reportsWhereAFileIsWrong() throws {
        #expect(throws: TOML.ParseError(line: 3, message: "unclosed string")) {
            try Snippets.parse("[[snippet]]\ntrigger = \"a\"\nbody = \"\"\"\nnever closed\n")
        }
        #expect(throws: TOML.ParseError(line: 2, message: "unclosed string")) { try Snippets.parse("[[snippet]]\ntrigger = \"a\n") }
        let (snippets, problems) = try Snippets.parse("""
            [[snippet]]
            trigger = "ok"
            body = "fine"
            [[snippet]]
            body = "no trigger"
            [[snippet]]
            trigger = "two words"
            body = "x"
            [[snippet]]
            trigger = "lisp"
            body = "${1:$(upcase yas-text)}"
            [[snippet]]
            trigger = "open"
            body = "${1:never closed"
            [[snippet]]
            trigger = "ok"
            body = "again"
            [snippets]
            """)
        #expect(snippets.map(\.trigger) == ["ok"])
        #expect(problems == [
            "line 4: a snippet needs trigger and body", "line 6: a trigger has no spaces",
            "line 9: Emacs Lisp in a field isn't supported", "line 12: a ${ isn't closed",
            "line 15: trigger ok is used twice", "line 18: expected [[snippet]]",
        ])
    }

    @Test func multilineStringsFollowTOML() throws {
        let tables = try TOML.parse("a = \"\"\"\none \\\n   two\\tthree\"\"\"\nb = '''x\\n'''\nc = \"\"\"same line\"\"\" # note\n")
        #expect(tables[0].values["a"] == .string("one two\tthree"))
        #expect(tables[0].values["b"] == .string("x\\n"))
        #expect(tables[0].values["c"] == .string("same line"))
    }

    // MARK: - Bodies

    @Test func fieldsDefaultsAndMirrors() throws {
        let e = try expand("a ${1:foo} b $1 c ${2:bar} $0 d")
        #expect(e.text == "a foo b foo c bar  d")
        #expect(e.fields.map(\.number) == [1, 2])
        #expect(e.fields[0].ranges.map { text(e, $0) } == ["foo", "foo"])
        #expect(e.fields[0].ranges[0] == 2..<5 && e.fields[0].ranges[1] == 8..<11)
        #expect(text(e, e.fields[1].ranges[0]) == "bar" && e.fields[1].ranges.count == 1)
        #expect(e.exit == 18..<18)
    }

    @Test func theFieldIsTheOccurrenceWithADefault() throws {
        // As yasnippet: `$1` before `${1:x}` mirrors it.
        let e = try expand("$1 then ${1:x}")
        #expect(e.text == "x then x")
        #expect(e.fields[0].ranges == [7..<8, 0..<1])
        let empty = try expand("$2 and $2")
        #expect(empty.text == " and " && empty.fields[0].ranges == [0..<0, 5..<5])
    }

    @Test func escapesAndExits() throws {
        #expect(try expand(#"cost \$1 \\ ${1:x\}y} $1"#).text == #"cost $1 \ x}y x}y"#)
        #expect(try expand("no fields").exit == 9..<9)
        let selected = try expand("${0:end} $1")
        #expect(text(selected, selected.exit) == "end")
        // `%?` of capture is the exit too.
        #expect(try expand("ab%?cd").exit == 2..<2)
        // Tabs and blank lines stay as written.
        #expect(try expand("\n\tx $1\n\n").text == "\n\tx \n\n")
    }

    @Test func captureEscapesFill() throws {
        #expect(try expand("%t %U %<%A>").text == "<2026-11-25 Wed> [2026-11-25 Wed 09:30] Wednesday")
        #expect(try expand("${1:%u} $1").text == "[2026-11-25 Wed] [2026-11-25 Wed]")
        // An escaped escape stays.
        #expect(try expand(#"\%t"#).text == "%t")
    }

    @Test func promptsAreAskedInOrder() throws {
        let snippet = Snippet(trigger: "p", body: "* %^{Title} $1\n%^{Where|home|home|work} %^t %\\1")
        let questions = Snippets.questions(snippet, context: capture())
        #expect(questions.map(\.prompt) == ["Title", "Where", "Date"])
        #expect(questions[1].defaultValue == "home" && questions[1].choices == ["home", "work"])
        #expect(Snippets.prompt(questions[2], key: "snippet-2").date == .init(defaultDate: nil))
        let e = try Snippets.expand(snippet, context: capture(), answers: ["Plan", "", "+1d"]).get()
        #expect(e.text == "* Plan \nhome <2026-11-26 Thu> Plan")
        #expect(e.fields[0].ranges == [7..<7])
    }

    @Test func linesAfterTheFirstTakeTheIndentation() throws {
        let e = try expand("- ${1:a}\n- $1", indentation: "  ")
        #expect(e.text == "- a\n  - a")
        #expect(e.fields[0].ranges == [2..<3, 8..<9])
    }

    // MARK: - Triggers

    @Test func triggerBeforeTheCaret() {
        let snippets = [Snippet(trigger: "date", body: "%t"), Snippet(trigger: "<d", body: "x"), Snippet(trigger: "file", body: "x", file: true)]
        func found(_ text: String) -> String? {
            Snippets.trigger(before: text.utf16.count, in: text, snippets: snippets).map { "\($0.snippet.trigger)@\($0.range.lowerBound)" }
        }
        #expect(found("today date") == "date@6")
        #expect(found("(date") == "date@1")
        #expect(found("x<d") == nil)
        #expect(found("<d") == "<d@0")
        #expect(found("update") == nil)
        #expect(found("date ") == nil)
        #expect(found("file") == nil)
    }

    // MARK: - Commands

    func context(_ text: String, caret: Int? = nil, selection: Range<Int>? = nil, snippets: [Snippet], answers: [String: String] = [:]) -> EditContext {
        var options = EditingOptions.org
        options.snippets = snippets
        let caret = caret ?? text.utf16.count
        return EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [selection ?? caret..<caret],
                           now: Self.now, calendar: Self.utc, answers: answers, options: options)
    }

    @Test func expandingReplacesTheTriggerAndStartsASession() throws {
        let snippets = [Snippet(trigger: "todo", body: "TODO ${1:what} by ${2:when}$0")]
        let ctx = context("* todo", snippets: snippets)
        #expect(ExpandSnippet().applies(in: ctx))
        guard case .commit(let result) = ExpandSnippet().run(in: ctx) else { Issue.record("no commit"); return }
        #expect(result.edits == [TextEdit(range: 2..<6, replacement: "TODO what by when")])
        #expect(result.selection == [7..<11])
        guard case .snippet(let session) = result.effects.first else { Issue.record("no session"); return }
        #expect(session.fields.map(\.ranges) == [[7..<11], [15..<19]] && session.extent == 2..<19)
        #expect(!ExpandSnippet().applies(in: context("* todo ", snippets: snippets)))
        #expect(!ExpandSnippet().applies(in: context("* todo", selection: 2..<6, snippets: snippets)))
    }

    @Test func promptsComeBackAsAnswers() throws {
        let snippets = [Snippet(trigger: "m", body: "Meet %^{Who}: $0")]
        guard case .prompt(let prompt) = ExpandSnippet().run(in: context("m", snippets: snippets)) else { Issue.record("no prompt"); return }
        #expect(prompt.key == "snippet-0" && prompt.message == "Who: ")
        guard case .commit(let result) = ExpandSnippet().run(in: context("m", snippets: snippets, answers: ["snippet-0": "Ana"])) else {
            Issue.record("no commit")
            return
        }
        #expect(result.edits.first?.replacement == "Meet Ana: " && result.selection == [10..<10] && result.effects.isEmpty)
    }

    @Test func insertSnippetChoosesByNameAndWrapsTheSelection() throws {
        let snippets = [Snippet(trigger: "q", name: "Quote", body: "#+begin_quote\n%i$0\n#+end_quote"), Snippet(trigger: "f", body: "x", file: true)]
        guard case .prompt(let prompt) = InsertSnippet().run(in: context("hello", selection: 0..<5, snippets: snippets)) else { Issue.record("no prompt"); return }
        #expect(prompt.choices == ["Quote (q)"])
        guard case .commit(let result) = InsertSnippet().run(in: context("hello", selection: 0..<5, snippets: snippets, answers: ["snippet": "Quote (q)"])) else {
            Issue.record("no commit")
            return
        }
        #expect(result.edits == [TextEdit(range: 0..<5, replacement: "#+begin_quote\nhello\n#+end_quote")])
        #expect(!InsertSnippet().applies(in: context("", snippets: [snippets[1]])))
        // The named command reaches file templates too.
        #expect(Snippets.command("org.snippet:f")?.applies(in: context("", snippets: snippets)) == true)
        #expect(Snippets.command("org.cycle") == nil)
    }

    // MARK: - Sessions

    /// The buffer and session after typing `typed` over the active field, as the editors do it:
    /// the edit, then the mirrors.
    func type(_ typed: String, into text: inout String, _ session: inout SnippetSession?, caret: Int? = nil) {
        let end = caret ?? text.utf16.count
        let range = session?.selection ?? (end..<end)
        let edit = TextEdit(range: range, replacement: typed)
        text = edit.apply(to: text)
        if session?.map(edit) == false { session = nil }
        guard let current = session else { return }
        for mirror in current.mirrorEdits(in: text).reversed() {
            text = mirror.apply(to: text)
            if session?.map(mirror) == false { session = nil }
        }
    }

    @Test func tabStopsAsAStateMachine() throws {
        let e = try expand("a ${1:foo} b $1 c ${2:bar} $0 d")
        var session = SnippetSession(e, at: 2)
        var text = "x " + e.text
        #expect(session?.selection == 4..<7)
        type("XY", into: &text, &session)
        #expect(text == "x a XY b XY c bar  d")
        #expect(session?.fields[0].ranges == [4..<6, 9..<11])
        // Typing at the end of the field goes into it.
        let end = TextEdit(range: 6..<6, replacement: "Z")
        text = end.apply(to: text)
        let mapped = session?.map(end)
        #expect(mapped == true)
        for mirror in session!.mirrorEdits(in: text).reversed() {
            text = mirror.apply(to: text)
            let kept = session?.map(mirror)
            #expect(kept == true)
        }
        #expect(text == "x a XYZ b XYZ c bar  d")
        let next = session?.next()
        #expect(next == .field(16..<19))
        let back = session?.previous(), first = session?.previous()
        #expect(back == 4..<7 && first == 4..<7)
    }

    @Test func leavingEndsTheSession() throws {
        let e = try expand("${1:a} ${2:b}$0!")
        var session = SnippetSession(e, at: 10)!
        let second = session.next(), last = session.next()
        #expect(second == .field(12..<13) && last == .exit(13..<13))
        #expect(session.contains(10) && session.contains(14) && !session.contains(9) && !session.contains(15))
        // An edit outside the snippet ends it; one inside moves it.
        var moved = session
        let outside = moved.map(TextEdit(range: 0..<1, replacement: ""))
        let inside = session.map(TextEdit(range: 11..<11, replacement: "--"))
        #expect(!outside && inside)
        #expect(session.fields.map(\.ranges) == [[10..<11], [14..<15]] && session.exit == 15..<15)
        #expect(SnippetSession(try expand("no fields$0"), at: 0) == nil)
    }

    @Test func mirrorsFollowAnEmptyField() throws {
        let e = try expand("$1-$1-$1")
        var session = SnippetSession(e, at: 0)
        var text = e.text
        type("ab", into: &text, &session)
        #expect(text == "ab-ab-ab")
        type("", into: &text, &session)
        #expect(text == "--")
    }

    // MARK: - Completion

    @Test func completionOffersSnippetsWhereOrgOffersNothing() {
        let snippets = [Snippet(trigger: "meet", name: "Meeting notes", body: "x"), Snippet(trigger: "memo", body: "y"), Snippet(trigger: "mt", body: "z", file: true)]
        let c = OrgCompletion.at(context("Notes me", snippets: snippets))
        #expect(c?.kind == .snippet && c?.candidates == ["meet", "memo"] && c?.range == 6..<8)
        #expect(c?.label("meet") == "meet  Meeting notes" && c?.label("memo") == "memo")
        // Org's own contexts come first.
        #expect(OrgCompletion.at(context("#+TI", snippets: snippets))?.kind == .keyword)
        #expect(OrgCompletion.at(context("plain", snippets: snippets)) == nil)
        #expect(OrgCompletion.at(context("me", snippets: []))  == nil)
    }

    // MARK: - yasnippet

    /// yasnippet's folder, for comparing expansions with it: `ORGSTAR_YASNIPPET`, else one a
    /// Doom or package.el install has.
    static let yasnippet: String? = {
        if let path = ProcessInfo.processInfo.environment["ORGSTAR_YASNIPPET"] { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for base in [".config/emacs/.local/straight", ".emacs.d/.local/straight", ".emacs.d/elpa"] {
            let folder = home.appendingPathComponent(base)
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                for candidate in [folder.appendingPathComponent(entry).appendingPathComponent("yasnippet"), folder.appendingPathComponent(entry)]
                where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("yasnippet.el").path) {
                    return candidate.path
                }
            }
        }
        return nil
    }()

    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil && yasnippet != nil

    static let bodies = [
        "a ${1:foo} b $1 c ${2:bar} $0 d", "${1:x} and $2 then $1$2 end", "no fields $0 here", "plain",
        "${2:second} ${1:first} $0", #"\$1 \\ ${1:x\}y} $1"#, "${1:a}$1", "line1 ${1:x}\nline2 $1\n$0",
    ]

    /// After expanding, after typing `XY`, and after each of two `yas-next-field`: the text and
    /// point (0-based).
    struct Steps: Codable, Equatable {
        var text: [String]
        var point: [Int]
    }

    func ours(_ body: String) throws -> Steps {
        let e = try expand(body)
        var session = SnippetSession(e, at: 0)
        var text = e.text
        var steps = Steps(text: [text], point: [session?.selection.lowerBound ?? e.exit.lowerBound])
        type("XY", into: &text, &session, caret: e.exit.lowerBound)
        var point = (session?.selection.lowerBound ?? e.exit.lowerBound) + 2
        steps.text.append(text)
        steps.point.append(point)
        for _ in 0..<2 {
            if var current = session {
                switch current.next() {
                case .field(let range):
                    point = range.lowerBound
                    session = current
                case .exit(let range):
                    point = range.lowerBound
                    session = nil
                }
            }
            steps.point.append(point)
        }
        return steps
    }

    @Test(.enabled(if: oracle)) func matchesYasnippet() throws {
        func lisp(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-yas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("out.json")
        let script = folder.appendingPathComponent("yas.el")
        try """
            ;;; -*- lexical-binding: t -*-
            (add-to-list 'load-path \(lisp(Self.yasnippet!)))
            (require 'yasnippet)
            (require 'json)
            (setq yas-indent-line nil)
            (let (out)
              (dolist (body (list \(Self.bodies.map(lisp).joined(separator: " "))))
                (with-temp-buffer
                  (yas-minor-mode 1)
                  (yas-expand-snippet body)
                  (let ((texts (list (buffer-string))) (points (list (1- (point)))))
                    (insert "XY")
                    (run-hooks 'post-command-hook)
                    (push (buffer-string) texts)
                    (push (1- (point)) points)
                    (dotimes (_ 2)
                      (ignore-errors (yas-next-field))
                      (push (1- (point)) points))
                    (push `((text . ,(vconcat (nreverse texts))) (point . ,(vconcat (nreverse points)))) out))))
              (with-temp-file \(lisp(output.path)) (insert (json-encode (nreverse out)))))
            """.write(to: script, atomically: true, encoding: .utf8)
        _ = try EmacsOracle.run(["-Q", "--batch", "-l", script.path])
        let theirs = try JSONDecoder().decode([Steps].self, from: Data(contentsOf: output))
        for (body, expected) in zip(Self.bodies, theirs) {
            let mine = try ours(body)
            #expect(mine == expected, "\(body): \(mine) against \(expected)")
        }
    }
}
