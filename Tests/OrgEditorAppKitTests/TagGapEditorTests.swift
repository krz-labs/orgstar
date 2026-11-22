import AppKit
import OrgCore
import Testing
@testable import OrgEditorAppKit

/// The spaces before a heading's tags, drawn as one gap that fits the view's width.
@MainActor
struct TagGapEditorTests {
    static func heading(_ title: String, _ tags: String, column: Int = 77) -> String {
        title + String(repeating: " ", count: max(1, column - title.count - tags.count)) + tags
    }

    func y(_ h: Harness, _ offset: Int) -> CGFloat {
        h.layout()
        return h.textView.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil).minY
    }

    func x(_ h: Harness, _ offset: Int) -> CGFloat {
        h.layout()
        return h.textView.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil).maxX
    }

    @Test func theGapIsAsWrittenInAWideViewAndFitsANarrowOne() async throws {
        let text = Self.heading("* TODO Call the office", ":office:") + "\n" + Self.heading("** A title long enough to need the line twice over in a narrow view", ":report:", column: 90) + "\nbody\n"
        let h = Harness(text)
        h.window.setContentSize(NSSize(width: 900, height: 800))
        h.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let ns = text as NSString
        let tags = ns.range(of: ":office:").location
        let storage = try #require(h.textView.textStorage)
        // Wide enough: the spaces stay as written.
        #expect(storage.attribute(.kern, at: tags - 1, effectiveRange: nil) == nil)
        #expect(y(h, tags) == y(h, 0))

        h.window.setContentSize(NSSize(width: 450, height: 800))
        h.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        // The tags at the right edge of the heading's line.
        #expect(y(h, tags) == y(h, 0))
        let container = try #require(h.textView.textContainer)
        let indent = (storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
        let lineStart = h.textView.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil).minX
        #expect(abs(x(h, tags + 7) - lineStart - (container.size.width - 2 * container.lineFragmentPadding - indent)) < 3)
        // A title that wraps: one space, and the tags whole on the last line.
        let report = ns.range(of: ":report:").location
        #expect(y(h, report) == y(h, report + 7))
        // Screen coordinates: lower lines have a smaller y.
        #expect(y(h, report) < y(h, ns.range(of: "** A").location))
        #expect(storage.string == text)
    }
}
