import Foundation
import OrgCore
import Testing

struct MarkdownStructureTests {
    @Test func headingsSkipFencesAndFrontMatter() {
        let text = "---\ntitle: Notes\n# not a heading\n---\n# One\n```swift\n# comment\n```\n## Two ##\n####### seven\n#tag\n   ### Three\n"
        let structure = Markdown.structure(text)
        #expect(structure.frontMatter?.format == .yaml)
        #expect(structure.frontMatter?.range == 0..<37)
        #expect(structure.fences.count == 1)
        #expect(structure.fences[0].language == "swift")
        #expect(structure.headings.map(\.title) == ["One", "Two", "Three"])
        #expect(structure.headings.map(\.level) == [1, 2, 3])
        #expect(structure.headings[0].start == 37)
        #expect(structure.headings[0].lineEnd == 43)
    }

    @Test func fences() {
        let structure = Markdown.structure("~~~ {.python}\nx\n```\n~~~~\nafter\n````\nopen to the end\n```\n")
        #expect(structure.fences.count == 2)
        #expect(structure.fences[0].language == "python")
        #expect(structure.fences[0].range == 0..<25)
        #expect(structure.fences[0].body == 14..<20)
        // Unclosed, and a shorter run doesn't close it.
        #expect(structure.fences[1].closing == nil)
        #expect(structure.fences[1].range.upperBound == 56)
        // Backticks in a backtick fence's info string make it inline code.
        #expect(Markdown.structure("``` a`b\n").fences.isEmpty)
    }

    @Test func closingHashesAndEmptyHeadings() {
        let headings = Markdown.structure("# a # b ##\n#\n## #\n# c#\n").headings
        #expect(headings.map(\.title) == ["a # b", "", "", "c#"])
    }

    @Test func titles() {
        #expect(Markdown.title("---\ntitle: \"A note\"\n---\n# Heading\n") == "A note")
        #expect(Markdown.title("+++\ntitle      = 'TOML note'\n+++\n") == "TOML note")
        #expect(Markdown.title("Intro\n\n## First\n") == "First")
        #expect(Markdown.title("---\ndate: 2026\n---\n# From the heading\n") == "From the heading")
        #expect(Markdown.title("no headings") == nil)
        // A `---` line alone isn't front matter.
        #expect(Markdown.structure("---\ntext\n").frontMatter == nil)
    }

    /// Updating the structure through an edit gives what reading the new text does.
    @Test func editsMatchAFreshRead() {
        let pieces = ["# A\n", "## B\n", "text\n", "```\n", "~~~ py\n", "# in fence?\n", "---\n", "+++\n", "\n", "#", "x", "`", " ", "\n"]
        var generator = SeededGenerator(state: testSeed(159))
        var text = "Intro\n# One\nbody\n```\n# code\n```\n## Two\nmore\n"
        var structure = Markdown.structure(text)
        for _ in 0..<2_000 {
            let old = Array(text.utf16)
            let lower = Int.random(in: 0...old.count, using: &generator)
            let upper = min(old.count, lower + Int.random(in: 0...6, using: &generator))
            let replacement = Int.random(in: 0...2, using: &generator) == 0 ? "" : pieces.randomElement(using: &generator)!
            var new = old
            new.replaceSubrange(lower..<upper, with: Array(replacement.utf16))
            let edit = TextEdit(range: lower..<upper, replacement: replacement)
            structure = Markdown.structure(structure, old: old, new: new, after: edit) ?? Markdown.structure(new)
            text = String(decoding: new, as: UTF16.self)
            #expect(structure == Markdown.structure(new), "\(text.debugDescription) after \(edit)")
            if structure != Markdown.structure(new) { return }
        }
    }

    @Test func paths() {
        #expect(Markdown.isPath("/a/b.md") && Markdown.isPath("x.MARKDOWN") && !Markdown.isPath("x.org"))
        #expect(Markdown.isPlainTextPath("notes.txt") && !Markdown.isPlainTextPath("notes.md"))
    }
}

struct MarkdownSpanTests {
    func spans(_ line: String) -> [String] {
        let u = Array(line.utf16)
        return Markdown.lineSpans(u, 0, u.count).map { span in
            "\(span.kind):" + String(decoding: u[span.range], as: UTF16.self)
        }
    }

    @Test func emphasis() {
        #expect(spans("a **b** _c_ ~~d~~") == [
            "bold:**b**", "marker:**", "marker:**", "italic:_c_", "marker:_", "marker:_", "strikeThrough:~~d~~", "marker:~~", "marker:~~",
        ])
        #expect(spans("***both***") == ["italic:***both***", "marker:*", "bold:**both**", "marker:**", "marker:**", "marker:*"])
        // Intraword underscores and spaced stars aren't emphasis.
        #expect(spans("snake_case_name and 2 * 3 * 4").isEmpty)
    }

    @Test func codeHidesMarkup() {
        #expect(spans("`*not*` and ``a ` b``") == ["code:`*not*`", "marker:`", "marker:`", "code:``a ` b``", "marker:``", "marker:``"])
        #expect(spans("an `unclosed *span*").contains("italic:*span*"))
    }

    @Test func links() {
        #expect(spans("[a *b*](http://x.y/(z)) ![img](p.png)") == [
            "linkMarkup:[", "link:a *b*", "italic:*b*", "marker:*", "marker:*", "linkMarkup:](http://x.y/(z))",
            "linkMarkup:![", "link:img", "linkMarkup:](p.png)",
        ])
        #expect(spans("<https://example.com> and https://a.b/c_d_e.") == [
            "linkMarkup:<", "link:https://example.com", "linkMarkup:>", "link:https://a.b/c_d_e",
        ])
        #expect(spans("[ref]: https://example.com \"Title\"") == ["linkMarkup:[ref]: ", "link:https://example.com"])
        #expect(spans("[text][ref]") == ["linkMarkup:[", "link:text", "linkMarkup:][ref]"])
    }

    @Test func lines() {
        #expect(spans("## Title with `code`") == ["heading(level: 2):## Title with `code`", "code:`code`", "marker:`", "marker:`"])
        #expect(spans("- [x] done") == ["marker:-", "checkbox:[x]"])
        #expect(spans("  12. item") == ["marker:12."])
        #expect(spans("> > quoted *text*") == ["marker:>", "marker:>", "quote:quoted *text*", "italic:*text*", "marker:*", "marker:*"])
        #expect(spans("* * *") == ["rule:* * *"])
        #expect(spans("| a | b |") == ["table:| a | b |"])
        #expect(spans("<!-- note --> after") == ["comment:<!-- note -->"])
    }
}

struct OrgOnlyCommandTests {
    @Test func refusedOutsideOrg() {
        for id in ["org.todo.cycle", "org.meta-return", "org.link.insert", "app.refile", "app.archive", "app.attach.attach", "app.export.html",
                   "app.table-import", "app.clock.in", "app.node.insert", "app.crypt.encrypt-entry", "app.export-dialog"] {
            #expect(OrgOnlyCommands.refuses(id, markdown: true), "\(id)")
            #expect(OrgOnlyCommands.refuses(id, markdown: false), "\(id)")
        }
        for id in ["org.cycle", "org.cycle-global", "org.fold.toggle", "org.fold.close-all"] {
            #expect(!OrgOnlyCommands.refuses(id, markdown: true), "\(id)")
            #expect(OrgOnlyCommands.refuses(id, markdown: false), "\(id)")
        }
        for id in ["app.save", "app.agenda", "app.capture", "app.search", "app.word-count", "app.export.icalendar-agenda", "edit.undo", "editor.toggle-truncate-lines"] {
            #expect(!OrgOnlyCommands.refuses(id, markdown: true), "\(id)")
        }
    }
}
