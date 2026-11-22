import Foundation
import Testing
@testable import OrgCore

/// `org-attach-expand-links` before HTML export.
struct AttachmentExportTests {
    static let text = """
        :PROPERTIES:
        :ID: 786d6b41-ff99
        :END:
        [[attachment:scan.pdf]]
        [[attachment:photo.jpg]]
        #+begin_example
        [[attachment:kept.png]]
        #+end_example

        * Task
        :PROPERTIES:
        :ID: aa11bb22-cc33
        :END:
        See [[attachment:in.png][the picture]].

        """

    @Test func attachmentLinksBecomeFileLinksIntoTheEntrysFolder() {
        let folder = "/notes/data/78/6d6b41-ff99"
        let expanded = ExportPreprocess.attachments(Self.text, path: "/notes/a.org", settings: .default) { $0 == folder }
        #expect(expanded.contains("[[file:\(folder)/scan.pdf]]\n[[file:\(folder)/photo.jpg]]\n"))
        // No link in an example block, and no folder for the second entry: the file's own.
        #expect(expanded.contains("[[attachment:kept.png]]"))
        #expect(expanded.contains("See [[file:/notes/in.png][the picture]]."))
    }

    @Test func htmlShowsAnAttachedImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-attach-\(UUID().uuidString)").standardizedFileURL
        let folder = root.appendingPathComponent("data/78/6d6b41-ff99")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let html = HTMLExport.page(Self.text, fallbackTitle: "t", path: root.appendingPathComponent("a.org").path, bodyOnly: true)
        // An absolute path, which is how this exporter writes a file link to one.
        #expect(html.contains("<a href=\"\(folder.path)/scan.pdf\">\(folder.path)/scan.pdf</a>"))
        #expect(html.contains("<img src=\"\(folder.path)/photo.jpg\" alt=\"photo.jpg\">"))
        #expect(html.contains("<a href=\"\(root.path)/in.png\">the picture</a>"))
    }
}
