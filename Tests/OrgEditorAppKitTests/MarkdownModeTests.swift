import AppKit
import OrgCore
import OrgDocument
import OrgPresentation
import Testing
@testable import OrgEditorAppKit

/// Markdown files: highlighted, folded by heading, and closed to org's commands.
@MainActor
struct MarkdownModeTests {
    func markdown(_ text: String) -> Harness {
        let h = Harness(DocumentState(bytes: Array(text.utf8)), mode: .markdown)
        h.drainStyling()
        h.layout()
        return h
    }

    func font(_ h: Harness, at offset: Int) -> NSFont? {
        h.textView.textStorage!.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
    }

    @Test func highlighting() {
        let text = "# Title\nplain **bold** and `code`\n* item\n"
        let h = markdown(text)
        let theme = h.editor.theme
        #expect(font(h, at: 2)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(font(h, at: 10) == theme.font)
        #expect(font(h, at: 17)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let storage = h.textView.textStorage!
        let code = (text as NSString).range(of: "code").location
        #expect(storage.attribute(.foregroundColor, at: code, effectiveRange: nil) as? NSColor == theme.color("code"))
        // `* item` is a list item, not an org heading.
        let item = (text as NSString).range(of: "item").location
        #expect(font(h, at: item) == theme.font)
    }

    @Test func typingKeepsHighlightingInStep() {
        let h = markdown("a\n```\n# code\n```\n# Heading\n")
        let heading = h.offset(of: "# Heading") + 2
        #expect(font(h, at: heading)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        // Removing the closing fence makes the heading code.
        let closing = h.offset(of: "```\n# Heading")
        h.textView.setSelectedRange(NSRange(location: closing, length: 4))
        h.textView.insertText("", replacementRange: h.textView.selectedRange())
        #expect(font(h, at: h.offset(of: "# Heading") + 2) == h.editor.theme.font)
        #expect(h.editor.document.text == "a\n```\n# code\n# Heading\n")
    }

    @Test func tabFoldsHeadings() {
        let h = markdown("# A\nbody\n## B\nmore\n# C\ntext\n")
        h.caret(at: 1)
        h.editor.run("org.cycle")
        #expect(h.visibleLines == ["# A\n", "# C\n", "text\n"])
        h.editor.run("org.cycle")
        #expect(h.visibleLines == ["# A\n", "body\n", "## B\n", "# C\n", "text\n"])
        h.editor.run("org.cycle-global")
        #expect(h.visibleLines == ["# A\n", "# C\n"])
        h.editor.reveal(h.offset(of: "more"))
        #expect(h.visibleLines.contains("more\n"))
        // Folds stay on their headings as text is typed above them.
        h.editor.run("org.cycle-global")
        h.caret(at: 0)
        h.textView.insertText("x", replacementRange: h.textView.selectedRange())
        let folded = h.editor.foldState.folds.union(h.editor.foldState.bodyFolds)
        #expect(folded == Set(h.editor.markdown.outline.map(\.start)))
    }

    @Test func clickingHashesCycles() {
        let h = markdown("## A\nbody\n- [ ] task\n")
        #expect(!h.editor.click(at: 4))
        #expect(h.editor.click(at: 1))
        #expect(h.visibleLines == ["## A\n"])
        // A task box isn't toggled: that would be org's checkbox command.
        _ = h.editor.click(at: 1)
        #expect(!h.editor.click(at: h.offset(of: "[ ]") + 1))
        #expect(h.editor.document.text == "## A\nbody\n- [ ] task\n")
    }

    @Test func orgCommandsAreRefused() {
        let text = "# Heading\n- item\n| a |\n"
        let h = markdown(text)
        var messages: [String] = []
        var appCommands: [String] = []
        h.editor.onMessage = { messages.append($0) }
        h.editor.onAppCommand = { appCommands.append($0) }
        for id in ["org.todo.cycle", "org.item.insert", "org.heading.insert", "org.timestamp.inactive", "org.link.insert", "org.emphasize.bold",
                   "org.table.align", "org.tags.set", "org.schedule", "org.priority.up", "app.refile", "app.archive", "app.attach.attach",
                   "app.table-import", "app.export.html", "app.clock.in"] {
            h.caret(at: 3)
            h.editor.run(id)
            #expect(h.editor.document.text == text, "\(id)")
        }
        #expect(appCommands.isEmpty)
        #expect(messages == Array(repeating: "Not an org file", count: 16))
        // Typing doesn't continue lists or fill as org would.
        h.caret(at: 16)
        h.textView.insertNewline(nil)
        #expect(h.editor.document.text == "# Heading\n- item\n\n| a |\n")
        // App commands that aren't about the file's entries still reach the app.
        h.editor.run("app.save")
        #expect(appCommands == ["app.save"])
    }

    @Test func plainTextDoesNotFold() {
        let h = Harness(DocumentState(bytes: Array("# A\nbody\n".utf8)), mode: .plain(language: nil))
        var messages: [String] = []
        h.editor.onMessage = { messages.append($0) }
        h.caret(at: 1)
        h.editor.run("org.cycle")
        #expect(h.visibleLines == ["# A\n", "body\n"])
        #expect(messages == ["Not an org file"])
    }
}
