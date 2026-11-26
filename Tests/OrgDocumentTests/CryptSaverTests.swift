import Foundation
import OrgCore
import Testing
@testable import OrgDocument

/// A version another writer puts on disk just before ours, with crypt-tagged entries in
/// plaintext and no passphrase known: recovery can't keep it, and it must not be lost.
struct CryptSaverTests {
    static let theirs = "a\nb\nc\n* Theirs :crypt:\ntheir secret\n"

    func saver(_ files: FaultyFileSystem, _ recovery: MemoryRecovery) -> (Saver, CryptVault) {
        let vault = CryptVault()
        vault.encryptsTaggedEntries = true
        return (Saver(fileSystem: CryptFileSystem(base: files, vault: vault), recovery: CryptRecoveryStore(base: recovery, vault: vault)), vault)
    }

    @Test func anOverwrittenVersionMergesIntoTheBuffer() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        files.beforeReplace = Array(Self.theirs.utf8)
        let recovery = MemoryRecovery()
        var doc = try editedState()
        let outcome = try saver(files, recovery).0.save(&doc, to: url)
        guard case .overwroteExternalChange(.merged) = outcome else { Issue.record("\(outcome)"); return }
        #expect(doc.text.contains("their secret"))
        #expect(recovery.kept.allSatisfy { !$0.text.contains("their secret") })
    }

    @Test func aConflictingOverwrittenVersionGoesIntoTheBufferWithMarkers() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        files.beforeReplace = Array("Z\nb\nc\n* Theirs :crypt:\ntheir secret\n".utf8)
        let recovery = MemoryRecovery()
        var doc = try editedState()
        let outcome = try saver(files, recovery).0.save(&doc, to: url)
        #expect(outcome == .overwroteExternalChange(.conflict([])))
        #expect(doc.text.contains("their secret") && doc.text.contains("Z") && doc.text.contains("A"))
        #expect(recovery.kept.allSatisfy { !$0.text.contains("their secret") })
    }

    @Test func keepMineDoesntReplaceAVersionItCantKeep() throws {
        let files = FaultyFileSystem(Self.theirs)
        let recovery = MemoryRecovery()
        var doc = try editedState()
        #expect(throws: CryptHold.self) { try saver(files, recovery).0.overwrite(&doc, to: url) }
        #expect(files.text == Self.theirs)
    }

    @Test func closedFilesKeepNothingAfterTheirWrite() async throws {
        let files = FaultyFileSystem("a\n")
        let recovery = MemoryRecovery()
        let (saver, vault) = saver(files, recovery)
        vault.unlock("pw", for: url.path)
        var doc = state("a\n")
        try doc.apply([TextEdit(range: 2..<2, replacement: "* S :crypt:\nsecret\n")], baseRevision: 0)
        #expect(try saver.save(&doc, to: url) == .saved)
        #expect(files.text?.contains("secret") == false)
        await MainActor.run {}
        try await Task.sleep(for: .milliseconds(50))
        #expect(!vault.keepsAnything(for: url.path))
        // Only open files keep sealing after the setting goes off.
        vault.encryptsTaggedEntries = false
        #expect(!vault.sealsEntries(for: url.path))
    }
}
