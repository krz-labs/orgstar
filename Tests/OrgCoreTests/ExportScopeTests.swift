import Foundation
import Testing
@testable import OrgCore

struct ExportScopeTests {
    static let file = """
        #+TITLE: Whole file
        #+AUTHOR: Ann
        #+OPTIONS: toc:nil num:nil
        * Intro
        Some intro.
        * TODO [#A] Project :work:
        SCHEDULED: <2026-10-10 Sat>
        :PROPERTIES:
        :EXPORT_FILE_NAME: project-notes
        :EXPORT_AUTHOR: Bob
        :END:
        Body of project.
        ** Step one
        Do it.
        *** Deep
        deep text
        * Other
        """

    static var project: Int { (file as NSString).range(of: "Body of").location }

    /// As `org-export-as` with SUBTREEP in Emacs 31: the heading's title is the title, its
    /// EXPORT_AUTHOR the author, in place of the file's; planning and drawer left out; children
    /// one level up.
    @Test func subtreeIsADocumentOfItsOwn() throws {
        let text = try #require(ExportScope.subtree(Self.file, at: Self.project))
        #expect(text == """
            #+OPTIONS: toc:nil num:nil
            #+TITLE: Project
            #+AUTHOR: Bob
            Body of project.
            * Step one
            Do it.
            ** Deep
            deep text

            """)
        let meta = HTMLExport.metadata(text)
        #expect(meta.title == "Project" && meta.author == "Bob")
        let body = HTMLExport.page(text, fallbackTitle: "t", bodyOnly: true)
        #expect(!body.contains("<html") && !body.contains("class=\"title\"") && !body.contains("Intro"))
        #expect(body.contains("<h2") && body.contains("Step one") && body.contains("<h3") && !body.contains("table-of-contents"))
        #expect(ExportScope.subtree(Self.file, at: 0) == nil)
    }

    @Test func exportTitleOverridesTheHeading() throws {
        let file = "* Proj\n:PROPERTIES:\n:EXPORT_TITLE: Custom\n:EXPORT_OPTIONS: toc:nil\n:END:\nText.\n"
        let text = try #require(ExportScope.subtree(file, at: 0))
        #expect(HTMLExport.metadata(text).title == "Custom")
        #expect(text.hasSuffix("#+OPTIONS: toc:nil\nText.\n"))
    }

    /// `org-export-output-file-name`: relative to the file's folder, the extension replaced.
    @Test func fileNames() {
        let source = URL(fileURLWithPath: "/notes/t.org")
        #expect(ExportScope.fileName(Self.file, subtreeAt: Self.project) == "project-notes")
        #expect(ExportScope.fileName(Self.file, subtreeAt: 0) == nil)
        #expect(ExportScope.fileName("#+EXPORT_FILE_NAME: out/x\n* A\n") == "out/x")
        #expect(ExportScope.fileName(OrgParser.parse(Self.file), subtreeAt: Self.project) == "project-notes")
        #expect(ExportScope.fileName(OrgParser.parse("#+EXPORT_FILE_NAME: out/x\n* A\n")) == "out/x")
        #expect(ExportScope.output(for: source, name: "out/x", extension: "html").path == "/notes/out/x.html")
        #expect(ExportScope.output(for: source, name: "out/x.txt", extension: "html").path == "/notes/out/x.html")
        #expect(ExportScope.output(for: source, name: "/tmp/abs", extension: "md").path == "/tmp/abs.md")
        #expect(ExportScope.output(for: source, name: nil, extension: "md").path == "/notes/t.md")
    }

    /// The words `C-s` and `C-b` keep in ox-html and ox-md, for the whole file and a subtree.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func subtreeAndBodyOnlyKeepWhatOrgKeeps() throws {
        let text = """
            #+TITLE: wordtitle
            #+AUTHOR: wordauthor
            #+OPTIONS: toc:nil num:nil
            wordintro
            * wordone
            SCHEDULED: <2026-10-10 Sat>
            :PROPERTIES:
            :EXPORT_AUTHOR: wordbob
            :wordkey: wordvalue
            :END:
            wordfirst
            ** wordsub
            worddeep
            * wordtwo
            wordsecond
            """ + "\n"
        let offset = (text as NSString).range(of: "wordfirst").location
        let point = EmacsOracle.point(offset, in: text)
        let emacs = try EmacsOracle.evaluate(text, """
            (progn
              (require 'ox-html) (require 'ox-md)
              (goto-char \(point))
              (list (org-export-as 'html t nil nil) (org-export-as 'html nil nil t) (org-export-as 'html t nil t)
                    (org-export-as 'md t nil nil) (org-export-as 'md nil nil t) (org-export-as 'md t nil t)))
            """)
        let subtree = try #require(ExportScope.subtree(text, at: offset))
        let ours = [
            HTMLExport.page(subtree, fallbackTitle: "t"), HTMLExport.page(text, fallbackTitle: "t", bodyOnly: true),
            HTMLExport.page(subtree, fallbackTitle: "t", bodyOnly: true),
            MarkdownExport.document(subtree), MarkdownExport.document(text, bodyOnly: true), MarkdownExport.document(subtree, bodyOnly: true),
        ]
        let names = ["html subtree", "html body", "html subtree body", "md subtree", "md body", "md subtree body"]
        let words = Set(text.matches(of: /\bword[a-z]+\b/).map { String($0.0) })
        for (index, name) in names.enumerated() {
            // ox-md writes no title; this export makes it the top heading.
            for word in words where !(name == "md subtree" && word == "wordone") {
                #expect(ours[index].contains(word) == emacs[index].contains(word), "\(name) \(word)\nours:\n\(ours[index])\nemacs:\n\(emacs[index])")
            }
        }
        #expect(emacs[0].contains("wordone") && !emacs[2].contains("wordone") && !emacs[1].contains("wordtitle") && emacs[1].contains("wordsecond"))
    }

    @Test func markdownBodyOnlyHasNoTitle() {
        let text = "#+TITLE: T\n* A\nx\n"
        #expect(MarkdownExport.document(text).hasPrefix("# T"))
        #expect(MarkdownExport.document(text, bodyOnly: true).hasPrefix("## A"))
    }
}
