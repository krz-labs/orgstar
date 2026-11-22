import Foundation
import OrgCore
import Testing
@testable import OrgPresentation

struct TagGapTests {
    @Test func aPaddedHeadingHasAGap() {
        let text = "* TODO Call     :office:\n** Short :a:b:\n* Tab\t   :x:\n*** Deep  :y:\n"
        let gaps = Presentation.tagGaps(OrgParser.parse(text))
        let ns = text as NSString
        #expect(gaps.map { ns.substring(with: NSRange($0.gap)) } == ["     ", "  "])
        #expect(gaps.map { ns.substring(with: NSRange($0.tags)) } == [":office:", ":y:"])
    }

    @Test func theGapFitsTheWidth() {
        // As written when the line fits, as on a wide Mac window.
        #expect(Presentation.tagGapWidth(title: 100, gap: 300, space: 7, tags: 50, available: 500) == nil)
        // The tags at the right edge when only the padding doesn't fit.
        #expect(Presentation.tagGapWidth(title: 100, gap: 300, space: 7, tags: 50, available: 300) == 150)
        // One space when the title and tags don't fit on the line.
        #expect(Presentation.tagGapWidth(title: 280, gap: 300, space: 7, tags: 50, available: 300) == 7)
    }
}
