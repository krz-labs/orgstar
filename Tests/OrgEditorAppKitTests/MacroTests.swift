import AppKit
import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp
@testable import OrgEditorAppKit

/// Keyboard macros in the Emacs and Mac presets: C-x (, C-x ), C-x e and their counts, F3 and
/// F4, prompts answered from the macro, errors that stop it, and named macros in macros.toml.
@MainActor
@Suite(.serialized)
struct MacroTests {

    /// Types `keys`, in the keymap's notation, as key events.
    func type(_ h: Harness, _ keys: String) {
        for key in KeySequence.parse(keys)! {
            let event = OrgEditor.event(for: key, window: h.window)!
            if key.modifiers.contains(.command) {
                _ = h.textView.performKeyEquivalent(with: event)
            } else {
                h.textView.keyDown(with: event)
            }
        }
    }

    /// An editor with the Emacs keys, no macro recorded, and the messages it shows.
    func emacs(_ text: String, caret: Int = 0) -> (Harness, () -> [String]) {
        OrgEditor.kmacro = MacroRecorder()
        let h = Harness(text)
        var messages: [String] = []
        h.editor.onMessage = { messages.append($0) }
        h.caret(at: caret)
        return (h, { messages })
    }

    @Test func recordStopAndCall() {
        let (h, messages) = emacs("one\ntwo\nthree\nfour\n")
        type(h, "C-x ( C-a * SPC C-n C-x )")
        #expect(h.string == "* one\ntwo\nthree\nfour\n")
        #expect(OrgEditor.kmacro.last == KeySequence.parse("C-a * SPC C-n"))
        #expect(messages() == ["Defining keyboard macro…", "Keyboard macro defined"])
        type(h, "C-x e")
        #expect(h.string == "* one\n* two\nthree\nfour\n")
        #expect(messages().last == "(Type e to repeat macro)")
        // e runs it again right after, and only then.
        type(h, "e e")
        #expect(h.string == "* one\n* two\n* three\n* four\n")
        type(h, "C-a e")
        #expect(h.string == "* one\n* two\n* three\n* four\ne")
    }

    @Test func counts() {
        let (h, _) = emacs("a\nb\nc\nd\ne\nf\ng\nh\n")
        type(h, "C-x ( C-a - SPC C-n C-x )")
        type(h, "C-u 2 C-x e")
        #expect(h.string == "- a\n- b\n- c\nd\ne\nf\ng\nh\n")
        type(h, "C-u C-x e")
        #expect(h.string == "- a\n- b\n- c\n- d\n- e\n- f\n- g\nh\n")
        // 0 runs it until a command fails: C-n on the last line.
        type(h, "C-u 0 C-x e")
        #expect(h.string == "- a\n- b\n- c\n- d\n- e\n- f\n- g\n- h\n- ")
    }

    @Test func endingWithCallRunsTheMacroOnce() {
        let (h, _) = emacs("x\n")
        type(h, "C-x ( C-e ! C-x e")
        #expect(h.string == "x!!\n")
        #expect(OrgEditor.kmacro.last == KeySequence.parse("C-e !"))
    }

    @Test func aFailingCommandStopsTheMacro() {
        let (h, messages) = emacs("ab\ncd\n")
        OrgEditor.kmacro.last = KeySequence.parse("C-f C-f C-f C-f C-f C-f C-f y")
        type(h, "C-x e")
        #expect(h.string == "ab\ncd\n")
        #expect(h.textView.selectedRange().location == 6)
        #expect(messages().last == "End of buffer")
        // Nothing waits for e after an error.
        type(h, "e")
        #expect(h.string == "ab\ncd\ne")
        // So does a key sequence nothing binds.
        let (other, _) = emacs("text\n")
        OrgEditor.kmacro.last = KeySequence.parse("C-c C-z z")
        type(other, "C-x e")
        #expect(other.string == "text\n")
    }

    @Test func errorsAsInEmacs() {
        let (h, messages) = emacs("x\n")
        type(h, "C-x e")
        #expect(messages().last == "No kbd macro has been defined")
        type(h, "C-x )")
        #expect(messages().last == "Not defining kbd macro")
        type(h, "C-x ( C-x )")
        #expect(messages().last == "Ignore empty macro")
        #expect(OrgEditor.kmacro.last == nil)
        type(h, "C-x ( C-x (")
        #expect(messages().last == "Already defining keyboard macro")
        h.editor.run("macro.end")
        // A prefix argument counts macros only.
        type(h, "C-u 3 C-c C-t")
        #expect(messages().last == "C-c C-t doesn't take a prefix argument")
        type(h, "C-u C-e")
        #expect(messages().last == "C-e doesn't take a prefix argument")
        #expect(h.string == "x\n")
        // Bindings that start with C-u keep it.
        type(h, "C-u C-c C-w")
        #expect(messages().last != "C-c C-w doesn't take a prefix argument")
    }

    @Test func promptsAnswersAreRecordedAndReplayed() {
        let (h, _) = emacs("* a\n* b\n* c\n")
        var asked = 0
        h.editor.onPrompt = { prompt, reply in
            asked += 1
            #expect(prompt.key == "tags")
            reply("foo:bar")
        }
        type(h, "C-x ( C-c C-q C-n C-x )")
        #expect(asked == 1)
        #expect(OrgEditor.kmacro.last == KeySequence.parse("C-c C-q f o o : b a r RET C-n"))
        type(h, "C-u 2 C-x e")
        #expect(asked == 1)
        #expect(h.string.components(separatedBy: "\n").filter { $0.hasSuffix(":foo:bar:") }.count == 3)
        // A cancelled prompt records C-g, which stops the macro when replayed.
        h.editor.onPrompt = { _, reply in reply(nil) }
        h.caret(at: 0)
        type(h, "C-x ( C-c C-q C-x )")
        #expect(OrgEditor.kmacro.last == KeySequence.parse("C-c C-q C-g"))
    }

    @Test func f3InsertsTheCounterAndF4EndsOrCalls() {
        let (h, _) = emacs("")
        type(h, "<f3> <f3> RET <f4>")
        #expect(h.string == "0\n")
        type(h, "<f4> <f4>")
        #expect(h.string == "0\n1\n2\n")
        type(h, "C-u <f4>")
        #expect(h.string == "0\n1\n2\n3\n4\n5\n6\n")
    }

    @Test func menuCommandsKeepEveryKey() {
        let (h, _) = emacs("abc\n")
        h.editor.run("macro.start")
        type(h, "C-f C-d")
        h.editor.run("macro.end")
        #expect(OrgEditor.kmacro.last == KeySequence.parse("C-f C-d"))
        h.editor.run("macro.call")
        #expect(h.string == "ac")
    }

    @Test func macPresetKeys() {
        let (h, _) = emacs("a\nb\nc\n")
        h.editor.keymap = KeymapPreset.mac.keymap
        type(h, "C-s-r - <down> <left> C-S-s-r")
        #expect(OrgEditor.kmacro.last == KeySequence.parse("- <down> <left>"))
        type(h, "C-s-m C-s-m")
        #expect(h.string == "-a\n-b\n-c\n")
    }

    @Test func doomNormalStateKeys() {
        let (h, _) = emacs("one two\nthree four\nfive six\n")
        h.editor.keymap = KeymapPreset.doom.keymap
        h.editor.modal = true
        type(h, "C-x ( d w j C-x )")
        #expect(OrgEditor.kmacro.last == KeySequence.parse("d w j"))
        type(h, "C-x e e")
        #expect(h.string == "two\nfour\nsix\n")
    }

    @Test func namingSavesToTheFileAndLoadsBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-macros-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(NamedMacros.fileName)
        let store = NamedMacros()
        #expect(MacroFile.load(into: store, from: file).isEmpty)
        let (h, messages) = emacs("* a\n* b\n")
        h.editor.namedMacros = store
        var answers = ["x", "tags-and-next", "bad name"]
        h.editor.onPrompt = { _, reply in reply(answers.removeFirst()) }
        type(h, "C-x ( C-c C-q C-n C-x ) C-x C-k n")
        #expect(messages().last == "Macro tags-and-next saved in macros.toml")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasSuffix("[macros]\ntags-and-next = \"C-c C-q x RET C-n\"\n"), "\(text)")
        type(h, "C-x C-k n")
        #expect(messages().last == "A macro name has letters, digits, - and _ only")

        let loaded = NamedMacros()
        #expect(MacroFile.load(into: loaded, from: file).isEmpty)
        #expect(loaded.names == ["tags-and-next"])
        #expect(loaded.keys("tags-and-next") == KeySequence.parse("C-c C-q x RET C-n"))
        // Naming another adds it, keeping the first.
        try loaded.name("other", KeySequence.parse("C-e")!)
        var problems: [String] = []
        #expect(try NamedMacros.parse(String(contentsOf: file, encoding: .utf8), problems: &problems).keys.sorted() == ["other", "tags-and-next"])
        #expect(problems.isEmpty)
    }

    @Test func namedMacroBoundInKeymap() throws {
        let store = NamedMacros()
        store.replace(["bang": KeySequence.parse("C-e ! C-n")!])
        let known = Set((EditorCommands.builtIn + EditorCommands.namedMacros(store)).map(\.id))
        var problems: [String] = []
        let toml = "[[bind]]\nkeys = \"C-c m\"\ncommand = \"macro.named.bang\"\n[[bind]]\nkeys = \"C-c n\"\ncommand = \"macro.named.missing\"\n"
        let user = try Keymap(toml: toml, problems: &problems, commands: known)
        #expect(problems == ["line 4: unknown command macro.named.missing"])
        let (h, messages) = emacs("a\nb\nc\n")
        h.editor.namedMacros = store
        h.editor.keymap = .layered([KeymapPreset.emacs.keymap, user])
        type(h, "C-c m C-u 2 C-c m")
        #expect(h.string == "a!\nb!\nc!\n")
        h.editor.run("macro.named.missing")
        #expect(messages().last == "No macro named missing")
        // Run Macro… picks one by name.
        h.caret(at: 0)
        h.editor.onPrompt = { prompt, reply in
            #expect(prompt.choices == ["bang"])
            reply("bang")
        }
        h.editor.run("macro.run")
        #expect(h.string == "a!!\nb!\nc!\n")
    }

    @Test func parsingReportsBadEntries() throws {
        var problems: [String] = []
        let macros = try NamedMacros.parse("[macros]\nok = \"C-a\"\nbad = \"C-\"\n[other]\nx = 1\n", problems: &problems)
        #expect(macros == ["ok": [KeyChord("a", .control)]])
        #expect(problems == ["bad: bad keys", "line 4: unknown table [other]"])
    }

    @Test func answerKeysRoundTrip() {
        let text = "Tag one\tand\ntwo é"
        let keys = MacroRecorder.keys(typing: text) + [KeyChord("RET")]
        #expect(KeySequence.parse(KeySequence.format(keys)) == keys)
        #expect(MacroRecorder.reply(from: keys)?.reply == .answer(text))
        #expect(MacroRecorder.reply(from: KeySequence.parse("a b DEL c RET z")!)! == (.answer("ac"), 5))
        #expect(MacroRecorder.reply(from: KeySequence.parse("a")!) == nil)
    }

    /// A keyboard macro records a user command's key and its prompt's answer; replaying waits
    /// for the command to finish before the next key, and answers its prompt from the macro.
    @Test func macrosWaitForUserCommands() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let modules = folder.appendingPathComponent("config/commands")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("""
            export async function stamp(org) {
              const word = await org.prompt("Word: ");
              await new Promise(resolve => setTimeout(resolve, 100));
              const { selection: [{ from }] } = await org.run("org.todo.cycle");
              const heading = await org.heading();
              return { edits: [{ from: heading.titleEnd, text: " " + word }], selection: from };
            }
            """.utf8).write(to: modules.appendingPathComponent("stamp.js"))
        let file = folder.appendingPathComponent("a.org")
        try Data("* one\n* two\n* three\n".utf8).write(to: file)
        let shared = (UserCommands.shared.all, UserCommands.shared.folder)
        defer { UserCommands.shared.replace(shared.0, folder: shared.1) }
        UserCommands.shared.replace([UserCommand(name: "stamp", title: "Stamp", file: "stamp.js", function: "stamp")], folder: modules)
        OrgEditor.kmacro = MacroRecorder()
        defer { OrgEditor.kmacro = MacroRecorder() }

        let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.appendingPathComponent("r")))
        session.saveMode = .explicit
        session.userCommands = UserCommands.shared
        session.open(file.path)
        let h = Harness(try #require(session.document))
        h.editor.onChange = { [weak session] in session?.bufferChanged() }
        session.attach(h.editor)
        var problems: [String] = []
        let toml = "[[bind]]\nkeys = \"C-c u\"\ncommand = \"user.stamp\"\n[[bind]]\nkeys = \"C-c m\"\ncommand = \"macro.named.stamp\"\n"
        let user = try Keymap(toml: toml, problems: &problems, commands: Set(EditorCommands.all.map(\.id) + ["macro.named.stamp"]))
        h.editor.keymap = .layered([KeymapPreset.emacs.keymap, user])
        var asked = 0
        h.editor.onPrompt = { _, reply in
            asked += 1
            reply("ok")
        }
        var messages: [String] = []
        h.editor.onMessage = { messages.append($0) }
        h.editor.onUserCommand = { [weak session, weak h] request, finished in
            guard let session, let h else { return }
            session.startUserCommand(request, context: h.editor.context(), file: "a.org", ask: h.editor.ask, report: { messages.append($0) }, finished: finished)
        }
        func settled() async throws {
            for _ in 0..<250 where session.isRunningUserCommand || h.editor.kmacroDepth > 0 { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!session.isRunningUserCommand && h.editor.kmacroDepth == 0)
        }
        h.caret(at: 2)
        type(h, "C-x ( C-c u")
        try await settled()
        type(h, "C-n C-x )")
        #expect(h.string == "* TODO one ok\n* two\n* three\n")
        #expect(OrgEditor.kmacro.last == KeySequence.parse("C-c u o k RET C-n"))
        #expect(asked == 1)

        type(h, "C-u 2 C-x e")
        try await settled()
        #expect(h.string == "* TODO one ok\n* TODO two ok\n* TODO three ok\n")
        #expect(asked == 1)
        #expect(!messages.contains { $0.contains("undefined") })
        h.checkInSync()
        // Each run is one undo step.
        h.textView.undoManager?.undo()
        #expect(h.string == "* TODO one ok\n* TODO two ok\n* three\n")

        // A macro waits for a named macro it runs that waits for a user command.
        let store = NamedMacros()
        store.replace(["stamp": try OrgEditor.kmacro.lastMacro()])
        h.editor.namedMacros = store
        OrgEditor.kmacro.last = KeySequence.parse("C-c m C-e !")
        h.caret(at: 30)
        type(h, "C-x e")
        try await settled()
        #expect(h.string == "* TODO one ok\n* TODO two ok\n* TODO three ok\n!")
        #expect(asked == 1)
    }

    // MARK: - Emacs

    struct OracleCase {
        var text: String
        var caret: Int
        var keys: String
        var count: Int
    }

    static let oracleCases = [
        OracleCase(text: "one\ntwo\nthree\nfour", caret: 0, keys: "C-a * SPC C-n", count: 0),
        OracleCase(text: "* a\n* b\n* c\n", caret: 0, keys: "C-c C-t C-n", count: 2),
        OracleCase(text: "* a\n* b\n", caret: 0, keys: "C-c C-q f o o RET C-n", count: 2),
        OracleCase(text: "ab\ncd", caret: 1, keys: "C-f C-f C-f C-f C-f C-f y", count: 1),
        OracleCase(text: "- a\n- b\n", caret: 0, keys: "C-e SPC x C-n", count: 0),
        OracleCase(text: "* TODO a\n", caret: 0, keys: "C-c C-t", count: 3),
        OracleCase(text: "x", caret: 1, keys: "RET * SPC h", count: 2),
        OracleCase(text: "a b c\nd e f\n", caret: 0, keys: "C-d C-f C-k C-n C-a", count: 4),
        OracleCase(text: "first\nsecond\n", caret: 12, keys: "C-p C-p C-e .", count: 0),
    ]

    /// Each case run in Emacs with `execute-kbd-macro` and here with C-u N C-x e: the same
    /// buffer and point.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func replayMatchesEmacs() throws {
        let emacs = try Self.runEmacs(Self.oracleCases)
        for (index, c) in Self.oracleCases.enumerated() {
            let (h, _) = self.emacs(c.text, caret: c.caret)
            OrgEditor.kmacro.last = KeySequence.parse(c.keys)
            type(h, c.count == 1 ? "C-x e" : "C-u \(c.count) C-x e")
            #expect(h.string == emacs[index].text, "\(c.keys)")
            #expect(h.textView.selectedRange().location + 1 == emacs[index].point, "\(c.keys)")
        }
    }

    static func runEmacs(_ cases: [OracleCase]) throws -> [(text: String, point: Int)] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-kmacro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func literal(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let forms = cases.map { "(orgstar-case \(literal($0.text)) \($0.caret + 1) \(literal($0.keys)) \($0.count))" }.joined(separator: "\n")
        let output = folder.appendingPathComponent("out.json")
        let script = folder.appendingPathComponent("kmacro.el")
        try """
            ;;; -*- lexical-binding: t -*-
            (require 'org)
            (require 'json)
            (setq org-todo-keywords '((sequence "TODO" "DONE")) org-log-done nil org-tags-column -77)
            (setq-default indent-tabs-mode nil)
            (defvar orgstar-results nil)
            (defun orgstar-case (text point keys count)
              (let ((buffer (generate-new-buffer "case")))
                ;; Keys run in the selected window's buffer.
                (switch-to-buffer buffer)
                (insert text)
                (org-mode)
                (goto-char point)
                (condition-case nil (execute-kbd-macro (kbd keys) count) (error nil))
                (push (list (buffer-substring-no-properties (point-min) (point-max)) (point)) orgstar-results)
                (kill-buffer buffer)))
            \(forms)
            (with-temp-file \(literal(output.path))
              (insert (json-encode (vconcat (nreverse orgstar-results)))))
            """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ProcessInfo.processInfo.environment["ORGSTAR_EMACS"] ?? "emacs", "-Q", "--batch", "-l", script.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let results = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [[Any]]
        return results.map { ($0[0] as! String, $0[1] as! Int) }
    }
}
