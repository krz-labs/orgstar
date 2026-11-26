import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// Saving with `org-crypt-use-before-save-magic`, and `.org.gpg` files: what reaches disk.
@MainActor
struct CryptSaveTests {
    static let secret = "Account 12345"
    static let file = "#+TITLE: Notes\n* Plain\nOpen text.\n* Bank :crypt:\n\(secret)\n* Last\n"

    let notes: Folder
    let file: URL
    let recoveryFolder: URL
    let session: DocumentSession

    init() throws {
        notes = try Folder()
        file = try notes.write("a.org", Self.file)
        recoveryFolder = notes.url.appendingPathComponent(".recovery")
        session = DocumentSession(recovery: FileRecoveryStore(directory: recoveryFolder))
        session.saveMode = .explicit
        session.encryptsTaggedEntries = true
        session.hasStoredPassphrase = { _ in false }
    }

    /// Types `text` at `offset` in the open file, as the editor would.
    func type(_ text: String, at offset: Int) throws {
        let buffer = StateBuffer(session.document!)
        session.attach(buffer)
        try buffer.update { try $0.apply([TextEdit(range: offset..<offset, replacement: text)], baseRevision: $0.revision) }
        session.bufferChanged()
    }

    /// Puts `text` in place of the open file's text.
    func replace(with text: String) throws {
        let buffer = StateBuffer(session.document!)
        session.attach(buffer)
        try buffer.update { try $0.apply([TextEdit(range: 0..<($0.text as NSString).length, replacement: text)], baseRevision: $0.revision) }
        session.bufferChanged()
    }

    var disk: String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    /// Every file the recovery folder holds, as text.
    var recoveryFiles: [String] {
        let files = FileManager.default.enumerator(at: recoveryFolder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.compactMap { try? Data(contentsOf: $0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    func offset(of needle: String) -> Int {
        (session.document!.text as NSString).range(of: needle).location
    }

    /// Waits for `condition`, as the Keychain's answer comes back on a task.
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func savesTaggedEntriesEncryptedWithTheRememberedPassphrase() async throws {
        try notes.write("a.org", "* Bank :crypt:\nold\n* Last\n")
        session.hasStoredPassphrase = { _ in true }
        var asked = 0
        session.storedPassphrase = { _ in asked += 1; return "pw" }
        var written: [String] = []
        session.fileWritten = { written.append($0) }
        session.open(file.path)
        try replace(with: Self.file)
        #expect(!session.save())
        try await wait { !session.isDirty }
        #expect(session.held.isEmpty)
        #expect(asked == 1)
        #expect(written == [file.path])
        // The buffer keeps the text; the file has a message in its place.
        #expect(session.document?.text == Self.file)
        #expect(!disk.contains(Self.secret) && !disk.contains("old"))
        #expect(disk.contains("* Bank :crypt:\n-----BEGIN PGP MESSAGE-----\n"))
        let bank = (disk as NSString).range(of: "* Bank").location
        #expect(try OrgCrypt.decrypt(disk, at: bank, passphrase: "pw").plaintext == Self.secret + "\n")
        // The version the save replaced went to recovery encrypted too.
        #expect(!recoveryFiles.isEmpty)
        #expect(recoveryFiles.allSatisfy { !$0.contains(Self.secret) && !$0.contains("old") })
        // Later saves don't ask again.
        try type("More. ", at: offset(of: "Open text."))
        #expect(session.save())
        #expect(asked == 1)
        #expect(written.count == 2)
        #expect(!disk.contains(Self.secret))
        // The index reads the file from disk and keeps no text of the entry.
        let workspace = try WorkspaceModel(directory: notes.url.appendingPathComponent(".index"))
        try await workspace.addRoot(notes.url)
        let database = try Data(contentsOf: notes.url.appendingPathComponent(".index/index.sqlite"))
        #expect(database.range(of: Data(Self.secret.utf8)) == nil)
        #expect(try workspace.search("12345").isEmpty)
        #expect(try workspace.search("Open").map(\.title).contains("Plain"))
    }

    @Test func holdsTheWholeFileWithoutThePassphrase() throws {
        try notes.write("a.org", "* Plain\nOpen text.\n")
        var written: [String] = []
        session.fileWritten = { written.append($0) }
        session.open(file.path)
        try replace(with: Self.file)
        #expect(!session.save())
        #expect(session.held[file.path] == .entries(1))
        #expect(written.isEmpty)
        #expect(disk == "* Plain\nOpen text.\n")
        #expect(recoveryFiles.isEmpty)
        #expect(session.isDirty)
        // Nothing reads the held text from the session for the agenda or widgets.
        #expect(session.openTexts[file.path] == nil)
        // Keep Mine holds too.
        session.keepMine()
        #expect(disk == "* Plain\nOpen text.\n")
        #expect(recoveryFiles.isEmpty)
        // The passphrase, when given, encrypts and saves.
        #expect(written.isEmpty)
        #expect(session.unlock("pw", for: file.path) == nil)
        #expect(session.held.isEmpty)
        #expect(!session.isDirty)
        #expect(written == [file.path])
        #expect(!disk.contains(Self.secret))
        #expect(recoveryFiles.allSatisfy { !$0.contains(Self.secret) })
        #expect(session.openTexts[file.path] == nil)
    }

    @Test func restoringAVersionOfAHeldFileKeepsNoPlaintext() throws {
        try notes.write("a.org", "* Plain\nOpen text.\n")
        session.open(file.path)
        try replace(with: Self.file)
        #expect(!session.save())
        #expect(session.restore(text: "* Plain\nOpen text.\n* Other\n") == nil)
        #expect(recoveryFiles.isEmpty)
        #expect(session.save())
        #expect(recoveryFiles.allSatisfy { !$0.contains(Self.secret) })
    }

    @Test func aHeldFileIsReleasedWhenTheEntryGoes() throws {
        session.saveMode = .automatic
        session.autosaveDelay = .seconds(60)
        session.open(file.path)
        try type("x", at: 0)
        #expect(!session.save())
        #expect(session.held[file.path] == .entries(1))
        let text = session.document!.text as NSString
        try replace(with: text.replacingOccurrences(of: " :crypt:", with: ""))
        #expect(session.held.isEmpty)
    }

    @Test func aWrongPassphraseForTheFilesEntriesIsRefused() throws {
        let encrypted = try #require(try OrgCrypt.encrypt(Self.file, at: (Self.file as NSString).range(of: "* Bank").location, passphrase: "pw"))
        try notes.write("a.org", encrypted + "* New :crypt:\nNew secret\n")
        session.open(file.path)
        try type("x", at: 0)
        #expect(!session.save())
        #expect(session.held[file.path] == .entries(1))
        #expect(session.unlock("other", for: file.path) == "Wrong passphrase")
        #expect(session.isDirty && disk.hasPrefix(encrypted))
        #expect(session.unlock("pw", for: file.path) == nil)
        #expect(!disk.contains("New secret") && !session.isDirty)
    }

    @Test func blankTaggedEntriesDontHoldTheFile() throws {
        try notes.write("a.org", "* Plain\n")
        session.open(file.path)
        try type("* Empty :crypt:\n", at: 8)
        #expect(session.save())
        #expect(disk == "* Plain\n* Empty :crypt:\n")
    }

    @Test func unchangedEncryptedEntriesStayByteForByte() throws {
        let bank = (Self.file as NSString).range(of: "* Bank").location
        let encrypted = try #require(try OrgCrypt.encrypt(Self.file, at: bank, passphrase: "pw"))
        try notes.write("a.org", encrypted)
        session.open(file.path)
        // Decrypt Entry in File, as the passphrase sheet runs it.
        let message = try #require(OrgCrypt.firstMessage(encrypted))
        let decrypted = try OrgCrypt.decryptInPlace(encrypted, at: bank, passphrase: "pw")
        session.cryptUsed("pw", for: file.path)
        let body = try #require(OrgCrypt.bodyRange(decrypted, at: bank))
        session.cryptDecrypted(message: message, plaintext: (decrypted as NSString).substring(with: NSRange(body)), for: file.path)
        try replace(with: decrypted)
        #expect(session.document?.text.contains(Self.secret) == true)
        // Saving writes the entry's message as it was.
        #expect(session.save())
        #expect(disk == encrypted)
        try type("More. ", at: offset(of: "Open text."))
        #expect(session.save())
        #expect(disk == (encrypted as NSString).replacingOccurrences(of: "Open text.", with: "More. Open text."))
        #expect(disk.contains(message))
        // A changed entry gets a new message.
        try type("Changed. ", at: offset(of: Self.secret))
        #expect(session.save())
        #expect(!disk.contains(message) && !disk.contains("Changed."))
        let saved = disk
        #expect(try OrgCrypt.decrypt(saved, at: (saved as NSString).range(of: "* Bank").location, passphrase: "pw").plaintext == "Changed. \(Self.secret)\n")
        // An entry left encrypted in the buffer stays as it is.
        let other = try notes.write("b.org", encrypted)
        session.open(other.path)
        try type("x", at: 0)
        #expect(session.save())
        #expect((try String(contentsOf: other, encoding: .utf8)) == "x" + encrypted)
    }

    @Test func offWritesWhatTheBufferHas() throws {
        session.encryptsTaggedEntries = false
        try notes.write("a.org", "* Plain\n")
        session.open(file.path)
        try replace(with: Self.file)
        #expect(session.save())
        #expect(disk == Self.file)
        #expect(session.openTexts[file.path] == Self.file)
    }

    @Test func aFileChangedOnDiskMergesWithTheDecryptedBuffer() throws {
        try notes.write("a.org", "* Plain\nOpen text.\n")
        session.open(file.path)
        session.cryptUsed("pw", for: file.path)
        try replace(with: Self.file)
        #expect(session.save())
        // Another program appends to the file; the buffer keeps its decrypted entry.
        try notes.write("a.org", disk + "* From Emacs\n")
        session.fileChanged(file.path)
        #expect(session.document?.text == Self.file + "* From Emacs\n")
        #expect(!session.isDirty)
        try type("y", at: 0)
        #expect(session.save())
        #expect(!disk.contains(Self.secret) && disk.hasSuffix("* From Emacs\n"))
    }

    // MARK: - Encrypted files

    static let gpgText = "* Diary\nDear diary, \(secret).\n"

    @Test func encryptedFilesOpenWithThePassphraseAndSaveEncrypted() throws {
        let message = try OpenPGP.encryptedMessage(Data(Self.gpgText.utf8), passphrase: "pw")
        let path = notes.url.appendingPathComponent("diary.org.gpg")
        try message.write(to: path)
        var written: [String] = []
        session.fileWritten = { written.append($0) }
        session.open(path.path)
        #expect(session.unlockRequest == path.path)
        #expect(!session.isOpen(path.path))
        #expect(session.unlock("wrong", for: path.path) == "Wrong passphrase")
        #expect(try Data(contentsOf: path) == message)
        #expect(session.unlock("pw", for: path.path) == nil)
        #expect(session.unlockRequest == nil)
        #expect(session.path == path.path && session.document?.text == Self.gpgText)
        #expect(session.isOrg)
        #expect(session.openTexts[path.path] == nil)
        try type("x", at: 0)
        #expect(session.save())
        #expect(written == [path.path])
        let disk = try Data(contentsOf: path)
        #expect(!OpenPGP.isArmored(disk))
        #expect(disk.range(of: Data(Self.secret.utf8)) == nil)
        #expect(try OpenPGP.decryptFile(disk, passphrase: "pw") == Data(("x" + Self.gpgText).utf8))
        // Recovery keeps the version replaced, encrypted, and shows it decrypted.
        #expect(!recoveryFiles.isEmpty && recoveryFiles.allSatisfy { !$0.contains(Self.secret) })
        let version = try #require(session.recoveryVersions().first)
        #expect(session.recoveryText(version.url) == Self.gpgText)
        // A passphrase forgotten while the file is open must be the file's when given again.
        session.crypt.forgetPassphrase(for: path.path)
        try type("y", at: 0)
        #expect(!session.save())
        #expect(session.held[path.path] == .file)
        #expect(session.unlock("typo", for: path.path) == "Wrong passphrase")
        #expect(session.unlock("pw", for: path.path) == nil && !session.isDirty)
        #expect(try OpenPGP.decryptFile(Data(contentsOf: path), passphrase: "pw") == Data(("yx" + Self.gpgText).utf8))
        // Closing forgets the passphrase.
        session.kill(path.path)
        session.open(path.path)
        #expect(session.unlockRequest == path.path)
    }

    @Test func armoredFilesStayArmored() throws {
        let armored = try OpenPGP.encrypt(Data(Self.gpgText.utf8), passphrase: "pw")
        let path = try notes.write("diary.org.gpg", armored)
        session.open(path.path)
        #expect(session.unlock("pw", for: path.path) == nil)
        try type("x", at: 0)
        #expect(session.save())
        let disk = try Data(contentsOf: path)
        #expect(OpenPGP.isArmored(disk))
        #expect(try OpenPGP.decryptFile(disk, passphrase: "pw") == Data(("x" + Self.gpgText).utf8))
    }

    @Test func aNewEncryptedFileWaitsForItsPassphrase() throws {
        let path = try notes.write("new.org.gpg", "")
        session.open(path.path)
        #expect(session.unlockRequest == nil && session.path == path.path)
        try type(Self.gpgText, at: 0)
        #expect(!session.save())
        #expect(session.held[path.path] == .file)
        #expect(try Data(contentsOf: path).isEmpty)
        #expect(recoveryFiles.isEmpty)
        #expect(session.unlock("new", for: path.path) == nil)
        #expect(!session.isDirty && session.held.isEmpty)
        #expect(try OpenPGP.decryptFile(Data(contentsOf: path), passphrase: "new") == Data(Self.gpgText.utf8))
    }

    @Test func anEncryptedFileChangedOnDiskMergesInMemory() throws {
        let path = notes.url.appendingPathComponent("diary.org.gpg")
        try OpenPGP.encryptedMessage(Data(Self.gpgText.utf8), passphrase: "pw").write(to: path)
        session.open(path.path)
        #expect(session.unlock("pw", for: path.path) == nil)
        try type("x", at: 0)
        try OpenPGP.encryptedMessage(Data((Self.gpgText + "* Added elsewhere\n").utf8), passphrase: "pw").write(to: path)
        session.fileChanged(path.path)
        #expect(session.document?.text == "x" + Self.gpgText + "* Added elsewhere\n")
        #expect(session.save())
        #expect(try OpenPGP.decryptFile(Data(contentsOf: path), passphrase: "pw") == Data(("x" + Self.gpgText + "* Added elsewhere\n").utf8))
        #expect(recoveryFiles.allSatisfy { !$0.contains(Self.secret) && !$0.contains("Added elsewhere") })
    }
}
