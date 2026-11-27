import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// User commands run through the real command host against a session's buffer.
@MainActor
@Suite(.serialized)
struct UserCommandRunTests {
    static let manifest = """
        api = 1

        [[command]]
        name = "upcase-title"
        title = "Upcase Heading Title"
        file = "headings.js"
        function = "upcaseTitle"
        when = "heading"

        [[command]]
        name = "weekly-review"
        title = "Add Weekly Review"
        file = "review.js"
        function = "weeklyReview"

        [[command]]
        name = "overlap"
        file = "bad.js"
        function = "overlap"

        [[command]]
        name = "loop"
        file = "bad.js"
        function = "loop"
        timeout = 1

        [[command]]
        name = "refuse"
        file = "bad.js"
        function = "refuse"

        [[command]]
        name = "copy"
        file = "bad.js"
        function = "copy"

        [[command]]
        name = "compose"
        file = "run.js"
        function = "compose"

        [[command]]
        name = "schedule"
        file = "run.js"
        function = "schedule"

        [[command]]
        name = "promote"
        title = "Promote"
        file = "run.js"
        function = "promote"

        [[command]]
        name = "refused"
        file = "run.js"
        function = "refused"

        [[command]]
        name = "save"
        file = "run.js"
        function = "save"

        [[command]]
        name = "edit-while-running"
        file = "run.js"
        function = "editWhileRunning"
        """
    static let headings = """
        import { upper } from "./lib/text.js";

        export async function upcaseTitle(org) {
          const heading = await org.heading();
          if (!heading) return org.fail("Not in an entry");
          const text = await org.text();
          const title = text.slice(heading.titleStart, heading.titleEnd);
          return {
            edits: [{ from: heading.titleStart, to: heading.titleEnd, text: upper(title) }],
            message: `Upcased ${title}`,
          };
        }
        """
    static let review = """
        export async function weeklyReview(org) {
          const heading = await org.heading();
          if (!heading) return org.fail("Not on a heading");
          const week = await org.prompt({ message: "Week: ", initial: "W48" });
          return {
            edits: [{ from: heading.end, to: heading.end, text: `${"*".repeat(heading.level + 1)} Review ${week}\\n` }],
            selection: heading.end + heading.level + 2,
          };
        }
        """
    static let bad = """
        export function overlap() { return { edits: [{ from: 0, to: 4 }, { from: 2, to: 6 }] }; }
        export function loop() { for (;;) {} }
        export async function refuse(org) { await org.fail("Not today"); }
        export async function copy(org) { org.message("Copying"); return { copy: (await org.file()) ?? "none" }; }
        """
    static let builtIns = """
        export async function compose(org) {
          await org.run("org.todo.cycle");
          await org.run("org.todo.cycle");
          const { text, selection: [{ from }] } = await org.run("org.heading.insert");
          if (text !== await org.text()) return org.fail("org.text() isn't the text org.run gave");
          return { edits: [{ from, text: "New" }] };
        }
        export async function schedule(org) {
          await org.run("org.schedule");
          await org.message((await org.heading()).scheduled);
        }
        export async function promote(org) {
          try {
            await org.run("org.heading.promote");
          } catch (error) {
            org.message("caught " + error.message);
          }
          await org.run("org.heading.promote");
        }
        export async function refused(org) {
          const messages = [];
          for (const id of ["app.export.html", "user.compose", "org.cycle", "org.babel.execute"]) {
            try {
              await org.run(id);
              messages.push("ran " + id);
            } catch (error) {
              messages.push(error.message);
            }
          }
          await org.message(messages.join(" | "));
        }
        export async function save(org) {
          await org.run("org.todo.cycle");
          const { text } = await org.run("app.save");
          await org.message(text.slice(0, 6));
        }
        export async function editWhileRunning(org) {
          await org.run("org.todo.cycle");
          await org.prompt("Go on? ");
        }
        """
    static let file = "* Plan the week :work:\nbody\n* Next\n"

    let config: Folder
    let notes: Folder
    let path: String
    let session: DocumentSession
    let buffer: StateBuffer

    init() throws {
        config = try Folder()
        notes = try Folder()
        try config.write("commands.toml", Self.manifest)
        try config.write("commands/headings.js", Self.headings)
        try config.write("commands/lib/text.js", "export const upper = s => s.toUpperCase();\n")
        try config.write("commands/review.js", Self.review)
        try config.write("commands/bad.js", Self.bad)
        try config.write("commands/run.js", Self.builtIns)
        path = try notes.write("a.org", Self.file).path
        session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".recovery")))
        session.saveMode = .explicit
        session.passphrases = FakeKeychain.passphrases(.undecided).passphrases
        session.userCommands = UserCommands()
        #expect(UserCommandFile.load(into: session.userCommands, folder: config.url) == [])
        session.open(path)
        buffer = StateBuffer(try #require(session.document))
        session.attach(buffer)
    }

    func run(_ name: String, at caret: Int = 4, ask: @escaping @MainActor (Prompt, @escaping (String?) -> Void) -> Void = { _, reply in reply(nil) },
             report: @escaping @MainActor (String) -> Void = { _ in }) async throws -> String? {
        let command = try #require(session.userCommands.command("user." + name))
        let document = buffer.document
        let context = EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: [caret..<caret])
        guard case .external(.userCommand(let request)) = command.run(in: context) else { throw CancellationError() }
        return await session.runUserCommand(request, context: context, file: "a.org", ask: ask, report: report)
    }

    @Test func upcasesTheHeadingTitle() async throws {
        #expect(try await run("upcase-title") == nil)
        #expect(buffer.document.text == "* PLAN THE WEEK :work:\nbody\n* Next\n")
        // Before the first heading, `org.fail`'s text.
        _ = buffer.perform(ReplaceText(old: buffer.document.text, new: "intro\n" + Self.file), now: Date(), answers: [:])
        #expect(try await run("upcase-title", at: 0) == "Not in an entry")
    }

    @Test func asksThroughThePrompt() async throws {
        var asked: Prompt?
        let message = try await run("weekly-review", ask: { prompt, reply in
            asked = prompt
            reply("W49")
        })
        #expect(message == nil)
        #expect(asked == Prompt(key: "user", message: "Week: ", initial: "W48", requireMatch: false))
        #expect(buffer.document.text == "* Plan the week :work:\nbody\n** Review W49\n* Next\n")
        #expect(buffer.selection == [31..<31])
        // A canceled prompt ends the command with nothing changed.
        #expect(try await run("weekly-review") == "Quit")
        #expect(buffer.document.text == "* Plan the week :work:\nbody\n** Review W49\n* Next\n")
    }

    @Test func anEditWhileItRanRefusesItsResult() async throws {
        let message = try await run("weekly-review", ask: { [buffer] _, reply in
            _ = buffer.perform(ReplaceText(old: buffer.document.text, new: buffer.document.text + "typed\n"), now: Date(), answers: [:])
            reply("W49")
        })
        #expect(message == "The file changed; try again.")
        #expect(buffer.document.text == Self.file + "typed\n")
    }

    @Test func refusesWhatCantApply() async throws {
        #expect(try await run("overlap") == "overlap: edits overlap")
        #expect(try await run("refuse") == "Not today")
        let start = ContinuousClock.now
        #expect(try await run("loop") == "loop didn't finish within 1 s and was stopped.")
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(buffer.document.text == Self.file)
        var reported: [String] = []
        #expect(try await run("copy", report: { reported.append($0) }) == nil)
        #expect(reported == ["Copying"])
    }

    // MARK: - org.run

    /// The commands a script runs and its own edits after them are one undo step, with the text
    /// and selection that running the same commands directly gives.
    @Test func runningBuiltInsIsOneUndoStep() async throws {
        let direct = StateBuffer(DocumentState(bytes: Array(Self.file.utf8)))
        direct.selection = [4..<4]
        for id in ["org.todo.cycle", "org.todo.cycle", "org.heading.insert"] {
            guard case .commit = direct.perform(try #require(Commands.command(id)), now: Date(), answers: [:]) else {
                Issue.record("\(id) didn't commit")
                return
            }
        }
        let caret = direct.selection[0].lowerBound
        #expect(try await run("compose") == nil)
        #expect(buffer.document.text == (direct.document.text as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: "New"))
        #expect(buffer.document.text.hasPrefix("* DONE Pl"))
        #expect(buffer.selection == [caret + 3..<caret + 3])
        #expect(buffer.update { $0.undo() } != nil)
        #expect(buffer.document.text == Self.file)
        #expect(!buffer.document.canUndo)
    }

    /// A built-in command's prompt goes through the prompt the command's own prompts use.
    @Test func aBuiltInsPromptGoesThroughThePrompt() async throws {
        var asked: [Prompt] = []
        var reported: [String] = []
        let message = try await run("schedule", ask: { prompt, reply in
            asked.append(prompt)
            reply("2026-12-01")
        }, report: { reported.append($0) })
        #expect(message == nil)
        #expect(asked.count == 1 && asked.first?.key == "date" && asked.first?.date != nil)
        let scheduled = "* Plan the week :work:\nSCHEDULED: <2026-12-01 Tue>\nbody\n* Next\n"
        #expect(buffer.document.text == scheduled)
        #expect(reported == ["<2026-12-01 Tue>"])
        // Canceling it ends the command with nothing changed.
        #expect(try await run("schedule") == "Quit")
        #expect(buffer.document.text == scheduled)
    }

    /// A failing built-in rejects with its message, which the script can catch.
    @Test func aFailingBuiltInRejectsWithItsMessage() async throws {
        let document = buffer.document
        let context = EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: [4..<4])
        guard case .failed(let failure) = PromoteHeading().run(in: context) else {
            Issue.record("promoting a level 1 heading didn't fail")
            return
        }
        var reported: [String] = []
        #expect(try await run("promote", report: { reported.append($0) }) == "Promote: \(failure)")
        #expect(reported == ["caught \(failure)"])
        #expect(buffer.document.text == Self.file)
    }

    /// Commands of the app other than the safe ones, user commands, the editor's own commands
    /// and work outside the text are refused.
    @Test func refusesWhatIsntABuiltInCommand() async throws {
        let block = "#+begin_src sh\necho hi\n#+end_src\n"
        _ = buffer.perform(ReplaceText(old: buffer.document.text, new: block), now: Date(), answers: [:])
        let document = buffer.document
        let context = EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: [2..<2])
        guard case .external(.babel) = ExecuteSrcBlock().run(in: context) else {
            Issue.record("the block doesn't run through Babel")
            return
        }
        var reported: [String] = []
        #expect(try await run("refused", at: 2, report: { reported.append($0) }) == nil)
        #expect(reported == [[
            "app.export.html is a command of the app, which user commands can't run",
            "A user command can't run another: user.compose",
            "No built-in command org.cycle",
            UserCommandAPI.external("org.babel.execute").message,
        ].joined(separator: " | ")])
        #expect(buffer.document.text == block)
    }

    /// `app.save` saves the file once the command's changes are applied.
    @Test func saveRunsAfterTheChanges() async throws {
        var reported: [String] = []
        #expect(try await run("save", report: { reported.append($0) }) == nil)
        #expect(reported == ["* TODO"])
        #expect(buffer.document.text.hasPrefix("* TODO Plan"))
        #expect(!buffer.document.isDirty)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == buffer.document.text)
    }

    @Test func anEditWhileRunningRefusesWhatItsCommandsDid() async throws {
        let message = try await run("edit-while-running", ask: { [buffer] _, reply in
            _ = buffer.perform(ReplaceText(old: buffer.document.text, new: buffer.document.text + "typed\n"), now: Date(), answers: [:])
            reply("yes")
        })
        #expect(message == "The file changed; try again.")
        #expect(buffer.document.text == Self.file + "typed\n")
    }

    @Test func cancelStopsTheCommand() async throws {
        let document = buffer.document
        let command = try #require(session.userCommands.command("user.loop"))
        let request = UserCommandRequest(command: command, revision: document.revision, selection: [0..<0])
        let context = EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: [0..<0])
        var reported: [String] = []
        session.startUserCommand(request, context: context, file: nil, ask: { _, reply in reply(nil) }) { reported.append($0) }
        #expect(session.isRunningUserCommand)
        try await Task.sleep(for: .milliseconds(200))
        session.cancelUserCommand()
        for _ in 0..<100 where reported.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(reported == ["loop canceled."])
        #expect(!session.isRunningUserCommand)
    }

    @Test func refusedInBuffersWithDecryptedText() async throws {
        let gpg = notes.url.appendingPathComponent("d.org.gpg")
        try OpenPGP.encryptedMessage(Data("* Secret\n".utf8), passphrase: "pw").write(to: gpg)
        session.open(gpg.path)
        #expect(session.unlock("pw", for: gpg.path) == nil)
        #expect(session.refusesUserCommand(gpg.path) == "d.org.gpg has decrypted entries, so user commands don't run in it.")
        let document = try #require(session.document)
        let command = try #require(session.userCommands.command("user.upcase-title"))
        let context = EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: [3..<3])
        let request = UserCommandRequest(command: command, revision: document.revision, selection: [3..<3])
        #expect(await session.runUserCommand(request, context: context, file: nil, ask: { _, _ in }, report: { _ in })
            == "d.org.gpg has decrypted entries, so user commands don't run in it.")
        #expect(session.document?.text == "* Secret\n")
        #expect(session.refusesUserCommand(path) == nil)
    }
}

@MainActor
struct UserCommandFileTests {
    @Test func reportsProblemsByFile() throws {
        let config = try Folder()
        let store = UserCommands()
        #expect(UserCommandFile.load(into: store, folder: config.url) == [])
        try config.write("commands.toml", "api = 1\n[[command]]\nname = \"a\"\nfile = \"a.js\"\nfunction = \"a\"\n")
        #expect(UserCommandFile.load(into: store, folder: config.url) == ["commands.toml: command a: no file commands/a.js"])
        #expect(store.all.isEmpty && store.folder == nil)
        try config.write("commands/a.js", "export function a() {}\n")
        #expect(UserCommandFile.load(into: store, folder: config.url) == [])
        #expect(store.all.map(\.id) == ["user.a"])
        #expect(store.folder?.lastPathComponent == "commands")
        try config.write("commands.toml", "api = 1\n[[command]\n")
        #expect(UserCommandFile.load(into: store, folder: config.url) == ["commands.toml: line 2: unclosed table header"])
        #expect(store.all.isEmpty)
    }

    @Test func importsResolveInsideTheFolder() {
        let text = """
            import { a } from "./a.js";
            import * as b from '../b.js';
            export { c } from "./lib/c.mjs";
            import "./side.js";
            const d = await import("./d.js");
            import e from "https://example.com/e.js";
            """
        #expect(UserCommandFile.imports(text, from: "sub/main.js").sorted() == ["b.js", "sub/a.js", "sub/d.js", "sub/lib/c.mjs", "sub/side.js"])
        #expect(UserCommandFile.imports("import x from '../../x.js';", from: "main.js") == [])
    }

    @Test func relativePath() {
        #expect(UserCommandFile.relativePath("/n/notes/a/b.org", roots: ["/n", "/n/notes"]) == "a/b.org")
        #expect(UserCommandFile.relativePath("/elsewhere/c.org", roots: ["/n"]) == "c.org")
    }

    /// Always keeps trust for the file and its imports as they are; a change to either, as one
    /// arriving by sync, asks again.
    @Test func aChangedScriptAsksForTrustAgain() throws {
        let config = try Folder()
        try config.write("commands/main.js", "import { x } from \"./lib.js\";\nexport function go() { return x; }\n")
        try config.write("commands/lib.js", "export const x = null;\n")
        let modules = config.url.appendingPathComponent("commands")
        let trust = TrustStore(file: config.url.appendingPathComponent("trusted.json"))
        let command = UserCommand(name: "go", title: "Go", file: "main.js", function: "go")
        var asked: [UserCommandTrust.Question] = []
        var runs = 0
        var refusals: [String] = []
        func check(_ answer: UserCommandTrust.Answer?) {
            UserCommandTrust.check(command, modules: modules, trust: trust, ask: { question, reply in
                asked.append(question)
                reply(answer)
            }, run: { runs += 1 }, refuse: { refusals.append($0) })
        }
        check(.dontRun)
        #expect(runs == 0 && refusals == ["Not run"])
        #expect(asked == [UserCommandTrust.Question(file: "commands/main.js", imports: ["commands/lib.js"])])
        check(.runOnce)
        check(.runOnce)
        #expect(runs == 2 && asked.count == 3)
        check(.always)
        check(nil)
        #expect(runs == 4 && asked.count == 4)
        try config.write("commands/lib.js", "export const x = 1;\n")
        check(.always)
        #expect(runs == 5 && asked.count == 5)
        try config.write("commands/main.js", "import { x } from \"./lib.js\";\nexport function go() { return 2; }\n")
        check(nil)
        #expect(runs == 5 && asked.count == 6 && refusals == ["Not run", "Not run"])
        // Back to a version trusted before, it runs without asking.
        try config.write("commands/main.js", "import { x } from \"./lib.js\";\nexport function go() { return x; }\n")
        check(nil)
        #expect(runs == 6)
        #expect(UserCommandFile.trustedText("gone.js", modules: modules) == nil)
        #expect(UserCommandFile.trustedText("main.js", modules: modules)
            == "// lib.js\nexport const x = 1;\n\n// main.js\nimport { x } from \"./lib.js\";\nexport function go() { return x; }\n")
    }

    /// The question names the file and every module it imports, through other modules too;
    /// one that can't be read isn't listed.
    @Test func theTrustQuestionListsTheImportedModules() throws {
        let config = try Folder()
        try config.write("commands/tools/main.js", "import { a } from \"../lib/a.js\";\nimport \"./gone.js\";\nexport function go() {}\n")
        try config.write("commands/lib/a.js", "export { b } from \"./b.js\";\nexport const a = 1;\n")
        try config.write("commands/lib/b.js", "export const b = 2;\n")
        let modules = config.url.appendingPathComponent("commands")
        let trust = TrustStore(file: config.url.appendingPathComponent("trusted.json"))
        var asked: [UserCommandTrust.Question] = []
        UserCommandTrust.check(UserCommand(name: "go", title: "Go", file: "tools/main.js", function: "go"), modules: modules, trust: trust,
                               ask: { question, _ in asked.append(question) }, run: {}, refuse: { _ in })
        #expect(asked == [UserCommandTrust.Question(file: "commands/tools/main.js", imports: ["commands/lib/a.js", "commands/lib/b.js"])])
        #expect(asked.first?.title == "Run commands from commands/tools/main.js?")

        let question = UserCommandTrust.Question(file: "commands/review.js", imports: ["commands/lib/dates.js"])
        #expect(question.message == """
            It imports commands/lib/dates.js.
            They can read and change the file you run them in, and nothing else: no other files and no network.
            """)
        #expect(UserCommandTrust.Question(file: "commands/review.js").message
            == "They can read and change the file you run them in, and nothing else: no other files and no network.")
        #expect(UserCommandTrust.Question(file: "commands/review.js", workspace: true).message
            == "They can read and change the file you run them in, read every file in your folders and capture to them, but not use the network.")
    }

    @Test func emacsImportNotesBindingsToTheUsersFunctions() throws {
        let folder = try Folder()
        try folder.write("init.el", """
            (defun my/weekly-review () (interactive) (org-insert-heading))
            (global-set-key (kbd "C-c w") #'my/weekly-review)
            (global-set-key (kbd "C-c q") #'some-package-command)
            """)
        let result = EmacsImport.scan(EmacsImport.files(in: folder.url))
        #expect(result.unsupported.contains { $0.name == "C-c w → my/weekly-review" && $0.reason == "your own function; write it as a user command in commands.toml" })
        #expect(result.unsupported.contains { $0.name == "C-c q → some-package-command" && $0.reason == "orgstar has no such command" })
    }
}
