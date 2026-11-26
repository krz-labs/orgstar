import AppKit
import OrgCore
import Testing
@testable import OrgEditorAppKit

/// TAB expands a trigger only where it means nothing else, in each preset; then TAB, S-TAB
/// and Escape move through the fields and end the snippet.
@MainActor
struct SnippetEditorTests {
    static let snippets = [
        Snippet(trigger: "date", body: "<2026-11-25 Wed>"),
        Snippet(trigger: "todo", body: "TODO ${1:what} by ${2:when}$0"),
        Snippet(trigger: "pair", body: "${1:a}-$1"),
    ]

    func harness(_ text: String, preset: KeymapPreset = .emacs, caret: Int? = nil) -> Harness {
        let h = Harness(text)
        h.editor.keymap = preset.keymap
        h.editor.modal = preset.isModal
        var options = h.editor.options
        options.snippets = Self.snippets
        h.editor.options = options
        h.caret(at: caret ?? text.utf16.count)
        return h
    }

    func type(_ h: Harness, _ text: String) {
        h.textView.insertText(text, replacementRange: h.textView.selectedRange())
    }

    func key(_ h: Harness, _ keys: String) { ModalTests().type(h, keys) }

    func shiftTab(_ h: Harness) {
        KeyTests().send(h, characters: "\u{19}", ignoring: "\u{19}", code: 48, flags: .shift)
    }

    @Test(arguments: [KeymapPreset.emacs, .mac]) func tabExpandsATrigger(preset: KeymapPreset) {
        let h = harness("Due date", preset: preset)
        key(h, "TAB")
        #expect(h.string == "Due <2026-11-25 Wed>" && h.editor.snippetSession == nil)
        // No trigger: TAB is the text system's again.
        let plain = harness("Due soon", preset: preset)
        key(plain, "TAB")
        #expect(plain.string == "Due soon\t")
    }

    @Test(arguments: [KeymapPreset.emacs, .mac]) func tabStillCyclesAndMovesInTables(preset: KeymapPreset) {
        let heading = harness("* date\nbody\n", preset: preset, caret: 6)
        key(heading, "TAB")
        #expect(heading.string == "* date\nbody\n" && heading.editor.foldState.folds.contains(0))
        let table = harness("| date | b |\n| c | d |\n", preset: preset, caret: 6)
        key(table, "TAB")
        #expect(!table.string.contains("2026") && table.caret > 7)
    }

    @Test func doomExpandsInInsertStateOnly() {
        let h = harness("Due date", preset: .doom)
        key(h, "TAB")
        #expect(h.string == "Due date")
        key(h, "A TAB")
        #expect(h.string == "Due <2026-11-25 Wed>")
        // A heading demotes in insert state, as Doom's TAB does there.
        let heading = harness("* date", preset: .doom)
        key(heading, "A TAB")
        #expect(heading.string == "** date")
    }

    @Test func fieldsTakeTypingAndTabMovesOn() {
        let h = harness("- todo")
        key(h, "TAB")
        #expect(h.string == "- TODO what by when")
        #expect(h.textView.selectedRange() == NSRange(location: 7, length: 4))
        type(h, "Call")
        key(h, "TAB")
        #expect(h.textView.selectedRange() == NSRange(location: 15, length: 4))
        shiftTab(h)
        #expect(h.textView.selectedRange() == NSRange(location: 7, length: 4))
        key(h, "TAB")
        type(h, "Fri")
        key(h, "TAB")
        #expect(h.string == "- TODO Call by Fri" && h.caret == 18 && h.editor.snippetSession == nil)
        // TAB is TAB again.
        key(h, "TAB")
        #expect(h.string == "- TODO Call by Fri\t")
    }

    @Test func mirrorsFollowTheirField() {
        let h = harness("pair")
        key(h, "TAB")
        type(h, "x")
        #expect(h.string == "x-x")
        type(h, "yz")
        #expect(h.string == "xyz-xyz")
        h.textView.deleteBackward(nil)
        #expect(h.string == "xy-xy")
    }

    @Test func escapeOrLeavingEndsIt() {
        let h = harness("todo")
        key(h, "TAB")
        key(h, "ESC")
        #expect(h.editor.snippetSession == nil)
        let moved = harness("text\ntodo")
        key(moved, "TAB")
        #expect(moved.editor.snippetSession != nil)
        moved.caret(at: 0)
        #expect(moved.editor.snippetSession == nil)
    }

    @Test func undoingTheExpansionEndsIt() {
        let h = harness("todo")
        key(h, "TAB")
        h.textView.undoManager?.undo()
        #expect(h.string == "todo" && h.editor.snippetSession == nil)
    }

    @Test func completionListsAndExpandsSnippets() {
        let h = harness("Notes da")
        h.editor.run("editor.complete")
        #expect(h.string == "Notes <2026-11-25 Wed>")
        let several = harness("x ")
        type(several, "p")
        several.editor.run("editor.complete")
        #expect(several.string == "x a-a" && several.editor.snippetSession != nil)
    }

    @Test func aKeyCanExpandOneSnippet() throws {
        var problems: [String] = []
        let user = try Keymap(toml: "[[bind]]\nkeys = \"C-c s\"\ncommand = \"org.snippet:date\"\n", problems: &problems, commands: Set(EditorCommands.all.map(\.id)))
        #expect(problems.isEmpty)
        let h = harness("On ")
        h.editor.keymap = .layered([KeymapPreset.emacs.keymap, user])
        key(h, "C-c s")
        #expect(h.string == "On <2026-11-25 Wed>")
    }

    @Test func commandsByName() {
        let h = harness("")
        h.editor.run("org.snippet:todo")
        #expect(h.string == "TODO what by when" && h.editor.snippetSession != nil)
        h.editor.run("org.snippet.next-field")
        #expect(h.textView.selectedRange() == NSRange(location: 13, length: 4))
    }
}
