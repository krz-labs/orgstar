import Foundation
import OrgCore
import Testing
@testable import OrgPresentation

struct StyledExtentTests {
    @Test func chunksEndAtLineStartsAndCoverTheText() {
        let text = String(repeating: "a line of text\n", count: 100) + "last" as NSString
        var extent = StyledExtent()
        var chunks: [Range<Int>] = []
        while let chunk = extent.next(100, in: text) { chunks.append(chunk) }
        #expect(chunks.first?.lowerBound == 0)
        #expect(chunks.last?.upperBound == text.length)
        #expect(extent.end == text.length)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        for chunk in chunks.dropLast() {
            #expect(chunk.count >= 100)
            #expect(text.character(at: chunk.upperBound - 1) == 0x0A)
        }
        extent.reset()
        #expect(extent.end == 0)
    }

    @Test func editsMoveOrPullBackTheEnd() {
        let text = String(repeating: "line\n", count: 10) as NSString
        var extent = StyledExtent()
        _ = extent.next(12, in: text)
        #expect(extent.end == 15)
        // Before: shifted.
        var before = extent
        before.map(through: TextEdit(range: 0..<0, replacement: "abc"), in: "abc" + (text as String) as NSString)
        #expect(before.end == 18)
        // Across: pulled back to the edited line.
        var across = extent
        let edited = text.replacingCharacters(in: NSRange(location: 12, length: 5), with: "") as NSString
        across.map(through: TextEdit(range: 12..<17, replacement: ""), in: edited)
        #expect(across.end == 10)
        // After: unchanged.
        var after = extent
        after.map(through: TextEdit(range: 20..<20, replacement: "x"), in: text)
        #expect(after.end == 15)
    }
}

struct StyleChangeTests {
    /// Highlights whose later runs overlap earlier ones that start before them.
    struct Overlapping: CodeHighlighter {
        func highlights(language: String, code: String) -> [(range: Range<Int>, category: SyntaxCategory)] {
            [(5..<7, .string), (0..<7, .keyword), (2..<4, .comment)]
        }
    }

    static let sample = """
        #+TITLE: Sample
        * TODO [#A] Heading with *bold* and [[https://a.b][a link]] :tag:
        SCHEDULED: <2026-11-21 Sat>
        :PROPERTIES:
        :ID: x
        :END:
        Text with /italic/, =code=, ~verb~ and x^{2} and \\alpha.
        - item *one* [ ]
          - nested [[file:a.org]]
        | a | *b* |
        |---+-----|
        #+begin_src sh
        echo hi
        #+end_src
        ** DONE Second
        #+begin_quote
        quoted *text*
        #+end_quote

        """

    /// Every role on one attribute, so the last one set over a character shows.
    private func applied(_ changes: [StyleChange], length: Int) -> NSAttributedString {
        let out = NSMutableAttributedString(string: String(repeating: " ", count: length))
        let role = NSAttributedString.Key("role")
        let indent = NSAttributedString.Key("indent")
        for change in changes {
            switch change {
            case .indent(let line): out.addAttribute(indent, value: "\(line.firstLine) \(line.wrapped)", range: NSRange(line.range))
            case .role(let r, let range): out.addAttribute(role, value: "\(r)", range: NSRange(range))
            case .hidden(let range): out.addAttribute(role, value: "hidden", range: NSRange(range))
            }
        }
        return out
    }

    /// Indents first, then roles in `Presentation.styles` order.
    private func inStylesOrder(_ tree: OrgTree, _ range: Range<Int>, showMarkup: Bool, revealed: Range<Int>) -> [StyleChange] {
        var changes = Presentation.lineIndents(tree, in: range).map(StyleChange.indent)
        for run in Presentation.styles(tree, in: range, highlighter: Overlapping()) {
            let clipped = run.range.clamped(to: range)
            guard !clipped.isEmpty else { continue }
            if !showMarkup, Presentation.hidesWithMarkup(run.role, options: .org), !clipped.overlaps(revealed) {
                changes.append(.hidden(clipped))
            } else {
                changes.append(.role(run.role, clipped))
            }
        }
        return changes
    }

    @Test(arguments: [true, false]) func ascendingOrderSetsWhatStylesOrderSets(showMarkup: Bool) {
        let tree = OrgParser.parse(Self.sample)
        let length = Self.sample.utf16.count
        let revealed = 16..<80
        for range in [0..<length, 16..<200, 300..<length] {
            let (changes, _) = Presentation.styleChanges(
                tree, in: range, highlighter: Overlapping(), indented: true, hideStars: false,
                showMarkup: showMarkup, options: .org, revealed: revealed
            )
            let expected = inStylesOrder(tree, range, showMarkup: showMarkup, revealed: revealed)
            #expect(changes.count == expected.count)
            #expect(applied(changes, length: length).isEqual(to: applied(expected, length: length)))
        }
    }

    @Test func changesStartInAscendingOrder() {
        let tree = OrgParser.parse(Self.sample)
        let (changes, exclusions) = Presentation.styleChanges(
            tree, in: 0..<Self.sample.utf16.count, highlighter: nil, indented: true, hideStars: false,
            showMarkup: true, options: .org, revealed: 0..<0
        )
        let starts = changes.map { change in
            switch change {
            case .indent(let line): line.range.lowerBound
            case .role(_, let range), .hidden(let range): range.lowerBound
            }
        }
        #expect(starts == starts.sorted())
        #expect(!exclusions.isEmpty)
    }

    @Test func leadingStarsAndHiddenMarkup() {
        let text = "** a *b*\n"
        let tree = OrgParser.parse(text)
        func changes(indented: Bool, showMarkup: Bool, revealed: Range<Int>) -> [StyleChange] {
            var options = EditingOptions.org
            options.hideEmphasisMarkers = true
            return Presentation.styleChanges(
                tree, in: 0..<text.utf16.count, highlighter: nil, indented: indented, hideStars: false,
                showMarkup: showMarkup, options: options, revealed: revealed
            ).changes
        }
        #expect(changes(indented: true, showMarkup: true, revealed: 0..<0).contains(.role(.leadingStars, 0..<1)))
        #expect(!changes(indented: false, showMarkup: true, revealed: 0..<0).contains(.role(.leadingStars, 0..<1)))
        #expect(changes(indented: false, showMarkup: false, revealed: 0..<0).contains(.hidden(5..<6)))
        #expect(changes(indented: false, showMarkup: false, revealed: 0..<9).contains(.role(.markup, 5..<6)))
        #expect(changes(indented: false, showMarkup: true, revealed: 0..<0).filter { if case .indent = $0 { true } else { false } }.isEmpty)
    }
}

struct RestyleRangeTests {
    private func range(_ old: String, _ edit: TextEdit) -> Range<Int> {
        var new = Array(old.utf16)
        new.replaceSubrange(edit.range, with: Array(edit.replacement.utf16))
        let newText = String(decoding: new, as: UTF16.self)
        return Presentation.restyleRange(
            for: edit, old: (OrgParser.parse(old), old as NSString), new: (OrgParser.parse(newText), newText as NSString)
        )
    }

    @Test func aParagraphEditStaysInItsParagraph() {
        let text = String(repeating: "* Heading\nSome text here.\n\nMore text.\n\n", count: 2_000)
        let at = (text as NSString).range(of: "Some text", options: [], range: NSRange(location: 40_000, length: 1_000)).location
        let affected = range(text, TextEdit(range: at..<at, replacement: "x"))
        #expect(affected.contains(at))
        #expect(affected.count < 100)
    }

    @Test func aHeadingEditWidensToItsSection() {
        let text = "* A\nbody\n\nmore body\n* B\nnext\n"
        let affected = range(text, TextEdit(range: 2..<3, replacement: "AB"))
        #expect(affected.lowerBound == 0)
        #expect(affected.upperBound >= ("* AB\nbody\n\nmore body\n" as NSString).length)
    }

    /// A replacement across the newline before a top-level heading, as a keyboard makes: the
    /// sections on either side change, not the text from the start of the file.
    @Test func aReplacementBeforeATopLevelHeadingStaysNearIt() {
        let text = String(repeating: "* TODO Project :work:\n** Section\nSome *text*.\n\n- item one\n- item two [ ]\n\n", count: 2_000)
        let at = (text as NSString).range(of: "\n\n* TODO", options: [], range: NSRange(location: 40_000, length: 1_000)).location + 1
        let affected = range(text, TextEdit(range: at..<(at + 1), replacement: "x\n"))
        #expect(affected.contains(at))
        #expect(affected.count < 200)
    }

    /// Restyling only what an edit affects leaves the same styling as restyling everything.
    @Test(arguments: ["a", "\n", "* ", "#+end_src\n", ""])
    func restylingTheRangeMatchesRestylingAll(replacement: String) {
        let text = StyleChangeTests.sample + "* B\n:PROPERTIES:\n:ID: x\n:END:\n| a |\n|---|\n\n- a\n  - b\n* C\nend\n"
        let length = text.utf16.count
        let oldTree = OrgParser.parse(text)
        let old = styled(oldTree, in: 0..<length)
        for at in 0..<length {
            let edit = TextEdit(range: at..<(replacement.isEmpty ? at + 1 : at), replacement: replacement)
            let newText = (text as NSString).replacingCharacters(in: NSRange(edit.range), with: replacement)
            let newTree = OrgParser.parse(newText)
            let affected = Presentation.restyleRange(for: edit, old: (oldTree, text as NSString), new: (newTree, newText as NSString))
            let restyle = affected.clamped(to: 0..<newText.utf16.count)
            let incremental = NSMutableAttributedString(attributedString: old)
            incremental.replaceCharacters(in: NSRange(edit.range), with: replacement)
            incremental.setAttributes([:], range: NSRange(restyle))
            apply(styled(newTree, in: restyle), to: incremental, at: restyle.lowerBound)
            let whole = styled(newTree, in: 0..<newText.utf16.count)
            #expect(incremental.isEqual(to: whole), "edit at \(at)")
        }
    }

    /// Roles and indents for `range` of `tree`, on a string of spaces as long as the range.
    private func styled(_ tree: OrgTree, in range: Range<Int>) -> NSAttributedString {
        let (changes, _) = Presentation.styleChanges(
            tree, in: range, highlighter: nil, indented: true, hideStars: false, showMarkup: true, options: .org, revealed: 0..<0
        )
        let out = NSMutableAttributedString(string: (tree.text as NSString).substring(with: NSRange(range)))
        for change in changes {
            switch change {
            case .indent(let line): out.addAttribute(.init("indent"), value: "\(line.firstLine) \(line.wrapped)", range: NSRange(line.range.shifted(-range.lowerBound)))
            case .role(let role, let r): out.addAttribute(.init("role"), value: "\(role)", range: NSRange(r.shifted(-range.lowerBound)))
            case .hidden(let r): out.addAttribute(.init("role"), value: "hidden", range: NSRange(r.shifted(-range.lowerBound)))
            }
        }
        return out
    }

    private func apply(_ part: NSAttributedString, to string: NSMutableAttributedString, at offset: Int) {
        part.enumerateAttributes(in: NSRange(location: 0, length: part.length)) { attributes, range, _ in
            string.addAttributes(attributes, range: NSRange(location: offset + range.location, length: range.length))
        }
    }

    @Test func closingABlockCoversTheBlock() {
        let text = "Intro.\n#+begin_src sh\necho\nmore\n\nend\n"
        let at = (text as NSString).length
        let affected = range(text, TextEdit(range: at..<at, replacement: "#+end_src\n"))
        #expect(affected.lowerBound <= ("Intro.\n" as NSString).length)
        #expect(affected.upperBound >= at + 10)
    }
}

private extension Range<Int> {
    func shifted(_ by: Int) -> Range<Int> { (lowerBound + by)..<(upperBound + by) }
}
