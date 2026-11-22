import Foundation
import Testing
@testable import OrgCore

struct InlineImagesTests {
    /// Each image link's text and the path it shows.
    static func shown(_ text: String, includeLinked: Bool = false, remote: Bool = false, attachment: ((String, Int) -> String?)? = nil) -> [[String]] {
        let tree = OrgParser.parse(text)
        return InlineImages.links(tree, in: 0..<(text as NSString).length, includeLinked: includeLinked, remote: remote, attachment: attachment)
            .map { [(text as NSString).substring(with: NSRange($0.range)), $0.image.path] }
    }

    @Test func findsImageLines() {
        let text = "#+STARTUP: inlineimages\n* Images\n[[file:pic.png]]\n#+NAME: x\n#+ATTR_ORG: :width 60\n[[./pic.png]]\n[[pic.png][desc]]\n[[https://x.org/a.png]]\n"
        let tree = OrgParser.parse(text)
        let links = InlineImages.links(tree, in: 0..<(text as NSString).length)
        #expect(links.map(\.image) == [InlineImages.Image(path: "pic.png", width: nil), InlineImages.Image(path: "./pic.png", width: 60)])
        #expect(links.map(\.range.lowerBound) == ["[[file:pic", "[[./pic"].map { (text as NSString).range(of: $0).location })
        #expect(InlineImages.startup(tree) == true)
        #expect(InlineImages.startup(OrgParser.parse("#+STARTUP: overview noinlineimages\n")) == false)
        #expect(InlineImages.startup(OrgParser.parse("* x\n")) == nil)
        #expect(InlineImages.startup(OrgParser.parse("#+begin_src org\n#+STARTUP: inlineimages\n#+end_src\n")) == nil)
    }

    @Test func attachmentLinksNeedTheResolver() {
        let text = "* Photo\n[[attachment:cat.jpg]]\n#+ATTR_ORG: :width 80\n[[attachment:sub/dog.png]]\n[[attachment:cat.jpg][desc]]\n"
        #expect(Self.shown(text).isEmpty)
        var asked: [(String, Int)] = []
        let resolve: (String, Int) -> String? = { name, offset in
            asked.append((name, offset))
            return "/notes/data/ab/cd/" + name
        }
        let links = InlineImages.links(OrgParser.parse(text), in: 0..<(text as NSString).length, attachment: resolve)
        #expect(links.map(\.image) == [
            InlineImages.Image(path: "/notes/data/ab/cd/cat.jpg", width: nil), InlineImages.Image(path: "/notes/data/ab/cd/sub/dog.png", width: 80),
        ])
        #expect(asked.map(\.0) == ["cat.jpg", "sub/dog.png"] && asked[0].1 == (text as NSString).range(of: "[[attachment:cat.jpg]]").location)
        #expect(Self.shown(text, attachment: { _, _ in nil }).isEmpty)
    }

    /// `org-link-preview-region`: a described link shows only with INCLUDE-LINKED.
    @Test func describedLinksShowWithThePrefix() {
        let text = "See [[file:a.png][the figure]] here.\n"
        #expect(Self.shown(text).isEmpty)
        #expect(Self.shown(text, includeLinked: true) == [["[[file:a.png][the figure]]", "a.png"]])
        #expect(Self.shown("[[file:notes.org][the figure]]\n", includeLinked: true).isEmpty)
    }

    /// A description that is one `file:` or `attachment:` link, plain or in angle brackets,
    /// shows without the prefix, in place of the description; with it, the path decides.
    @Test func descriptionThatIsAnImageLink() {
        #expect(Self.shown("[[https://example.com][file:thumb.png]]\n") == [["file:thumb.png", "thumb.png"]])
        #expect(Self.shown("[[file:big.png][<file:small thumb.png>]]\n") == [["<file:small thumb.png>", "small thumb.png"]])
        #expect(Self.shown("[[file:big.png][attachment:t.png]]\n", attachment: { name, _ in "/a/" + name }) == [["attachment:t.png", "/a/t.png"]])
        #expect(Self.shown("[[file:big.png][file:thumb.png]]\n", includeLinked: true) == [["[[file:big.png][file:thumb.png]]", "big.png"]])
        #expect(Self.shown("[[https://example.com][file:thumb.png]]\n", includeLinked: true).isEmpty)
        // Not the whole description, no explicit type, or a remote link.
        #expect(Self.shown("[[file:big.png][see file:thumb.png]]\n[[file:big.png][./thumb.png]]\n[[file:big.png][https://example.com/t.png]]\n", remote: true).isEmpty)
    }

    @Test func imagesInALinesText() {
        let text = "Before [[file:a.png]] between [[./b.jpg]] and file:c.gif and <file:d e.png> after.\n"
        #expect(Self.shown(text) == [["[[file:a.png]]", "a.png"], ["[[./b.jpg]]", "./b.jpg"], ["file:c.gif", "c.gif"], ["<file:d e.png>", "d e.png"]])
        // Only the links a range overlaps.
        let tree = OrgParser.parse(text)
        let b = (text as NSString).range(of: "[[./b.jpg]]")
        #expect(InlineImages.links(tree, in: b.location..<(b.location + 1)).map(\.image.path) == ["./b.jpg"])
    }

    @Test func imagesInHeadingsTablesAndItems() {
        let text = "* Head [[file:h.png]]\n- item [[file:i.png]]\n  1. [[file:n.png]]\n| a | [[file:t.png]] |\n"
        #expect(Self.shown(text).map { $0[1] } == ["h.png", "i.png", "n.png", "t.png"])
    }

    /// Links are objects: none in verbatim text, comments, keywords and literal blocks; quote,
    /// center and verse blocks and captions hold Org text.
    @Test func onlyWhereOrgHasLinks() {
        let text = "=[[file:v.png]]= ~[[file:c.png]]~\n# [[file:comment.png]]\n#+begin_src org\n[[file:s.png]]\n#+end_src\n#+BEGIN_EXAMPLE\n[[file:e.png]]\n#+END_EXAMPLE\n"
        #expect(Self.shown(text).isEmpty)
        let quote = "#+begin_quote\n#+ATTR_ORG: :width 40\n[[file:q.png]]\nText [[file:r.png][desc]] end\n#+end_quote\n"
        #expect(Self.shown(quote) == [["[[file:q.png]]", "q.png"]])
        #expect(Self.shown(quote, includeLinked: true).map { $0[1] } == ["q.png", "r.png"])
        #expect(InlineImages.links(OrgParser.parse(quote), in: 0..<(quote as NSString).length).first?.image.width == 40)
        #expect(Self.shown("#+CAPTION: See [[file:k.png]]\n#+NAME: [[file:n.png]]\nText\n") == [["[[file:k.png]]", "k.png"]])
    }

    /// The paragraph's `#+ATTR_ORG` sizes every image in it, as `org-display-inline-image--width`
    /// reads it from the link's paragraph.
    @Test func widthComesFromTheParagraph() {
        let text = "#+ATTR_ORG: :width 120\nFirst line\nthen [[file:a.png]] and [[file:b.png]]\n\n- [[file:item.png]]\n* [[file:head.png]]\n"
        let links = InlineImages.links(OrgParser.parse(text), in: 0..<(text as NSString).length)
        #expect(links.map(\.image.width) == [120, 120, nil, nil])
    }

    /// The links `org-link-preview-region` hands to the `file:` preview with an image's name,
    /// and the text each overlay covers, with and without INCLUDE-LINKED.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil && EmacsOracle.isAvailable))
    func linksMatchEmacs() throws {
        let text = """
            * Head [[file:h.png]] tail
            #+ATTR_ORG: :width 60
            Para [[file:a.png][desc]] and [[./b.jpg]] and file:c.gif and <file:d e.png> end
            more =[[file:v.png]]= ~[[file:w.png]]~ [[https://example.com][file:t.png]] [[file:big.png][file:small.png]]
            [[file:big.png][<file:angle.png>]] [[file:big.png][see file:not.png]] [[file:notes.org][notes]] [[file:n.org]]

            - item [[file:i.png]]
              1. [[file:n.png][n]]
            | a | [[file:t1.png]] | [[file:t2.png][two]] |
            #+begin_quote
            [[file:q.png]]
            Text [[file:r.png][desc]] end
            #+end_quote
            #+begin_src org
            [[file:s.png]]
            #+end_src
            #+begin_example
            [[file:e.png]]
            #+end_example
            # [[file:comment.png]]
            #+CAPTION: [[file:k.png]]
            [[file:z.png]]

            """
        for includeLinked in [false, true] {
            let emacs = try EmacsOracle.evaluate(text, """
                (let (out (org-link-preview-batch-size 1000))
                  (advice-add 'org-link-preview-file :override
                              (lambda (ov path _link)
                                (when (string-match-p (image-file-name-regexp) path)
                                  (push (format "%s -> %s" (buffer-substring-no-properties (overlay-start ov) (overlay-end ov)) path) out))
                                nil))
                  (org-link-preview-region \(includeLinked ? "t" : "nil") t (point-min) (point-max))
                  (nreverse out))
                """)
            #expect(Self.shown(text, includeLinked: includeLinked).map { "\($0[0]) -> \($0[1])" } == emacs, "INCLUDE-LINKED \(includeLinked)")
            #expect(emacs.count > 8)
        }
    }

    @Test func notImagesAndRemoteLinks() {
        let text = "[[file:notes.org]] [[file:a.png::3]] [[https://x.org/a.png]] [[ftp://x.org/b.png]] https://x.org/c.png\n"
        #expect(Self.shown(text).isEmpty)
        #expect(Self.shown(text, remote: true) == [["[[https://x.org/a.png]]", "https://x.org/a.png"]])
    }
}
