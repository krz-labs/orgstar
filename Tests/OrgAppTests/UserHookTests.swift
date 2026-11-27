import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// `[[hook]]`s run through the real command host after TODO changes and before captures.
@MainActor
@Suite(.serialized)
struct UserHookTests {
    static let manifest = """
        api = 1

        [[hook]]
        event = "after-todo-state-change"
        file = "todo.js"
        function = "logState"

        [[hook]]
        event = "capture-before-finalize"
        file = "capture.js"
        function = "check"
        """
    static let todo = """
        export async function logState(org, { entry, from, to }) {
          if (entry.title === "Broken") throw new Error("broken");
          if (entry.title === "Again") {
            await org.run("org.todo.cycle");
            await org.message(`again ${from ?? "none"} -> ${to}`);
            return;
          }
          if (entry.title === "Typed") await org.message("typing");
          const text = await org.text();
          const line = text.indexOf("\\n", entry.start) + 1;
          await org.message(`${entry.title}: ${from ?? "none"} -> ${to ?? "none"}`);
          return { edits: [{ from: line, text: `- State ${to ?? "none"} from ${from ?? "none"}\\n` }] };
        }
        """
    static let capture = """
        export async function check(org, { text, template }) {
          if (text.includes("cancel")) return org.fail(`Not filed with ${template}`);
          if (template === "s") return { selection: 0 };
          const heading = await org.heading(0);
          return { edits: [{ from: heading.titleStart, to: heading.titleEnd, text: heading.title.toUpperCase() }], message: "checked" };
        }
        """
    static let file = "* Plan\nbody\n* Broken\n* Again\n* Typed\n"

    let config: Folder
    let notes: Folder
    let path: String
    let session: DocumentSession
    let buffer: StateBuffer
    let trust: TrustStore
    var reported: [String] { messages.list }
    let messages = Messages()
    final class Messages { var list: [String] = [] }

    init() throws {
        config = try Folder()
        notes = try Folder()
        try config.write("commands.toml", Self.manifest)
        try config.write("commands/todo.js", Self.todo)
        try config.write("commands/capture.js", Self.capture)
        path = try notes.write("a.org", Self.file).path
        session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".recovery")))
        session.saveMode = .explicit
        session.passphrases = FakeKeychain.passphrases(.undecided).passphrases
        session.userCommands = UserCommands()
        #expect(UserCommandFile.load(into: session.userCommands, folder: config.url) == [])
        session.open(path)
        buffer = StateBuffer(try #require(session.document))
        session.attach(buffer)
        trust = TrustStore(file: notes.url.appendingPathComponent("trusted.json"))
        let messages = messages
        session.hooks = UserHookHost(trust: trust, ask: { _, reply in reply(.runOnce) }, report: { messages.list.append($0) })
    }

    /// Changes the TODO keyword of the heading titled `title`, as the agenda does, and waits for
    /// the hooks.
    func cycle(_ title: String, in path: String? = nil) async throws {
        let path = path ?? self.path
        let text = try #require(session.document(of: path)?.text ?? (try? String(contentsOfFile: path, encoding: .utf8)))
        let found = (text as NSString).range(of: " \(title)\n")
        try #require(found.location != NSNotFound)
        let offset = (text as NSString).lineRange(for: found).location
        guard case .commit = session.perform(TodoCycle(), path: path, at: offset, expect: nil) else {
            Issue.record("cycling \(title) didn't commit")
            return
        }
        await session.hooksFinished()
    }

    @Test func aStateChangeHookEditsAsItsOwnUndoStep() async throws {
        try await cycle("Plan")
        #expect(buffer.document.text == "* TODO Plan\n- State TODO from none\nbody\n* Broken\n* Again\n* Typed\n")
        #expect(reported == ["Plan: none -> TODO"])
        #expect(buffer.update { $0.undo() } != nil)
        #expect(buffer.document.text == "* TODO Plan\nbody\n* Broken\n* Again\n* Typed\n")
        #expect(buffer.update { $0.undo() } != nil)
        #expect(buffer.document.text == Self.file)
    }

    /// The editor's route: the command's effect, handed to the session.
    @Test func runsForTheEditorsCommands() async throws {
        buffer.selection = [2..<2]
        guard case .commit(let result) = buffer.perform(SetTodo(keyword: "DONE"), now: Date(), answers: [:]) else {
            Issue.record("SetTodo didn't commit")
            return
        }
        session.afterTodoStateChange(result.effects, in: path)
        await session.hooksFinished()
        #expect(buffer.document.text.hasPrefix("* DONE Plan\n- State DONE from none\n"))
    }

    /// A hook's own TODO changes, through `org.run`, run no hooks.
    @Test func aHooksOwnChangesRunNoHooks() async throws {
        try await cycle("Again")
        #expect(reported == ["again none -> TODO"])
        #expect(buffer.document.text.contains("* DONE Again\n"))
    }

    @Test func aFailingHookLeavesTheChangeAndReports() async throws {
        try await cycle("Broken")
        #expect(reported == ["logState in commands/todo.js: broken"])
        #expect(buffer.document.text == "* Plan\nbody\n* TODO Broken\n* Again\n* Typed\n")
    }

    /// Typing while a hook runs refuses its edits.
    @Test func aChangedBufferRefusesTheHooksEdits() async throws {
        let messages = messages
        session.hooks?.report = { [buffer] message in
            messages.list.append(message)
            if message == "typing" {
                _ = buffer.perform(ReplaceText(old: buffer.document.text, new: buffer.document.text + "typed\n"), now: Date(), answers: [:])
            }
        }
        try await cycle("Typed")
        #expect(reported == ["typing", "Typed: none -> TODO", "a.org changed while logState in commands/todo.js ran; its changes weren't made."])
        #expect(buffer.document.text == "* Plan\nbody\n* Broken\n* Again\n* TODO Typed\ntyped\n")
    }

    /// A file that isn't open is changed on disk.
    @Test func runsForAFileThatIsntOpen() async throws {
        let other = try notes.write("b.org", "* Call\n").path
        try await cycle("Call", in: other)
        #expect(try String(contentsOfFile: other, encoding: .utf8) == "* TODO Call\n- State TODO from none\n")
    }

    @Test func untrustedHooksDontRunSilently() async throws {
        // Where orgstar can't ask, they are skipped with a message.
        session.hooks?.ask = nil
        try await cycle("Plan")
        #expect(reported == ["logState in commands/todo.js: commands/todo.js isn't trusted on this device yet, and orgstar can't ask here."])
        #expect(buffer.document.text == "* TODO Plan\nbody\n* Broken\n* Again\n* Typed\n")
        // Don't Run runs nothing; Always runs it and doesn't ask again.
        var asked: [UserCommandTrust.Question] = []
        session.hooks?.ask = { question, reply in
            asked.append(question)
            reply(.dontRun)
        }
        try await cycle("Plan")
        #expect(reported.last == "logState in commands/todo.js: Not run")
        #expect(asked == [UserCommandTrust.Question(file: "commands/todo.js", hook: .afterTodoStateChange)])
        session.hooks?.ask = { question, reply in
            asked.append(question)
            reply(.always)
        }
        try await cycle("Plan")
        try await cycle("Plan")
        #expect(asked.count == 2)
        #expect(buffer.document.text.hasPrefix("* TODO Plan\n- State TODO from none\n- State none from DONE\nbody\n"))
    }

    @Test func aCaptureHookRewritesTheTextOrCancels() async throws {
        #expect(await session.runCaptureHooks("* buy milk :shop:\n", template: "t", interactive: true) == .success("* BUY MILK :shop:\n"))
        #expect(reported == ["checked"])
        #expect(await session.runCaptureHooks("* cancel this\n", template: "t", interactive: true)
            == .failure(CaptureError(message: "Not filed with t")))
        #expect(await session.runCaptureHooks("* x\n", template: "s", interactive: true)
            == .failure(CaptureError(message: "check in commands/capture.js: a hook returns only edits and message")))
        // Without a way to ask, an untrusted hook is skipped and the capture goes on unchanged.
        session.hooks?.ask = { _, _ in Issue.record("asked without a way to ask") }
        #expect(await session.runCaptureHooks("* cancel this\n", template: "t", interactive: false) == .success("* cancel this\n"))
        #expect(reported.last == "check in commands/capture.js: commands/capture.js isn't trusted on this device yet, and orgstar can't ask here.")
    }

    @Test func noHostRunsNoHooks() async throws {
        session.hooks = nil
        try await cycle("Plan")
        #expect(buffer.document.text == "* TODO Plan\nbody\n* Broken\n* Again\n* Typed\n")
        #expect(await session.runCaptureHooks("* cancel\n", template: "t", interactive: true) == .success("* cancel\n"))
    }
}
