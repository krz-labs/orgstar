import Foundation
import OrgApp
import Testing

/// Gate for File ▸ Import ▸ Obsidian Vault…: planning and writing a vault of 1,000 notes.
extension GateTests {
    @Test func importingAThousandNoteVault() async throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let vault = scratch.appendingPathComponent("Vault")
        let destination = scratch.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("img"), withIntermediateDirectories: true)
        for n in 0..<1_000 {
            let dir = vault.appendingPathComponent("area \(n % 10)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var text = "---\ntags: [t\(n % 7)]\n---\n# Note \(n) #tag\(n % 5)\n"
            for p in 0..<10 {
                text += "Paragraph \(p) with **bold**, *italic*, `code`, [[Note \((n + p + 1) % 1_000)]] and [[Note \((n + 2) % 1_000)#Section]].\n\n"
            }
            text += "## Section\n- [ ] task 📅 2026-12-01\n- item\n\n| a | b |\n|---|---|\n| \(n) | x |\n\n![[pic \(n % 20).png]]\n"
            try Data(text.utf8).write(to: dir.appendingPathComponent("Note \(n).md"))
        }
        for k in 0..<20 { try Data("png".utf8).write(to: vault.appendingPathComponent("img/pic \(k).png")) }

        var notes = 0
        let time = try await ContinuousClock().measure {
            let plan = try await Task.detached { try MarkdownImport.plan(.obsidian, sources: [vault], into: destination) }.value
            notes = plan.notes
            _ = try await Task.detached { try MarkdownImport.write(plan) }.value
        }
        print("import 1,000-note vault: \(time)")
        #expect(notes == 1_000)
        #expect(time < .seconds(5))
    }
}
