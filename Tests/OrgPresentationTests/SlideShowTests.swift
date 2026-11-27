import Foundation
import OrgCore
import Testing
@testable import OrgPresentation

struct SlideShowTests {
    static let file = """
        #+TITLE: Talk
        #+AUTHOR: Ann
        Opening line.
        * TODO First :tag:
        SCHEDULED: <2026-11-26 Thu>
        :PROPERTIES:
        :ID: x
        :END:
        Body text.
        #+BEGIN_NOTES
        Say hello.
        #+END_NOTES
        [[file:pic.png]]
        After.
        ** Child
        - item
        * Hidden :noexport:
        ** Under hidden
        * COMMENT Draft
        * Last

        """

    static func shown(_ piece: SlideShow.Slide.Piece, _ text: String) -> String {
        switch piece {
        case .text(let range): (text as NSString).substring(with: NSRange(range))
        case .image(let path, _): "image " + path
        }
    }

    @Test func oneSlidePerHeadingAfterTheTitle() {
        let tree = OrgParser.parse(Self.file)
        let slides = SlideShow.slides(tree)
        #expect(slides.count == 4)
        #expect(slides[0].title == "Talk")
        #expect(slides[0].byline == ["Ann"])
        #expect(slides[0].pieces.map { Self.shown($0, Self.file) } == ["Opening line."])
        let first = slides[1]
        #expect(first.heading.map { (Self.file as NSString).substring(with: NSRange($0)) } == "TODO First")
        #expect(first.level == 1)
        #expect(first.pieces.map { Self.shown($0, Self.file) } == ["Body text.\n", "image pic.png", "After."])
        #expect(first.notes == "Say hello.")
        #expect(slides[2].heading.map { (Self.file as NSString).substring(with: NSRange($0)) } == "Child")
        #expect(slides[2].pieces.map { Self.shown($0, Self.file) } == ["- item"])
        #expect(slides[3].heading.map { (Self.file as NSString).substring(with: NSRange($0)) } == "Last")
        #expect(slides[3].pieces.isEmpty)
    }

    @Test func noTitleSlideWithoutTitleOrText() {
        let slides = SlideShow.slides(OrgParser.parse("* A\n* B\n"))
        #expect(slides.map(\.start) == [0, 4])
    }
}
