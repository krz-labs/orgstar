import Foundation
import OrgCore
@testable import OrgPresentation
import Testing

@MainActor
struct RemoteImagesTests {
    final class Counter: @unchecked Sendable {
        var calls = 0
    }

    @Test func linksNeedTheSetting() {
        let text = "[[https://example.com/a.png]]\n[[ftp://example.com/b.png]]\n[[file:c.png]]\n"
        let tree = OrgParser.parse(text)
        #expect(InlineImages.links(tree, in: 0..<75).map(\.image.path) == ["c.png"])
        #expect(InlineImages.links(tree, in: 0..<75, remote: true).map(\.image.path) == ["https://example.com/a.png", "c.png"])
    }

    @Test func downloadsOnceAndCaches() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let counter = Counter()
        let images = RemoteImages(directory: folder) { url in
            counter.calls += 1
            if url.lastPathComponent == "missing.png" { throw URLError(.badServerResponse) }
            return Data("image".utf8)
        }
        let url = URL(string: "https://example.com/a.png")!
        #expect(images.data(for: url, mode: .skip) {} == nil)
        var arrived = false
        #expect(images.data(for: url, mode: .cache) { arrived = true } == nil)
        #expect(images.data(for: url, mode: .cache) {} == nil)
        while !arrived { try await Task.sleep(for: .milliseconds(10)) }
        #expect(images.data(for: url, mode: .cache) {} == Data("image".utf8))
        #expect(counter.calls == 1)
        // A new run reads the cached copy.
        let again = RemoteImages(directory: folder) { _ in Issue.record("fetched again"); return Data() }
        #expect(again.data(for: url, mode: .cache) {} == Data("image".utf8))
        #expect(again.data(for: url, mode: .download) {} == Data("image".utf8))

        let missing = URL(string: "https://example.com/missing.png")!
        var done = false
        #expect(images.data(for: missing, mode: .download) { done = true } == nil)
        while !done { try await Task.sleep(for: .milliseconds(10)) }
        #expect(images.data(for: missing, mode: .download) {} == nil)
        #expect(counter.calls == 2)
        #expect(images.version == 2)
        #expect(images.data(for: URL(string: "file:///tmp/a.png")!, mode: .cache) {} == nil)
    }
}
