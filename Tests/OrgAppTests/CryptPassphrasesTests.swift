import Foundation
import LocalAuthentication
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// The Keychain's stand-in: saved passphrases by path, and every call made.
@MainActor
final class FakeKeychain: PassphraseKeychain {
    var saved: [String: String]
    var calls: [String] = []
    var contexts: [LAContext] = []

    init(_ saved: [String: String] = [:]) {
        self.saved = saved
    }

    /// Passphrases with `setting`, over a new stand-in holding `saved`.
    static func passphrases(_ setting: CryptPassphrases.Setting, saved: [String: String] = [:], defaults: UserDefaults = TestDefaults("crypt")) -> (keychain: FakeKeychain, passphrases: CryptPassphrases) {
        if setting != .undecided { defaults.set(setting.rawValue, forKey: CryptPassphrases.settingKey) }
        let keychain = FakeKeychain(saved)
        return (keychain, CryptPassphrases(keychain: keychain, defaults: defaults))
    }

    func contains(_ path: String) -> Bool {
        calls.append("contains \(path)")
        return saved[path] != nil
    }

    func read(_ path: String, context: LAContext) async -> String? {
        calls.append("read \(path)")
        contexts.append(context)
        return saved[path]
    }

    func write(_ passphrase: String, for path: String) -> String? {
        calls.append("write \(path)")
        saved[path] = passphrase
        return nil
    }

    func delete(_ path: String) {
        calls.append("delete \(path)")
        saved[path] = nil
    }

    func deleteAll() {
        calls.append("deleteAll")
        saved = [:]
    }

    /// The listing finds nothing, as when the Keychain refuses it.
    var listingFails = false

    func paths() -> [String] {
        calls.append("paths")
        return listingFails ? [] : Array(saved.keys)
    }
}

/// "Use Face ID to Decrypt": the Keychain is used only while it's on.
@MainActor
struct CryptPassphrasesTests {
    static let secret = "Account 12345"
    let notes: Folder

    init() throws {
        notes = try Folder()
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Every way a saved passphrase was read: commands, opening a `.org.gpg`, Encrypt… on a held
    /// file and encrypt-on-save. Off or undecided, none of them reaches the Keychain, though it
    /// holds the files' passphrases (as saved by an earlier version).
    @Test(arguments: [CryptPassphrases.Setting.undecided, .off])
    func notOnTouchesNoKeychain(_ setting: CryptPassphrases.Setting) async throws {
        let file = try notes.write("a.org", "* Plain\n")
        let gpg = notes.url.appendingPathComponent("b.org.gpg")
        try OpenPGP.encryptedMessage(Data("* B\n".utf8), passphrase: "pw").write(to: gpg)
        let (keychain, passphrases) = FakeKeychain.passphrases(setting, saved: [file.path: "pw", gpg.path: "pw"])
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".recovery")))
        session.saveMode = .explicit
        session.encryptsTaggedEntries = true
        session.passphrases = passphrases

        // Encrypt-on-save holds the file: no passphrase in memory, none read.
        session.open(file.path)
        let buffer = StateBuffer(session.document!)
        session.attach(buffer)
        try buffer.update { try $0.apply([TextEdit(range: 8..<8, replacement: "* Bank :crypt:\n\(Self.secret)\n")], baseRevision: $0.revision) }
        session.bufferChanged()
        #expect(!session.save())
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.held[file.path] == .entries(1))
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains(Self.secret))

        // An encrypted file waits for its typed passphrase.
        session.open(gpg.path)
        #expect(session.unlockRequest == gpg.path && !session.isOpen(gpg.path))

        // The sheet's read (the org-crypt commands, Decrypt File, Encrypt… on a held file), and
        // a typed passphrase that worked.
        #expect(await passphrases.stored(for: file.path) == nil)
        #expect(await passphrases.stored(for: gpg.path) == nil)
        #expect(!passphrases.hasStored(file.path))
        #expect(passphrases.keep("typed", for: file.path, text: "") == nil)
        #expect(session.unlock("pw", for: gpg.path) == nil)
        #expect(session.isOpen(gpg.path))

        #expect(keychain.calls.isEmpty)
        #expect(keychain.saved == [file.path: "pw", gpg.path: "pw"])
    }

    @Test func onSavesATypedPassphraseAndReadsItThroughTheFilesAuthentication() async throws {
        let (keychain, passphrases) = FakeKeychain.passphrases(.on)
        #expect(!passphrases.asksFirst)
        #expect(passphrases.keep("pw", for: "/x/a.org", text: "") == nil)
        #expect(keychain.saved == ["/x/a.org": "pw"])
        #expect(passphrases.savedPaths == ["/x/a.org"])
        #expect(passphrases.hasStored("/x/a.org"))
        #expect(await passphrases.stored(for: "/x/a.org") == "pw")
        #expect(await passphrases.stored(for: "/x/a.org") == "pw")
        let context = passphrases.context(for: "/x/a.org")
        #expect(keychain.contexts.count == 2 && keychain.contexts.allSatisfy { $0 === context })
        // Closing the file ends its authentication; the next read asks again.
        passphrases.endSession(for: "/x/a.org")
        #expect(await passphrases.stored(for: "/x/a.org") == "pw")
        #expect(keychain.contexts.last !== context)
        #expect(await passphrases.stored(for: "/x/b.org") == nil)
    }

    @Test func onEncryptOnSaveUsesTheSavedPassphrase() async throws {
        let file = try notes.write("a.org", "* Bank :crypt:\nold\n")
        let (keychain, passphrases) = FakeKeychain.passphrases(.on, saved: [file.path: "pw"])
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".recovery")))
        session.saveMode = .explicit
        session.encryptsTaggedEntries = true
        session.passphrases = passphrases
        session.open(file.path)
        let buffer = StateBuffer(session.document!)
        session.attach(buffer)
        try buffer.update { try $0.apply([TextEdit(range: 15..<18, replacement: Self.secret)], baseRevision: $0.revision) }
        session.bufferChanged()
        #expect(!session.save())
        try await wait { !session.isDirty }
        #expect(session.held.isEmpty)
        #expect(keychain.calls.filter { $0.hasPrefix("read ") } == ["read \(file.path)"])
        let disk = try String(contentsOf: file, encoding: .utf8)
        #expect(!disk.contains(Self.secret))
        #expect(try OrgCrypt.decrypt(disk, at: 0, passphrase: "pw").plaintext == Self.secret + "\n")
    }

    @Test func theQuestionIsAskedOnce() {
        let defaults = TestDefaults("crypt")
        // Undecided: the first typed passphrase asks, and isn't saved before the answer.
        let (keychain, passphrases) = FakeKeychain.passphrases(.undecided, defaults: defaults)
        #expect(passphrases.setting == .undecided && passphrases.asksFirst)
        #expect(passphrases.keep("pw", for: "/x/a.org", text: "") == nil && keychain.saved.isEmpty)
        // Not Now turns it off, for good.
        passphrases.answer(enable: false)
        #expect(passphrases.setting == .off && !passphrases.asksFirst)
        #expect(passphrases.keep("pw", for: "/x/a.org", text: "") == nil && keychain.saved.isEmpty)
        let later = CryptPassphrases(keychain: FakeKeychain(["/x/old.org": "pw"]), defaults: defaults)
        #expect(later.setting == .off && !later.asksFirst)
        later.askIfSavedBefore()
        #expect(!later.asking)
        // Enable turns it on and saves the passphrase.
        let (enabled, enabling) = FakeKeychain.passphrases(.undecided)
        enabling.answer(enable: true)
        #expect(enabling.setting == .on && !enabling.asksFirst)
        enabling.keep("pw", for: "/x/a.org", text: "")
        #expect(enabled.saved == ["/x/a.org": "pw"])
    }

    /// Passphrases an earlier version saved: the first launch asks, and they aren't read before
    /// the answer.
    @Test func savedPassphrasesFromBeforeAskAtLaunch() async {
        let defaults = TestDefaults("crypt")
        let (keychain, passphrases) = FakeKeychain.passphrases(.undecided, saved: ["/x/old.org": "pw"], defaults: defaults)
        passphrases.askIfSavedBefore()
        #expect(passphrases.asking)
        #expect(await passphrases.stored(for: "/x/old.org") == nil)
        #expect(keychain.calls == ["paths"])
        passphrases.answer(enable: true)
        #expect(!passphrases.asking)
        #expect(await passphrases.stored(for: "/x/old.org") == "pw")
        let next = CryptPassphrases(keychain: keychain, defaults: defaults)
        next.askIfSavedBefore()
        #expect(!next.asking && next.setting == .on)
        // None saved: nothing to ask until a passphrase is typed.
        let (_, empty) = FakeKeychain.passphrases(.undecided)
        empty.askIfSavedBefore()
        #expect(!empty.asking && empty.setting == .undecided)
    }

    @Test func turningOffRemovesEverySavedPassphrase() async {
        let (keychain, passphrases) = FakeKeychain.passphrases(.on, saved: ["/x/a.org": "a", "/x/b.org.gpg": "b"])
        passphrases.refresh()
        #expect(passphrases.savedPaths == ["/x/a.org", "/x/b.org.gpg"])
        #expect(CryptPassphrases.removal(passphrases.savedPaths.count).contains("2 files"))
        #expect(CryptPassphrases.removal(1).contains("1 file"))
        _ = await passphrases.stored(for: "/x/a.org")
        let context = passphrases.context(for: "/x/a.org")
        passphrases.turnOff()
        #expect(passphrases.setting == .off)
        #expect(keychain.saved.isEmpty && passphrases.savedPaths.isEmpty)
        #expect(keychain.calls.contains("deleteAll"))
        #expect(passphrases.context(for: "/x/a.org") !== context)
        // Forget in Settings removes one.
        let (one, forgetting) = FakeKeychain.passphrases(.on, saved: ["/x/a.org": "a", "/x/b.org": "b"])
        forgetting.refresh()
        forgetting.forget("/x/a.org")
        #expect(one.saved == ["/x/b.org": "b"] && forgetting.savedPaths == ["/x/b.org"])
    }

    @Test func theSettingIsKeptInUserDefaults() {
        let defaults = TestDefaults("crypt")
        let (_, passphrases) = FakeKeychain.passphrases(.undecided, defaults: defaults)
        passphrases.turnOn()
        #expect(defaults.string(forKey: "decryptWithBiometrics") == "on")
        passphrases.turnOff()
        #expect(defaults.string(forKey: "decryptWithBiometrics") == "off")
    }

    // MARK: - Review of MR 494

    /// Two entries, A encrypted with "pw" and B with "other".
    static func twoPassphrases() throws -> String {
        let text = "* A :crypt:\na\n* B :crypt:\nb\n"
        let a = try #require(try OrgCrypt.encrypt(text, at: 0, passphrase: "pw"))
        let b = (a as NSString).range(of: "* B").location
        return try #require(try OrgCrypt.encrypt(a, at: b, passphrase: "other"))
    }

    /// 1: a passphrase is saved only when it opens every message in the file.
    @Test func onlyAPassphraseThatOpensEveryMessageIsSaved() throws {
        let mixed = try Self.twoPassphrases()
        #expect(OrgCrypt.messages(mixed).count == 2)
        let (keychain, passphrases) = FakeKeychain.passphrases(.on, saved: ["/x/a.org": "saved"])
        // Encrypting an entry with "pw" beside one encrypted with "other": not saved, and the
        // saved one stays.
        #expect(passphrases.keep("pw", for: "/x/a.org", text: mixed) == nil)
        #expect(keychain.saved == ["/x/a.org": "saved"])
        #expect(!keychain.calls.contains { $0.hasPrefix("write ") })
        // One that opens them all, or a file with no other message, is saved.
        let one = try #require(try OrgCrypt.encrypt("* A :crypt:\na\n", at: 0, passphrase: "pw"))
        passphrases.keep("pw", for: "/x/a.org", text: one)
        #expect(keychain.saved == ["/x/a.org": "pw"])
        passphrases.keep("new", for: "/x/b.org", text: "* Plain\n")
        #expect(keychain.saved["/x/b.org"] == "new")
    }

    /// 1: the sheet's path, through the question, checks the same way.
    @Test func theQuestionsAnswerSavesOnlyAPassphraseThatFits() throws {
        let mixed = try Self.twoPassphrases()
        let (keychain, passphrases) = FakeKeychain.passphrases(.undecided)
        var note: String?
        #expect(passphrases.typed("pw", for: "/x/a.org", text: mixed, note: &note))
        #expect(passphrases.answer(enable: true, passphrase: "pw", for: "/x/a.org", text: mixed) == nil)
        #expect(passphrases.setting == .on && keychain.saved.isEmpty)
        #expect(!passphrases.typed("other", for: "/x/a.org", text: "* Plain\n", note: &note))
        #expect(keychain.saved == ["/x/a.org": "other"])
    }

    /// 1: unlocking a file with a passphrase that opens its first message but not another.
    @Test func unlockingWithAPassphraseThatOpensOnlySomeMessagesSavesNothing() async throws {
        let mixed = try Self.twoPassphrases()
        let file = try notes.write("a.org", mixed)
        let (keychain, passphrases) = FakeKeychain.passphrases(.on, saved: [file.path: "saved"])
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".recovery")))
        session.saveMode = .explicit
        session.passphrases = passphrases
        session.open(file.path)
        #expect(session.unlock("pw", for: file.path) == nil)
        passphrases.keep("pw", for: file.path, text: session.document(of: file.path)?.text ?? "")
        #expect(keychain.saved == [file.path: "saved"])
    }

    /// 2: a question answered after the setting was decided elsewhere changes nothing.
    @Test func aLateAnswerChangesNothing() {
        // Two sheets asked; the first said Enable, the second Not Now.
        let (keychain, passphrases) = FakeKeychain.passphrases(.undecided)
        var note: String?
        #expect(passphrases.typed("a", for: "/x/a.org", text: "", note: &note))
        #expect(passphrases.typed("b", for: "/x/b.org", text: "", note: &note))
        _ = passphrases.answer(enable: true, passphrase: "a", for: "/x/a.org", text: "")
        _ = passphrases.answer(enable: false, passphrase: "b", for: "/x/b.org", text: "")
        #expect(passphrases.setting == .on)
        #expect(keychain.saved == ["/x/a.org": "a"])
        // Settings turned it off while the question was open: Enable doesn't turn it on.
        let (other, settings) = FakeKeychain.passphrases(.undecided)
        #expect(settings.typed("a", for: "/x/a.org", text: "", note: &note))
        settings.turnOff()
        _ = settings.answer(enable: true, passphrase: "a", for: "/x/a.org", text: "")
        #expect(settings.setting == .off && other.saved.isEmpty)
        // The launch question too.
        let (_, launch) = FakeKeychain.passphrases(.off)
        launch.asking = true
        #expect(!launch.answer(enable: true))
        #expect(launch.setting == .off && !launch.asking)
    }

    /// 2: Not Now leaves earlier passphrases in place, unread, listed for Forget.
    @Test func notNowKeepsEarlierPassphrasesListed() async {
        let (keychain, passphrases) = FakeKeychain.passphrases(.undecided, saved: ["/x/old.org": "pw"])
        passphrases.askIfSavedBefore()
        passphrases.answer(enable: false)
        #expect(keychain.saved == ["/x/old.org": "pw"])
        #expect(await passphrases.stored(for: "/x/old.org") == nil)
        passphrases.refresh()
        #expect(passphrases.savedPaths == ["/x/old.org"])
    }

    /// 3: turning off deletes by service, so a listing that fails leaves nothing behind.
    @Test func turningOffDeletesEverythingWhenTheListingFails() {
        let (keychain, passphrases) = FakeKeychain.passphrases(.on, saved: ["/x/a.org": "a", "/x/b.org": "b"])
        keychain.listingFails = true
        passphrases.turnOff()
        #expect(keychain.saved.isEmpty)
    }

    /// 4: the test process's sessions get no Keychain, whatever the setting in user defaults.
    @Test func testSessionsDontReachTheKeychain() {
        #expect(CryptPassphrases.shared.keychain is NoKeychain)
        #expect(DocumentSession(recovery: FileRecoveryStore(directory: notes.url)).passphrases.keychain is NoKeychain)
    }
}
