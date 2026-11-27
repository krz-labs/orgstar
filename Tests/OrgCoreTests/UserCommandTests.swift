import Foundation
import Testing
@testable import OrgCore

struct UserCommandManifestTests {
    func parse(_ toml: String, files: Set<String> = ["review.js", "lib/dates.mjs"]) throws -> ([UserCommand], [String]) {
        var problems: [String] = []
        let commands = try UserCommands.parse(toml, problems: &problems) { files.contains($0) }
        return (commands, problems)
    }

    @Test func readsCommands() throws {
        let (commands, problems) = try parse("""
            api = 1

            [[command]]
            name = "weekly-review"
            title = "Start Weekly Review"
            file = "review.js"
            function = "weeklyReview"
            when = "heading"
            timeout = 5

            [[command]]
            name = "dates"
            file = "lib/dates.mjs"
            function = "$fix_dates"
            """)
        #expect(problems == [])
        #expect(commands == [
            UserCommand(name: "weekly-review", title: "Start Weekly Review", file: "review.js", function: "weeklyReview", when: "heading", timeout: 5),
            UserCommand(name: "dates", title: "dates", file: "lib/dates.mjs", function: "$fix_dates", timeout: 2),
        ])
        #expect(commands[0].id == "user.weekly-review")
    }

    @Test func reportsProblemsByCommandAndKey() throws {
        let (commands, problems) = try parse("""
            api = 1
            extra = true

            [[command]]
            name = "ok"
            file = "review.js"
            function = "ok"
            colour = "red"

            [[command]]
            name = "missing"
            file = "gone.js"
            function = "f"

            [[command]]
            name = "outside"
            file = "../secret.js"
            function = "f"

            [[command]]
            name = "bad function"
            file = "review.js"
            function = "f"

            [[command]]
            name = "fn"
            file = "review.js"
            function = "1f"

            [[command]]
            name = "ctx"
            file = "review.js"
            function = "f"
            when = "everywhere"

            [[command]]
            name = "slow"
            file = "review.js"
            function = "f"
            timeout = 60

            [[command]]
            name = "ok"
            file = "review.js"
            function = "again"

            [other]
            """)
        #expect(commands.map(\.name) == ["ok"])
        #expect(problems == [
            "unknown key extra",
            "command ok: unknown key colour",
            "command missing: no file commands/gone.js",
            "command outside: file must be a .js or .mjs file in commands/",
            "line 20: command needs a name of letters, digits, - and _",
            "command fn: function must be the name of an exported function",
            "command ctx: unknown context everywhere",
            "command slow: timeout must be 1 to 30 seconds",
            "command ok: defined twice",
            "line 47: unknown table [other]",
        ])
    }

    @Test func needsAKnownAPI() throws {
        let command = "\n[[command]]\nname = \"a\"\nfile = \"review.js\"\nfunction = \"a\"\n"
        #expect(try parse(command) == ([], ["missing api = 1"]))
        #expect(try parse("api = 2\n" + command) == ([], ["api 2 needs a newer orgstar"]))
        #expect(try parse("api = 0\n" + command) == ([], ["unknown api 0"]))
        #expect(try parse("") == ([], []))
        #expect(throws: TOML.ParseError.self) { _ = try parse("api = \n[[command") }
    }

    @Test func whenHidesTheCommandWhereItDoesntApply() {
        let text = "intro\n* Heading\nbody\n"
        let command = UserCommand(name: "h", title: "H", file: "a.js", function: "h", when: "heading")
        func context(_ caret: Int) -> EditContext { EditContext(revision: 3, text: text, tree: OrgParser.parse(text), selection: [caret..<caret]) }
        #expect(!command.applies(in: context(0)))
        #expect(command.applies(in: context(8)))
        #expect(UserCommand(name: "e", title: "E", file: "a.js", function: "e").applies(in: context(0)))
        #expect(command.run(in: context(8)) == .external(.userCommand(UserCommandRequest(command: command, revision: 3, selection: [8..<8]))))
    }

    @Test func registry() {
        let store = UserCommands()
        let command = UserCommand(name: "a", title: "A", file: "a.js", function: "a")
        store.replace([command], folder: URL(fileURLWithPath: "/c/commands"))
        #expect(store.command("user.a") == command)
        #expect(store.command("user.b") == nil)
        #expect(store.command("a") == nil)
        #expect(store.folder?.path == "/c/commands")
    }
}

struct UserCommandAPITests {
    static let text = """
        #+FILETAGS: :home:
        intro
        * TODO [#A] Plan the week :work:
        SCHEDULED: <2026-11-30 Mon> DEADLINE: <2026-12-04 Fri>
        :PROPERTIES:
        :EFFORT: 1:00
        :END:
        ** Sub é
        * Done
        """

    func context(_ caret: Int, selection: [Range<Int>]? = nil) -> EditContext {
        EditContext(revision: 7, text: Self.text, tree: OrgParser.parse(Self.text), selection: selection ?? [caret..<caret], knownTags: { ["work", "home"] })
    }

    func offset(_ needle: String) -> Int { (Self.text as NSString).range(of: needle).location }

    @Test func headingAtThePoint() throws {
        let context = context(offset("EFFORT"))
        let heading = try #require(UserCommandAPI.answer("heading", NSNull(), context: context, file: nil) as? [String: Any])
        #expect(heading["level"] as? Int == 1)
        #expect(heading["keyword"] as? String == "TODO")
        #expect(heading["done"] as? Bool == false)
        #expect(heading["priority"] as? String == "A")
        #expect(heading["title"] as? String == "Plan the week")
        #expect(heading["tags"] as? [String] == ["work"])
        #expect(heading["start"] as? Int == offset("* TODO"))
        #expect(heading["end"] as? Int == offset("* Done"))
        let titleStart = try #require(heading["titleStart"] as? Int), titleEnd = try #require(heading["titleEnd"] as? Int)
        #expect((Self.text as NSString).substring(with: NSRange(titleStart..<titleEnd)) == "Plan the week")
        #expect(heading["scheduled"] as? String == "<2026-11-30 Mon>")
        #expect(heading["deadline"] as? String == "<2026-12-04 Fri>")
        #expect(heading["closed"] is NSNull)
        #expect(heading["properties"] as? [String: String] == ["EFFORT": "1:00"])
        // Before the first heading, none; with an offset, the heading there.
        #expect(UserCommandAPI.answer("heading", NSNull(), context: self.context(0), file: nil) is NSNull)
        let sub = try #require(UserCommandAPI.answer("heading", offset("Sub") as NSNumber, context: context, file: nil) as? [String: Any])
        #expect(sub["title"] as? String == "Sub é")
        #expect(sub["level"] as? Int == 2)
        #expect(sub["keyword"] is NSNull)
    }

    @Test func outlineSelectionTextFileAndSettings() throws {
        let context = context(0, selection: [3..<5, 9..<9])
        let outline = try #require(UserCommandAPI.answer("outline", NSNull(), context: context, file: nil) as? [[String: Any]])
        #expect(outline.map { $0["title"] as? String } == ["Plan the week", "Sub é", "Done"])
        #expect(outline.last?["end"] as? Int == (Self.text as NSString).length)
        #expect(UserCommandAPI.answer("text", NSNull(), context: context, file: nil) as? String == Self.text)
        #expect(UserCommandAPI.answer("selection", NSNull(), context: context, file: nil) as? [[String: Int]] == [["from": 3, "to": 5], ["from": 9, "to": 9]])
        #expect(UserCommandAPI.answer("file", NSNull(), context: context, file: "notes/a.org") as? String == "notes/a.org")
        #expect(UserCommandAPI.answer("file", NSNull(), context: context, file: nil) is NSNull)
        let settings = try #require(UserCommandAPI.answer("settings", NSNull(), context: context, file: nil) as? [String: Any])
        #expect(settings["todoKeywords"] as? [String] == ["TODO"])
        #expect(settings["doneKeywords"] as? [String] == ["DONE"])
        #expect(settings["fileTags"] as? [String] == ["home"])
        #expect(settings["tags"] as? [String] == ["work", "home"])
        #expect(settings["fillColumn"] as? Int == 70)
        #expect(UserCommandAPI.answer("nope", NSNull(), context: context, file: nil) == nil)
    }

    func result(_ json: String) -> Result<EditResult, UserCommandAPI.Problem> {
        UserCommandAPI.result(json, in: EditContext(revision: 4, text: "ab😀cd", tree: OrgParser.parse("ab😀cd"), selection: [0..<0]))
    }

    @Test func readsTheResult() {
        #expect(result("null") == .success(EditResult(baseRevision: 4, edits: [])))
        #expect(result(#"{"edits": [{"from": 5, "to": 6, "text": "D"}, {"from": 0, "to": 1}, {"from": 2, "text": "+"}], "selection": {"from": 1, "to": 2}, "message": "done", "copy": "x"}"#)
            == .success(EditResult(baseRevision: 4, edits: [
                TextEdit(range: 0..<1, replacement: ""), TextEdit(range: 2..<2, replacement: "+"), TextEdit(range: 5..<6, replacement: "D"),
            ], selection: [1..<2], effects: [.message("done"), .copy("x")])))
        #expect(result(#"{"selection": [3, {"from": 5, "to": 1}]}"#) == .success(EditResult(baseRevision: 4, edits: [], selection: [3..<3, 1..<5])))
    }

    @Test func refusesEditsThatCantApply() {
        func problem(_ json: String) -> String? {
            if case .failure(let problem) = result(json) { return problem.message }
            return nil
        }
        #expect(problem(#"{"edits": [{"from": 0, "to": 2}, {"from": 1, "to": 4}]}"#) == "edits overlap")
        #expect(problem(#"{"edits": [{"from": 1, "text": "a"}, {"from": 1, "text": "b"}]}"#) == "edits overlap")
        #expect(problem(#"{"edits": [{"from": 5, "to": 9}]}"#) == "edit 1 is outside the text")
        #expect(problem(#"{"edits": [{"from": 2, "to": 1}]}"#) == "edit 1 is outside the text")
        #expect(problem(#"{"edits": [{"from": -1}]}"#) == "edit 1 is outside the text")
        #expect(problem(#"{"edits": [{"from": 3}]}"#) == "edit 1 splits a character")
        #expect(problem(#"{"edits": [{"from": 0.5}]}"#) == "edit 1 needs a from offset")
        #expect(problem(#"{"edits": [{"from": 0, "text": 3}]}"#) == "edit 1 has a text that isn't a string")
        #expect(problem(#"{"edits": {"from": 0}}"#) == "edits must be a list")
        #expect(problem(#"{"edit": []}"#) == "returned an unknown key edit")
        #expect(problem(#"{"selection": 7}"#) == "selection is outside the text")
        #expect(problem(#"{"edits": [{"from": 0, "to": 6}], "selection": 2}"#) == "selection is outside the text")
        #expect(problem(#"{"message": 3}"#) == "message must be a string")
        #expect(problem(#""text""#) == "returned something other than an object")
    }

    @Test func prompts() {
        let prompt = UserCommandAPI.prompt(["message": "Week: ", "initial": "W48", "choices": ["W48", "W49"], "requireMatch": true] as [String: Any])
        #expect(prompt == Prompt(key: "user", message: "Week: ", initial: "W48", choices: ["W48", "W49"], requireMatch: true))
        #expect(UserCommandAPI.prompt(["message": "Any: ", "requireMatch": true] as [String: Any]).requireMatch == false)
        let date = UserCommandAPI.prompt(["message": "When? ", "date": true] as [String: Any])
        #expect(date.date == Prompt.DateRead(defaultDate: nil))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_795_000_000)  // 2026-11-18
        #expect(UserCommandAPI.answer("+2d", to: date, now: now, calendar: utc) == "2026-11-20")
        #expect(UserCommandAPI.answer("2026-12-01 9:30", to: date, now: now, calendar: utc) == "2026-12-01 09:30")
        #expect(UserCommandAPI.answer("+2d", to: prompt, now: now, calendar: utc) == "+2d")
    }
}
