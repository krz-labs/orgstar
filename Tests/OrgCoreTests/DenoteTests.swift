import Foundation
import Testing
@testable import OrgCore

struct DenoteTests {
    @Test func readsIdentifiersFromFileNames() {
        #expect(Denote.identifier(ofFile: "/n/20261119T120000--a-note__kw1_kw2.org") == "20261119T120000")
        #expect(Denote.identifier(ofFile: "20261119T120000.org") == "20261119T120000")
        #expect(Denote.identifier(ofFile: "20261119T120000==1a--title.org") == "20261119T120000")
        #expect(Denote.identifier(ofFile: "--a-note@@20261119T120000__kw.org") == "20261119T120000")
        #expect(Denote.identifier(ofFile: "a-note.org") == nil)
        #expect(Denote.identifier(ofFile: "20261119-diary.org") == nil)
    }

    @Test func splitsSearchOptions() {
        #expect(Denote.split("20261119T120000") == ("20261119T120000", nil))
        #expect(Denote.split("20261119T120000::#h") == ("20261119T120000", "#h"))
    }

    @Test func prefersOrgFiles() {
        let paths = ["/n/20261119T120000--a.pdf", "/n/20261119T120000--a.org", "/n/20261119T120001--b.org"]
        #expect(Denote.file(withIdentifier: "20261119T120000", in: paths) == "/n/20261119T120000--a.org")
        #expect(Denote.file(withIdentifier: "20261119T120002", in: paths) == nil)
    }

    /// 2026-11-19 09:05:03, a Thursday, in UTC.
    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    static let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 9, minute: 5, second: 3))!

    @Test func namesNewFiles() {
        #expect(Denote.slug("Hello, World: a_test -- Note!") == "hello-world-a-test-note")
        #expect(Denote.slug("  Café au lait  ") == "café-au-lait")
        #expect(Denote.keywords(["Emacs", "org-mode", "emacs", "", "two words"]) == ["emacs", "orgmode", "twowords"])
        let id = Denote.identifier(for: Self.date, calendar: Self.calendar)
        #expect(id == "20261119T090503")
        #expect(Denote.fileName(identifier: id, title: "A note", keywords: ["b", "a"]) == "20261119T090503--a-note__b_a.org")
        #expect(Denote.fileName(identifier: id, signature: "1a", title: "", keywords: []) == "20261119T090503==1a.org")
        #expect(Denote.frontMatter(title: "A note", date: Self.date, keywords: ["a", "b"], identifier: id, calendar: Self.calendar) == """
            #+title:      A note
            #+date:       [2026-11-19 Thu 09:05]
            #+filetags:   :a:b:
            #+identifier: 20261119T090503


            """)
    }

    @Test func signatures() {
        #expect(Denote.signature("Two Words") == "two=words")
        #expect(Denote.signature(" 1a_b-c==d ") == "1a=bc=d")
        #expect(Denote.frontMatter(title: "A", date: Self.date, keywords: [], identifier: "20261119T090503", signature: "1a", calendar: Self.calendar)
            == "#+title:      A\n#+date:       [2026-11-19 Thu 09:05]\n#+filetags:   \n#+identifier: 20261119T090503\n#+signature:  1a\n\n")
    }

    @Test func readsNamesInAnyOrder() {
        #expect(Denote.name(ofFile: "/n/20261119T090503==1a--a-note__kw1_kw2.org")
            == Denote.Name(identifier: "20261119T090503", signature: "1a", title: "a-note", keywords: ["kw1", "kw2"], ext: "org"))
        #expect(Denote.name(ofFile: "--a-note__kw@@20261119T090503.pdf")
            == Denote.Name(identifier: "20261119T090503", signature: nil, title: "a-note", keywords: ["kw"], ext: "pdf"))
    }

    @Test func renamesFromFrontMatter() {
        let text = "#+title:      New Title\n#+filetags:   :Zeta:alpha:\n#+identifier: 20261119T090503\n\nBody\n"
        // The signature, like the title and keywords, comes from the front matter; the
        // keywords are sorted, and the front matter is rewritten from what was read.
        #expect(Denote.renamed("/n/20261119T090503==1a--old__x.org", text: text)?.path == "/n/20261119T090503--new-title__alpha_zeta.org")
        #expect(Denote.renamed("/n/20261119T090503==1a--old__x.org", text: text)?.text == text.replacingOccurrences(of: ":Zeta:alpha:", with: ":alpha:zeta:"))
        #expect(Denote.renamed("/n/20261119T090503==1a--old__x.org", text: "#+signature:  Two Words\n" + text)?.path
            == "/n/20261119T090503==two=words--new-title__alpha_zeta.org")
        #expect(Denote.renamed("/n/plain.org", text: text)?.path == "/n/20261119T090503--new-title__alpha_zeta.org")
        #expect(Denote.renamed("/n/plain.org", text: "#+title: x\n") == nil)
        #expect(Denote.renamed("/n/20261119T090503--old-name__x.org", text: "No front matter\n") == nil)
        #expect(Denote.renamed("/n/20261119T090503--old-name__x.org", text: "#+title: Only a title\n")?.path == "/n/20261119T090503--only-a-title.org")
        #expect(Denote.renamed("/n/20261119T090503--a.pdf", text: "#+title: Not a type\n") == nil)
    }

    // MARK: - Markdown and text notes

    @Test func fileTypes() {
        #expect(Denote.FileType(path: "/n/a.org") == .org)
        #expect(Denote.FileType(path: "/n/a.txt") == .text)
        #expect(Denote.FileType(path: "/n/a.md", text: "---\ntitle: x\n---\n") == .markdownYAML)
        #expect(Denote.FileType(path: "/n/a.md", text: "+++\ntitle = \"x\"\n+++\n") == .markdownTOML)
        #expect(Denote.FileType(path: "/n/a.md", text: "# x\n") == .markdownYAML)
        #expect(Denote.FileType(path: "/n/a.md", text: "# x\n", preferred: .markdownTOML) == .markdownTOML)
        #expect(Denote.FileType(path: "/n/a.md", text: "# x\n", preferred: .text) == .markdownYAML)
        #expect(Denote.FileType(path: "/n/a.markdown") == nil && Denote.FileType(path: "/n/a.pdf") == nil)
    }

    @Test func textTypeFrontMatter() {
        var calendar = Self.calendar
        #expect(Denote.frontMatter(title: "A \"q\" note", date: Self.date, keywords: ["a", "b"], identifier: "20261119T090503", signature: "1a",
                                   type: .markdownYAML, calendar: calendar) == """
            ---
            title:      "A \\"q\\" note"
            date:       2026-11-19T09:05:03+00:00
            tags:       ["a", "b"]
            identifier: "20261119T090503"
            signature:  "1a"
            ---


            """)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600 - 1800)!
        #expect(Denote.frontMatter(title: "A", date: Self.date, keywords: [], identifier: "20261119T090503", type: .markdownTOML, calendar: calendar) == """
            +++
            title      = "A"
            date       = 2026-11-19T03:35:03-05:30
            tags       = []
            identifier = "20261119T090503"
            +++


            """)
        #expect(Denote.frontMatter(title: "A", date: Self.date, keywords: ["a", "b"], identifier: "20261119T090503", type: .text, calendar: Self.calendar)
            == "title:      A\ndate:       2026-11-19\ntags:       a  b\nidentifier: 20261119T090503\n---------------------------\n\n")
        #expect(Denote.frontMatter(title: "A", date: Self.date, keywords: [], identifier: "20261119T090503", type: .text, calendar: Self.calendar)
            .contains("\ntags:       \n"))
    }

    @Test func readsTextTypeFrontMatter() {
        let yaml = "---\ntitle:      \"A \\\"q\\\" note\"\ndate:       2026-11-19T10:05:03+01:00\ntags:       [\"a\", \"b\"]\nidentifier: \"20261119T090503\"\nsignature:  '1a'\n---\n"
        let front = Denote.frontMatter(of: yaml, type: .markdownYAML)
        // As Denote reads it: quotes trimmed, backslashes kept.
        #expect(front.title == #"A \"q\" note"# && front.keywords == ["a", "b"] && front.identifier == "20261119T090503" && front.signature == "1a")
        #expect(Denote.date(of: yaml, type: .markdownYAML) == Self.date)
        let toml = "+++\nTitle = \"T\"\ntags       = [\"x\",\"y\"]\nidentifier = \"20261119T090503\"\n+++\n"
        #expect(Denote.frontMatter(of: toml, type: .markdownTOML).title == "T" && Denote.frontMatter(of: toml, type: .markdownTOML).keywords == ["x", "y"])
        #expect(Denote.frontMatter(of: toml, type: .markdownYAML).title == nil)
        let text = "title:      Plain\ndate:       2026-11-19\ntags:       a  b\nidentifier: 20261119T090503\n---------------------------\n"
        #expect(Denote.frontMatter(of: text, type: .text).title == "Plain" && Denote.frontMatter(of: text, type: .text).keywords == ["a", "b"])
        #expect(Denote.date(of: text, type: .text, calendar: Self.calendar) == Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 19)))
        #expect(Denote.frontMatter(ofFile: "/n/x.txt", text: text).title == "Plain")
    }

    @Test func rewritesTextTypeFrontMatter() {
        let yaml = "---\ntitle:  \"Old\"\ntags:       [\"x\"]\nidentifier: \"20261119T090503\"\nsignature:  \"zz\"\n---\n\nBody\n"
        // The key keeps its spacing; a date is added after the title, the signature removed.
        #expect(Denote.rewritingFrontMatter(yaml, title: "New", keywords: ["a"], signature: "", date: Self.date, identifier: "20261119T090503",
                                            type: .markdownYAML, calendar: Self.calendar)
            == "---\ntitle:  \"New\"\ndate:       2026-11-19T09:05:03+00:00\ntags:       [\"a\"]\nidentifier: \"20261119T090503\"\n---\n\nBody\n")
        // No date given: the date line stays and none is added.
        #expect(Denote.rewritingFrontMatter("title:      Old\nidentifier: 1\n---------------------------\n", title: "New", keywords: [], signature: "s",
                                            date: nil, identifier: "1", type: .text, calendar: Self.calendar)
            == "title:      New\nidentifier: 1\nsignature:  s\n---------------------------\n")
        // Without front matter, all of it goes first.
        #expect(Denote.rewritingFrontMatter("# Heading\n", title: "T", keywords: [], signature: "", date: Self.date, identifier: "1",
                                            type: .markdownTOML, calendar: Self.calendar).hasPrefix("+++\ntitle      = \"T\"\n"))
    }

    @Test func renamesTextTypesFromFrontMatter() {
        let toml = "+++\ntitle      = 'Toml Title'\ntags       = [\"zeta\", \"alpha\"]\nidentifier = \"20261119T090503\"\n+++\n\nBody\n"
        let renamed = Denote.renamed("/n/20261119T090503--old.md", text: toml)
        #expect(renamed?.path == "/n/20261119T090503--toml-title__alpha_zeta.md")
        #expect(renamed?.text == "+++\ntitle      = \"Toml Title\"\ntags       = [\"alpha\", \"zeta\"]\nidentifier = \"20261119T090503\"\n+++\n\nBody\n")
        #expect(Denote.renamed("/n/20261119T090503--old.txt", text: "title:      Text\ntags:       b  a\n")?.path == "/n/20261119T090503--text__a_b.txt")
        #expect(Denote.renamed("/n/20261119T090503--old.md", text: "# No front matter\n") == nil)
    }

    @Test func linksInTextNotes() {
        #expect(Denote.linkText("denote:20261119T090503", description: "A note", inFile: "/n/x.md") == "[A note](denote:20261119T090503)")
        #expect(Denote.linkText("denote:20261119T090503", description: "", inFile: "/n/x.md") == "[[denote:20261119T090503]]")
        #expect(Denote.linkText("denote:20261119T090503", description: "A note", inFile: "/n/x.txt") == "[[denote:20261119T090503][A note]]")
        #expect(Denote.linkText("denote:20261119T090503", description: "A note", inFile: "/n/x.org") == "[[denote:20261119T090503][A note]]")
        #expect(Denote.linkText("id:abc", description: "A", inFile: "/n/x.md") == "[[id:abc][A]]")
        let text = "See [one](denote:20261119T090501) and [[denote:20261119T090502][two]], [[denote:20261119T090503::#h]], [web](https://x.org).\n"
        #expect(Denote.links(in: text, markdown: true).map(\.target) == ["denote:20261119T090501", "denote:20261119T090502", "denote:20261119T090503::#h"])
        #expect(Denote.links(in: text, markdown: false).map(\.target) == ["denote:20261119T090502", "denote:20261119T090503::#h"])
        #expect(Denote.link(at: 6, in: text, markdown: true)?.path == "20261119T090501")
        #expect(Denote.link(at: 6, in: text, markdown: false) == nil)
        #expect(Denote.link(at: 50, in: text, markdown: true)?.type == "denote")
        #expect(Denote.link(at: 106, in: text, markdown: true) == nil)
    }

    @Test func followsAndInsertsOnlyDenoteLinksInTextNotes() {
        var options = EditingOptions.org
        options.filePath = "/n/20261119T090500--x.md"
        let text = "[one](denote:20261119T090501) <https://x.org>\n"
        func context(_ caret: Int) -> EditContext { EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], options: options) }
        #expect(OpenLinkAtPoint().applies(in: context(2)))
        #expect(!OpenLinkAtPoint().applies(in: context(34)))
        if case .external(.openLink(let link)) = OpenLinkAtPoint().run(in: context(2)) { #expect(link.raw == "denote:20261119T090501") } else { Issue.record("not followed") }
        for path in ["/n/x.md", "/n/x.txt"] {
            #expect(!OrgOnlyCommands.refuses("org.link.open", markdown: path.hasSuffix(".md"), path: path))
            #expect(!OrgOnlyCommands.refuses("app.node.insert", markdown: false, path: path))
            #expect(!OrgOnlyCommands.refuses("app.node.rename", markdown: false, path: path))
            #expect(!OrgOnlyCommands.refuses("app.node.rename-from-front-matter", markdown: false, path: path))
            #expect(OrgOnlyCommands.refuses("app.node.sequence-link", markdown: false, path: path))
            #expect(OrgOnlyCommands.refuses("org.link.insert", markdown: false, path: path))
        }
        #expect(OrgOnlyCommands.refuses("org.link.open", markdown: false, path: "/n/x.py"))
        #expect(OrgOnlyCommands.refuses("app.node.insert", markdown: true, path: "/n/x.markdown"))
    }
}
