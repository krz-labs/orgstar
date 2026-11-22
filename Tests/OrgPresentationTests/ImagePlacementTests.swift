import Foundation
import OrgCore
import Testing
@testable import OrgPresentation

struct ImagePlacementTests {
    static func placements(_ text: String, includeLinked: Bool = false) -> [Presentation.ImagePlacement] {
        let links = InlineImages.links(OrgParser.parse(text), in: 0..<(text as NSString).length, includeLinked: includeLinked)
        return Presentation.imagePlacements(links, in: text as NSString)
    }

    @Test func aLinkAloneTakesItsLine() {
        #expect(Self.placements("[[file:a.png]]\n  [[file:b.png]] \t\n[[file:c.png]]").map(\.ownLine) == [true, true, true])
        #expect(Self.placements("[[file:a.png][A figure]]\n", includeLinked: true).map(\.ownLine) == [true])
    }

    @Test func aLinkWithTextAroundItStandsInTheText() {
        #expect(Self.placements("See [[file:a.png]]\n[[file:b.png]] here\n").map(\.ownLine) == [false, false])
        #expect(Self.placements("[[file:a.png]] [[file:b.png]]\n").map(\.ownLine) == [false, false])
        #expect(Self.placements("* [[file:h.png]]\n- [[file:i.png]]\n| [[file:t.png]] |\n").map(\.ownLine) == [false, false, false])
        // The image stands for the description, inside the link.
        #expect(Self.placements("[[https://example.com][file:thumb.png]]\n").map(\.ownLine) == [false])
    }

    /// A link past the text's end, from a tree older than the text, is left out.
    @Test func linksPastTheTextAreLeftOut() {
        let links = InlineImages.links(OrgParser.parse("text\n[[file:a.png]]\n"), in: 0..<20)
        #expect(Presentation.imagePlacements(links, in: "text\n") == [])
    }

    @Test func sizeKeepsProportionsWithinTheWidth() {
        let natural = CGSize(width: 400, height: 200)
        #expect(Presentation.imageSize(natural: natural, width: nil, maxWidth: 600) == CGSize(width: 400, height: 200))
        #expect(Presentation.imageSize(natural: natural, width: 100, maxWidth: 600) == CGSize(width: 100, height: 50))
        #expect(Presentation.imageSize(natural: natural, width: 800, maxWidth: 600) == CGSize(width: 600, height: 300))
        #expect(Presentation.imageSize(natural: natural, width: nil, maxWidth: 300) == CGSize(width: 300, height: 150))
        #expect(Presentation.imageSize(natural: .zero, width: nil, maxWidth: 300) == .zero)
    }

    @Test func fontSizeGivesALineAsTallAsTheImage() {
        // A 13-point font with a 16-point line: a 160-point image needs a 130-point font.
        #expect(Presentation.imageFontSize(height: 160, pointSize: 13, lineHeight: 16) == 130)
        #expect(Presentation.imageFontSize(height: 0, pointSize: 13, lineHeight: 16) == 0.01)
    }
}
