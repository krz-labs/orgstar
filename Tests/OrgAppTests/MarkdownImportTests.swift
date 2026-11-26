import Foundation
import OrgCore
import Testing
@testable import OrgApp

/// File ▸ Import ▸ Markdown Files… and Obsidian Vault…: names, links, attachments, and the
/// sources left alone.
struct MarkdownImportTests {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("md-import-\(UUID().uuidString)")

    func write(_ files: [String: String], in folder: URL) throws {
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    /// Every file below `folder` with its contents and modification date.
    func snapshot(_ folder: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])!
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            let relative = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(folder.standardizedFileURL.resolvingSymlinksInPath().path.count))
            if values.isRegularFile == true {
                out[relative] = try Data(contentsOf: url) + Data("\(values.contentModificationDate!.timeIntervalSince1970)".utf8)
            } else {
                out[relative + "/"] = Data()
            }
        }
        return out
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: scratch.appendingPathComponent("dest").appendingPathComponent(path), encoding: .utf8)
    }

    /// `file:` links in the org file at `path` whose files don't exist.
    func brokenLinks(_ path: String) throws -> [String] {
        let url = scratch.appendingPathComponent("dest").appendingPathComponent(path)
        let model = DocumentModel(tree: OrgParser.parse(try String(contentsOf: url, encoding: .utf8)))
        let links = model.links + model.headings.flatMap(\.links)
        return links.filter { $0.hasPrefix("file:") }.filter { link in
            let target = String(link.dropFirst(5)).components(separatedBy: "::")[0]
            return !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(target).path)
        }
    }

    static let vault: [String: String] = [
        "Home.md": """
            ---
            tags: [start]
            aliases: [Index]
            ---
            Links: [[Projects/Alpha]], [[Alpha#Goals|goals]], [[Alpha#^key]], [[Missing note]] and [md](Projects/Alpha.md#goals).

            ![[diagram.png]]
            ![[Alpha]]
            ![[report.pdf]]

            """,
        "Projects/Alpha.md": """
            # Goals #project
            Ship it. ^key

            - [ ] Write 📅 2026-12-01
            Back to [[Home]].

            """,
        "attachments/diagram.png": "png",
        "attachments/report.pdf": "pdf",
        "attachments/unused.png": "png",
        "Board.canvas": "{}",
        ".obsidian/app.json": "{}"
    ]

    @Test func vaultBecomesAFolderWithLinksBetweenTheNewFiles() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("Vault")
        let destination = scratch.appendingPathComponent("dest")
        try write(Self.vault, in: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let before = try snapshot(source)

        let plan = try MarkdownImport.plan(.obsidian, sources: [source], into: destination)
        #expect(plan.notes == 2)
        #expect(plan.headings == 1)
        #expect(plan.attachments == 2)
        #expect(plan.renamed.isEmpty)
        #expect(Set(plan.problems) == [
            MarkdownImport.Problem(file: "Vault/Board.canvas", reason: .notConverted),
            MarkdownImport.Problem(file: "Vault/Home.md", reason: .converted(.unresolvedLink("Missing note")))
        ])
        let written = try MarkdownImport.write(plan)
        #expect(written.paths.count == 4)
        #expect(written.renamed.isEmpty)

        let home = try read("Vault/Home.org")
        #expect(home.hasPrefix(":PROPERTIES:\n:ROAM_ALIASES: Index\n:END:\n#+title: Home\n#+filetags: :start:\n"))
        #expect(home.contains("[[file:Projects/Alpha.org][Alpha]],"))
        #expect(home.contains("[[file:Projects/Alpha.org::*Goals][goals]]"))
        #expect(home.contains("[[file:Projects/Alpha.org::key][Alpha > key]]"))
        #expect(home.contains("[[file:Missing note.org][Missing note]]"))
        #expect(home.contains("[[file:Projects/Alpha.org::*Goals][md]]"))
        #expect(home.contains("[[file:attachments/diagram.png]]"))
        #expect(home.contains("[[file:attachments/report.pdf][report.pdf]]"))
        let alpha = try read("Vault/Projects/Alpha.org")
        #expect(alpha.contains("* Goals :project:"))
        #expect(alpha.contains("Ship it. <<key>>"))
        #expect(alpha.contains("[[file:../Home.org][Home]]"))
        #expect(alpha.contains("DEADLINE: <2026-12-01 Tue>"))
        #expect(try brokenLinks("Vault/Home.org") == ["file:Missing note.org"])
        #expect(try brokenLinks("Vault/Projects/Alpha.org").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Vault/attachments/unused.png").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Vault/.obsidian").path))
        #expect(try snapshot(source) == before)
    }

    @Test func takenNamesGetFreeOnesAndNothingIsOverwritten() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("src")
        let destination = scratch.appendingPathComponent("dest")
        try write(["Vault/Note.md": "# Hi\n", "a.md": "A ![p](pic.png)\n", "pic.png": "new", "b.markdown": "B\n"], in: source)
        try write(["Vault/keep.org": "old vault", "a.org": "old a", "attachments/pic.png": "old pic"], in: destination)
        let before = try snapshot(source)
        let existing = try snapshot(destination)

        let plan = try MarkdownImport.plan(.markdown, sources: [source.appendingPathComponent("Vault"), source.appendingPathComponent("a.md"),
                                                                 source.appendingPathComponent("b.markdown")], into: destination)
        #expect(plan.renamed.map(\.to) == ["Vault 2", "a 2.org"])
        #expect(plan.renamed.map(\.from) == ["Vault", "a.md"])
        let written = try MarkdownImport.write(plan)
        #expect(written.renamed.isEmpty)
        #expect(try read("Vault 2/Note.org") == "* Hi\n")
        #expect(try read("a 2.org") == "A [[file:attachments/pic 2.png]]\n")
        #expect(try read("attachments/pic 2.png") == "new")
        #expect(try read("b.org") == "B\n")
        let after = try snapshot(destination)
        for (path, data) in existing { #expect(after[path] == data, "\(path)") }
        #expect(try snapshot(source) == before)
    }

    @Test func aNameTakenAfterThePreviewIsNotOverwritten() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("src")
        let destination = scratch.appendingPathComponent("dest")
        try write(["Note.md": "new\n", "Folder/x.md": "x\n"], in: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let plan = try MarkdownImport.plan(.markdown, sources: [source.appendingPathComponent("Note.md"), source.appendingPathComponent("Folder")], into: destination)
        try write(["Note.org": "someone else's", "Folder/y.org": "theirs"], in: destination)

        let written = try MarkdownImport.write(plan)
        #expect(Set(written.renamed.map(\.to)) == ["Note 2.org", "Folder 2"])
        #expect(try read("Note.org") == "someone else's")
        #expect(try read("Note 2.org") == "new\n")
        #expect(try read("Folder 2/x.org") == "x\n")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Folder/x.org").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }

    @Test func markdownLinksBetweenChosenFiles() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("src")
        let destination = scratch.appendingPathComponent("dest")
        try write(["one.md": "# Top\nSee [two](two.md#second-part), [self](#top) and [gone](gone.md).\n", "two.md": "## Second part\n"], in: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let plan = try MarkdownImport.plan(.markdown, sources: [source.appendingPathComponent("one.md"), source.appendingPathComponent("two.md")], into: destination)
        #expect(plan.problems == [MarkdownImport.Problem(file: "one.md", reason: .converted(.unresolvedLink("gone.md")))])
        _ = try MarkdownImport.write(plan)
        #expect(try read("one.org") == "* Top\nSee [[file:two.org::*Second part][two]], [[*Top][self]] and [[file:gone.md][gone]].\n")
    }

    @Test func unreadableNoteIsReported() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([0xff, 0xfe, 0x00, 0xd8]).write(to: source.appendingPathComponent("bad.md"))
        let plan = try MarkdownImport.plan(.markdown, sources: [source.appendingPathComponent("bad.md")], into: scratch)
        #expect(plan.notes == 0)
        #expect(plan.problems == [MarkdownImport.Problem(file: "bad.md", reason: .unreadable)])
    }

    /// Writes a vault of `count` notes, each linking to the next two and embedding an image.
    static func writeVault(_ count: Int, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
        for n in 0..<count {
            let dir = folder.appendingPathComponent("area \(n % 10)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let text = """
                ---
                tags: [t\(n % 7)]
                ---
                # Note \(n) #tag\(n % 5)
                Text with **bold**, a [[Note \((n + 1) % count)]] link and [[Note \((n + 2) % count)#Section]].

                ## Section
                - [ ] task 📅 2026-12-0\(n % 9 + 1)
                - item with `code`

                | a | b |
                |---|---|
                | \(n) | x |

                ![[pic \(n % 20).png]]

                """
            try Data(text.utf8).write(to: dir.appendingPathComponent("Note \(n).md"))
        }
        for k in 0..<20 { try Data("png".utf8).write(to: folder.appendingPathComponent("img/pic \(k).png")) }
    }

    @Test func largeVaultConvertsWithEveryLinkResolved() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("Big")
        let destination = scratch.appendingPathComponent("dest")
        try Self.writeVault(1_000, to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let plan = try MarkdownImport.plan(.obsidian, sources: [source], into: destination)
        #expect(plan.notes == 1_000)
        #expect(plan.headings == 2_000)
        #expect(plan.links == 3_000)
        #expect(plan.attachments == 20)
        #expect(plan.problems.isEmpty)
        let written = try MarkdownImport.write(plan)
        #expect(written.paths.count == 1_020)
        for n in [0, 499, 999] { #expect(try brokenLinks("Big/area \(n % 10)/Note \(n).org").isEmpty) }
    }
}
