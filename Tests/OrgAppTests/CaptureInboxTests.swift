import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

struct CaptureInboxTests {
    @Test func keepsLinksOldestFirstUntilRemoved() throws {
        let folder = try Folder()
        let inbox = CaptureInbox(folder: folder.url.appendingPathComponent("Captures"))
        #expect(inbox.links() == [])
        try inbox.add("org-protocol://capture?body=one")
        try inbox.add("org-protocol://capture?body=two")
        let links = inbox.links()
        #expect(links.map(\.text) == ["org-protocol://capture?body=one", "org-protocol://capture?body=two"])
        // Another instance, as after the app was ended with both queued.
        #expect(CaptureInbox(folder: inbox.folder).links() == links)
        inbox.remove(links[0])
        #expect(inbox.links().map(\.text) == ["org-protocol://capture?body=two"])
        inbox.remove(links[1])
        #expect(inbox.links() == [])
    }

    @Test func keepsALinkItCannotRead() throws {
        let folder = try Folder()
        let inbox = CaptureInbox(folder: folder.url.appendingPathComponent("Captures"))
        try inbox.add("org-protocol://capture?body=one")
        let notText = inbox.folder.appendingPathComponent("0-not-text.link")
        try Data([0xFF, 0xFE, 0xFD]).write(to: notText)
        let directory = inbox.folder.appendingPathComponent("1-directory.link")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(inbox.links().map(\.text) == ["org-protocol://capture?body=one"])
        #expect(FileManager.default.fileExists(atPath: notText.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func keepsTheTemplateList() throws {
        let folder = try Folder()
        let inbox = CaptureInbox(folder: folder.url.appendingPathComponent("Captures"))
        #expect(inbox.templates() == [])
        let templates = [CaptureInbox.Template(key: "t", name: "Task"), CaptureInbox.Template(key: "w", name: "Web page")]
        try inbox.setTemplates(templates)
        #expect(inbox.templates() == templates)
    }
}

@MainActor
struct CaptureWithoutWindowTests {
    @Test func filesWithTheKeyedTemplateAndDefaultAnswers() async throws {
        let notes = try Folder()
        let todo = try notes.write("todo.org", "* Inbox\n")
        let workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        let clock = ClockModel(file: notes.url.appendingPathComponent("clock.json"))
        let templates = [
            CaptureTemplates.defaults[0],
            CaptureTemplate(key: "x", name: "Errand", target: .headline(file: "todo.org", headline: "Inbox"), template: "* TODO %^{What|Buy milk}\n%i"),
        ]
        let chosen = session.capture("from the share sheet", templateKey: "x", templates: templates, workspace: workspace, clock: clock, clipboard: "", userName: "")
        #expect((try? chosen.get())?.key == "x")
        #expect(try String(contentsOf: todo, encoding: .utf8) == "* Inbox\n** TODO Buy milk\nfrom the share sheet\n")

        let missing = session.capture("x", templateKey: "nope", templates: templates, workspace: workspace, clock: clock, clipboard: "", userName: "")
        guard case .failure(let error) = missing else { Issue.record("filed with a missing template"); return }
        #expect(error.message == "No capture template \"nope\"")
    }
}
