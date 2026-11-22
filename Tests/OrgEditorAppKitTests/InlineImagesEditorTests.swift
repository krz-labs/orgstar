import AppKit
import OrgCore
@testable import OrgEditorAppKit
import Testing

@MainActor
struct InlineImagesEditorTests {
    static let filler = String(repeating: "word ", count: 40)
    static let text = "* Images\n\(filler)[[file:pic.png]] \(filler)\n[[file:pic.png]]\n| a | [[file:pic.png]] | [[./pic.png]] |\n"
        + "Described [[file:pic.png][a figure]] here\nMissing [[file:missing.png]] here\n"

    /// A folder holding `pic.png`, 100 by 60 points.
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("pic.png"))
        return folder
    }

    static func harness(_ folder: URL) -> Harness {
        let h = Harness(text)
        h.editor.baseDirectory = folder
        return h
    }

    static func box(_ h: Harness, at offset: Int) -> InlineImageBox? {
        h.textView.textStorage?.attribute(.orgImage, at: offset, effectiveRange: nil) as? InlineImageBox
    }

    static func fragment(_ h: Harness, at offset: Int) -> NSTextLayoutFragment? {
        h.layout()
        let manager = h.editor.textLayoutManager
        let content = manager.textContentManager!
        guard let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        return manager.textLayoutFragment(for: location)
    }

    @Test func anImageInWrappedTextMakesOnlyItsLineTall() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let h = Self.harness(folder)
        let ns = Self.text as NSString
        let link = ns.range(of: "[[file:pic.png]]")
        #expect(Self.box(h, at: link.location) == nil)
        h.editor.run("org.toggle-inline-images")

        let box = try #require(Self.box(h, at: link.location))
        #expect(box.inText && !box.below && box.size == CGSize(width: 100, height: 60))
        #expect(Self.box(h, at: link.location + 1) == nil)
        let fragment = try #require(Self.fragment(h, at: link.location) as? ImageFragment)
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        #expect(lines.count > 2)
        let tall = lines.filter { $0.typographicBounds.height >= 59 }
        #expect(tall.count == 1 && NSLocationInRange(link.location - NSMaxRange(ns.lineRange(for: NSRange(location: 0, length: 0))), tall[0].characterRange))
        #expect(lines.filter { $0.typographicBounds.height < 30 }.count == lines.count - 1)
        // The image covers the link's place: from its first character, 100 points wide, in the tall line.
        let frame = try #require(ImageFragment.frames(of: fragment).first).frame
        let bounds = tall[0].typographicBounds
        #expect(frame.width == 100 && frame.height == 60)
        #expect(frame.minY >= bounds.minY - 1 && frame.maxY <= bounds.maxY + 1)
        let start = tall[0].locationForCharacter(at: tall[0].characterRange.location + 0).x
        #expect(frame.minX >= bounds.minX + start)
        let paragraphStart = NSMaxRange(ns.lineRange(for: NSRange(location: 0, length: 0)))
        let before = tall[0].locationForCharacter(at: link.location - paragraphStart).x
        let after = tall[0].locationForCharacter(at: NSMaxRange(link) - paragraphStart).x
        #expect(abs(after - before - 100) < 1)
    }

    @Test func theCaretsLineShowsTheLinkWithTheImageUnderIt() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let h = Self.harness(folder)
        let ns = Self.text as NSString
        let link = ns.range(of: "[[file:pic.png]]")
        h.editor.run("org.toggle-inline-images")
        h.caret(at: link.location + 3)
        h.editor.revealCaretLine()

        let box = try #require(Self.box(h, at: link.location))
        #expect(box.inText && box.below)
        let storage = try #require(h.textView.textStorage)
        #expect(storage.attribute(.kern, at: link.location, effectiveRange: nil) == nil)
        let fragment = try #require(Self.fragment(h, at: link.location) as? ImageFragment)
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        #expect(lines.allSatisfy { $0.typographicBounds.height < 30 })
        let frame = try #require(ImageFragment.frames(of: fragment).first).frame
        #expect(frame.minY >= lines.last!.typographicBounds.maxY)
        #expect(fragment.layoutFragmentFrame.height >= frame.maxY)

        // Away again, the image is back in the text.
        h.caret(at: 0)
        h.editor.revealCaretLine()
        #expect(Self.box(h, at: link.location)?.below == false)
    }

    @Test func aLinkAloneKeepsItsLineAndATableRowShowsEachImage() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let h = Self.harness(folder)
        let ns = Self.text as NSString
        h.editor.run("org.toggle-inline-images")

        let alone = ns.range(of: "\n[[file:pic.png]]\n").location + 1
        let box = try #require(Self.box(h, at: alone))
        #expect(!box.inText && !box.below)
        #expect(Self.box(h, at: alone + 5) === box)

        let row = ns.range(of: "| a |").location
        let fragment = try #require(Self.fragment(h, at: row) as? ImageFragment)
        let frames = ImageFragment.frames(of: fragment).map(\.frame)
        #expect(frames.count == 2 && frames[1].minX >= frames[0].maxX)
        #expect(fragment.textLineFragments[0].typographicBounds.height >= 59)
    }

    @Test func describedLinksNeedTheirCommandAndMissingFilesStayLinks() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let h = Self.harness(folder)
        let ns = Self.text as NSString
        let described = ns.range(of: "[[file:pic.png][a figure]]").location
        let missing = ns.range(of: "[[file:missing.png]]").location
        var messages: [String] = []
        h.editor.onMessage = { messages.append($0) }

        h.editor.run("org.toggle-inline-images")
        #expect(Self.box(h, at: described) == nil && Self.box(h, at: missing) == nil)
        h.editor.run("org.toggle-inline-images-linked")
        #expect(!h.editor.showsImages && Self.box(h, at: ns.range(of: "[[file:pic.png]]").location) == nil)
        h.editor.run("org.toggle-inline-images-linked")
        #expect(h.editor.showsImages && Self.box(h, at: described)?.inText == true && Self.box(h, at: missing) == nil)
        #expect(messages == ["4 images displayed inline", "Inline image display turned off", "5 images displayed inline"])
    }
}
