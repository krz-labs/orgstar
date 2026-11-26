import Foundation
import OrgApp
import OrgCore
import Testing

/// Gates for a large workspace: the first index build, the agenda refresh, the backlinks of a
/// file and a heading, and Lint All Folders. In `GateTests` so they run one at a time with the
/// editor gates.
extension GateTests {
    /// Writes `count` notes of eight headings each, about 2 kB a note. Every heading has an ID
    /// and a paragraph; the first `fiveLinks` notes have five links and the rest four. A third of
    /// the headings are TODOs, and every hundredth note has one scheduled in the week of
    /// 5 October 2026.
    static func writeNotes(_ count: Int, fiveLinks: Int, to folder: URL) throws {
        let week = ["2026-10-05 Mon", "2026-10-06 Tue", "2026-10-07 Wed", "2026-10-08 Thu", "2026-10-09 Fri", "2026-10-10 Sat", "2026-10-11 Sun"]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in 0..<count {
            let links = [
                "[[id:\((n + 1) % count)-0][note \((n + 1) % count)]]",
                "[[file:note-\((n + 2) % count).org::*Heading \((n + 2) % count).1][a heading]]",
                "[[*Heading \(n).2]]",
                "[[file:note-\((n + 3) % count).org]]",
                "[[https://example.com/\(n)][the web]]"
            ].prefix(n < fiveLinks ? 5 : 4)
            var text = "#+title: Note \(n)\n\n"
            for h in 0..<8 {
                text += "* \(h % 3 == 0 ? "TODO " : "")Heading \(n).\(h) :tag\(h):\n"
                if h == 0, n % 100 == 0 { text += "SCHEDULED: <\(week[n / 100 % 7])>\n" }
                text += ":PROPERTIES:\n:ID:       \(n)-\(h)\n:END:\n"
                text += "Paragraph of heading \(h) in note \(n), with *bold*, /italic/ and =code=, about as long as a note someone wrote. It goes on for a second sentence about nothing in particular.\n"
                if h < links.count { text += "See \(links[h]).\n" }
                text += "\n"
            }
            try Data(text.utf8).write(to: folder.appendingPathComponent("note-\(n).org"))
        }
    }

    /// A folder of `count` notes, indexed on disk as the app does, and how long the first build took.
    static func workspace(_ count: Int, fiveLinks: Int, in scratch: URL) async throws -> (model: WorkspaceModel, build: Duration) {
        let notes = scratch.appendingPathComponent("notes")
        try writeNotes(count, fiveLinks: fiveLinks, to: notes)
        let model = try WorkspaceModel(directory: scratch.appendingPathComponent("data"))
        let start = ContinuousClock.now
        try await model.addRoot(notes)
        return (model, ContinuousClock.now - start)
    }

    /// One run of Lint All Folders over the workspace, and how many files had findings.
    static func lintAll(_ model: WorkspaceModel) async throws -> (files: Int, time: Duration) {
        let paths = FileLint.folderPaths(model.files)
        let environment = FileLint.environment(index: model.index)
        var files = 0
        let time = try await ContinuousClock().measure {
            files = try await FileLint.lint(paths: paths, texts: [:], environment: environment).count
        }
        return (files, time)
    }

    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-gates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One pass of the backlinks pane: the file's backlinks and the heading's.
    static func backlinks(_ model: WorkspaceModel) throws -> (found: Int, time: Duration) {
        let path = model.files.first { $0.name == "note-0.org" }!.path
        var found = 0
        let time = try ContinuousClock().measure {
            found += try model.backlinks(to: Backlinks.Target(path: path)).count
            found += try model.backlinks(to: Backlinks.Target(path: path, title: "Heading 0.1", id: "0-1")).count
        }
        return (found, time)
    }

    /// 10,000 notes, 49,400 links.
    @Test func workspaceGates() async throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (model, build) = try await Self.workspace(10_000, fiveLinks: 9_400, in: scratch)
        #expect(model.files.count == 10_000)

        let agenda = AgendaModel(workspace: model)
        agenda.agendaFiles = []
        agenda.includeSubfolders = false
        let now = DateComponents(calendar: .current, year: 2026, month: 10, day: 5, hour: 12).date!
        let clock = ContinuousClock()
        let cold = await clock.measure { await agenda.refresh(open: [:], now: now) }
        let warm = await clock.measure { await agenda.refresh(open: [:], now: now) }
        let items = agenda.days.reduce(0) { $0 + $1.items.count }
        #expect(items > 0)

        let (found, backlinks) = try Self.backlinks(model)
        #expect(found > 0)
        let lint = try await Self.lintAll(model)
        print("GATE 10,000 notes: index build \(build), agenda refresh cold \(cold) / warm \(warm) (\(items) items), backlinks over 49,400 links \(backlinks), lint all folders \(lint.time) (\(lint.files) files with findings)")
        #expect(build < .seconds(15), "index build")
        #expect(cold < .seconds(10), "agenda refresh, cold")
        #expect(warm < .seconds(2), "agenda refresh, warm")
        #expect(backlinks < .milliseconds(1_500), "backlinks, 49,400 links")
        #expect(lint.time < .seconds(15), "lint all folders, 10,000 notes")
    }

    /// 1,000 notes, 5,000 links.
    @Test func backlinksGate() async throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (model, _) = try await Self.workspace(1_000, fiveLinks: 1_000, in: scratch)
        let (found, time) = try Self.backlinks(model)
        #expect(found > 0)
        let lint = try await Self.lintAll(model)
        print("GATE 1,000 notes: backlinks over 5,000 links \(time), lint all folders \(lint.time) (\(lint.files) files with findings)")
        #expect(time < .milliseconds(150), "backlinks, 5,000 links")
        #expect(lint.time < .seconds(2), "lint all folders, 1,000 notes")
    }
}
