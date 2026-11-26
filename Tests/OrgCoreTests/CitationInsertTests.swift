import Foundation
import Testing
@testable import OrgCore

/// Bibliography files as Insert Citation… reads them, `org-cite-insert`'s edits, key
/// completion and following citations.
struct CitationInsertTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let bib = #"""
        % A comment line.
        @String{jos = "Journal of " # "Stuff"}
        @Article{doe2020,
          Author = {Doe, Jane and {Roe and Sons}},
          title = {A {Study} of {{Nested}} Things},
          journal = jos,
          year = 2020,
          doi = {https://doi.org/10.1000/xyz},
          file = {Full Text:papers/doe.pdf:application/pdf;/abs/other.pdf}
        }
        @comment{@book{hidden, title = {No}}}
        @book(smith1999,
          author = "Smith, John",
          title = "The {"}Book{"}",
          url = {https://example.org/book},
          date = {1999-04-01}
        )
        @proceedings{conf2021,
          title = {Proceedings of the Conference},
          editor = {Park, Min},
          publisher = {ACM},
          year = {2021}
        }
        @inproceedings{talk,
          author = {Lee, Kim},
          title = {A Talk},
          crossref = {Conf2021}
        }
        """#

    static let json = #"""
        [{"id": "csl1", "author": [{"family": "Zed", "given": "Ann"}], "title": "From JSON", "issued": {"date-parts": [[2018]]}, "DOI": "10.1/j", "URL": "https://j.example"}]
        """#

    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-bib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.bib.write(to: folder.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
        try Self.json.write(to: folder.appendingPathComponent("more.json"), atomically: true, encoding: .utf8)
        return folder
    }

    // MARK: - Reading

    @Test func readsBibTeXWithBracesStringsAndCrossrefs() throws {
        let entries = Bibliography.entries(Data(Self.bib.utf8), path: "/refs/refs.bib")
        #expect(entries.map(\.key) == ["conf2021", "doe2020", "smith1999", "talk"])
        let doe = try #require(entries.first { $0.key == "doe2020" })
        #expect(doe.fields["author"] == "Doe, Jane and {Roe and Sons}")
        #expect(doe.author == "Doe, Jane and Roe and Sons")
        #expect(doe.fields["title"] == "A {Study} of {{Nested}} Things")
        #expect(doe.title == "A Study of Nested Things")
        #expect(doe.fields["journal"] == "Journal of Stuff")
        #expect(doe.year == "2020")
        #expect(doe.doi == "10.1000/xyz")
        #expect(doe.files == ["/refs/papers/doe.pdf", "/abs/other.pdf"])
        #expect(doe.label == "doe2020  Doe, Jane; Roe and Sons  2020  A Study of Nested Things")
        #expect(doe.summary == "Doe, Jane and Roe and Sons (2020). A Study of Nested Things. Journal of Stuff.")
        let smith = try #require(entries.first { $0.key == "smith1999" })
        #expect(smith.title == "The \"Book\"")
        #expect(smith.year == "1999")
        #expect(smith.url == "https://example.org/book")
        // Fields the entry lacks come from the one it cross-references; its title is the book's.
        let talk = try #require(entries.first { $0.key == "talk" })
        #expect(talk.title == "A Talk")
        #expect(talk.field("booktitle") == "Proceedings of the Conference")
        #expect(talk.field("publisher") == "ACM")
        #expect(talk.year == "2021")
        #expect(talk.fields["crossref"] == "Conf2021")
    }

    @Test func readsCSLJSON() throws {
        let entries = Bibliography.entries(Data(Self.json.utf8), path: "/refs/more.json")
        let entry = try #require(entries.first)
        #expect(entry.key == "csl1")
        #expect(entry.author == "Zed Ann")
        #expect(entry.year == "2018")
        #expect(entry.doi == "10.1/j")
        #expect(entry.url == "https://j.example")
    }

    @Test func listsTheFilesBibliographyKeywordsAndTheGlobalSettingName() {
        let text = "#+BIBLIOGRAPHY: refs.bib\n#+bibliography: \"with space.bib\"\n#+bibliography: /abs/a.bib\n  #+bibliography: refs.bib\n"
        #expect(Bibliography.files(in: text, directory: "/notes", global: ["/abs/a.bib", "/g/global.json"])
            == ["/notes/refs.bib", "/notes/with space.bib", "/abs/a.bib", "/g/global.json"])
        #expect(Bibliography.files(in: "No keywords\n", directory: "/notes", global: ["~/g.bib"]) == [OrgPaths.home + "/g.bib"])
    }

    @Test func findsTheLineAnEntryStartsOn() {
        #expect(Bibliography.line(of: "smith1999", in: Self.bib, json: false) == 12)
        #expect(Bibliography.line(of: "doe2020", in: Self.bib, json: false) == 3)
        #expect(Bibliography.line(of: "csl1", in: Self.json, json: true) == 1)
        #expect(Bibliography.line(of: "hidden2", in: Self.bib, json: false) == nil)
    }

    /// A file is parsed again only when its modification date changes; the first file wins
    /// for a key in two.
    @Test func cachesFilesByModificationDate() throws {
        final class Disk: @unchecked Sendable {
            var dates: [String: Date] = [:]
            var texts: [String: String] = [:]
            var reads = 0
        }
        let disk = Disk()
        disk.dates = ["/a.bib": Date(timeIntervalSince1970: 1), "/b.bib": Date(timeIntervalSince1970: 1)]
        disk.texts = ["/a.bib": "@misc{one, title = {A}}", "/b.bib": "@misc{one, title = {B}}\n@misc{two, title = {Two}}"]
        let cache = BibliographyCache(modified: { disk.dates[$0] }, read: { disk.reads += 1; return disk.texts[$0].map { Data($0.utf8) } })
        #expect(cache.entries(["/a.bib", "/b.bib", "/missing.bib"]).map { "\($0.key) \($0.title ?? "")" } == ["one A", "two Two"])
        #expect(disk.reads == 2)
        _ = cache.entries(["/a.bib", "/b.bib"])
        #expect(disk.reads == 2)
        disk.texts["/a.bib"] = "@misc{three, title = {C}}"
        disk.dates["/a.bib"] = Date(timeIntervalSince1970: 2)
        #expect(cache.entries(["/a.bib"]).map(\.key) == ["three"])
        #expect(disk.reads == 3)
    }

    @Test func loadsOffTheMainThread() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        final class Seen: @unchecked Sendable { var main: Bool? }
        let seen = Seen()
        let cache = BibliographyCache(read: { seen.main = Thread.isMainThread; return FileManager.default.contents(atPath: $0) })
        let entries = await Self.loadOnMain(cache, [folder.appendingPathComponent("refs.bib").path])
        #expect(entries.count == 4)
        #expect(seen.main == false)
    }

    @MainActor
    static func loadOnMain(_ cache: BibliographyCache, _ paths: [String]) async -> [BibEntry] {
        await cache.load(paths)
    }

    // MARK: - Inserting

    /// Text with `|` at the caret, Insert Citation… of `key` with `style`, and the result
    /// with `|` at the caret.
    func insert(_ marked: String, key: String? = "k2", style: String? = nil, prefix: String = "", suffix: String = "") -> String {
        let caret = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        let result = runCommand(InsertCitation(key: key, style: style, prefix: prefix, suffix: suffix), text, caret: caret)
        if let failure = result.failure { return "failed: " + failure }
        return (result.text as NSString).replacingCharacters(in: NSRange(location: result.caret, length: 0), with: "|")
    }

    /// Cases where orgstar and `org-cite-insert` do the same, with the style asked (Emacs's
    /// prefix argument) or not.
    static let cases: [(text: String, styled: Bool, expected: String)] = [
        ("Text | more", false, "Text [cite:@k2]| more"),
        ("Text |", true, "Text [cite/text:@k2]|"),
        ("|[cite:@a]", false, "[cite:@k2]|[cite:@a]"),
        ("[cite:@a] |", false, "[cite:@a] [cite:@k2]|"),
        ("[cite:@a|]", false, "[cite:@a;@k2|]"),
        ("[cite:|@a]", false, "[cite:|@k2;@a]"),
        ("[cite:@a|b]", false, "[cite:|@k2]"),
        ("[cite:see @a p. |4; @b]", false, "[cite:see @a p. |4;@k2; @b]"),
        ("[cite:@a; @b|]", false, "[cite:@a; @b;@k2|]"),
        ("[cite:@a;| @b]", false, "[cite:@a;|@k2; @b]"),
        ("[cite:pre|; @a; post]", false, "[cite:pre|;@k2; @a; post]"),
        ("[cite:pre; @a; po|st]", false, "[cite:pre; @a;@k2; po|st]"),
        ("[cite/t|:@a]", true, "[cite|/text:@a]"),
        ("[ci|te:@a]", true, "[ci|te/text:@a]"),
    ]

    @Test func insertsAsOrgCiteInsert() {
        for c in Self.cases {
            #expect(insert(c.text, style: c.styled ? "text" : nil) == c.expected, "\(c.text)")
        }
    }

    @Test(.enabled(if: oracle))
    func insertionMatchesEmacs() throws {
        let oracleCases = Self.cases.map { c in
            let caret = (c.text as NSString).range(of: "|").location
            let text = c.text.replacingOccurrences(of: "|", with: "")
            let form = """
                (progn (require 'oc-basic)
                  (let ((org-cite-insert-processor 'basic))
                    (cl-letf (((symbol-function 'org-cite-basic--complete-key) (lambda (&optional multiple) (if multiple (list "k2") "k2")))
                              ((symbol-function 'org-cite-basic--complete-style) (lambda (_) "text")))
                      (org-cite-insert \(c.styled && Citations.place(at: caret, tree: OrgParser.parse(text)) == .new ? "'(4)" : "nil")))))
                """
            return EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: form)
        }
        let results = try EmacsOracle.run(oracleCases)
        for (c, result) in zip(Self.cases, results) {
            let emacs = (result.text as NSString).replacingCharacters(in: NSRange(location: EmacsOracle.offset(result.point, in: result.text), length: 0), with: "|")
            #expect(result.error.isEmpty, "\(c.text): \(result.error)")
            #expect(insert(c.text, style: c.styled ? "text" : nil) == emacs, "\(c.text)")
        }
    }

    @Test func putsThePrefixAndSuffixAroundTheKey() {
        #expect(insert("A |", prefix: "see", suffix: "p. 4") == "A [cite:see @k2 p. 4]|")
        #expect(insert("A |", style: "t", prefix: "see ", suffix: ", ch. 2") == "A [cite/t:see @k2, ch. 2]|")
        #expect(insert("[cite:@a|]", prefix: "cf.") == "[cite:@a;cf. @k2|]")
        // A key replaced keeps the reference's own prefix and suffix.
        #expect(insert("[cite:see @a|b p. 4]", prefix: "x", suffix: "y") == "[cite:see |@k2 p. 4]")
        // An empty style is the default.
        #expect(insert("[cite/t|:@a]", style: "") == "[cite|:@a]")
        #expect(insert("[cite/t|:@a]", key: nil, style: nil) == "failed: Aborted")
        #expect(insert("A |", key: nil) == "failed: Aborted")
    }

    @Test func keysRunInsertCitation() {
        #expect(KeymapPreset.emacs.keymap.candidates(for: KeySequence.parse("C-c C-x @")!).first?.command == "app.cite.insert")
        #expect(KeymapPreset.doom.keymap.candidates(for: KeySequence.parse("SPC m @")!, mode: "normal").first?.command == "app.cite.insert")
    }

    @Test func tellsWhereTheCaretIs() {
        func place(_ marked: String) -> Citations.Place {
            let caret = (marked as NSString).range(of: "|").location
            return Citations.place(at: caret, tree: OrgParser.parse(marked.replacingOccurrences(of: "|", with: "")))
        }
        #expect(place("x |") == .new)
        #expect(place("|[cite:@a]") == .new)
        #expect(place("[cite:@a]|") == .new)
        #expect(place("[|cite:@a]") == .style)
        #expect(place("[cite/t|:@a]") == .style)
        #expect(place("[cite:|@a]") == .reference)
        #expect(place("[cite:@|a]") == .key)
        #expect(place("[cite:@a|]") == .reference)
        #expect(place("* Heading [cite:@a|b]") == .key)
    }

    // MARK: - Following and completing

    @Test func followsTheReferenceOrEveryKey() {
        func link(_ marked: String) -> OrgLink? {
            let caret = (marked as NSString).range(of: "|").location
            let text = marked.replacingOccurrences(of: "|", with: "")
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
            guard case .external(.openLink(let link)) = OpenLinkAtPoint().run(in: context) else { return nil }
            return link
        }
        #expect(link("See [cite:@a; @|b]")?.raw == "cite:b")
        #expect(link("See [cite:pre; @a; @b; @a; po|st]")?.raw == "cite:a;b")
        #expect(link("See |[cite/t:@a]")?.path == "a")
        #expect(link("See [cite:@a]| x") == nil)
        let text = "x [cite:@a]"
        #expect(OrgDwim().run(in: EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [4..<4])) == .external(.openLink(OrgLink(type: "cite", path: "a", raw: "cite:a"))))
    }

    @Test func completesKeysAfterTheAtSign() throws {
        func complete(_ text: String, path: String? = "/notes/doc.org", global: [String] = []) -> Completion? {
            var options = EditingOptions.org
            options.filePath = path
            var settings = OrgSettings.default
            settings.citeGlobalBibliography = global
            let tree = OrgParser.parse(text, defaults: settings)
            return OrgCompletion.at(EditContext(revision: 0, text: text, tree: tree, selection: [text.utf16.count..<text.utf16.count], options: options))
        }
        let completion = try #require(complete("#+bibliography: refs.bib\nSee [cite:@do"))
        #expect(completion.kind == .citationKey)
        #expect(completion.typed == "do")
        #expect(completion.range == 36..<38)
        #expect(completion.query == .citationKeys(["/notes/refs.bib"]))
        #expect(complete("[cite/t:see @a; @", global: ["/g.bib"])?.query == .citationKeys(["/g.bib"]))
        #expect(complete("[cite:@")?.typed == "")
        #expect(complete("[cite:@a] and @b")?.kind != .citationKey)
        #expect(complete("mail me@ho")?.kind != .citationKey)

        let entries = Bibliography.entries(Data(Self.bib.utf8), path: "/notes/refs.bib")
        let filled = OrgCompletion.filled(completion, with: CompletionResult(entries: entries), fuzzy: false)
        #expect(filled.candidates == ["doe2020"])
        #expect(filled.label("doe2020") == "doe2020  Doe, Jane; Roe and Sons  2020  A Study of Nested Things")
        #expect(OrgCompletion.filled(completion, with: CompletionResult(entries: entries), fuzzy: true).candidates.first == "doe2020")
    }

    @Test func exportReadsTheGlobalBibliography() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = OrgSettings.default
        settings.citeGlobalBibliography = [folder.appendingPathComponent("refs.bib").path]
        let markdown = MarkdownExport.document("See [cite/t:@smith1999].\n", settings: settings, path: folder.appendingPathComponent("doc.org").path)
        #expect(markdown.contains("See Smith, John (1999)."))
    }
}
