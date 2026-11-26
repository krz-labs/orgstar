import Foundation
import Testing
@testable import OrgCore

/// Markdown to org, one construct at a time; each output is read back with orgstar's parser.
struct MarkdownToOrgTests {
    func org(_ markdown: String, obsidian: Bool = false, title: String? = nil) -> (text: String, tree: OrgTree, model: DocumentModel, result: MarkdownToOrg.Result) {
        let result = MarkdownToOrg.convert(markdown, obsidian: obsidian, title: title)
        let tree = OrgParser.parse(result.text)
        return (result.text, tree, DocumentModel(tree: tree), result)
    }

    func nodes(_ tree: OrgTree, _ kind: SyntaxKind) -> [SyntaxNode] {
        tree.root.descendants().filter { $0.kind == kind }
    }

    func tokens(_ tree: OrgTree, _ kind: SyntaxKind) -> [SyntaxToken] {
        tree.root.descendants().flatMap(\.tokens).filter { $0.kind == kind }
    }

    @Test func atxAndSetextHeadings() {
        let out = org("# One\ntext\n## Two ##\nSetext\n======\nUnder\n---\n")
        #expect(out.model.headings.map(\.level) == [1, 2, 1, 2])
        #expect(out.model.headings.map(\.title) == ["One", "Two", "Setext", "Under"])
        #expect(out.result.headings == 4)
    }

    @Test func emphasisAndCode() {
        let out = org("Some **bold**, __strong__, *it*, _em_, ***both***, `co~de`, `x` and ~~gone~~.\n")
        #expect(out.text == "Some *bold*, *strong*, /it/, /em/, */both/*, =co~de=, ~x~ and +gone+.\n")
        #expect(nodes(out.tree, .bold).count == 3)
        #expect(nodes(out.tree, .italic).count == 3)
        #expect(nodes(out.tree, .verbatim).count == 1)
        #expect(nodes(out.tree, .code).count == 1)
        #expect(nodes(out.tree, .strikeThrough).count == 1)
    }

    @Test func intrawordUnderscoreStaysText() {
        #expect(org("snake_case_name\n").text == "snake_case_name\n")
    }

    @Test func linksAndImages() {
        let out = org("""
            A [site](https://example.com "Title"), <https://auto.example>, <me@example.com>,
            ![alt text](pics/a%20b.png) and [ref] and [label][ref].

            [ref]: https://ref.example

            """)
        #expect(out.model.links == ["https://example.com", "https://auto.example", "mailto:me@example.com", "file:pics/a b.png", "https://ref.example", "https://ref.example"])
        #expect(out.text.contains("[[https://example.com][site]]"))
        #expect(out.result.links == 6)
    }

    @Test func imageAloneGetsAltAttribute() {
        let out = org("![A cat](cat.png)\n")
        #expect(out.text == "#+attr_html: :alt A cat\n[[file:cat.png]]\n")
        #expect(nodes(out.tree, .affiliatedKeyword).count + nodes(out.tree, .keyword).count >= 1)
    }

    @Test func nestedOrderedAndTaskLists() {
        let out = org("""
            - one
              - nested *a*
              - [ ] open
              - [x] done
            - two

            3. three
            4. four

            """)
        #expect(out.text == """
            - one
              - nested /a/
              - [ ] open
              - [X] done
            - two


            3. [@3] three
            4. four

            """)
        #expect(nodes(out.tree, .plainList).count == 3)
        #expect(nodes(out.tree, .item).count == 7)
        #expect(tokens(out.tree, .checkbox).count == 2)
        #expect(tokens(out.tree, .counter).count == 1)
    }

    @Test func listItemWithParagraphsAndCode() {
        let out = org("1. First\n\n   More text.\n\n   ```sh\n   ls\n   ```\n2. Second\n")
        #expect(out.text == "1. First\n\n   More text.\n   #+begin_src sh\n   ls\n   #+end_src\n2. Second\n")
        #expect(nodes(out.tree, .item).count == 2)
        #expect(out.model.srcBlocks.map(\.language) == ["sh"])
    }

    @Test func blockQuote() {
        let out = org("> quoted *text*\n> more\n>\n> - item\n")
        #expect(out.text == "#+begin_quote\nquoted /text/\nmore\n\n- item\n#+end_quote\n")
        #expect(nodes(out.tree, .block).count == 1)
    }

    @Test func codeFencesBecomeSourceBlocks() {
        let out = org("```python\n* star\n#+keyword\nprint(1)\n```\n\n```\nplain\n```\n\n    indented\n")
        #expect(out.text == "#+begin_src python\n,* star\n,#+keyword\nprint(1)\n#+end_src\n\n#+begin_example\nplain\n#+end_example\n\n#+begin_example\nindented\n#+end_example\n")
        #expect(out.model.srcBlocks.count == 1)
        #expect(out.model.headings.isEmpty)
    }

    @Test func tablesBecomeOrgTables() {
        let out = org("| A | B \\| C |\n|:--|--:|\n| `x` | **y** |\n| z |\n")
        #expect(out.model.tables.count == 1)
        #expect(out.model.tables[0].rows == [.cells(["A", "B \\vert{} C"]), .rule, .cells(["~x~", "*y*"]), .cells(["z", ""])])
    }

    @Test func footnotes() {
        let out = org("Text[^1] and more[^note].\n\n[^1]: First.\n[^note]: Second\n    continued.\n")
        #expect(nodes(out.tree, .footnoteReference).count == 2)
        #expect(nodes(out.tree, .footnoteDefinition).count == 2)
        #expect(out.text.hasSuffix("[fn:1] First.\n\n[fn:note] Second\ncontinued.\n"))
    }

    @Test func frontMatter() {
        let out = org("""
            ---
            title: "A Note"
            date: 2024-01-05
            tags: [one, two/three]
            aliases:
              - First alias
              - second
            status: draft
            nested:
              a: 1
            ---
            Body.

            """)
        #expect(out.text == """
            :PROPERTIES:
            :ROAM_ALIASES: "First alias" second
            :status: draft
            :END:
            #+title: A Note
            #+date: 2024-01-05
            #+filetags: :one:two_three:

            Body.

            """)
        #expect(out.model.fileTags == ["one", "two_three"])
        #expect(nodes(out.tree, .propertyDrawer).count == 1)
        #expect(out.result.issues == [.frontMatter("nested")])
    }

    @Test func mathRuleHTMLAndComments() {
        let out = org("$$\nE = mc^2\n$$\n\nInline $x^2$, not $5 or $6.\n\n***\n\n<!-- hidden -->\n\n<div>\n<b>x</b>\n</div>\n")
        #expect(out.text == "\\[\nE = mc^2\n\\]\n\nInline \\(x^2\\), not $5 or $6.\n\n-----\n\n#+begin_comment\nhidden\n#+end_comment\n\n#+begin_export html\n<div>\n<b>x</b>\n</div>\n#+end_export\n")
        #expect(nodes(out.tree, .latexFragment).count >= 1)
        #expect(nodes(out.tree, .horizontalRule).count == 1)
    }

    @Test func hardBreaksAndEntities() {
        let out = org("one  \ntwo\\\nthree &amp; &#8212;\n")
        #expect(out.text == "one \\\\\ntwo \\\\\nthree & —\n")
        #expect(nodes(out.tree, .lineBreak).count == 2)
    }

    @Test func paragraphLinesThatOrgWouldReadAsElements() {
        // A continuation line can't start a list or a table in org; it joins the line above.
        let out = org("Item count:\n2. is not a list\n| not a table\n")
        #expect(out.text == "Item count: 2. is not a list | not a table\n")
        #expect(nodes(out.tree, .plainList).isEmpty)
        #expect(nodes(out.tree, .table).isEmpty)
    }

    @Test func headingInsideListIsBold() {
        let out = org("- # Title\n")
        #expect(out.text == "- *Title*\n")
        #expect(out.model.headings.isEmpty)
    }

    // MARK: - Obsidian

    @Test func wikilinksAndEmbeds() {
        let out = org("See [[Other note]], [[Other note#Part|alias]], [[#Local]] and ![[pic.png|300]].\n", obsidian: true)
        #expect(out.text == "See [[file:Other note.org][Other note]], [[file:Other note.org][alias]], #Local and [[file:pic.png]].\n")
        #expect(out.result.issues == [.unresolvedLink("#Local")])
    }

    @Test func embeddedImageWidth() {
        let out = org("![[pic.png|300]]\n", obsidian: true)
        #expect(out.text == "#+attr_org: :width 300\n[[file:pic.png]]\n")
    }

    @Test func tagsGoToHeadingsAndFile() {
        let out = org("#inbox note\n\n# Meeting #work #2024\nTalked about #project/alpha.\n", obsidian: true)
        #expect(out.model.fileTags == ["inbox"])
        #expect(out.model.headings.first?.localTags == ["work", "project_alpha"])
        #expect(out.model.headings.first?.title == "Meeting #work #2024")
    }

    @Test func calloutsBecomeSpecialBlocks() {
        let out = org("> [!warning]- Careful\n> Inside **it**.\n\n> [!example]\n> e.g.\n", obsidian: true)
        #expect(out.text == "#+begin_warning\n*Careful*\n\nInside *it*.\n#+end_warning\n\n#+begin_callout-example\ne.g.\n#+end_callout-example\n")
        #expect(nodes(out.tree, .block).count == 2)
    }

    @Test func taskDates() {
        let out = org("- [ ] Pay 📅 2024-01-10 ⏳ 2024-01-08\n- [x] Paid ✅ 2024-01-09\n- [>] Moved\n- [ ] Weekly 🔁 every week\n", obsidian: true)
        #expect(out.text == "- [ ] Pay DEADLINE: <2024-01-10 Wed> SCHEDULED: <2024-01-08 Mon>\n- [X] Paid CLOSED: [2024-01-09 Tue]\n- [ ] Moved\n- [ ] Weekly 🔁 every week\n")
        #expect(nodes(out.tree, .timestamp).count == 3)
        #expect(Set(out.result.issues) == [.taskStatus(">"), .recurrence])
    }

    @Test func highlightCommentAndBlockID() {
        let out = org("A ==marked== word.\nLast line ^block-1\n\n%%\nhidden\n%%\n", obsidian: true)
        #expect(out.text == "A *marked* word.\nLast line <<block-1>>\n\n#+begin_comment\nhidden\n#+end_comment\n")
        #expect(nodes(out.tree, .target).count == 1)
    }

    @Test func fileNameIsTheFallbackTitle() {
        #expect(org("Body\n", obsidian: true, title: "Note").text == "#+title: Note\n\nBody\n")
        #expect(org("---\ntitle: Own\n---\nBody\n", obsidian: true, title: "Note").text == "#+title: Own\n\nBody\n")
    }

    @Test func headingFragments() {
        let headings = MarkdownToOrg.parse("# Some *Heading*\n## Other: part\n", obsidian: false).headings
        #expect(MarkdownToOrg.heading("some-heading", in: headings) == "Some /Heading/")
        #expect(MarkdownToOrg.heading("Other: part", in: headings) == "Other: part")
        #expect(MarkdownToOrg.heading("missing", in: headings) == nil)
    }
}
