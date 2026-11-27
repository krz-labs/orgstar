import CoreGraphics
import Foundation
import Observation
import OrgCore
import OrgPresentation

/// Present: the open file's slides (`SlideShow`) and the one showing, for the full-screen
/// presentation on the Mac and iOS and an iPad's external display.
@MainActor @Observable
public final class SlideDeck {
    public let tree: OrgTree
    /// The file's path, for images.
    public let path: String
    public let slides: [SlideShow.Slide]
    public private(set) var index: Int

    /// Nil when the file has nothing to show. Starts at the slide of the heading at `caret`.
    public init?(tree: OrgTree, path: String, settings: OrgSettings = .default, caret: Int = 0) {
        let slides = SlideShow.slides(tree, settings: settings)
        guard !slides.isEmpty else { return nil }
        self.tree = tree
        self.path = path
        self.slides = slides
        index = slides.lastIndex { ($0.start ?? 0) <= caret } ?? 0
    }

    public var slide: SlideShow.Slide { slides[index] }
    /// The slide after this one, for the presenter's screen.
    public var upcoming: SlideShow.Slide? { index + 1 < slides.count ? slides[index + 1] : nil }
    public var directory: URL { URL(fileURLWithPath: path).deletingLastPathComponent() }
    /// "3 / 12".
    public var position: String { "\(index + 1) / \(slides.count)" }

    public func next() { index = min(index + 1, slides.count - 1) }
    public func previous() { index = max(index - 1, 0) }
    public func first() { index = 0 }
    public func last() { index = slides.count - 1 }

    /// The body text's size in points on a screen of `size`: about 40 columns across and 18
    /// lines down at most, and never below 1.25 times the theme's own size.
    public nonisolated static func bodySize(for size: CGSize, themeSize: Int) -> CGFloat {
        max(CGFloat(themeSize) * 1.25, min(size.width / 40, size.height / 18))
    }
}
