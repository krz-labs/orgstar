import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// `org.search`, `org.outlineOf`, `org.agenda` and `org.capture` through the real command host.
@MainActor
@Suite(.serialized)
struct UserCommandWorkspaceTests {
    static let manifest = """
        api = 1

        [[command]]
        name = "search"
        file = "ws.js"
        function = "search"
        workspace = true

        [[command]]
        name = "outline"
        file = "ws.js"
        function = "outline"
        workspace = true

        [[command]]
        name = "agenda"
        file = "ws.js"
        function = "agenda"
        workspace = true

        [[command]]
        name = "capture"
        file = "ws.js"
        function = "capture"
        workspace = true

        [[command]]
        name = "buffer-only"
        file = "ws.js"
        function = "all"
        """
    /// Each command asks for its arguments and shows what the call gave, or its error.
    static let module = """
        async function show(org, call) {
          try {
            await org.message(JSON.stringify(await call()));
          } catch (error) {
            await org.message("error: " + error.message);
          }
        }
        export const search = org => show(org, async () => org.search(await org.prompt("Query: ")));
        export const outline = org => show(org, async () => org.outlineOf(await org.prompt("Path: ")));
        export const agenda = org => show(org, async () => org.agenda(JSON.parse(await org.prompt("Span: "))));
        export const capture = org => show(org, async () =>
          org.capture(await org.prompt("Template: "), await org.prompt("Text: "), JSON.parse(await org.prompt("Fields: "))));
        export async function all(org) {
          const errors = [];
          for (const call of [() => org.search("x"), () => org.outlineOf("todo.org"), () => org.agenda(), () => org.capture("t", "x")]) {
            try { await call(); } catch (error) { errors.push(error.message); }
          }
          await org.message(errors.join(" | "));
        }
        """
    static let todo = """
        * Inbox
        * Project
        ** TODO Write report about milk
        SCHEDULED: <2026-11-26 Thu 10:00>
        Milk prices for the report.
        * TODO Call Sam :phone:

        """
    static let current = "* Current\nbody\n"

    let config: Folder
    let notes: Folder
    let outside: Folder
    let path: String
    let workspace: WorkspaceModel
    let session: DocumentSession
    let buffer: StateBuffer
    var access: UserCommandWorkspace

    init() async throws {
        config = try Folder()
        notes = try Folder()
        outside = try Folder()
        try config.write("commands.toml", Self.manifest)
        try config.write("commands/ws.js", Self.module)
        try notes.write("todo.org", Self.todo)
        try notes.write("sub/deep.org", "#+TITLE: Deep\n* Top\n** Inner :x:\n:PROPERTIES:\n:KIND: deep\n:END:\n")
        try notes.write("crypt.org", "* Bank :crypt:\n-----BEGIN PGP MESSAGE-----\n\nhQEMAciphertext\n-----END PGP MESSAGE-----\n")
        try OpenPGP.encryptedMessage(Data("* Vault milk\nmilk secret\n".utf8), passphrase: "pw").write(to: notes.url.appendingPathComponent("vault.org.gpg"))
        try notes.write("b.org", "* Plain\n")
        try outside.write("secret.org", "* Outside secret\n")
        try FileManager.default.createSymbolicLink(at: notes.url.appendingPathComponent("link.org"), withDestinationURL: outside.url.appendingPathComponent("secret.org"))
        try FileManager.default.createSymbolicLink(at: notes.url.appendingPathComponent("inner.org"), withDestinationURL: notes.url.appendingPathComponent("sub/deep.org"))
        path = try notes.write("a.org", Self.current).path
        workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        await workspace.refresh()
        session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".recovery")))
        session.saveMode = .explicit
        session.passphrases = FakeKeychain.passphrases(.undecided).passphrases
        session.userCommands = UserCommands()
        #expect(UserCommandFile.load(into: session.userCommands, folder: config.url) == [])
        session.open(path)
        buffer = StateBuffer(try #require(session.document))
        session.attach(buffer)
        access = UserCommandWorkspace(workspace: workspace, clock: ClockModel(file: notes.url.appendingPathComponent("clock.json"), defaults: TestDefaults("user-command-workspace")))
        access.templates = {
            [
                CaptureTemplate(key: "t", name: "Todo", target: .headline(file: "todo.org", headline: "Inbox"), template: "* TODO %i"),
                CaptureTemplate(key: "e", name: "Errand", target: .headline(file: "todo.org", headline: "Inbox"), template: "* TODO %^{What} %^g\n%i"),
                CaptureTemplate(key: "here", name: "Here", target: .file("a.org"), template: "* %i"),
            ]
        }
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-26T09:00:00Z"))
        access.now = { now }
        access.calendar = Calendar(identifier: .gregorian)
        access.calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    /// Runs `name` in a.org with `answers` to its prompts, in order; what it showed.
    func run(_ name: String, _ answers: [String] = [], workspace: Bool = true) async throws -> String {
        let command = try #require(session.userCommands.command("user." + name))
        let document = buffer.document
        let context = EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: [0..<0])
        guard case .external(.userCommand(let request)) = command.run(in: context) else { throw CancellationError() }
        var answers = answers
        var shown: [String] = []
        let message = await session.runUserCommand(request, context: context, file: "a.org", workspace: workspace ? access : nil, ask: { _, reply in
            reply(answers.isEmpty ? nil : answers.removeFirst())
        }, report: { shown.append($0) })
        #expect(message == nil)
        return shown.joined(separator: "\n")
    }

    func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    @Test func searchesTheIndex() async throws {
        let results = try #require(try json(try await run("search", ["milk report"])) as? [[String: Any]])
        #expect(results.count == 1)
        let found = try #require(results.first)
        #expect(found["file"] as? String == "todo.org")
        #expect(found["title"] as? String == "Write report about milk")
        #expect(found["outline"] as? [String] == ["Project"])
        #expect(found["start"] as? Int == (Self.todo as NSString).range(of: "** TODO").location)
        #expect(found["heading"] as? Bool == true)
        #expect((found["snippet"] as? String)?.contains("Milk prices") == true)
        // The text before a file's first heading.
        let deep = try #require(try json(try await run("search", ["Deep"])) as? [[String: Any]])
        #expect(deep.contains { $0["file"] as? String == "sub/deep.org" && $0["heading"] as? Bool == false && $0["title"] as? String == "Deep" })
    }

    @Test func readsAnotherFilesOutline() async throws {
        let headings = try #require(try json(try await run("outline", ["sub/deep.org"])) as? [[String: Any]])
        #expect(headings.map { $0["title"] as? String } == ["Top", "Inner"])
        #expect(headings[1]["level"] as? Int == 2)
        #expect(headings[1]["tags"] as? [String] == ["x"])
        #expect(headings[1]["properties"] as? [String: String] == ["KIND": "deep"])
        // Absolute inside a folder, and a symlink to a file inside one.
        let absolute = notes.url.appendingPathComponent("todo.org").path
        #expect((try json(try await run("outline", [absolute])) as? [[String: Any]])?.count == 4)
        #expect((try json(try await run("outline", ["inner.org"])) as? [[String: Any]])?.count == 2)
    }

    @Test func refusesFilesOutsideTheFolders() async throws {
        #expect(try await run("outline", ["link.org"]) == "error: No file link.org in orgstar's folders.")
        #expect(try await run("outline", ["../" + outside.url.lastPathComponent + "/secret.org"])
            == "error: No file ../\(outside.url.lastPathComponent)/secret.org in orgstar's folders.")
        let secret = outside.url.appendingPathComponent("secret.org").path
        #expect(try await run("outline", [secret]) == "error: No file \(secret) in orgstar's folders.")
        #expect(try await run("outline", ["/etc/hosts"]) == "error: No file /etc/hosts in orgstar's folders.")
        #expect(try await run("outline", ["sub"]) == "error: No file sub in orgstar's folders.")
    }

    @Test func readsTheAgendaForASpan() async throws {
        let entries = try #require(try json(try await run("agenda", [#"{"from": "2026-11-26", "to": "2026-11-27"}"#])) as? [[String: Any]])
        let report = try #require(entries.first { $0["title"] as? String == "Write report about milk" })
        #expect(report["date"] as? String == "2026-11-26")
        #expect(report["time"] as? String == "10:00")
        #expect(report["kind"] as? String == "scheduled")
        #expect(report["file"] as? String == "todo.org")
        #expect(report["todo"] as? String == "TODO")
        // A span with nothing in it.
        #expect((try json(try await run("agenda", [#"{"from": "2026-12-10"}"#])) as? [Any])?.isEmpty == true)
        #expect(try await run("agenda", [#"{"from": "2026-11-27", "to": "2026-11-26"}"#]) == "error: org.agenda: to is before from.")
        #expect(try await run("agenda", [#"{"from": "2026-02-30"}"#]) == "error: org.agenda: from must be a date as YYYY-MM-DD.")
        #expect(try await run("agenda", [#"{"from": "2026-01-01", "to": "2027-06-01"}"#]) == "error: org.agenda: a span of at most 366 days.")
    }

    @Test func capturesThroughATemplate() async throws {
        let shown = try json(try await run("capture", ["e", "for the weekend", #"{"What": "Buy bread", "Tags": "shop"}"#])) as? [String: String]
        #expect(shown == ["template": "e", "file": "todo.org"])
        let todo = try String(contentsOf: notes.url.appendingPathComponent("todo.org"), encoding: .utf8)
        #expect(todo.hasPrefix("* Inbox\n** TODO Buy bread "))
        #expect(todo.contains(" :shop:\nfor the weekend\n* Project\n"))
        // The buffer the command ran in is as it was, with nothing to undo.
        #expect(buffer.document.text == Self.current)
        #expect(!buffer.document.canUndo)
    }

    @Test func refusesCapturesItCantFill() async throws {
        #expect(try await run("capture", ["e", "x", "{}"]) == "error: Template \"e\" asks for What, Tags; give them in fields.")
        #expect(try await run("capture", ["e", "x", #"{"What": "Milk"}"#]) == "error: Template \"e\" asks for Tags; give it in fields.")
        #expect(try await run("capture", ["zz", "x", "null"]) == "error: No capture template \"zz\".")
        #expect(try await run("capture", ["e", "x", #"{"What": 1}"#]) == "error: org.capture: field What must be a string.")
        #expect(try await run("capture", ["here", "x", "null"]) == "error: org.capture can't file to the file the command runs in; return edits instead.")
        #expect(try String(contentsOf: notes.url.appendingPathComponent("todo.org"), encoding: .utf8) == Self.todo)
        #expect(buffer.document.text == Self.current)
    }

    @Test func refusedWithoutWorkspace() async throws {
        let needs = { (name: String) in "org.\(name) needs workspace = true on the command in commands.toml." }
        #expect(try await run("buffer-only") == ["search", "outlineOf", "agenda", "capture"].map(needs).joined(separator: " | "))
        // Where the app gives no access, a command with workspace = true is told so.
        #expect(try await run("search", ["milk"], workspace: false) == "error: org.search isn't available here.")
    }

    /// Text encrypted on disk is never returned: not from `.gpg` files, not from buffers
    /// holding decrypted entries, and not as a snippet of an encrypted entry.
    @Test func encryptedTextIsNotReturned() async throws {
        #expect(try await run("outline", ["vault.org.gpg"]) == "error: vault.org.gpg is encrypted, so user commands can't read it.")
        let milk = try #require(try json(try await run("search", ["milk"])) as? [[String: Any]])
        #expect(!milk.contains { ($0["file"] as? String)?.hasSuffix(".gpg") == true })
        let cipher = try #require(try json(try await run("search", ["hQEMAciphertext"])) as? [[String: Any]])
        #expect(cipher.count == 1 && cipher.first?["title"] as? String == "Bank" && cipher.first?["snippet"] is NSNull)

        // A buffer with an entry decrypted and edited: search and outlines read the file on disk.
        session.encryptsTaggedEntries = true
        let other = notes.url.appendingPathComponent("b.org")
        session.open(other.path)
        let secret = StateBuffer(try #require(session.document))
        session.attach(secret)
        try secret.update { try $0.apply([TextEdit(range: 8..<8, replacement: "* Bank :crypt:\nAccount zebra12345\n")], baseRevision: $0.revision) }
        session.bufferChanged()
        #expect(session.openTexts[other.path] == nil)
        session.open(path)
        #expect(session.path == path)
        #expect((try json(try await run("search", ["zebra12345"])) as? [Any])?.isEmpty == true)
        let outline = try #require(try json(try await run("outline", ["b.org"])) as? [[String: Any]])
        #expect(outline.map { $0["title"] as? String } == ["Plain"])
    }

    /// Trust for workspace access is kept apart from trust for the buffer alone.
    @Test func workspaceAccessAsksForTrustAgain() throws {
        let modules = config.url.appendingPathComponent("commands")
        let file = config.url.appendingPathComponent("trusted.json")
        let trust = TrustStore(file: file)
        var asked: [UserCommandTrust.Question] = []
        var runs = 0
        func check(_ command: UserCommand, _ answer: UserCommandTrust.Answer?, in store: TrustStore) {
            UserCommandTrust.check(command, modules: modules, trust: store, ask: { question, reply in
                asked.append(question)
                reply(answer)
            }, run: { runs += 1 }, refuse: { _ in })
        }
        let bufferOnly = UserCommand(name: "a", title: "A", file: "ws.js", function: "all")
        let withWorkspace = UserCommand(name: "a", title: "A", file: "ws.js", function: "all", workspace: true)
        check(bufferOnly, .always, in: trust)
        check(bufferOnly, nil, in: trust)
        #expect(runs == 2 && asked == [UserCommandTrust.Question(file: "commands/ws.js")])
        // `workspace = true` added: asked again, saying what it can read.
        check(withWorkspace, nil, in: trust)
        #expect(runs == 2 && asked.last == UserCommandTrust.Question(file: "commands/ws.js", workspace: true))
        check(withWorkspace, .always, in: trust)
        #expect(runs == 3 && asked.count == 3)
        // Kept on the device: both kinds of command run without asking, and the workspace
        // trust survives the buffer-only one being given again.
        let relaunched = TrustStore(file: file)
        check(withWorkspace, nil, in: relaunched)
        check(bufferOnly, nil, in: relaunched)
        #expect(runs == 5 && asked.count == 3)
        // A file trusted only for the buffer, in a fresh store, doesn't cover workspace access.
        let fresh = TrustStore(file: config.url.appendingPathComponent("other.json"))
        check(bufferOnly, .always, in: fresh)
        check(withWorkspace, nil, in: fresh)
        #expect(runs == 6 && asked.count == 5)
    }
}
