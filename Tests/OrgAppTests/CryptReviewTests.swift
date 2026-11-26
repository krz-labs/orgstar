import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// What an encrypted entry or file must not leak, nor lose, past the save path.
@MainActor
struct CryptReviewTests {
    static let secret = "Account 12345"
    static let file = "* Plain\nOpen text.\n* Bank :crypt:\n\(secret)\n* Last\n"

    let notes: Folder
    let file: URL
    let recoveryFolder: URL
    let session: DocumentSession

    init() throws {
        notes = try Folder()
        file = try notes.write("a.org", "* Plain\nOpen text.\n* Last\n")
        recoveryFolder = notes.url.appendingPathComponent(".recovery")
        session = DocumentSession(recovery: FileRecoveryStore(directory: recoveryFolder))
        session.saveMode = .explicit
        session.encryptsTaggedEntries = true
        session.hasStoredPassphrase = { _ in false }
    }

    func replace(with text: String) throws {
        let buffer = StateBuffer(session.document!)
        session.attach(buffer)
        try buffer.update { try $0.apply([TextEdit(range: 0..<($0.text as NSString).length, replacement: text)], baseRevision: $0.revision) }
        session.bufferChanged()
    }

    func type(_ text: String, at offset: Int) throws {
        let buffer = StateBuffer(session.document!)
        session.attach(buffer)
        try buffer.update { try $0.apply([TextEdit(range: offset..<offset, replacement: text)], baseRevision: $0.revision) }
        session.bufferChanged()
    }

    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    var disk: String { read(file) }

    var recoveryFiles: [String] {
        let files = FileManager.default.enumerator(at: recoveryFolder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.compactMap { try? Data(contentsOf: $0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    func offset(of needle: String) -> Int { (session.document!.text as NSString).range(of: needle).location }

    // 1
    @Test func turningTheSettingOffKeepsSealingOpenFiles() throws {
        session.open(file.path)
        session.cryptUsed("pw", for: file.path)
        try replace(with: Self.file)
        #expect(session.save())
        #expect(!disk.contains(Self.secret))
        session.encryptsTaggedEntries = false
        try type("x", at: 0)
        #expect(session.save())
        #expect(!disk.contains(Self.secret))
        #expect(session.openTexts[file.path] == nil)
        // A file opened after it was turned off is as before.
        let other = try notes.write("b.org", Self.file)
        session.open(other.path)
        try type("y", at: 0)
        #expect(session.save())
        #expect(read(other).contains(Self.secret))
    }

    // 2
    @Test func useDiskVersionOnAHeldFileKeepsTheEdits() throws {
        session.open(file.path)
        try replace(with: Self.file)
        #expect(!session.save())
        session.useDiskVersion()
        #expect(session.document?.text == Self.file)
        #expect(session.lastError?.contains("Encrypt…") == true)
        #expect(session.restore(text: "* Plain\n")?.contains("Encrypt…") == true)
        #expect(session.document?.text == Self.file)
        #expect(recoveryFiles.isEmpty && disk == "* Plain\nOpen text.\n* Last\n")
    }

    // 3a
    @Test func archivingAChildOfATaggedEntryEncryptsItFirst() throws {
        let text = "* Parent :crypt:\nparent text\n** Child\nchild secret\n* Last\n"
        try notes.write("a.org", text)
        session.open(file.path)
        let child = (text as NSString).range(of: "** Child").location
        let archive = notes.url.appendingPathComponent("a.org_archive")
        #expect(session.archive(from: (file.path, child))?.contains("Encrypt…") == true)
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        session.cryptUsed("pw", for: file.path)
        #expect(session.archive(from: (file.path, child)) == "Archived to a.org_archive")
        #expect(!read(archive).contains("child secret") && read(archive).contains("-----BEGIN PGP MESSAGE-----"))
        #expect(session.save())
        #expect(!disk.contains("child secret") && !disk.contains("parent text"))
    }

    // 3b
    @Test func encryptedFilesArchiveToEncryptedFilesAndRefileOnlyThere() throws {
        let path = notes.url.appendingPathComponent("diary.org.gpg")
        try OpenPGP.encryptedMessage(Data("* Monday\nDear diary.\n* Tuesday\nMore.\n".utf8), passphrase: "pw").write(to: path)
        session.open(path.path)
        #expect(session.unlock("pw", for: path.path) == nil)
        let target = RefileTarget(label: "a.org", path: file.path, start: nil, title: "", level: 0, contentHash: "")
        #expect(session.refile(to: target, from: (path.path, 0))?.contains("isn't") == true)
        #expect(!disk.contains("Dear diary"))
        #expect(session.archive(from: (path.path, 0)) == "Archived to diary_archive.org.gpg")
        let archive = notes.url.appendingPathComponent("diary_archive.org.gpg")
        #expect(!FileManager.default.fileExists(atPath: notes.url.appendingPathComponent("diary.org.gpg_archive").path))
        let bytes = try Data(contentsOf: archive)
        #expect(bytes.range(of: Data("Dear diary".utf8)) == nil)
        #expect(String(decoding: try OpenPGP.decryptFile(bytes, passphrase: "pw"), as: UTF8.self).contains("Dear diary."))
        // Capture into an encrypted file that isn't open writes nothing.
        session.kill(path.path)
        let template = CaptureTemplate(key: "d", name: "Diary", target: .file(path.path), template: "* %?")
        if case .success = session.capture("* Captured secret\n", template: template, root: nil) { Issue.record("captured into a locked file") }
        #expect(try Data(contentsOf: path).range(of: Data("Captured".utf8)) == nil)
    }

    // 5
    @Test func textBelowAMessageIsHeldThenSealedWithIt() throws {
        let encrypted = try #require(try OrgCrypt.encrypt(Self.file, at: (Self.file as NSString).range(of: "* Bank").location, passphrase: "pw"))
        try notes.write("a.org", encrypted)
        session.open(file.path)
        try type("typed below\n", at: offset(of: "* Last"))
        #expect(!session.save())
        #expect(session.held[file.path] == .entries(1))
        #expect(!disk.contains("typed below"))
        #expect(session.unlock("pw", for: file.path) == nil)
        #expect(!disk.contains("typed below"))
        let bank = (disk as NSString).range(of: "* Bank").location
        #expect(try OrgCrypt.decrypt(disk, at: bank, passphrase: "pw").plaintext == Self.secret + "\ntyped below\n")
    }

    // 7
    @Test func exportsLeaveOutWhatIsEncryptedOnDisk() throws {
        session.open(file.path)
        session.cryptUsed("pw", for: file.path)
        try replace(with: Self.file)
        #expect(session.save())
        #expect(session.exportLeavesOut(file.path))
        #expect(session.exportText(of: file.path) == disk)
        #expect(session.exportText(of: file.path)?.contains(Self.secret) == false)
        let gpg = notes.url.appendingPathComponent("d.org.gpg")
        try OpenPGP.encryptedMessage(Data("* D\nsecret\n".utf8), passphrase: "pw").write(to: gpg)
        session.open(gpg.path)
        #expect(session.unlock("pw", for: gpg.path) == nil)
        #expect(session.exportText(of: gpg.path) == nil && session.exportLeavesOut(gpg.path))
        // Nor is either copied for Emacs.
        #expect(session.refusesEmacsCopy(gpg.path) != nil && session.refusesEmacsCopy(file.path) != nil)
        let plain = try notes.write("c.org", "* C\n")
        session.open(plain.path)
        #expect(session.exportText(of: plain.path) == "* C\n" && session.refusesEmacsCopy(plain.path) == nil)
    }

    // 8
    @Test func clockingInDoesntKeepEncryptedTitles() throws {
        let text = "* Bank :crypt:\nintro\n** Secret task\nbody\n* Open task\n"
        try notes.write("a.org", text)
        session.open(file.path)
        session.cryptUsed("pw", for: file.path)
        let clock = ClockModel(file: notes.url.appendingPathComponent("clock.json"))
        _ = clock.clockIn(session, path: file.path, at: (text as NSString).range(of: "** Secret").location)
        #expect(clock.running?.heading == "Encrypted entry")
        #expect(clock.history.allSatisfy { $0.title != "Secret task" })
        #expect(!read(notes.url.appendingPathComponent("clock.json")).contains("Secret task"))
        #expect(session.shareableTitle("Bank", path: file.path, heading: 0) == "Bank")
        #expect(session.shareableTitle("Monday", path: "/x/d.org.gpg", heading: 0) == "Encrypted entry")
        _ = clock.clockOut(session)
        #expect(session.save())
        #expect(!disk.contains("Secret task") && !disk.contains("intro"))
    }

    // 9
    @Test func unchangedEntriesKeepTheirMessageAcrossSaves() throws {
        session.open(file.path)
        session.cryptUsed("pw", for: file.path)
        try replace(with: Self.file)
        #expect(session.save())
        let message = try #require(OrgCrypt.firstMessage(disk))
        for n in 0..<5 {
            try type("\(n)", at: 0)
            #expect(session.save())
            #expect(disk.contains(message))
        }
        #expect(session.crypt.revealedMessages(for: file.path).count == 1)
    }

    // 10
    @Test func entriesEncryptedToAPublicKeyDontBlockThePassphrase() throws {
        // A public-key session packet (tag 1) where a message's packets start.
        let publicKey = OpenPGP.armor(Data([0xC1, 0x02, 0x03, 0x00]))
        try notes.write("a.org", "* Pub :crypt:\n" + publicKey + "* Plain\n")
        session.open(file.path)
        try type("* New :crypt:\nnew secret\n", at: (session.document!.text as NSString).length)
        #expect(!session.save())
        #expect(session.unlock("pw", for: file.path) == nil)
        #expect(!disk.contains("new secret"))
        #expect(disk.contains(publicKey))
    }

    // 6
    @Test func keychainItemsAreThisDeviceOnlyAfterUserPresence() throws {
        let item = try #require(CryptPassphrases.newItem("pw", for: "/x/a.org"))
        #expect(item[kSecAttrAccessControl as String] != nil)
        #expect(item[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(item[kSecAttrService as String] as? String == "sh.krz.orgstar.crypt.v2")
        #expect(item[kSecAttrAccessible as String] == nil)
    }
}
