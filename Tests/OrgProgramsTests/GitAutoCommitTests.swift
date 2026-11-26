import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp
@testable import OrgPrograms

let git = Git.find()

/// A repository in a temporary folder, with its own identity and no signing, hooks or
/// credential helper from the user's configuration.
struct Repository {
    let folder: Folder
    var url: URL { folder.url }

    init(_ folder: Folder = try! Folder(), clone remote: URL? = nil) async throws {
        self.folder = folder
        if let remote {
            try await run("clone", "-q", remote.path, ".")
        } else {
            try await run("init", "-q", "-b", "main")
        }
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.com"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("credential.helper", "")] {
            try await run("config", key, value)
        }
    }

    @discardableResult
    func run(_ arguments: String...) async throws -> String {
        let output = try await git!.run(arguments, in: url)
        guard output.succeeded else { throw Git.Failure(description: "git \(arguments.joined(separator: " ")): \(output.problem)") }
        return output.stdout
    }

    func commitAll(_ message: String) async throws {
        try await run("add", "-A")
        try await run("commit", "-q", "-m", message)
    }

    func head() async throws -> String { try await run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
}

/// A bare repository and two clones of it, the first with `a.org` and `b.org` pushed.
private func remoteAndClones() async throws -> (remote: Folder, mine: Repository, theirs: Repository) {
    let remote = try Folder()
    _ = try await git!.run(["init", "-q", "--bare", "-b", "main"], in: remote.url)
    let mine = try await Repository(clone: remote.url)
    try mine.folder.write("a.org", "* A\n")
    try mine.folder.write("b.org", "* B\n")
    try await mine.commitAll("Start")
    try await mine.run("push", "-q", "-u", "origin", "main")
    let theirs = try await Repository(clone: remote.url)
    return (remote, mine, theirs)
}

@Suite(.enabled(if: git != nil, "git isn't installed"))
struct GitAutoCommitTests {
    @Test func commitsOnlyTheFilesOrgstarWrote() async throws {
        let repo = try await Repository()
        try repo.folder.write("a.org", "* A\n")
        try repo.folder.write("b.org", "* B\n")
        try await repo.commitAll("Start")
        try repo.folder.write("a.org", "* A\nsaved by orgstar\n")
        try repo.folder.write("b.org", "* B\nsomeone's work in progress\n")
        try repo.folder.write("c.txt", "staged by hand\n")
        try await repo.run("add", "c.txt")
        try repo.folder.write("sub/new.org", "* New\n")

        let outcome = await GitAutoCommit.run(files: [repo.path("a.org"), repo.path("sub/new.org")], pullAndPush: false, git: git!)
        #expect(outcome.committed.sorted() == ["a.org", "sub/new.org"])
        #expect(outcome.messages == ["Committed a.org, new.org in \(repo.url.resolvingSymlinksInPath().lastPathComponent)."])
        #expect(try await repo.run("show", "--name-only", "--format=%s", "HEAD") == "Update a.org, new.org\n\na.org\nsub/new.org\n")
        // The other changes are where they were: b.org modified, c.txt staged.
        #expect(try await repo.run("status", "--porcelain") == " M b.org\nA  c.txt\n")
    }

    @Test func nothingChangedIsNotCommitted() async throws {
        let repo = try await Repository()
        try repo.folder.write("a.org", "* A\n")
        try await repo.commitAll("Start")
        let head = try await repo.head()
        let outcome = await GitAutoCommit.run(files: [repo.path("a.org")], pullAndPush: false, git: git!)
        #expect(outcome == GitAutoCommit.Outcome())
        #expect(try await repo.head() == head)
    }

    @Test func noCommitWhileARebaseIsInProgress() async throws {
        let repo = try await Repository()
        try repo.folder.write("a.org", "* A\n")
        try await repo.commitAll("Start")
        let head = try await repo.head()
        try FileManager.default.createDirectory(at: repo.url.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true)
        try repo.folder.write("a.org", "* A\nchanged\n")

        let outcome = await GitAutoCommit.run(files: [repo.path("a.org")], pullAndPush: true, git: git!)
        #expect(outcome.committed.isEmpty)
        #expect(outcome.retry == [repo.path("a.org")])
        #expect(outcome.messages.count == 1 && outcome.messages[0].contains("a git rebase is in progress"))
        #expect(try await repo.head() == head)
        #expect(Git.operationInProgress(repo.url.appendingPathComponent(".git")) == "rebase")
    }

    @Test func pullsCommitsAndPushes() async throws {
        let (remote, mine, theirs) = try await remoteAndClones()
        try theirs.folder.write("b.org", "* B\nfrom the other Mac\n")
        try await theirs.commitAll("Theirs")
        try await theirs.run("push", "-q")
        try mine.folder.write("a.org", "* A\nmine\n")

        let outcome = await GitAutoCommit.run(files: [mine.path("a.org")], pullAndPush: true, git: git!)
        #expect(outcome.committed == ["a.org"] && outcome.pushed)
        #expect(outcome.messages.first?.hasPrefix("Committed and pushed a.org") == true)
        // A fast-forward pull, then our commit on top: no merge commit.
        #expect(try await mine.run("log", "--format=%s", "-3") == "Update a.org\nTheirs\nStart\n")
        let remoteHead = try await git!.run(["rev-parse", "main"], in: remote.url).stdout
        #expect(remoteHead == (try await mine.run("rev-parse", "HEAD")))
    }

    @Test func refusedFastForwardIsReportedAndNothingIsPushed() async throws {
        let (remote, mine, theirs) = try await remoteAndClones()
        try theirs.folder.write("b.org", "* B\ntheirs\n")
        try await theirs.commitAll("Theirs")
        try await theirs.run("push", "-q")
        let remoteHead = try await git!.run(["rev-parse", "main"], in: remote.url).stdout
        // A commit of mine the remote doesn't have: the histories have diverged.
        try mine.folder.write("b.org", "* B\nmine, by hand\n")
        try await mine.commitAll("Mine")
        try mine.folder.write("a.org", "* A\nsaved\n")

        let outcome = await GitAutoCommit.run(files: [mine.path("a.org")], pullAndPush: true, git: git!)
        #expect(!outcome.pushed)
        // Committed here; the pull left the repository as it was, with no merge.
        #expect(outcome.committed == ["a.org"])
        let message = try #require(outcome.messages.first)
        #expect(message.contains("Couldn't pull in") && message.contains("Not possible to fast-forward") && message.contains("Not pushed"))
        #expect(try await mine.run("log", "--format=%s", "-3") == "Update a.org\nMine\nStart\n")
        #expect(Git.operationInProgress(mine.url.appendingPathComponent(".git")) == nil)
        #expect(try await git!.run(["rev-parse", "main"], in: remote.url).stdout == remoteHead)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func credentialsAreNeverPromptedFor() async throws {
        // A server that wants a password for everything.
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", """
            import http.server
            class H(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(401)
                    self.send_header('WWW-Authenticate', 'Basic realm="x"')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                def log_message(self, *a): pass
            s = http.server.HTTPServer(('127.0.0.1', 0), H)
            print(s.server_port, flush=True)
            s.serve_forever()
            """]
        let out = Pipe()
        server.standardOutput = out
        try server.run()
        defer { server.terminate() }
        let port = try #require(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).split(separator: "\n").first)
        let repo = try await Repository()
        try repo.folder.write("a.org", "* A\n")
        try await repo.commitAll("Start")
        try await repo.run("remote", "add", "origin", "http://127.0.0.1:\(port)/notes.git")
        try await repo.run("config", "branch.main.remote", "origin")
        try await repo.run("config", "branch.main.merge", "refs/heads/main")
        try repo.folder.write("a.org", "* A\nchanged\n")

        let start = ContinuousClock.now
        let outcome = await GitAutoCommit.run(files: [repo.path("a.org")], pullAndPush: true, git: git!, networkTimeout: .seconds(20))
        #expect(ContinuousClock.now - start < .seconds(15))
        #expect(!outcome.pushed)
        let message = try #require(outcome.messages.first)
        #expect(message.contains("couldn't sign in"), "\(message)")
    }

    @MainActor
    @Test func commitsAMinuteAfterTheLastWriteAndOnQuit() async throws {
        let repo = try await Repository()
        try repo.folder.write("a.org", "* A\n")
        try repo.folder.write("b.org", "* B\n")
        try await repo.commitAll("Start")
        let start = try await repo.head()
        let defaults = try #require(UserDefaults(suiteName: "orgstar-git-\(UUID().uuidString)"))
        let settings = GitFolderSettings(defaults: defaults)
        settings.set(.commit, for: repo.url.path)
        let elsewhere = try Folder()
        settings.set(.commit, for: elsewhere.url.path)
        let autoCommit = GitAutoCommit(settings: settings)
        autoCommit.git = git
        autoCommit.delay = .milliseconds(600)
        autoCommit.roots = { [repo.url.path] }
        var reports: [String] = []
        autoCommit.report = { reports.append($0) }

        try repo.folder.write("a.org", "* A\none\n")
        autoCommit.fileWritten(repo.path("a.org"))
        // Outside every sidebar folder: not tracked.
        try elsewhere.write("x.org", "x\n")
        autoCommit.fileWritten(elsewhere.url.appendingPathComponent("x.org").path)
        try await Task.sleep(for: .milliseconds(300))
        try repo.folder.write("a.org", "* A\none\ntwo\n")
        autoCommit.fileWritten(repo.path("a.org"))
        try await Task.sleep(for: .milliseconds(300))
        // The second write pushed the commit back.
        #expect(try await repo.head() == start)
        var tries = 0
        while try await repo.head() == start, tries < 100 {
            try await Task.sleep(for: .milliseconds(100))
            tries += 1
        }
        #expect(try await repo.run("log", "--format=%s", "-2") == "Update a.org\nStart\n")
        #expect(reports.count == 1 && reports[0].hasPrefix("Committed a.org"))
        #expect(!autoCommit.hasPending)

        // Quitting commits what is waiting without the delay.
        autoCommit.delay = .seconds(600)
        try repo.folder.write("b.org", "* B\nbefore quitting\n")
        autoCommit.fileWritten(repo.path("b.org"))
        #expect(autoCommit.hasPending)
        await autoCommit.flush()
        #expect(try await repo.run("log", "--format=%s", "-1") == "Update b.org\n")

        // Off: nothing is tracked.
        settings.set(.off, for: repo.url.path)
        autoCommit.fileWritten(repo.path("b.org"))
        #expect(!autoCommit.hasPending)
    }

    @MainActor
    @Test func sessionReportsEachWrite() throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* A\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        var written: [String] = []
        session.fileWritten = { written.append($0) }
        session.open(file.path)
        #expect(session.save())
        #expect(written.isEmpty)
        let text = session.document!.text
        _ = session.perform(PrecomputedEdit(EditResult(baseRevision: session.document!.revision, edits: lineEdits(from: text, to: text + "more\n"))),
                            path: file.path, at: 0, expect: nil)
        #expect(session.save())
        #expect(written == [file.path])
    }
}
