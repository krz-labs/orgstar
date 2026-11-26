import Foundation
import Testing
@testable import OrgCore

struct LintTests {
    /// Files with problems of most kinds, which `LintOracleTests` also runs through org-lint.
    static let corpus: [String: String] = [
        "links.org": """
            #+TITLE: Links
            * Heading one
            :PROPERTIES:
            :CUSTOM_ID: one
            :ID: abc::def
            :END:
            SCHEDULED: <2026-11-26 Thu>
            Link [[*Missing heading]] and [[*Heading one]] and [[#nope]] and [[#one]].
            [[id:00000000-dead]] and [[file:nofile.org]] and [[./exists.org]] and [[id:abc::def]].
            <2026-11-26 Mon> <2026-11-26> <2026-11-26 Thu 9:00> <2026-02-30 Mon> <2026-11-26 Thu 25:00> [2026-11-26 Thu 10:00-11:00]
            <2026-11-26 Thu 9am> <2026-11-26 Thu 10:00>--<2026-11-27 Fri> <2026-11-26 Thu +1w -2d> <2026-11-26 Thu .+2d/3d>
            Footnote[fn:1] and [fn:missing] and [fn:: anon] and [fn:named: inline] and [fn:named].
            * Second
            :PROPERTIES:
            :CUSTOM_ID: one
            :END:
            #+NAME: tbl
            | a |

            #+NAME: tbl
            | b <2026-11-26> |
            <<target>> <<target>> <<My Target>>
            [[my target]] [[tbl]] [[TBL]] [[second]] [[*second]] [[Heading one]] [[nowhere]]
            [[(here)]] [[(nothere)]] [[file+sys:./exists.org]] [[attachment:nothing.png]]
            #+BEGIN_SRC emacs-lisp
            (foo) (ref:here)
            #+END_SRC
            * COMMENT Commented [1/2]
            [[Commented]] [[*commented]]
            * TODO [#A] Task title :tag:
            [[Task title]] [[*TODO Task title]]
            [fn:1] Def.
            [fn:2] Unused.
            [fn:1] Dup.
            """,
        "structure.org": """
            #+CATEGORY: one
            #+CATEGORY: two
            #+SETUPFILE: missing-setup.org
            #+TITLE no colon
            #+CAPTION: orphan

            * QUOTE old section
            * Tags :a::b:
            * Planning
            SCHEDULED: <2026-11-26 Thu +1w> DEADLINE: <2026-11-27 Fri +2d>
            * Inactive
            SCHEDULED: [2026-11-26 Thu]
            * Repeaters same
            SCHEDULED: <2026-11-26 Thu +1w> DEADLINE: <2026-11-27 Fri +1w>
            * Body
            Text here
            :PROPERTIES:
            :A: b
            :END:
              %%(diary-date 1 1 2026) indented
            #+BEGIN_EXPORT
            x
            #+END_EXPORT
            #+BEGIN_HTML
            <b>x</b>
            #+END_HTML
            :OUTER:
            :INNER:
            x
            :END:
            #+BEGIN_EXAMPLE
            x
            #+END_EXAMPLE trailing
            Paragraph ** Oops heading
            #+SRCNAME: old
            #+BEGIN_SRC sh
            echo
            #+END_SRC
            #+BEGIN_SRC
            #+END_SRC
            :PROPERTIES:
            :EFFORT: abc
            :END:
            * Effort
            :PROPERTIES:
            :EFFORT: abc
            :Effort: def
            :TODO: x
            :ID:
            :END:
            CLOCK: [2026-11-26 Thu 9:00]--[2026-11-26 Thu 10:00] =>  1:00
            CLOCK: [2026-11-26 Thu 09:00]--[2026-11-26 Thu 10:00] => 1:00
            CLOCK: [2026-11-26 Thu 09:00]--[2026-11-26 Thu 10:00] =>  1:00
            :LOGBOOK:
            text
            * [#Z] Priority
            * [#a] Lower
            * [#1 Unclosed
            * TODOX Unknown keyword
            ** Heading after
            :drawer:
            #+BEGIN_SRC sh
            :inner:
            #+END_SRC
            :END:
            #+BEGIN_QUOTE
            never closed
            :END:
            DEADLINE: <2026-11-26 Thu>
            """,
    ]

    static func lint(_ text: String, path: String? = nil, environment: LintEnvironment = .fileSystem, defaults: OrgSettings = .default) -> [LintFinding] {
        OrgLint.lint(text, tree: OrgParser.parse(text, defaults: defaults), path: path, environment: environment)
    }

    /// The lines `checker` reports in `text`.
    static func lines(_ checker: LintChecker, _ text: String, path: String? = nil, environment: LintEnvironment = .fileSystem) -> [Int] {
        lint(text, path: path, environment: environment).filter { $0.checker == checker }.map(\.line)
    }

    /// A file system holding only `files` (absolute paths; folders end in `/`).
    static func environment(_ files: Set<String>, ids: [String: [String]]? = nil) -> LintEnvironment {
        var idFiles: (@Sendable (String) -> [String])?
        if let ids { idFiles = { ids[$0] ?? [] } }
        return LintEnvironment(
            fileExists: { path in files.contains(path) || files.contains(path + "/") },
            isDirectory: { files.contains($0 + "/") },
            contentsOfDirectory: { dir in
                Array(Set(files.compactMap { file -> String? in
                    guard file.hasPrefix(dir + "/") else { return nil }
                    return file.dropFirst(dir.count + 1).split(separator: "/").first.map(String.init)
                }))
            },
            readFile: { _ in nil },
            idFiles: idFiles
        )
    }

    // MARK: - Links

    @Test func fuzzyLinks() {
        let text = "* Heading one\n<<Target here>>\n#+NAME: tbl\n| a |\n\n[[*Heading one]] [[heading ONE]] [[target  here]] [[tbl]]\n[[*Nope]] [[TBL]] [[*Target here]]\n"
        #expect(Self.lines(.invalidFuzzyLink, text) == [7, 7, 7])
    }

    @Test func customIDLinks() {
        let text = "* A\n:PROPERTIES:\n:CUSTOM_ID: a\n:ID: uuid-1\n:END:\n[[#a]] [[#uuid-1]]\n[[#b]]\n"
        #expect(Self.lines(.invalidCustomIDLink, text) == [7])
    }

    @Test func idLinksResolveThroughTheIndex() {
        let text = ":PROPERTIES:\n:ID: file-id\n:END:\n* A\n:PROPERTIES:\n:ID: here\n:END:\n[[id:here]] [[id:file-id]] [[id:there]]\n[[id:nowhere]]\n"
        let environment = Self.environment([], ids: ["there": ["/notes/other.org"]])
        #expect(Self.lines(.invalidIDLink, text, environment: environment) == [9])
        #expect(Self.lines(.invalidIDLink, text, environment: Self.environment([])) == [8, 9])
    }

    @Test func coderefLinks() {
        let text = "#+BEGIN_SRC sh\necho (ref:one)\n#+END_SRC\n[[(one)]]\n[[(two)]]\n"
        #expect(Self.lines(.invalidCoderefLink, text) == [5])
    }

    @Test func fileLinks() {
        let environment = Self.environment(["/notes/a.org", "/notes/sub/"])
        let text = "[[file:a.org]] [[./sub]] [[file:/ssh:host:/x]]\n[[file:missing.org]] [[~/nowhere-at-all]]\n"
        #expect(Self.lines(.linkToLocalFile, text, path: "/notes/x.org", environment: environment) == [2, 2])
        #expect(Self.lines(.linkToLocalFile, text, path: nil, environment: environment).isEmpty)
    }

    @Test func fileSearchLinks() {
        var environment = Self.environment(["/notes/a.org"])
        environment.readFile = { _ in "* Alpha\n:PROPERTIES:\n:CUSTOM_ID: al\n:END:\n<<tgt>>\n" }
        let text = "[[file:a.org::*Alpha]] [[file:a.org::#al]] [[file:a.org::tgt]] [[file:a.org::12]]\n[[file:a.org::*Beta]] [[file:a.org::#be]]\n"
        #expect(Self.lines(.invalidFileSearch, text, path: "/notes/x.org", environment: environment) == [2, 2])
    }

    @Test func fileApplicationLinks() {
        #expect(Self.lines(.fileApplication, "[[file:a.org]]\n[[file+sys:a.org]] [[file+emacs:b.org]]\n") == [2, 2])
    }

    @Test func attachmentLinks() {
        let environment = Self.environment(["/notes/data/ab/cdef/", "/notes/data/ab/cdef/one.png"])
        let text = "* A :ATTACH:\n:PROPERTIES:\n:ID: abcdef\n:END:\n[[attachment:one.png]]\n[[attachment:two.png]]\n"
        let findings = Self.lint(text, path: "/notes/x.org", environment: environment).filter { $0.checker == .linkToLocalFile }
        #expect(findings.map(\.line) == [6])
        #expect(findings.first?.message == "Link to non-existent local file \"/notes/data/ab/cdef/two.png\"")
    }

    // MARK: - Attachments

    @Test func attachTagWithoutFolder() {
        let environment = Self.environment(["/notes/data/ab/cdef/"])
        let text = "* A :ATTACH:\n:PROPERTIES:\n:ID: abcdef\n:END:\n* B :ATTACH:\n:PROPERTIES:\n:ID: abcxyz\n:END:\n* C :ATTACH:\n"
        #expect(Self.lines(.missingAttachmentFolder, text, path: "/notes/x.org", environment: environment) == [5, 9])
    }

    @Test func attachmentFoldersWithoutEntries() {
        let files: Set<String> = ["/notes/data/", "/notes/data/ab/", "/notes/data/ab/cdef/", "/notes/data/ab/zzzz/", "/notes/data/ab/yyyy/",
                                  "/notes/data/__/", "/notes/data/__/q/", "/notes/data/__/q/qq/"]
        let environment = Self.environment(files, ids: ["abyyyy": ["/notes/other.org"], "abzzzz": ["/notes/x.org"]])
        let text = "* A\n:PROPERTIES:\n:ID: abcdef\n:END:\n"
        let findings = Self.lint(text, path: "/notes/x.org", environment: environment).filter { $0.checker == .orphanedAttachmentFolder }
        #expect(findings.map(\.message) == ["Attachment folder \"data/__/q/qq\" belongs to no entry", "Attachment folder \"data/ab/zzzz\" belongs to no entry"])
        #expect(findings.allSatisfy { $0.line == 1 })
        // Without an index there is nothing to tell an orphan from another file's folder.
        #expect(Self.lines(.orphanedAttachmentFolder, text, path: "/notes/x.org", environment: Self.environment(files)).isEmpty)
    }

    // MARK: - Duplicates

    @Test func duplicateIDs() {
        let text = "* A\n:PROPERTIES:\n:ID: one\n:END:\n* B\n:PROPERTIES:\n:ID: one\n:END:\n* C\n:PROPERTIES:\n:ID: two\n:END:\n* D\n:PROPERTIES:\n:ID: three\n:END:\n"
        let findings = Self.lint(text, path: "/notes/x.org", environment: Self.environment([], ids: ["two": ["/notes/y.org", "/notes/x.org"]]))
            .filter { $0.checker == .duplicateID }
        #expect(findings.map(\.line) == [3, 7, 11])
        #expect(findings.last?.message == "Duplicate ID \"two\", also in y.org")
    }

    @Test func duplicateCustomIDsNamesTargetsAndFootnotes() {
        let text = "* A\n:PROPERTIES:\n:CUSTOM_ID: x\n:END:\n* B\n:PROPERTIES:\n:custom_id: x\n:END:\n#+NAME: n\n| 1 |\n\n#+NAME: n\n| 2 |\n\n<<t>> <<u>>\n<<t>>\n[fn:1] a\n[fn:1] b\n[fn:2] c\n"
        let findings = Self.lint(text)
        #expect(findings.filter { $0.checker == .duplicateCustomID }.map(\.line) == [3, 7])
        #expect(findings.filter { $0.checker == .duplicateName }.map(\.line) == [9, 12])
        #expect(findings.filter { $0.checker == .duplicateTarget }.map(\.line) == [15, 16])
        #expect(findings.filter { $0.checker == .duplicateFootnoteDefinition }.map(\.line) == [17, 18])
    }

    // MARK: - Drawers and blocks

    @Test func drawers() {
        let text = "* A\n:LOGBOOK:\n- a\n:END:\n:NOTES:\nopen\n* B\n:OUTER:\n:INNER:\n:END:\n#+BEGIN_SRC sh\n:SRC:\n#+END_SRC\n"
        let findings = Self.lint(text).filter { $0.checker == .incompleteDrawer }
        #expect(findings.map(\.line) == [5, 9])
        #expect(findings.map(\.message) == ["Possible incomplete drawer \":NOTES:\"", "Possible misleading drawer entry \":INNER:\""])
    }

    @Test func propertyDrawers() {
        let text = "* A\n:PROPERTIES:\n:A: 1\n:END:\nText\n:PROPERTIES:\n:B: 2\n:END:\n* B\n:PROPERTIES:\n:C: 3\n\n:END:\n"
        #expect(Self.lines(.obsoletePropertiesDrawer, text) == [6, 10])
    }

    @Test func blocks() {
        let text = "#+BEGIN_SRC sh\nx\n#+END_SRC\n#+BEGIN_QUOTE\nopen\n#+END_SRC trailing\n#+BEGIN: clocktable\n#+END:\n"
        let findings = Self.lint(text).filter { $0.checker == .invalidBlock }
        #expect(findings.map(\.line) == [4, 6])
        #expect(findings.map(\.message) == ["Possible incomplete block \"#+BEGIN_QUOTE\"", "Invalid block closing line \"#+END_SRC trailing\""])
    }

    @Test func blockLanguagesAndBackends() {
        let text = "#+BEGIN_SRC python\n#+END_SRC\n#+BEGIN_SRC :results none\n#+END_SRC\n#+BEGIN_EXPORT html\n#+END_EXPORT\n#+BEGIN_EXPORT\n#+END_EXPORT\n#+BEGIN_LATEX\n#+END_LATEX\n#+BEGIN_NOTE\n#+END_NOTE\n"
        let findings = Self.lint(text)
        #expect(findings.filter { $0.checker == .missingLanguageInSrcBlock }.map(\.line) == [3])
        #expect(findings.filter { $0.checker == .missingBackendInExportBlock }.map(\.line) == [7])
        #expect(findings.filter { $0.checker == .deprecatedExportBlocks }.map(\.line) == [9])
    }

    @Test func misplacedPlanning() {
        let text = "* A\nSCHEDULED: <2026-11-26 Thu>\n* B\nText\nDEADLINE: <2026-11-26 Thu>\n#+BEGIN_EXAMPLE\nCLOSED: [2026-11-26 Thu]\n#+END_EXAMPLE\n* C\n:PROPERTIES:\n:A: b\n:END:\nscheduled: later\n"
        #expect(Self.lines(.misplacedPlanningInfo, text) == [5, 13])
    }

    @Test func misplacedHeadings() {
        #expect(Self.lines(.misplacedHeading, "* A\nText** Oops\nText ** fine\n,** escaped\n#+BEGIN_SRC sh\nx** y\n#+END_SRC\n") == [2])
    }

    @Test func indentedDiarySexps() {
        #expect(Self.lines(.indentedDiarySexp, "%%(diary-float t 4 2)\n  %%(diary-float t 4 2)\n#+BEGIN_SRC sh\n  %%(x)\n#+END_SRC\n") == [2])
    }

    @Test func keywordSyntax() {
        let text = "#+TITLE: fine\n#+TITLE wrong\n#+CAPTION[short]: long\n#+BEGIN_SRC sh\n#+END_SRC\n#+\n"
        #expect(Self.lines(.invalidKeywordSyntax, text) == [2, 6])
    }

    @Test func affiliatedKeywords() {
        let text = "#+CAPTION: orphan\n\n#+NAME: fine\n#+TBLNAME: old\n| a |\n#+RESULTS:\n\n#+ATTR_HTML: :width 10\n* H\n"
        let findings = Self.lint(text)
        #expect(findings.filter { $0.checker == .orphanedAffiliatedKeywords }.map(\.line) == [1, 8])
        #expect(findings.filter { $0.checker == .obsoleteAffiliatedKeywords }.map(\.message) == ["Obsolete affiliated keyword: \"TBLNAME\".  Use \"NAME\" instead"])
    }

    @Test func categoriesAndSetupFiles() {
        let environment = Self.environment(["/notes/setup.org"])
        let text = "#+CATEGORY: a\n#+SETUPFILE: setup.org\n#+SETUPFILE: \"missing.org\"\n#+SETUPFILE: https://example.com/x.org\n#+CATEGORY: b\n"
        let findings = Self.lint(text, path: "/notes/x.org", environment: environment)
        #expect(findings.filter { $0.checker == .deprecatedCategorySetup }.map(\.line) == [5])
        #expect(findings.filter { $0.checker == .nonExistentSetupfileParameter }.map(\.message) == ["Non-existent setup file \"missing.org\""])
    }

    // MARK: - Headings and properties

    @Test func unknownTodoKeywords() {
        var defaults = OrgSettings.default
        defaults.todoSequences = [TodoSequence(kind: .sequence, active: [TodoKeyword(name: "TODO"), TodoKeyword(name: "WAIT")], done: [TodoKeyword(name: "DONE")])]
        let text = "* TODO Known\n* WAIT From the config\n* NEXT Unknown\n* TODOX Typo\n* FAQ Questions\n* README\n* DONT x\n* COMMENT x\n"
        let findings = Self.lint(text, defaults: defaults).filter { $0.checker == .unknownTodoKeyword }
        #expect(findings.map(\.line) == [3, 4, 7])
        // The file's own keywords count.
        #expect(Self.lines(.unknownTodoKeyword, "#+TODO: NEXT | DONE\n* NEXT a\n* TODO b\n") == [3])
    }

    @Test func priorities() {
        let text = "* [#A] Fine\n* [#Z] Out\n* [#a] Lower\n* [#1 Unclosed\n* TODO [#B] Fine\n* [#AA] Two\n"
        let findings = Self.lint(text).filter { $0.checker == .priority }
        #expect(findings.map(\.message) == ["Out-of-bounds priority 'Z'", "Malformed priority '[#1 Unclosed'", "Invalid priority 'AA'"])
    }

    @Test func headingTags() {
        let text = "* A :x:y:\n* B :x::y:\n* QUOTE Old\n* COMMENT QUOTE Older\n* QUOTE\n"
        let findings = Self.lint(text)
        #expect(findings.filter { $0.checker == .spuriousColons }.map(\.line) == [2])
        #expect(findings.filter { $0.checker == .quoteSection }.map(\.line) == [3, 4])
    }

    @Test func properties() {
        let text = "* A\n:PROPERTIES:\n:EFFORT: 1:30\n:EFFORT: 2h 30min\n:EFFORT: soon\n:EFFORT: 15\n:Effort: soon\n:TODO: x\n:Scheduled: y\n:ID: a::b\n:ID: ab\n:END:\n"
        let findings = Self.lint(text)
        #expect(findings.filter { $0.checker == .invalidEffortProperty }.map(\.line) == [5, 6])
        #expect(findings.filter { $0.checker == .specialPropertyInPropertiesDrawer }.map(\.line) == [8, 9])
        #expect(findings.filter { $0.checker == .invalidIDProperty }.map(\.line) == [10])
    }

    // MARK: - Timestamps

    @Test func timestamps() {
        let fine = ["<2026-11-26 Thu>", "[2026-11-26 Thu 09:00]", "<2026-11-26 Thu 10:00-11:00>", "<2026-11-26 Thu>--<2026-11-27 Fri>",
                    "<2026-11-26 Thu +1w -2d>", "<2026-11-26 Thu .+2d/3d>", "<2026-11-26 Thu ++1m --3d>", "<%%(diary-float t 4 2)>"]
        for stamp in fine {
            #expect(Self.lines(.timestampSyntax, "Text \(stamp)\n").isEmpty, "\(stamp)")
        }
        let malformed: [(String, String)] = [
            ("<2026-11-26>", "<2026-11-26 Thu>"), ("<2026-11-26 Mon>", "<2026-11-26 Thu>"), ("<2026-11-26 Thu 9:00>", "<2026-11-26 Thu 09:00>"),
            ("<2026-02-30 Mon>", "<2026-03-02 Mon>"), ("<2026-11-26 Thu 25:00>", "<2026-11-27 Fri 01:00>"), ("<2026-11-26 Thu 9am>", "<2026-11-26 Thu>"),
            ("<2026-11-26 Thu 10:00>--<2026-11-27 Fri>", "<2026-11-26 Thu 10:00>--<2026-11-27 Fri 10:00>"),
        ]
        for (stamp, parsed) in malformed {
            let findings = Self.lint("Text \(stamp)\n").filter { $0.checker == .timestampSyntax }
            #expect(findings.map(\.message) == ["Potentially malformed timestamp \(stamp).  Parsed as: \(parsed)"])
        }
        // Planning lines are checked by the planning checkers only.
        #expect(Self.lines(.timestampSyntax, "* A\nSCHEDULED: <2026-11-26>\n").isEmpty)
    }

    @Test func clocks() {
        let text = "* A\n:LOGBOOK:\nCLOCK: [2026-11-26 Thu 09:00]--[2026-11-26 Thu 10:00] =>  1:00\nCLOCK: [2026-11-26 Thu 09:00]--[2026-11-26 Thu 10:00] => 1:00\nCLOCK: [2026-11-26 Thu 9:00]\nCLOCK: [2026-11-26 Thu 09:00]\n:END:\n"
        #expect(Self.lines(.clockSyntax, text) == [4, 5])
    }

    @Test func planning() {
        let text = "* A\nSCHEDULED: [2026-11-26 Thu]\n* B\nDEADLINE: [2026-11-26 Thu]\n* C\nSCHEDULED: <2026-11-26 Thu +1w> DEADLINE: <2026-11-27 Fri ++2d>\n* D\nSCHEDULED: <2026-11-26 Thu +1w> DEADLINE: <2026-11-27 Fri +1w>\n* E\nSCHEDULED: <2026-11-26 Thu .+1w> DEADLINE: <2026-11-27 Fri +2d>\n"
        let findings = Self.lint(text)
        #expect(findings.filter { $0.checker == .planningInactive }.map(\.line) == [2, 4])
        #expect(findings.filter { $0.checker == .mismatchedPlanningRepeaters }.map(\.line) == [6])
    }

    // MARK: - Footnotes

    @Test func footnotes() {
        let text = "Text[fn:1] [fn:2] [fn:in: inline] [fn:in] [fn:: anonymous] [fn:gone]\n\n[fn:1] One.\n[fn:3] Three.\n"
        let findings = Self.lint(text)
        #expect(findings.filter { $0.checker == .undefinedFootnoteReference }.map(\.message) == ["Missing definition for footnote [2]", "Missing definition for footnote [gone]"])
        #expect(findings.filter { $0.checker == .unreferencedFootnoteDefinition }.map(\.line) == [4])
    }

    // MARK: - Whole file

    @Test func encryptedEntriesAreSkipped() {
        let text = "* Secret :crypt:\n-----BEGIN PGP MESSAGE-----\n\n#+BEGIN_QUOTE\n:DRAWER:\n-----END PGP MESSAGE-----\n* Open\n#+BEGIN_QUOTE\n"
        #expect(Self.lint(text).map(\.line) == [8])
    }

    @Test func findingsAreInFileOrderWithLines() {
        let text = "[[#b]]\r\n* A\r\n[[#a]]\r\n"
        let findings = Self.lint(text)
        #expect(findings.map(\.line) == [1, 3])
        #expect(findings.map(\.offset) == [0, 13])
        #expect(findings.allSatisfy { $0.trust == .high })
        #expect(Self.lint("").isEmpty)
    }

    /// Entries with planning, properties, logbooks, links and footnotes that are all fine. The
    /// performance gates time Lint File on 1 MB files.
    @Test func wellFormedEntries() {
        var text = "#+TITLE: Large\n"
        for i in 0..<500 {
            text += "* TODO Entry \(i) [1/2] :tag:\nSCHEDULED: <2026-11-26 Thu>\n:PROPERTIES:\n:ID: id-\(i)\n:CUSTOM_ID: c\(i)\n:END:\n:LOGBOOK:\nCLOCK: [2026-11-26 Thu 09:00]--[2026-11-26 Thu 10:00] =>  1:00\n:END:\n"
            text += "Body with [[#c\(i)]], [[id:id-\(i)]], [[*Entry \(i)]] and a note[fn:\(i)].\n- item one\n- item two <2026-11-27 Fri>\n\n[fn:\(i)] Note \(i).\n\n"
        }
        #expect(Self.lint(text).isEmpty)
    }
}
