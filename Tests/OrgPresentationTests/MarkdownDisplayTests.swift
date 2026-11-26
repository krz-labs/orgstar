import Foundation
import OrgCore
import OrgPresentation
import Testing

/// Highlights `yaml` and `swift` code as one keyword run over the whole code.
struct WholeCodeHighlighter: CodeHighlighter {
    func highlights(language: String, code: String) -> [(range: Range<Int>, category: SyntaxCategory)] {
        ["yaml", "swift"].contains(language) ? [(0..<code.utf16.count, .keyword)] : []
    }
}

struct MarkdownDisplayTests {
    let text = "Intro\n# A\nbody\n## B\nmore\n```\n# not\n```\n# C\ntext\n"

    @Test func outline() {
        let document = MarkdownDocument(text)
        let outline = document.outline
        #expect(outline.map(\.title) == ["A", "B", "C"])
        #expect(outline.map(\.start) == [6, 15, 39])
        #expect(outline.map(\.end) == [39, 39, 48])
        #expect(outline.map(\.parent) == [nil, 0, nil])
        #expect(outline.map(\.isTopLevel) == [true, false, true])
    }

    @Test func foldsByHeading() {
        let document = MarkdownDocument(text)
        let tree = document.foldTree
        #expect(tree.text.utf16.count == text.utf16.count)
        #expect(Presentation.outline(tree).map(\.start) == document.outline.map(\.start))
        #expect(Presentation.hiddenRanges(tree, folds: [6]) == [10..<39])
        #expect(Presentation.hiddenRanges(tree, folds: [15]) == [20..<39])
        // TAB on a heading: folded, children, subtree.
        let folded = Presentation.cycle(6, in: tree, FoldState())
        #expect(folded.folds == [6])
        let children = Presentation.cycle(6, in: tree, folded)
        #expect(children.folds == [15])
        // Without the tree, the same ranges as org's for the tree.
        for (folds, bodyFolds) in [([6], []), ([15], []), ([6, 15], []), ([], [6]), ([39], [6]), ([], [6, 15, 39]), ([6], [15])] as [(Set<Int>, Set<Int>)] {
            #expect(Presentation.markdownHiddenRanges(document, folds: folds, bodyFolds: bodyFolds)
                == Presentation.hiddenRanges(tree, folds: folds, bodyFolds: bodyFolds), "\(folds) \(bodyFolds)")
        }
        // The `#` line in a fence isn't a heading.
        #expect(Presentation.heading(containing: 31, in: tree) == nil)
        #expect(Presentation.heading(containing: 40, in: tree) == 39)
    }

    func roles(_ text: String, highlighter: (any CodeHighlighter)? = nil) -> [String] {
        let document = MarkdownDocument(text)
        let ns = text as NSString
        return Presentation.markdownStyles(document, in: 0..<ns.length, highlighter: highlighter).map {
            "\($0.role) " + ns.substring(with: NSRange($0.range)).replacingOccurrences(of: "\n", with: "⏎")
        }
    }

    @Test func styles() {
        #expect(roles("---\nk: v\n---\n# H *e*\n```swift\nlet\n```\n> q\n", highlighter: WholeCodeHighlighter()) == [
            "blockDelimiter ---⏎", "metadata k: v⏎", "syntax(OrgPresentation.SyntaxCategory.keyword) k: v⏎", "blockDelimiter ---⏎",
            "blockDelimiter ```swift⏎", "block let⏎", "syntax(OrgPresentation.SyntaxCategory.keyword) let⏎", "blockDelimiter ```⏎",
            "heading(level: 1) # H *e*", "italic *e*", "markup *", "markup *",
            "markup >", "italic q",
        ])
    }

    @Test func stylesOnlyTheLinesAsked() {
        let text = "# A\n**b**\n```\n# c\n"
        let document = MarkdownDocument(text)
        let runs = Presentation.markdownStyles(document, in: 5..<6)
        #expect(runs.map(\.role) == [.bold, .markup, .markup])
        // Inside an unclosed fence, nothing is a heading.
        #expect(Presentation.markdownStyles(document, in: 14..<17).map(\.role) == [.blockDelimiter, .block])
    }

    @Test func restyleRangeFollowsFences() {
        let old = "a\n```\ncode\n```\nb\n# h\n"
        let oldBlocks = MarkdownDocument(old).structure.blocks
        // Deleting the closing fence opens the block to the end of the text.
        let edit = TextEdit(range: 11..<15, replacement: "")
        let new = "a\n```\ncode\nb\n# h\n"
        let range = Presentation.markdownRestyleRange(for: edit, oldBlocks: oldBlocks, new: MarkdownDocument(new), newText: new as NSString)
        #expect(range == 2..<(new as NSString).length)
        // Typing inside a paragraph restyles its line.
        let typed = TextEdit(range: 1..<1, replacement: "x")
        let after = "ax\n```\ncode\n```\nb\n# h\n"
        #expect(Presentation.markdownRestyleRange(for: typed, oldBlocks: oldBlocks, new: MarkdownDocument(after), newText: after as NSString) == 0..<3)
    }
}
