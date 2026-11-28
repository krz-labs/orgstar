import Foundation
import Testing
@testable import OrgApp

@MainActor
struct AgendaViewSaveTests {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-views-\(UUID().uuidString)")
        return folder.appendingPathComponent("config/views.toml")
    }

    @Test func savedViewsLoadBackAsTheyWere() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let modes: [(String, AgendaMode)] = [
            ("Work", .match("+work-boss|LEVEL>2/!TODO", todoOnly: false)),
            ("Waiting \"on\" others", .match("TODO=\"WAIT\"", todoOnly: true)),
            ("Heron", .search("+heron -pond {ot+er}", todoOnly: false)),
            ("Open phrases", .search("a phrase", todoOnly: true)),
            ("Holds", .todo(keywords: "WAIT|HOLD")),
            ("Three days", .agenda(span: 3, startOffset: -1)),
            ("Stuck", .stuck(nil)),
            ("Next at work", .query("todo:NEXT tags:work", sort: ["date", "priority"])),
            ("Overdue", .query("(and (todo) (deadline :to -1))", sort: [])),
        ]
        for (name, mode) in modes { try AgendaViewLoader.save(name: name, mode: mode, userFile: file) }
        let loaded = AgendaViewLoader.load(userFile: file)
        #expect(loaded.problems.isEmpty)
        let saved = loaded.views.dropFirst(AgendaViewLoader.builtIn.count)
        #expect(saved.map(\.name) == modes.map(\.0))
        #expect(saved.map(\.mode) == modes.map(\.1))
    }

    @Test func aViewIsAddedAfterWhatTheFileHolds() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = "# mine\n[[view]]\nname = \"Home\"\ntype = \"match\"\nmatch = \"+home\""
        try existing.write(to: file, atomically: true, encoding: .utf8)
        try AgendaViewLoader.save(name: "  Work ", mode: .match("+work", todoOnly: false), userFile: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == existing + "\n\n[[view]]\nname = \"Work\"\ntype = \"match\"\nmatch = \"+work\"\n")
    }

    @Test func refusesEmptyAndTakenNamesAndViewsOneTableCannotHold() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let mode = AgendaMode.match("+work", todoOnly: false)
        #expect(throws: AgendaViewLoader.SaveFailure.self) { try AgendaViewLoader.save(name: "  ", mode: mode, userFile: file) }
        #expect(throws: AgendaViewLoader.SaveFailure.self) { try AgendaViewLoader.save(name: "TODO List", mode: mode, userFile: file) }
        try AgendaViewLoader.save(name: "Work", mode: mode, userFile: file)
        #expect(throws: AgendaViewLoader.SaveFailure.self) { try AgendaViewLoader.save(name: "Work", mode: mode, userFile: file) }
        #expect(throws: AgendaViewLoader.SaveFailure.self) { try AgendaViewLoader.save(name: "Blocks", mode: .blocks([]), userFile: file) }
        #expect(AgendaViewLoader.load(userFile: file).views.count == AgendaViewLoader.builtIn.count + 1)
    }
}
