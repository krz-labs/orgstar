import Foundation
import Testing
@testable import OrgCore

/// reveal.js export against the structure org-re-reveal writes; Emacs's org-re-reveal isn't
/// installed for an oracle test.
struct RevealExportTests {
    static let library = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/OrgMathJax/Reveal")

    static let deck = """
        #+TITLE: Talk
        #+AUTHOR: Ann
        #+DATE: 2026-11-26
        #+OPTIONS: toc:nil num:nil

        * First
        Intro text.
        #+BEGIN_NOTES
        Say hello.
        #+END_NOTES
        ** Down
        #+ATTR_REVEAL: :frag (appear)
        - one
        - two
        * Second
        #+ATTR_REVEAL: :frag fade-in :frag_idx 2
        A fragment.
        *** Deep
        Still on Second's group.

        """

    /// The slides alone, between the slides div and its end, without the title slide.
    static func slides(_ html: String) -> String {
        let start = html.range(of: "<div class=\"slides\">\n")!.upperBound
        let end = html.range(of: "</div>\n</div>\n", options: .backwards)!.lowerBound
        return String(html[start..<end])
    }

    @Test func sectionsFollowHeadlineLevels() {
        let html = RevealExport.document(Self.deck, fallbackTitle: "talk", library: nil)
        #expect(Self.slides(html) == """
            <section id="sec-title-slide">
            <h1 class="title">Talk</h1><h2 class="author">Ann</h2><h2 class="date">2026-11-26</h2>
            </section>
            <section>
            <section id="slide-first">
            <h2 id="first">First</h2>
            <p>Intro text.</p>
            <aside class="notes">
            <p>Say hello.</p>
            </aside>
            </section>
            <section id="slide-down">
            <h3 id="down">Down</h3>
            <ul>
            <li class="fragment appear">one</li>
            <li class="fragment appear">two</li>
            </ul>
            </section>
            </section>
            <section>
            <section id="slide-second">
            <h2 id="second">Second</h2>
            <p class="fragment fade-in" data-fragment-index="2">A fragment.</p>
            </section>
            <section id="slide-deep">
            <h4 id="deep">Deep</h4>
            <p>Still on Second's group.</p>
            </section>
            </section>

            """)
    }

    @Test func inlinesRevealWithoutRoot() throws {
        let html = RevealExport.document(Self.deck, fallbackTitle: "talk", library: Self.library)
        let theme = try String(contentsOf: Self.library.appendingPathComponent("theme/black.css"), encoding: .utf8)
        let script = try String(contentsOf: Self.library.appendingPathComponent("reveal.js"), encoding: .utf8)
        #expect(html.contains("<style id=\"theme\">\n\(theme)\n</style>"))
        #expect(html.contains("<script>\n\(script)\n</script>"))
        #expect(!html.contains("<script src="))
        #expect(!html.contains("<link rel=\"stylesheet\""))
        #expect(html.contains("plugins: [ RevealNotes, RevealSearch, RevealZoom ]"))
        #expect(html.contains("e.RevealNotes="))
    }

    @Test func linksToRevealRoot() {
        let text = """
            #+REVEAL_ROOT: https://cdn.example/reveal.js
            #+REVEAL_THEME: moon
            #+REVEAL_TRANS: fade
            #+REVEAL_PLUGINS: (notes highlight)
            #+REVEAL_INIT_OPTIONS: width:1200, height:800,
            #+REVEAL_INIT_OPTIONS: slideNumber:false
            #+OPTIONS: toc:nil reveal_control:nil
            * A

            """
        let html = RevealExport.document(text, fallbackTitle: "deck", library: Self.library)
        #expect(html.contains("<link rel=\"stylesheet\" href=\"https://cdn.example/reveal.js/dist/reveal.css\"/>"))
        #expect(html.contains("<link rel=\"stylesheet\" href=\"https://cdn.example/reveal.js/dist/theme/moon.css\" id=\"theme\"/>"))
        #expect(html.contains("<script src=\"https://cdn.example/reveal.js/dist/reveal.js\"></script>\n<script src=\"https://cdn.example/reveal.js/dist/plugin/notes.js\"></script>\n<script src=\"https://cdn.example/reveal.js/dist/plugin/highlight.js\"></script>"))
        #expect(html.contains("controls: false,"))
        #expect(html.contains("transition: 'fade',\ntransitionSpeed: 'default',\nwidth:1200, height:800,\nslideNumber:false,\nplugins: [ RevealNotes, RevealHighlight ]"))
        #expect(!html.contains("<style id=\"theme\">"))
    }

    @Test func inlineDeckLeavesOutPluginsNotBundled() {
        let html = RevealExport.document("#+REVEAL_PLUGINS: (markdown zoom highlight)\n* A\n", fallbackTitle: "deck", library: Self.library)
        #expect(html.contains("plugins: [ RevealZoom ]"))
        #expect(!html.contains("RevealMarkdown"))
    }

    @Test func tableOfContentsAndFootnotesAreSlides() {
        let text = """
            #+OPTIONS: num:nil reveal_title_slide:nil
            * One
            See [[*Two][two]] and a note.[fn:1]
            * Two

            [fn:1] The note.

            """
        let slides = Self.slides(RevealExport.document(text, fallbackTitle: "deck", library: nil))
        #expect(slides.hasPrefix("<section id=\"table-of-contents-section\">\n<div id=\"table-of-contents\" role=\"doc-toc\">"))
        #expect(slides.contains("<li><a href=\"#/slide-one\">One</a>"))
        #expect(slides.contains("<a href=\"#/slide-two\">two</a>"))
        #expect(slides.hasSuffix("</section>\n<section>\n<section class=\"footnotes\" aria-label=\"Footnotes\">\n<hr>\n<ol>\n<li id=\"fn-1\"><p>The note.</p>\n <a class=\"footnote-back\" href=\"#fnr-1\" aria-label=\"Back to reference 1\">&#8617;</a></li>\n</ol>\n</section>\n</section>\n"))
        #expect(!slides.contains("sec-title-slide"))
    }

    @Test func hlevelTwoMakesSecondLevelHorizontal() {
        let text = "#+REVEAL_HLEVEL: 2\n#+OPTIONS: toc:nil num:nil reveal_title_slide:nil\n* A\n** B\n*** C\n"
        #expect(Self.slides(RevealExport.document(text, fallbackTitle: "deck", library: nil)) == """
            <section>
            <section id="slide-a">
            <h2 id="a">A</h2>
            </section>
            </section>
            <section>
            <section id="slide-b">
            <h3 id="b">B</h3>
            </section>
            <section id="slide-c">
            <h4 id="c">C</h4>
            </section>
            </section>

            """)
    }

    @Test func headingsBelowHAreNotSlides() {
        let text = "#+OPTIONS: toc:nil num:nil reveal_title_slide:nil H:1\n* A\n** B\nText.\n* C :noexport:\n"
        #expect(Self.slides(RevealExport.document(text, fallbackTitle: "deck", library: nil)) == """
            <section>
            <section id="slide-a">
            <h2 id="a">A</h2>
            <h3 id="b">B</h3>
            <p>Text.</p>
            </section>
            </section>

            """)
    }

    @Test func textBeforeTheFirstHeadingIsASlide() {
        let text = "#+OPTIONS: toc:nil num:nil reveal_title_slide:nil\nOpening words.\n* A\n"
        #expect(Self.slides(RevealExport.document(text, fallbackTitle: "deck", library: nil)).hasPrefix("<section>\n<p>Opening words.</p>\n</section>\n<section>\n<section id=\"slide-a\">"))
    }

    @Test func fragmentsSplitsAndRawHTML() {
        let text = """
            #+REVEAL_DEFAULT_FRAG_STYLE: grow
            #+OPTIONS: toc:nil num:nil reveal_title_slide:nil
            * A
              :PROPERTIES:
              :REVEAL_BACKGROUND: #123456
              :REVEAL_DATA_TRANSITION: zoom
              :END:
            #+ATTR_REVEAL: :frag t
            First.
            #+REVEAL: split
            #+ATTR_REVEAL: :frag (none fade-up) :frag_idx (- 3)
            1. one
            2. two
            3. three
            #+REVEAL_HTML: <div class="raw">raw</div>
            @@reveal:<b>snippet</b>@@

            """
        #expect(Self.slides(RevealExport.document(text, fallbackTitle: "deck", library: nil)) == """
            <section>
            <section id="slide-a" data-transition="zoom" data-background="#123456">
            <h2 id="a">A</h2>
            <p class="fragment grow">First.</p>
            </section>
            <section data-transition="zoom" data-background="#123456">
            <ol>
            <li>one</li>
            <li class="fragment fade-up" data-fragment-index="3">two</li>
            <li class="fragment fade-up" data-fragment-index="3">three</li>
            </ol>
            <div class="raw">raw</div>
            <p><b>snippet</b></p>
            </section>
            </section>

            """)
    }

    @Test func titleSlideTemplate() {
        let text = "#+TITLE: T\n#+SUBTITLE: S\n#+AUTHOR: A\n#+REVEAL_TITLE_SLIDE: <h1>%t</h1><p>%s by %a, 100%%</p>\n#+REVEAL_TITLE_SLIDE_BACKGROUND: bg.png\n"
        let html = RevealExport.document(text, fallbackTitle: "deck", library: nil)
        #expect(html.contains("<section id=\"sec-title-slide\" data-background=\"bg.png\">\n<h1>T</h1><p>S by A, 100%</p>\n</section>"))
    }

    @Test func inlineDeckEmbedsLocalImages() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folder.appendingPathComponent("a.png"))
        let path = folder.appendingPathComponent("deck.org").path
        let text = "* A\n  :PROPERTIES:\n  :REVEAL_BACKGROUND: ./a.png\n  :END:\n[[file:a.png]]\n[[file:missing.png]]\n"
        let html = RevealExport.document(text, fallbackTitle: "deck", path: path, library: Self.library)
        #expect(html.contains("data-background=\"data:image/png;base64,iVBORw==\""))
        #expect(html.contains("<img src=\"data:image/png;base64,iVBORw==\" alt=\"a.png\">"))
        #expect(html.contains("<img src=\"missing.png\""))
        let linked = RevealExport.document("#+REVEAL_ROOT: ./r\n" + text, fallbackTitle: "deck", path: path, library: Self.library)
        #expect(linked.contains("<img src=\"a.png\""))
    }

    @Test func codeColorsFollowTheThemesBackground() {
        let css = ".org-keyword { color: #111111; }\n@media (prefers-color-scheme: dark) { .org-keyword { color: #eeeeee; } }\n"
        #expect(RevealExport.codeCSS(css, dark: false) == ".org-keyword { color: #111111; }")
        #expect(RevealExport.codeCSS(css, dark: true) == ".org-keyword { color: #eeeeee; }")
    }
}
