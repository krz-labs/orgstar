import Foundation
import Testing
@testable import OrgApp

struct WorkingCopyTests {
    @Test func syncChainsCommitPullAndPush() throws {
        let url = WorkingCopy.syncURL(repo: "my notes", key: "k3y+/&=", message: "Update from orgstar")
        #expect(url.scheme == "working-copy")
        #expect(url.host == "x-callback-url")
        #expect(url.path == "/chain")
        let query = try #require(url.query(percentEncoded: true))
        // Spaces as %20, never +, and reserved characters encoded.
        #expect(!query.contains("+"))
        #expect(query.hasPrefix("repo=my%20notes&key=k3y%2B%2F%26%3D&x-success="))
        #expect(query.hasSuffix("&command=commit&message=Update%20from%20orgstar&limit=999&command=pull&command=push"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["repo", "key", "x-success", "x-error", "command", "message", "limit", "command", "command"])
        #expect(items.filter { $0.name == "command" }.map(\.value) == ["commit", "pull", "push"])
        #expect(items.first { $0.name == "key" }?.value == "k3y+/&=")
        #expect(items.first { $0.name == "x-success" }?.value == "orgstar://working-copy/success?repo=my%20notes")
        #expect(items.first { $0.name == "x-error" }?.value == "orgstar://working-copy/error?repo=my%20notes")
    }

    @Test func callbacksComeBackParsed() throws {
        let success = try #require(URL(string: "orgstar://working-copy/success?repo=my%20notes"))
        #expect(WorkingCopy.callback(success) == .success(repo: "my notes"))
        // Working Copy adds x-callback-url's errorCode and errorMessage.
        let error = try #require(URL(string: "orgstar://working-copy/error?repo=my%20notes&errorCode=1&errorMessage=Merge%20conflict%20in%20a.org"))
        #expect(WorkingCopy.callback(error) == .failure(repo: "my notes", message: "Merge conflict in a.org"))
        let bare = try #require(URL(string: "orgstar://working-copy/error?repo=notes"))
        #expect(WorkingCopy.callback(bare) == .failure(repo: "notes", message: nil))
        // The callback the sync asks for, as Working Copy would open it.
        let built = WorkingCopy.syncURL(repo: "a&b", key: "k")
        let back = try #require(URLComponents(url: built, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "x-success" }?.value)
        #expect(WorkingCopy.callback(try #require(URL(string: back))) == .success(repo: "a&b"))
        // Other links aren't callbacks.
        #expect(WorkingCopy.callback(try #require(URL(string: "orgstar://agenda"))) == nil)
        #expect(WorkingCopy.callback(try #require(URL(string: "orgstar://working-copy/other?repo=a"))) == nil)
        #expect(WorkingCopy.callback(try #require(URL(string: "orgstar://working-copy/success"))) == nil)
        #expect(AppLink(url: success) == nil)
    }

    @Test func foldersAreKeptByRootAndFoundByRepository() {
        let defaults = TestDefaults("WorkingCopyTests")
        let folders = WorkingCopy.Folders(defaults: defaults)
        #expect(folders.folder("/notes") == nil)
        folders.set(WorkingCopy.Folder(repository: "notes"), for: "/notes")
        folders.set(WorkingCopy.Folder(repository: "work", syncOnOpen: true), for: "/w")
        #expect(WorkingCopy.Folders(defaults: defaults).folder("/notes") == WorkingCopy.Folder(repository: "notes", syncOnOpen: false))
        #expect(folders.root(of: "work") == "/w")
        #expect(folders.root(of: "nope") == nil)
        folders.set(nil, for: "/notes")
        #expect(folders.all.keys.sorted() == ["/w"])
    }

    @Test func aGitFolderIsARepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(!WorkingCopy.isRepository(root.path))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(WorkingCopy.isRepository(root.path))
    }
}
