import Foundation
import OrgCore
import Testing
@testable import OrgApp

/// Bytes that aren't UTF-8: a file that is there and can't be read as text.
private let notText = Data([0xFF, 0xFE, 0xFD])

private func item(_ change: EmacsImport.Change) -> EmacsImport.Item {
    EmacsImport.Item(id: 0, name: "", summary: "", source: "config.el:1", change: change)
}

private func defaults() -> UserDefaults { TestDefaults("orgstar-userfile") }

/// Takes or gives back the folder's write permission, so that writes into it fail.
private func setWritable(_ writable: Bool, _ folder: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: folder.path)
}

struct UserFileTests {
    @Test func onlyAMissingFileIsEmpty() throws {
        let folder = try Folder()
        let file = folder.url.appendingPathComponent("config.toml")
        #expect(try UserFile.text(at: file) == nil)
        try "a = 1\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try UserFile.text(at: file) == "a = 1\n")
        try notText.write(to: file)
        #expect(throws: (any Error).self) { try UserFile.text(at: file) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try UserFile.text(at: file) }
    }

    @Test(arguments: [false, true]) func updateLeavesAFileItCannotRead(coordinated: Bool) throws {
        let folder = try Folder()
        let file = folder.url.appendingPathComponent("config.toml")
        try UserFile.update(file, coordinated: coordinated) { $0 + "a = 1\n" }
        try UserFile.update(file, coordinated: coordinated) { $0 + "b = 2\n" }
        #expect(try String(contentsOf: file, encoding: .utf8) == "a = 1\nb = 2\n")
        try notText.write(to: file)
        #expect(throws: (any Error).self) { try UserFile.update(file, coordinated: coordinated) { $0 + "c = 3\n" } }
        #expect(try Data(contentsOf: file) == notText)
    }

    @Test(arguments: [false, true]) func updateReportsAFailedWrite(coordinated: Bool) throws {
        let folder = try Folder()
        let file = folder.url.appendingPathComponent("config.toml")
        setWritable(false, folder.url)
        defer { setWritable(true, folder.url) }
        #expect(throws: (any Error).self) { try UserFile.update(file, coordinated: coordinated) { $0 + "a = 1\n" } }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    @Test func savingAViewLeavesAFileItCannotRead() throws {
        let folder = try Folder()
        let file = folder.url.appendingPathComponent("views.toml")
        try notText.write(to: file)
        #expect(throws: AgendaViewLoader.SaveFailure.self) { try AgendaViewLoader.save(name: "Work", mode: .match("+work", todoOnly: false), userFile: file) }
        #expect(try Data(contentsOf: file) == notText)
    }
}

@MainActor
struct EmacsImportFileTests {
    private let items = [
        item(.capture(key: "x", toml: "[[template]]\nkey = \"x\"\nfile = \"x.org\"\ntemplate = \"* %?\"\n")),
        item(.view(name: "Work", toml: "[[view]]\nname = \"Work\"\ntype = \"match\"\nmatch = \"+work\"\n")),
        item(.binding(keys: "C-c z", command: "app.agenda", mode: nil)),
        item(.setting(key: "fill-column", value: .integer(64))),
    ]

    @Test func leavesFilesItCannotReadAndDoesNotCountThem() async throws {
        let folder = try Folder()
        let names = ["capture.toml", "views.toml", "keymap.toml", "config.toml"]
        for name in names { try notText.write(to: folder.url.appendingPathComponent(name)) }
        let summary = await EmacsImport.apply(items, defaults: defaults(), workspace: nil, directory: folder.url, writeConfig: true)
        for name in names {
            #expect(try Data(contentsOf: folder.url.appendingPathComponent(name)) == notText)
            #expect(summary.components(separatedBy: "\(name) wasn't changed: ").count == 2, "\(summary)")
        }
        #expect(summary.hasPrefix("Nothing new to import. "), "\(summary)")
    }

    @Test func oneUnreadableFileDoesNotStopTheOthers() async throws {
        let folder = try Folder()
        try notText.write(to: folder.url.appendingPathComponent("capture.toml"))
        let summary = await EmacsImport.apply(items, defaults: defaults(), workspace: nil, directory: folder.url)
        #expect(summary.hasPrefix("Imported 1 setting, 1 key binding, 1 agenda view. capture.toml wasn't changed: "), "\(summary)")
        #expect(try Data(contentsOf: folder.url.appendingPathComponent("capture.toml")) == notText)
        #expect(try String(contentsOf: folder.url.appendingPathComponent("views.toml"), encoding: .utf8).contains("name = \"Work\""))
    }

    @Test func reportsFailedWritesAndDoesNotCountThem() async throws {
        let folder = try Folder()
        setWritable(false, folder.url)
        defer { setWritable(true, folder.url) }
        let summary = await EmacsImport.apply(items, defaults: defaults(), workspace: nil, directory: folder.url, writeConfig: true)
        #expect(summary.hasPrefix("Nothing new to import. "), "\(summary)")
        for name in ["capture.toml", "views.toml", "keymap.toml", "config.toml"] {
            #expect(summary.contains("\(name) wasn't written: "), "\(summary)")
        }
    }
}

@MainActor
struct ConfigSyncFileTests {
    @Test func leavesAFileItCannotReadAndReportsIt() throws {
        let folder = try Folder()
        let url = folder.url.appendingPathComponent("config.toml")
        try notText.write(to: url)
        let store = defaults()
        let sync = ConfigSync(url: url, defaults: store)
        sync.start(watch: false)
        store.set(64, forKey: "fillColumn")
        sync.writeBack()
        #expect(try Data(contentsOf: url) == notText)
        #expect(sync.problems.first?.hasPrefix("config.toml wasn't changed: ") == true, "\(sync.problems)")
    }

    @Test func reportsAFailedWriteUntilOneWorks() throws {
        let folder = try Folder()
        let url = folder.url.appendingPathComponent("config.toml")
        let store = defaults()
        let sync = ConfigSync(url: url, defaults: store)
        sync.start(watch: false)
        let written = try String(contentsOf: url, encoding: .utf8)
        setWritable(false, folder.url)
        defer { setWritable(true, folder.url) }
        store.set(64, forKey: "fillColumn")
        sync.writeBack()
        #expect(try String(contentsOf: url, encoding: .utf8) == written)
        #expect(sync.problems.first?.hasPrefix("config.toml wasn't written: ") == true, "\(sync.problems)")
        setWritable(true, folder.url)
        sync.writeBack()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("fill-column = 64"))
        #expect(!sync.problems.contains { $0.contains("wasn't written") })
    }

    @Test func reportsAFileItCannotCreate() throws {
        let folder = try Folder()
        let sync = ConfigSync(url: folder.url.appendingPathComponent("config.toml"), defaults: defaults())
        setWritable(false, folder.url)
        defer { setWritable(true, folder.url) }
        sync.start(watch: false)
        #expect(sync.problems.first?.hasPrefix("config.toml wasn't written: ") == true, "\(sync.problems)")
    }
}
