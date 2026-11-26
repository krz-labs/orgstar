import CryptoKit
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
        let text = "* Parent :crypt:\nparent text\n** SECRETTITLE child\nchild secret\n* Other :crypt:\nother secret\n* Last\n"
        try notes.write("a.org", text)
        session.open(file.path)
        let child = (text as NSString).range(of: "** SECRETTITLE").location
        let archive = notes.url.appendingPathComponent("a.org_archive")
        // A heading inside an encrypted entry isn't moved on its own, passphrase or not.
        #expect(session.archive(from: (file.path, child))?.contains("inside an encrypted entry") == true)
        session.cryptUsed("pw", for: file.path)
        #expect(session.archive(from: (file.path, child))?.contains("inside an encrypted entry") == true)
        let target = RefileTarget(label: "b.org", path: try notes.write("b.org", "* B\n").path, start: nil, title: "", level: 0, contentHash: "")
        #expect(session.refile(to: target, from: (file.path, child))?.contains("inside an encrypted entry") == true)
        #expect(!FileManager.default.fileExists(atPath: archive.path) && !read(notes.url.appendingPathComponent("b.org")).contains("SECRETTITLE"))
        // A tagged entry is encrypted where it is, then archived.
        let other = (session.document!.text as NSString).range(of: "* Other").location
        #expect(session.archive(from: (file.path, other)) == "Archived to a.org_archive")
        #expect(!read(archive).contains("other secret") && read(archive).contains("-----BEGIN PGP MESSAGE-----"))
        #expect(session.save())
        #expect(!disk.contains("child secret") && !disk.contains("SECRETTITLE"))
    }

    // Third review, A and B
    @Test func shareSubtreeOfAHeadingInsideAnEncryptedEntry() throws {
        let text = "* Parent :crypt:\nparent text\n** SECRETTITLE child\nchild secret\n* Last\n"
        try notes.write("a.org", text)
        session.open(file.path)
        session.cryptUsed("pw", for: file.path)
        let child = (text as NSString).range(of: "** SECRETTITLE").location
        let share = try #require(session.subtreeShare(file.path, at: child))
        #expect(share.fileName == "Encrypted entry.org")
        #expect(!share.text.contains("SECRETTITLE") && !share.text.contains("child secret") && share.text.hasPrefix("* Encrypted entry :crypt:\n"))
        let opened = try OrgCrypt.decryptInPlace(share.text, at: 0, passphrase: "pw")
        #expect(opened.contains("** SECRETTITLE child\nchild secret\n"))
        // Capture under that heading, into the file closed, isn't written.
        session.kill(file.path)
        let template = CaptureTemplate(key: "s", name: "Secret", target: .headline(file: file.path, headline: "SECRETTITLE child"), template: "* %?")
        if case .success = session.capture("** Captured\n", template: template, root: nil) { Issue.record("captured into plaintext") }
        #expect(disk == text)
    }

    @Test func shareSubtreeRefusesWhatCantBeEncrypted() throws {
        let text = "* A :crypt:\na secret\n* B :crypt:\nb secret\n* End\n"
        var both = try #require(try OrgCrypt.encrypt(text, at: 0, passphrase: "one"))
        both = try #require(try OrgCrypt.encrypt(both, at: (both as NSString).range(of: "* B").location, passphrase: "two"))
        try notes.write("a.org", both)
        session.open(file.path)
        session.cryptUsed("one", for: file.path)
        try type("typed below b\n", at: offset(of: "* End"))
        let b = offset(of: "* B")
        #expect(session.refusesSubtreeShare(file.path, at: b)?.contains("public key") == true)
        #expect(session.subtreeShare(file.path, at: b) == nil)
    }

    // Final check, 1
    @Test func closedFilesPutBackAVersionTheyCantKeep() throws {
        let files = InjectingFileSystem()
        let session = DocumentSession(fileSystem: files, recovery: FileRecoveryStore(directory: recoveryFolder))
        session.encryptsTaggedEntries = true
        session.hasStoredPassphrase = { _ in false }
        let theirs = "* B\nb\n* Emacs :crypt:\nemacs secret\n* Work\nEMACSWORK\n"
        let b = try notes.write("b.org", "* B\nb\n")
        func check(_ message: String?, _ what: String) {
            #expect(message?.contains("changed on disk") == true, "\(what): \(String(describing: message))")
            #expect(read(b) == theirs, "\(what)")
            #expect(recoveryFiles.allSatisfy { !$0.contains("emacs secret") }, "\(what)")
            try? notes.write("b.org", "* B\nb\n")
        }
        // Replace in Files.
        files.inject[b.path] = theirs
        check(session.applyChanges([TextEdit(range: 4..<5, replacement: "c")], to: b.path, expecting: "* B\nb\n"), "replace")
        // Agenda actions, the clock and capture run commands on the file.
        files.inject[b.path] = theirs
        if case .failed(let message) = session.perform(PrecomputedEdit(EditResult(baseRevision: 0, edits: [TextEdit(range: 4..<5, replacement: "c")])), path: b.path, at: 0, expect: nil) {
            check(message, "perform")
        } else {
            Issue.record("perform succeeded")
        }
        // Refile into it, and a new heading under its heading.
        try notes.write("a.org", "* Moved\nmoved text\n")
        session.open(file.path)
        files.inject[b.path] = theirs
        let target = RefileTarget(label: "b.org", path: b.path, start: nil, title: "", level: 0, contentHash: "")
        check(session.refile(to: target, from: (file.path, 0)), "refile")
        #expect(disk == "* Moved\nmoved text\n")
        files.inject[b.path] = theirs
        if case .failure(.message(let message)) = session.createRefileChild(under: target, title: "New") { check(message, "child") } else { Issue.record("child added") }
        // Archive into it.
        try notes.write("a.org", "#+ARCHIVE: b.org::\n* Old\nold text\n")
        session.kill(file.path)
        session.open(file.path)
        files.inject[b.path] = theirs
        check(session.archive(from: (file.path, 19)), "archive")
        // An open file merges it as before.
        session.open(b.path)
        let buffer = StateBuffer(session.document(of: b.path)!)
        session.attach(buffer, for: b.path)
        try buffer.update { try $0.apply([TextEdit(range: 0..<0, replacement: "x")], baseRevision: $0.revision) }
        session.bufferChanged(b.path)
        files.inject[b.path] = theirs
        _ = session.save(b.path)
        #expect(session.document(of: b.path)?.text.contains("EMACSWORK") == true)
    }

    // Final check, 2
    @Test func sameFileMovesDontTakeAHeadingOutOfItsEntry() throws {
        let text = "#+ARCHIVE: ::* Archive\n* Parent :crypt:\nparent text\n** SECRETTITLE child\nchild secret\n* Last\n"
        try notes.write("a.org", text)
        session.open(file.path)
        session.cryptUsed("pw", for: file.path)
        let child = (text as NSString).range(of: "** SECRETTITLE").location
        let target = RefileTarget(label: "a.org", path: file.path, start: nil, title: "", level: 0, contentHash: "")
        #expect(session.refile(to: target, from: (file.path, child))?.contains("inside an encrypted entry") == true)
        #expect(session.archive(from: (file.path, child))?.contains("inside an encrypted entry") == true)
        #expect(session.document?.text == text)
        // An entry not inside one moves as before.
        #expect(session.refile(to: target, from: (file.path, (text as NSString).range(of: "* Last").location)) != nil)
    }

    // Final check, 3
    @Test func hiddenTitlesAreHashedWithAKey() throws {
        ClockTask.titleKey = nil
        let session = ClockTask(path: "/x", title: "Real", ordinal: 0, id: nil).hiding("Encrypted entry")
        #expect(session.isSessionOnly && session.titleHash != OrgCrypt.checksum("Real"))
        #expect(session.locate(in: "* Real\n") == 0)
        let key = SymmetricKey(size: .bits256)
        ClockTask.titleKey = key
        defer { ClockTask.titleKey = nil }
        let kept = ClockTask(path: "/x", title: "Real", ordinal: 0, id: nil).hiding("Encrypted entry")
        #expect(!kept.isSessionOnly && kept.titleHash != OrgCrypt.checksum("Real") && kept.locate(in: "* Real\n") == 0)
        // Hidden tasks that can be found only in this run aren't written to the clock's file.
        ClockTask.titleKey = nil
        let text = "* Bank :crypt:\nintro\n** Secret task\nbody\n"
        try notes.write("a.org", text)
        self.session.open(file.path)
        self.session.cryptUsed("pw", for: file.path)
        let clockFile = notes.url.appendingPathComponent("clock.json")
        let clock = ClockModel(file: clockFile)
        _ = clock.clockIn(self.session, path: file.path, at: (text as NSString).range(of: "** Secret").location)
        _ = clock.clockOut(self.session)
        #expect(clock.history.count == 1)
        #expect(!read(clockFile).contains("s:"))
    }

    // Third review, C
    @Test func hiddenClockTasksNeedTheirTitle() throws {
        let hidden = ClockTask(path: "/x", title: "Real", ordinal: 1, id: nil).hiding("Encrypted entry")
        #expect(hidden.title == "Encrypted entry" && hidden.titleHash != nil)
        #expect(hidden.locate(in: "* A\n* Real\n") == 4)
        #expect(hidden.locate(in: "* New\n* A\n* Real\n") == 10)
        #expect(hidden.locate(in: "* A\n* Renamed\n") == nil)
        #expect(hidden.refreshed(in: "* New\n* A\n* Real\n")?.title == "Encrypted entry")
    }

    // Third review, D2
    @Test func keepMineHoldsWhenTheDiskVersionCantBeKept() throws {
        session.open(file.path)
        try type("x", at: 0)
        try notes.write("a.org", "* Plain\n* Theirs :crypt:\ntheir secret\n")
        session.keepMine()
        #expect(session.held[file.path] == .entries(1) && session.lastError == nil)
        #expect(disk.contains("their secret") && recoveryFiles.isEmpty)
    }

    // Third review, 3
    @Test func aCancelledOpenEndsItsAuthentication() throws {
        let path = notes.url.appendingPathComponent("d.org.gpg")
        try OpenPGP.encryptedMessage(Data("* D\n".utf8), passphrase: "pw").write(to: path)
        session.open(path.path)
        let context = CryptPassphrases.context(for: path.path)
        session.cancelUnlock()
        #expect(CryptPassphrases.context(for: path.path) !== context)
        CryptPassphrases.endSession(for: path.path)
        #expect(!CryptPassphrases.protectsItems)
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

    // Second review, 2
    @Test func clockHistoryKeepsNoEncryptedTitle() throws {
        let text = "* Bank :crypt:\nintro\n** Secret task\n:PROPERTIES:\n:ID: s-1\n:END:\nbody\n** Hidden no id\nmore\n* Open task\n"
        try notes.write("a.org", text)
        session.open(file.path)
        session.cryptUsed("pw", for: file.path)
        let clockFile = notes.url.appendingPathComponent("clock.json")
        let clock = ClockModel(file: clockFile)
        _ = clock.clockIn(session, path: file.path, at: (text as NSString).range(of: "** Secret").location)
        _ = clock.clockIn(session, path: file.path, at: (session.document!.text as NSString).range(of: "** Hidden").location)
        _ = clock.clockIn(session, path: file.path, at: (session.document!.text as NSString).range(of: "* Open").location)
        #expect(!read(clockFile).contains("Secret task") && !read(clockFile).contains("Hidden no id"))
        #expect(clock.history.map(\.title) == ["Open task", "Encrypted entry", "Encrypted entry"])
    }

    // Second review, 3
    @Test func eachFileHasItsOwnAuthentication() throws {
        let a = CryptPassphrases.context(for: "/x/a.org"), b = CryptPassphrases.context(for: "/x/b.org")
        #expect(a !== b && CryptPassphrases.context(for: "/x/a.org") === a)
        #expect(a.touchIDAuthenticationAllowableReuseDuration == 0)
        CryptPassphrases.endSession(for: "/x/a.org")
        #expect(CryptPassphrases.context(for: "/x/a.org") !== a)
    }

    // Second review, 4a
    @Test func anEntryThePassphraseCantEncryptHoldsTheFile() throws {
        let text = "* A :crypt:\na secret\n* B :crypt:\nb secret\n* End\n"
        var both = try #require(try OrgCrypt.encrypt(text, at: 0, passphrase: "one"))
        both = try #require(try OrgCrypt.encrypt(both, at: (both as NSString).range(of: "* B").location, passphrase: "two"))
        try notes.write("a.org", both)
        session.open(file.path)
        #expect(session.unlock("one", for: file.path) == nil)
        try type("typed below b\n", at: offset(of: "* End"))
        #expect(!session.save())
        guard case .blocked(let reason)? = session.held[file.path] else { Issue.record("\(String(describing: session.held[file.path]))"); return }
        #expect(reason.contains("public key") && session.lastError == nil)
        #expect(OrgCrypt.Failure("x").localizedDescription == "x")
        #expect(!disk.contains("typed below b"))
    }

    // Second review, 4b
    @Test func plaintextEntriesOnDiskHoldTheFileUntilThePassphrase() throws {
        session.open(file.path)
        try type("x", at: 0)
        // Written elsewhere, with no file event.
        try notes.write("a.org", "* Plain\nOpen text.\n* Last\n* Theirs :crypt:\ntheir secret\n")
        #expect(!session.save())
        #expect(session.held[file.path] == .entries(1) && session.lastError == nil)
        #expect(session.unlock("pw", for: file.path) == nil)
        #expect(!session.isDirty && !disk.contains("their secret") && session.document?.text.contains("their secret") == true)
        #expect(recoveryFiles.allSatisfy { !$0.contains("their secret") })
    }

    // Second review, 6
    @Test func anEncryptedFileSavesWithOneKey() throws {
        let path = notes.url.appendingPathComponent("d.org.gpg")
        try OpenPGP.encryptedMessage(Data("* D\nbody\n".utf8), passphrase: "pw").write(to: path)
        session.open(path.path)
        #expect(session.unlock("pw", for: path.path) == nil)
        try type("x", at: 0)
        #expect(session.save())
        let clock = ContinuousClock()
        var took: [Duration] = []
        for n in 0..<3 {
            try type("\(n)", at: 0)
            took.append(clock.measure { _ = session.save() })
        }
        print("Autosave of an .org.gpg file: \(took)")
        #expect(try OpenPGP.decryptFile(Data(contentsOf: path), passphrase: "pw") == Data("210x* D\nbody\n".utf8))
    }

    // MR 490 hooks
    @Test func handoffAndShareSubtreeKeepWhatIsEncrypted() throws {
        let text = "* Bank :crypt:\nintro\n** Secret child\nbody\n* Open\n"
        try notes.write("a.org", text)
        session.open(file.path)
        let child = (text as NSString).range(of: "** Secret").location
        // Without the passphrase, the subtree isn't shared.
        #expect(session.handoffPlace(file.path, roots: [notes.url.path]) == nil)
        #expect(session.refusesSubtreeShare(file.path, at: child)?.contains("Encrypt…") == true)
        #expect(session.subtreeShare(file.path, at: child) == nil)
        session.cryptUsed("pw", for: file.path)
        let share = try #require(session.subtreeShare(file.path, at: child))
        #expect(!share.text.contains("body") && share.text.contains("-----BEGIN PGP MESSAGE-----"))
        #expect(session.document?.text == text)
        let bank = try #require(session.subtreeShare(file.path, at: 0))
        #expect(!bank.text.contains("intro") && !bank.text.contains("Secret child"))
        // An open file without tagged entries is advertised as before.
        let plain = try notes.write("b.org", "* Plain\n")
        session.open(plain.path)
        #expect(session.handoffPlace(plain.path, roots: [notes.url.path]) != nil)
        // An encrypted file's entries aren't shared.
        let gpg = notes.url.appendingPathComponent("d.org.gpg")
        try OpenPGP.encryptedMessage(Data("* D\nsecret\n".utf8), passphrase: "pw").write(to: gpg)
        session.open(gpg.path)
        #expect(session.unlock("pw", for: gpg.path) == nil)
        #expect(session.refusesSubtreeShare(gpg.path, at: 0) != nil && session.subtreeShare(gpg.path, at: 0) == nil)
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

/// The disk, with another writer that puts `inject[path]` in place just before a replace.
final class InjectingFileSystem: FileSystem, @unchecked Sendable {
    let base = CoordinatedFileSystem(writesInPlaceWhenDenied: false)
    var inject: [String: String] = [:]

    func read(_ url: URL) throws -> [UInt8]? { try base.read(url) }

    func replace(_ url: URL, with bytes: [UInt8]) throws -> [UInt8]? {
        if let text = inject.removeValue(forKey: url.path) { try Data(text.utf8).write(to: url) }
        return try base.replace(url, with: bytes)
    }
}
