import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp
@testable import OrgPrograms

@Suite(.enabled(if: git != nil, "git isn't installed"))
struct FileHistoryTests {
    @Test func commitsFollowARename() async throws {
        let repo = try await Repository()
        try repo.folder.write("old.org", "* One\n")
        try await repo.commitAll("First")
        try await repo.run("mv", "old.org", "new.org")
        try await repo.commitAll("Rename")
        try repo.folder.write("new.org", "* One\n* Two\n")
        try repo.folder.write("other.org", "x\n")
        try await repo.commitAll("Second")

        let commits = await GitHistory.commits(for: repo.url.appendingPathComponent("new.org"), git: git)
        #expect(commits.map(\.subject) == ["Second", "Rename", "First"])
        #expect(commits.map(\.path) == ["new.org", "new.org", "old.org"])
        #expect(commits.allSatisfy { $0.author == "Test" && $0.hash.count == 40 })
        #expect(await GitHistory.text(of: commits[2], git: git) == "* One\n")
        #expect(await GitHistory.commits(for: repo.url.appendingPathComponent("missing.org"), git: git).isEmpty)
        let outside = try Folder()
        #expect(await GitHistory.commits(for: outside.url.appendingPathComponent("a.org"), git: git).isEmpty)
    }

    @Test func recoveryVersionsAndCommitsByDate() {
        let commit = { (hash: String, seconds: TimeInterval) in
            FileHistory.Commit(hash: hash, date: Date(timeIntervalSince1970: seconds), author: "A", subject: hash, path: "a.org", repository: URL(fileURLWithPath: "/r"))
        }
        let recovery = [(url: URL(fileURLWithPath: "/k/2"), date: Date(timeIntervalSince1970: 200), label: "snapshot"),
                        (url: URL(fileURLWithPath: "/k/1"), date: Date(timeIntervalSince1970: 50), label: "local")]
        let merged = FileHistory.merged(recovery: recovery, commits: [commit("c3", 300), commit("c1", 100)])
        #expect(merged.map(\.date.timeIntervalSince1970) == [300, 200, 100, 50])
        #expect(merged[1] == .recovery(url: URL(fileURLWithPath: "/k/2"), date: Date(timeIntervalSince1970: 200), label: "snapshot"))
    }

    @MainActor
    @Test func restoringACommitIsAnEdit() async throws {
        let repo = try await Repository()
        try repo.folder.write("a.org", "* A\nfirst\n")
        try await repo.commitAll("First")
        let file = try repo.folder.write("a.org", "* A\nnow\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: repo.url.appendingPathComponent(".git/r")))
        session.open(file.path)
        let commits = await GitHistory.commits(for: file, git: git)
        let first = try #require(commits.first)
        let text = try #require(await GitHistory.text(of: first, git: git))
        #expect(session.restore(text: text) == nil)
        #expect(session.document?.text == "* A\nfirst\n")
        #expect(session.isDirty)
        // The buffer as it was went to recovery; the file on disk is unchanged until saved.
        #expect(session.recoveryVersions().contains { session.recoveryText($0.url) == "* A\nnow\n" })
        #expect(try String(contentsOf: file, encoding: .utf8) == "* A\nnow\n")
    }
}
