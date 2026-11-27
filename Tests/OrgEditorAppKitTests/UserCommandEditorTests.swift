import AppKit
import Foundation
import OrgCore
import OrgDocument
@testable import OrgApp
import Testing
@testable import OrgEditorAppKit

/// A user command run through the command host on the session's editor.
@MainActor
struct UserCommandEditorTests {
    @Test func editsApplyAsOneUndoStep() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let modules = folder.appendingPathComponent("config/commands")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("""
            export async function swap(org) {
              const [{ from }] = await org.selection();
              const h = await org.heading();
              return {
                edits: [
                  { from: h.titleStart, to: h.titleStart, text: "[" },
                  { from: h.titleEnd, to: h.titleEnd, text: "]" },
                  { from: h.end, to: h.end, text: "added\\n" },
                ],
                selection: from + 1,
                message: "Swapped",
              };
            }
            """.utf8).write(to: modules.appendingPathComponent("swap.js"))
        let file = folder.appendingPathComponent("a.org")
        let text = "* One\nbody\n* Two\n"
        try Data(text.utf8).write(to: file)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.appendingPathComponent("r")))
        session.saveMode = .explicit
        session.userCommands = UserCommands()
        let command = UserCommand(name: "swap", title: "Swap", file: "swap.js", function: "swap")
        session.userCommands.replace([command], folder: modules)
        session.open(file.path)
        let h = Harness(try #require(session.document))
        h.editor.onChange = { [weak session] in session?.bufferChanged() }
        session.attach(h.editor)
        var messages: [String] = []
        h.editor.onMessage = { messages.append($0) }
        h.caret(at: 3)
        var requested: UserCommandRequest?
        h.editor.onExternal = { if case .userCommand(let request) = $0 { requested = request } }
        h.editor.perform(command)
        let request = try #require(requested)
        #expect(await session.runUserCommand(request, context: h.editor.context(), file: "a.org", ask: { _, _ in }, report: { _ in }) == nil)
        #expect(h.string == "* [One]\nbody\nadded\n* Two\n")
        #expect(h.textView.selectedRange() == NSRange(location: 4, length: 0))
        #expect(messages == ["Swapped"])
        #expect(session.isDirty)
        h.checkInSync()
        h.textView.undoManager?.undo()
        #expect(h.string == text)
        #expect(h.textView.undoManager?.canUndo != true)
        h.checkInSync()
    }

    @Test func registeredWhereCommandIDsAre() throws {
        let store = UserCommands()
        store.replace([UserCommand(name: "review", title: "Weekly Review", file: "r.js", function: "r", when: "heading")], folder: nil)
        let commands = EditorCommands.userCommands(store)
        #expect(commands.map(\.id) == ["user.review"])
        #expect(commands[0].localizedTitle == "Weekly Review" && commands[0].inPalette)
        var problems: [String] = []
        let ids = Set(EditorCommands.builtIn.map(\.id) + commands.map(\.id))
        let keymap = try Keymap(toml: "[[bind]]\nkeys = \"C-c w\"\ncommand = \"user.review\"\n[[bind]]\nkeys = \"C-c x\"\ncommand = \"user.other\"\n", problems: &problems, commands: ids)
        #expect(keymap.bindings.map(\.command) == ["user.review"])
        #expect(problems == ["line 4: unknown command user.other"])
    }
}
