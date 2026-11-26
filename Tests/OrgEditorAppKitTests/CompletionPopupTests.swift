import AppKit
import OrgCore
import Testing
@testable import OrgEditorAppKit

@MainActor
struct CompletionPopupTests {
    func at(_ text: String) -> Harness {
        let h = Harness(text)
        h.caret(at: text.utf16.count)
        return h
    }

    @Test func oneCandidateIsInserted() {
        let h = at("#+TI")
        h.editor.run("editor.complete")
        #expect(h.editor.document.text == "#+TITLE: " && h.caret == 9)
        let tags = at("* H :work:\n* I :")
        tags.editor.run("editor.complete")
        #expect(tags.editor.document.text == "* H :work:\n* I :work:")
        let template = at("  <s")
        template.editor.run("editor.complete")
        #expect(template.editor.document.text == "#+begin_src \n#+end_src" && template.caret == 12)
        let none = at("plain")
        none.editor.run("editor.complete")
        #expect(none.editor.completionPopup == nil && none.editor.document.text == "plain")
    }

    @Test func listPicksWithKeys() {
        let h = at("#+STARTUP: in")
        h.editor.run("editor.complete")
        #expect(h.editor.completionPopup?.completion.candidates == ["indent", "inlineimages"])
        #expect(h.editor.completionPopup?.window.isVisible == true)
        ModalTests().type(h, "C-n C-n")
        #expect(h.editor.completionPopup?.selected == "inlineimages")
        ModalTests().type(h, "C-p RET")
        #expect(h.editor.document.text == "#+STARTUP: indent" && h.editor.completionPopup == nil)

        // TAB completes the common start, then the list follows the text.
        let common = at("#+STARTUP: entities")
        common.editor.run("editor.complete")
        ModalTests().type(common, "TAB")
        #expect(common.editor.document.text == "#+STARTUP: entitiesp")
        #expect(common.editor.completionPopup?.completion.candidates == ["entitiesplain", "entitiespretty"])
        common.textView.insertText("r", replacementRange: common.textView.selectedRange())
        #expect(common.editor.completionPopup?.completion.candidates == ["entitiespretty"])
        common.textView.insertText(" ", replacementRange: common.textView.selectedRange())
        #expect(common.editor.completionPopup?.completion.candidates == nil || common.editor.completionPopup?.completion.range.lowerBound != 11)

        // RET with nothing chosen closes the list and is a newline.
        let plain = at("#+STARTUP: in")
        plain.editor.run("editor.complete")
        ModalTests().type(plain, "C-g")
        #expect(plain.editor.completionPopup == nil && plain.editor.document.text == "#+STARTUP: in")
    }

    @Test func doomOpensTheListAsYouType() {
        let h = Harness("* H :work:home:\n* I \n")
        h.editor.keymap = KeymapPreset.doom.keymap
        h.editor.modal = true
        h.caret(at: 20)
        ModalTests().type(h, "a")
        h.textView.insertText(":w", replacementRange: h.textView.selectedRange())
        h.editor.autoComplete()
        #expect(h.editor.completionPopup == nil)
        h.textView.insertText("o", replacementRange: h.textView.selectedRange())
        h.editor.autoComplete()
        #expect(h.editor.completionPopup?.completion.candidates == ["work:"])
        ModalTests().type(h, "ESC")
        #expect(h.editor.completionPopup == nil && h.editor.vim.mode == .normal)
        ModalTests().type(h, "a")
        h.textView.insertText("\\alp", replacementRange: h.textView.selectedRange())
        ModalTests().type(h, "C-SPC")
        #expect(h.editor.document.text.contains("\\alpha"))
    }

    /// #139: typing schedules the list only when the setting is on.
    @Test func typingOpensTheListOnlyWhenSet() {
        let h = at("* H :work:\n* I :wo")
        h.editor.textTyped()
        #expect(h.editor.completionTimer == nil)
        h.editor.options.completion = CompletionOptions(auto: true, delay: 0.01, prefix: 2)
        h.editor.textTyped()
        #expect(h.editor.completionTimer != nil)
        h.editor.completionTimer?.perform()
        #expect(h.editor.completionPopup?.completion.candidates == ["work:"])
    }

    /// #140: with fuzzy matching, letters in order, best first.
    @Test func fuzzyListFollowsTyping() {
        let h = at("#+STARTUP: lgd")
        h.editor.options.completion.fuzzy = true
        h.editor.run("editor.complete")
        #expect(h.editor.completionPopup?.completion.candidates.first == "logdone")
        h.textView.insertText("r", replacementRange: h.textView.selectedRange())
        #expect(h.editor.completionPopup?.completion.candidates == ["logdrawer", "nologdrawer"])
    }

    /// #141: M-/ expands and cycles; Doom's C-n lists words with the first chosen.
    @Test func wordsExpandAndList() {
        let h = at("help hello\nhe")
        h.editor.keymap = KeymapPreset.emacs.keymap
        h.editor.otherBuffers = { ["helmet"] }
        h.editor.run("editor.dabbrev-expand")
        #expect(h.editor.document.text == "help hello\nhello")
        h.editor.run("editor.dabbrev-expand")
        #expect(h.editor.document.text == "help hello\nhelp")
        h.editor.run("editor.dabbrev-expand")
        #expect(h.editor.document.text == "help hello\nhelmet")
        h.editor.run("editor.dabbrev-expand")
        #expect(h.editor.document.text == "help hello\nhe" && h.caret == 13)

        let doom = Harness("help hello\n\n")
        doom.editor.keymap = KeymapPreset.doom.keymap
        doom.editor.modal = true
        doom.caret(at: 11)
        ModalTests().type(doom, "a")
        doom.textView.insertText("he", replacementRange: doom.textView.selectedRange())
        ModalTests().type(doom, "C-n")
        #expect(doom.editor.completionPopup?.completion.candidates == ["hello", "help"] && doom.editor.completionPopup?.selected == "hello")
        ModalTests().type(doom, "C-n RET")
        #expect(doom.editor.document.text == "help hello\nhelp\n")
    }

    /// #143: a heading here without an ID gets one, and the link has its title.
    @Test func idLinkToAHeadingHere() {
        let h = at("* Plan\nBody\n* Notes\nSee [[id:Pl")
        h.editor.options.filePath = "/tmp/here.org"
        h.editor.run("editor.complete")
        #expect(h.editor.completionPopup?.completion.candidates == ["Plan"])
        ModalTests().type(h, "TAB")
        let text = h.editor.document.text
        let id = try? #require(text.firstMatch(of: /:ID: +(\S+)/)).1
        #expect(text.hasPrefix("* Plan\n:PROPERTIES:\n:ID:"))
        #expect(id.map { text.hasSuffix("See [[id:\($0)][Plan]]") } == true && h.caret == text.utf16.count)
    }
}
