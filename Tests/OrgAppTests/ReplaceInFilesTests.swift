import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// Replace in Files and the renames over a folder: files on disk and open buffers, unticked
/// changes, recovery versions, config.toml, refusals and cancelling.
@MainActor
struct ReplaceInFilesTests {
    let notes: Folder
    let other: Folder
    let recovery: Folder
    let workspace: WorkspaceModel
    let session: DocumentSession
    /// config.toml's settings as `Config.set` leaves them.
    final class ConfigBox {
        var todoKeywords = "TODO NEXT | DONE"
        var tagAlist = "work(w) home"
        var writes: [String: String] = [:]
    }
    let config = ConfigBox()

    init() async throws {
        notes = try Folder()
        other = try Folder()
        recovery = try Folder()
        workspace = try WorkspaceModel(directory: nil)
        session = DocumentSession(recovery: FileRecoveryStore(directory: recovery.url))
        session.saveMode = .explicit
    }

    func model() -> ReplaceInFiles {
        let box = config
        return ReplaceInFiles(session: session, workspace: workspace, config: ReplaceInFiles.Config(todoKeywords: box.todoKeywords, tagAlist: box.tagAlist) { key, value in
            box.writes[key] = value
        })
    }

    /// The indexed path of `name` in `folder`.
    func path(_ name: String, in folder: Folder? = nil) throws -> String {
        let root = (folder ?? notes).url.lastPathComponent
        return try #require(workspace.files.first { $0.path.hasSuffix(root + "/" + name) }?.path)
    }

    func disk(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    func search(_ model: ReplaceInFiles, _ mode: ReplaceInFiles.Mode, scope: String? = nil, includeConfig: Bool = true) async {
        model.start(mode, scope: scope, includeConfig: includeConfig)
        await model.waitForSearch()
    }

    @Test func replacesInFilesAndOpenBuffers() async throws {
        try notes.write("a.org", "* foo\nFoo and foo\n")
        try notes.write("b.org", "foo\n")
        try notes.write("c.txt", "foo\n")
        try notes.write("d.png", "foo\n")
        try notes.write("s.org.gpg", "foo\n")
        try notes.write("none.org", "nothing here\n")
        try other.write("e.org", "foo\n")
        try await workspace.addRoot(notes.url)
        try await workspace.addRoot(other.url)
        let a = try path("a.org"), b = try path("b.org"), c = try path("c.txt"), e = try path("e.org", in: other)

        // b.org is open with an unsaved edit, which the search sees.
        session.open(b)
        let doc = try #require(session.document(of: b))
        _ = session.perform(PrecomputedEdit(EditResult(baseRevision: doc.revision, edits: [TextEdit(range: 0..<0, replacement: "typed foo\n")])), path: b, at: 0, expect: nil)
        #expect(session.isDirty)

        let model = model()
        await search(model, .replace(TextReplace(pattern: "foo", replacement: "bar")), scope: workspace.files.first { $0.path == a }?.root)
        #expect(model.progress.done == model.progress.total)
        #expect(model.files.map(\.path) == [a, b, c])
        #expect(model.files[0].changes.map(\.line) == [1, 2, 2])
        #expect(model.files[0].changes.map(\.replacement) == ["bar", "Bar", "bar"])
        #expect(model.files[1].changes.count == 2)

        // Untick the second change in a.org.
        model.setTicked(false, change: 1, in: a)
        #expect(model.tickedCount == 5)
        let summary = model.apply()
        #expect(summary == "Files changed: 3")
        #expect(try disk(a) == "* bar\nFoo and bar\n")
        #expect(try disk(c) == "bar\n")
        #expect(try disk(e) == "foo\n")
        #expect(try disk(notes.url.appendingPathComponent("s.org.gpg").path) == "foo\n")

        // The open buffer took it as one undoable change and stays unsaved; the disk is as it was.
        #expect(session.document(of: b)?.text == "typed bar\nbar\n")
        #expect(session.isDirty)
        #expect(try disk(b) == "foo\n")
        var undone = try #require(session.document(of: b))
        _ = undone.undo()
        #expect(undone.text == "typed foo\nfoo\n")

        // A file that wasn't open has its old text in recovery.
        let store = FileRecoveryStore(directory: recovery.url)
        let kept = try #require(try store.versions(for: URL(fileURLWithPath: a)).first { $0.lastPathComponent.contains("-replace-") })
        #expect(try String(contentsOf: kept, encoding: .utf8) == "* foo\nFoo and foo\n")
    }

    @Test func regexpGroupsAndUntickedFiles() async throws {
        try notes.write("a.org", "Call 555-1234\n")
        try notes.write("b.org", "Call 555-9999\n")
        try await workspace.addRoot(notes.url)
        let a = try path("a.org"), b = try path("b.org")
        let model = model()
        await search(model, .replace(TextReplace(pattern: "([0-9]{3})-([0-9]{4})", replacement: "(\\1) $2", isRegexp: true)))
        model.setTicked(false, file: b)
        model.apply()
        #expect(try disk(a) == "Call (555) 1234\n")
        #expect(try disk(b) == "Call 555-9999\n")

        await search(model, .replace(TextReplace(pattern: "(", replacement: "", isRegexp: true)))
        #expect(model.problem != nil && model.files.isEmpty)
    }

    @Test func aFileChangedAfterTheSearchIsLeftAlone() async throws {
        try notes.write("a.org", "foo\n")
        try await workspace.addRoot(notes.url)
        let a = try path("a.org")
        let model = model()
        await search(model, .replace(TextReplace(pattern: "foo", replacement: "bar")))
        try Data("foo foo\n".utf8).write(to: URL(fileURLWithPath: a))
        let summary = model.apply()
        #expect(summary.contains("changed after the search"))
        #expect(try disk(a) == "foo foo\n")
    }

    @Test func cancelStopsTheSearch() async throws {
        for i in 0..<1000 { try notes.write("f\(i).org", String(repeating: "foo bar\n", count: 400)) }
        try await workspace.addRoot(notes.url)
        let model = model()
        model.start(.replace(TextReplace(pattern: "foo", replacement: "bar")), scope: nil)
        #expect(model.isSearching)
        model.cancel()
        await model.waitForSearch()
        #expect(model.wasCancelled && !model.isSearching)
        #expect(model.files.count < 1000)
    }

    @Test func renameTagWithConfig() async throws {
        try notes.write("a.org", "#+FILETAGS: :work:\n* Plan :work:\nwork :work: in the body\n")
        try await workspace.addRoot(notes.url)
        let a = try path("a.org")
        let model = model()
        await search(model, .renameTag(from: "work", to: "office"))
        #expect(model.configChange?.new == "office(w) home")
        #expect(model.files.first?.changes.map(\.line) == [1, 2])
        model.changesConfig = false
        model.apply()
        #expect(config.writes.isEmpty)
        let renamed = try disk(a)
        #expect(renamed.hasPrefix("#+FILETAGS: :office:\n* Plan"))
        #expect(renamed.hasSuffix(":office:\nwork :work: in the body\n"))

        await search(model, .renameTag(from: "home", to: "office"))
        model.apply()
        #expect(config.writes == ["tagAlist": "work(w) office"])

        await search(model, .renameTag(from: "office", to: "two words"))
        #expect(model.problem != nil)
    }

    @Test func renameKeywordFollowsWhereItIsDefined() async throws {
        // own.org defines NEXT; uses.org relies on config.toml's keywords.
        try notes.write("own.org", "#+TODO: TODO NEXT | DONE\n* NEXT a\n")
        try notes.write("uses.org", "* NEXT b\nNEXT in the body\n")
        try await workspace.addRoot(notes.url)
        session.defaults = OrgSettings.default.withTodoKeywords(config.todoKeywords)!
        let own = try path("own.org"), uses = try path("uses.org")

        let model = model()
        await search(model, .renameKeyword(from: "NEXT", to: "WAIT"), includeConfig: false)
        #expect(model.files.map(\.path) == [own])
        await search(model, .renameKeyword(from: "NEXT", to: "WAIT"))
        #expect(model.files.map(\.path) == [own, uses])
        model.apply()
        #expect(try disk(own) == "#+TODO: TODO WAIT | DONE\n* WAIT a\n")
        #expect(try disk(uses) == "* WAIT b\nNEXT in the body\n")
        #expect(config.writes == ["todoKeywords": "TODO WAIT | DONE"])

        // Across done and not-done states is refused, in config.toml or in a file.
        await search(model, .renameKeyword(from: "TODO", to: "DONE"))
        #expect(model.problem?.contains("done state") == true && model.files.isEmpty)
        try notes.write("types.org", "#+TODO: A | B\n* A x\n")
        await workspace.refresh()
        await search(model, .renameKeyword(from: "A", to: "B"))
        #expect(model.problem?.contains("types.org") == true)
    }
}
