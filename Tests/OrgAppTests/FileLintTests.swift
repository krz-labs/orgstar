import Foundation
import OrgCore
@testable import OrgIndex
import Testing
@testable import OrgApp

struct FileLintTests {
    @Test func idsResolveThroughTheIndexAndItsOverlay() async throws {
        let store = try IndexStore()
        try store.write(FileRecord(path: "/notes/a.org", root: "/notes", kind: .org, bytes: Array("* A\n:PROPERTIES:\n:ID: in-a\n:END:\n".utf8), mtime: 1, settings: IndexSettings()))
        // An unsaved buffer of b.org, in place of what the index has.
        let overlay = ["/notes/b.org": FileRecord(path: "/notes/b.org", root: "/notes", kind: .org, bytes: Array("* B\n:PROPERTIES:\n:ID: in-b\n:END:\n".utf8),
                                                  mtime: 2, settings: IndexSettings())]
        let text = "* Here\n:PROPERTIES:\n:ID: in-a\n:END:\n[[id:in-a]] [[id:in-b]]\n[[id:nowhere]]\n"
        let environment = FileLint.environment(index: store, overlay: overlay)
        let findings = await FileLint.lint(text, tree: OrgParser.parse(text), path: "/notes/here.org", environment: environment)
        #expect(findings.map(\.checker) == [.duplicateID, .invalidIDLink])
        #expect(findings.map(\.line) == [3, 6])
        #expect(findings.first?.message == "Duplicate ID \"in-a\", also in a.org")
    }

    @Test func settingsComeFromThePreferences() {
        let defaults = TestDefaults("FileLintTests")
        defaults.set("attach/", forKey: "attachIDDir")
        defaults.set("t", forKey: "attachUseInheritance")
        defaults.set("secret", forKey: "cryptTagMatcher")
        let environment = FileLint.environment(index: nil, defaults: defaults)
        #expect(environment.attachIDDir == "attach/")
        #expect(environment.attachInherit == true)
        #expect(environment.cryptTag == "secret")
        #expect(environment.idFiles == nil)
    }

    @Test func appliesToOrgFiles() {
        #expect(FileLint.applies(to: "/n/a.org"))
        #expect(FileLint.applies(to: "/n/a.org_archive"))
        #expect(FileLint.applies(to: "/n/a.org.gpg"))
        #expect(!FileLint.applies(to: "/n/a.md"))
        #expect(!FileLint.applies(to: nil))
    }

    @Test func summaries() {
        #expect(FileLint.summary([]) == "No problems found")
        let finding = LintFinding(offset: 0, line: 1, checker: .priority, message: "x")
        #expect(FileLint.summary([finding, finding]) == "2 problems")
        #expect(FileLint.severity(finding) == "Error")
        #expect(FileLint.severity(LintFinding(offset: 0, line: 1, checker: .timestampSyntax, message: "x")) == "Warning")
    }

    @Test func allFoldersGroupsByFileAndUsesOpenBuffers() async throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* A\n[[*Nowhere]]\n")
        let b = try notes.write("b.org", "* B\n")
        let c = try notes.write("sub/c.org", "* C\n[fn:1] unused\n")
        let paths = [a.path, b.path, c.path]
        let files = try await FileLint.lint(paths: paths, texts: [b.path: "* B\n#+BEGIN_SRC\n#+END_SRC\n"], environment: FileLint.environment(index: nil))
        #expect(files.map(\.path) == paths)
        #expect(files.map { $0.findings.map(\.checker) } == [[.invalidFuzzyLink], [.missingLanguageInSrcBlock], [.unreferencedFootnoteDefinition]])
        #expect(files[0].findings.first?.line == 2)
    }

    @Test func orphanedAttachmentFoldersAreReportedOnce() async throws {
        let notes = try Folder()
        let store = try IndexStore()
        var paths: [String] = []
        for name in ["a.org", "b.org", "c.org"] {
            let url = try notes.write(name, "* \(name)\n")
            try store.write(FileRecord(path: url.path, root: notes.url.path, kind: .org, bytes: Array("* \(name)\n".utf8), mtime: 1, settings: IndexSettings()))
            paths.append(url.path)
        }
        try FileManager.default.createDirectory(at: notes.url.appendingPathComponent("data/ab/cdef"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notes.url.appendingPathComponent("data/12/3456"), withIntermediateDirectories: true)
        // Each file alone lists both folders.
        let one = await FileLint.lint("* a\n", tree: OrgParser.parse("* a\n"), path: paths[1], environment: FileLint.environment(index: store))
        #expect(one.filter { $0.checker == .orphanedAttachmentFolder }.count == 2)
        let files = try await FileLint.lint(paths: paths, texts: [:], environment: FileLint.environment(index: store))
        #expect(files.map(\.path) == [paths[0]])
        #expect(files[0].findings.map(\.message) == ["Attachment folder \"data/12/3456\" belongs to no entry", "Attachment folder \"data/ab/cdef\" belongs to no entry"])
    }

    @Test func allFoldersLeavesOutEncryptedFiles() {
        let files = [
            FileEntry(path: "/n/b.org", root: "/n", kind: .org), FileEntry(path: "/n/a.org.gpg", root: "/n", kind: .org),
            FileEntry(path: "/n/a.org", root: "/n", kind: .org), FileEntry(path: "/n/old.org_archive", root: "/n", kind: .archive),
            FileEntry(path: "/n/a.sync-conflict-1.org", root: "/n", kind: .conflict), FileEntry(path: "/n/x.md", root: "/n", kind: .org),
            FileEntry(path: "/n/p.png", root: "/n", kind: .other)
        ]
        #expect(FileLint.folderPaths(files) == ["/n/a.org", "/n/b.org", "/n/old.org_archive"])
    }

    @Test func allFoldersNamesFilesBelowTheirFolder() {
        let one = [FileEntry(path: "/n/a.org", root: "/n", kind: .org), FileEntry(path: "/n/sub/b.org", root: "/n", kind: .org)]
        #expect(FileLint.names(one) == ["/n/a.org": "a.org", "/n/sub/b.org": "sub/b.org"])
        let two = one + [FileEntry(path: "/m/a.org", root: "/m", kind: .org)]
        #expect(FileLint.names(two) == ["/n/a.org": "n/a.org", "/n/sub/b.org": "n/sub/b.org", "/m/a.org": "m/a.org"])
    }

    @Test func allFoldersSkipsEncryptedEntries() async throws {
        let notes = try Folder()
        let text = "* Secret :crypt:\n-----BEGIN PGP MESSAGE-----\n\n[[*Nowhere]]\n-----END PGP MESSAGE-----\n* Open\n[[*Nowhere]]\n"
        let a = try notes.write("a.org", text)
        let files = try await FileLint.lint(paths: [a.path], texts: [:], environment: FileLint.environment(index: nil))
        #expect(files.first?.findings.map(\.line) == [7])
    }

    @Test func allFoldersStopsWhenCancelled() async throws {
        let notes = try Folder()
        let paths = try (0..<100).map { try notes.write("n\($0).org", "* N\n[[*Nowhere]]\n").path }
        let reports = Counter()
        let task = Task {
            try await FileLint.lint(paths: paths, texts: [:], environment: FileLint.environment(index: nil)) { _ in
                await reports.add()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await reports.count <= 1)
    }
}

private actor Counter {
    var count = 0
    func add() { count += 1 }
}
