import Foundation
import Testing
@testable import OrgCore

/// Encrypting tagged entries on save (`OrgCrypt.seal`) and whole encrypted files, against
/// gpg and Emacs's EasyPG.
struct CryptFileTests {
    static var oracle: Bool { ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil }
    static var gpg: Bool { OpenPGPTests.gpg != nil }
    static var emacs: Bool { gpg && oracle && EmacsOracle.isAvailable }

    @Test func sealEncryptsTaggedEntriesFromTheTop() throws {
        let (sealed, messages) = try OrgCrypt.seal(OrgCryptTests.file, passphrase: "pw")
        // Bank's tagged child goes inside Bank's message; the empty entry gets one too.
        #expect(messages.map(\.plaintext) == ["Account 12345, ünïcödé.\n** Child\nChild text.\n", "Dear diary.\n", ""])
        let (all, count) = try OrgCrypt.encryptAll(OrgCryptTests.file, passphrase: "pw")
        #expect(count == 3)
        #expect(OrgCryptTests.masked(sealed) == OrgCryptTests.masked(all))
        for (message, plaintext) in messages {
            #expect(sealed.contains(message))
            #expect(try String(decoding: OpenPGP.decrypt(OpenPGP.dearmor(message), passphrase: "pw"), as: UTF8.self) == plaintext)
        }
        // Sealing again changes nothing: every entry is encrypted.
        #expect(try OrgCrypt.seal(sealed, passphrase: "pw").text == sealed)
        // Entries known by their text get their message back.
        let known = Dictionary(uniqueKeysWithValues: messages.map { (OrgCrypt.checksum($0.plaintext), $0.message) })
        #expect(try OrgCrypt.seal(OrgCryptTests.file, passphrase: "pw", reuse: { known[$0] }).text == sealed)
        // Without the tag, the text is as it was.
        #expect(try OrgCrypt.seal("* A\ntext\n", passphrase: "pw").text == "* A\ntext\n")
    }

    @Test func unencryptedEntriesWithText() throws {
        #expect(OrgCrypt.unencrypted(OrgCryptTests.file).count == 2)
        let bank = (OrgCryptTests.file as NSString).range(of: "* TODO Bank").location
        let one = try #require(try OrgCrypt.encrypt(OrgCryptTests.file, at: bank, passphrase: "pw"))
        #expect(OrgCrypt.unencrypted(one).count == 1)
        #expect(OrgCrypt.firstMessage(one).map { OrgCrypt.opens($0, passphrase: "pw") } == true)
        #expect(OrgCrypt.firstMessage(one).map { OrgCrypt.opens($0, passphrase: "other") } == false)
        #expect(OrgCrypt.firstMessage(OrgCryptTests.file) == nil)
        #expect(OrgCrypt.unencrypted("* Empty :crypt:\n\n* B\n").isEmpty)
        #expect(OrgCrypt.unencrypted("#+FILETAGS: :crypt:\n* A\nsecret\n").count == 1)
    }

    @Test func encryptedFilesRoundTrip() throws {
        let text = Data("* Diary\nDear diary, ünïcödé.\n".utf8)
        let binary = try OpenPGP.encryptedMessage(text, passphrase: "pw")
        #expect(!OpenPGP.isArmored(binary))
        #expect(try OpenPGP.decryptFile(binary, passphrase: "pw") == text)
        let armored = Data(try OpenPGP.encrypt(text, passphrase: "pw").utf8)
        #expect(OpenPGP.isArmored(armored))
        #expect(try OpenPGP.decryptFile(armored, passphrase: "pw") == text)
        #expect(throws: OpenPGP.wrongPassphrase) { try OpenPGP.decryptFile(binary, passphrase: "wrong") }
        #expect(throws: OpenPGP.Failure.self) { try OpenPGP.decryptFile(Data("* plain text\n".utf8), passphrase: "pw") }
    }

    @Test(.enabled(if: gpg && oracle))
    func gpgReadsAndWritesEncryptedFiles() throws {
        let text = Data("* Diary\nDear diary, ünïcödé.\n".utf8)
        // `gpg --decrypt` reads orgstar's file, binary as orgstar writes it by default.
        let ours = try OpenPGP.encryptedMessage(text, passphrase: "pass phrase")
        #expect(try OpenPGPTests.gpg(["--passphrase", "pass phrase", "--decrypt"], input: ours) == text)
        // orgstar reads `gpg --symmetric`, binary and armored.
        let theirs = try OpenPGPTests.gpg(["--passphrase", "pass phrase", "--symmetric"], input: text)
        #expect(!OpenPGP.isArmored(theirs))
        #expect(try OpenPGP.decryptFile(theirs, passphrase: "pass phrase") == text)
        let armored = try OpenPGPTests.gpg(["--passphrase", "pass phrase", "--symmetric", "--armor"], input: text)
        #expect(try OpenPGP.decryptFile(armored, passphrase: "pass phrase") == text)
        #expect(throws: OpenPGP.Failure.self) { try OpenPGP.decryptFile(theirs, passphrase: "wrong") }
    }

    /// Emacs with EasyPG (`epa-file`), symmetric, the passphrase given without asking, run on
    /// `file` in a fresh GnuPG home: `form` runs with `file` as the variable `file`.
    static func emacs(_ form: String, in folder: URL) throws -> String {
        let home = "/tmp/ogpg-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            kill.arguments = ["gpgconf", "--homedir", home, "--kill", "gpg-agent"]
            try? kill.run()
            kill.waitUntilExit()
            try? FileManager.default.removeItem(atPath: home)
        }
        let elisp = """
        (progn
          (require 'org) (require 'epa-file) (epa-file-enable)
          (setq epg-pinentry-mode 'loopback epa-pinentry-mode 'loopback epa-file-select-keys 'silent epa-file-encrypt-to nil
                epg-gpg-program \(OrgCryptTests.lisp(OpenPGPTests.gpg!)) default-directory \(OrgCryptTests.lisp(folder.path + "/")))
          (cl-letf (((symbol-function 'epa-file-passphrase-callback-function) (lambda (&rest _) (copy-sequence "pw one")))
                    ((symbol-function 'epa-passphrase-callback-function) (lambda (&rest _) (copy-sequence "pw one"))))
            \(form)))
        """
        return try EmacsOracle.run(["-Q", "--batch", "--eval", elisp], environment: ["GNUPGHOME": home, "TZ": "UTC"])
    }

    @Test(.enabled(if: emacs))
    func emacsOpensWhatOrgstarWritesAndTheReverse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-gpg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = "* Diary :private:\nDear diary, ünïcödé.\n** Child\nMore.\n"
        // orgstar's file, binary and armored, opened by `find-file` in Emacs.
        for (name, data) in [("ours.org.gpg", try OpenPGP.encryptedMessage(Data(text.utf8), passphrase: "pw one")),
                             ("armored.org.gpg", Data(try OpenPGP.encrypt(Data(text.utf8), passphrase: "pw one").utf8))] {
            try data.write(to: folder.appendingPathComponent(name))
            let log = try Self.emacs("""
                (with-current-buffer (find-file-noselect \(OrgCryptTests.lisp(name)))
                  (let ((coding-system-for-write 'utf-8-unix)) (write-region (point-min) (point-max) "out.txt")))
                """, in: folder)
            let read = try? String(contentsOf: folder.appendingPathComponent("out.txt"), encoding: .utf8)
            #expect(read == text, "\(log)")
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("out.txt"))
        }
        // Emacs's file, saved through EasyPG, opened by orgstar.
        let log = try Self.emacs("""
            (with-current-buffer (find-file-noselect "theirs.org.gpg")
              (insert \(OrgCryptTests.lisp(text)))
              (let ((coding-system-for-write 'utf-8-unix)) (save-buffer)))
            """, in: folder)
        let theirs = try Data(contentsOf: folder.appendingPathComponent("theirs.org.gpg"))
        #expect(theirs.range(of: Data("Dear diary".utf8)) == nil, "\(log)")
        #expect(String(decoding: try OpenPGP.decryptFile(theirs, passphrase: "pw one"), as: UTF8.self) == text)
        #expect(throws: OpenPGP.Failure.self) { try OpenPGP.decryptFile(theirs, passphrase: "wrong") }
    }

    @Test(.enabled(if: emacs))
    func orgCryptKeepsAnUnchangedEntrysMessageAsOrgstarDoes() throws {
        // Emacs: an entry decrypted and encrypted again, unchanged, gets its own message back.
        // An entry with no text has none to carry the old message, and gets a new one.
        let file = OrgCryptTests.file.replacingOccurrences(of: "* Empty :crypt:\n", with: "")
        let (sealed, _) = try OrgCrypt.seal(file, passphrase: "pw one")
        let again = try OrgCryptTests.emacs(sealed, "(org-decrypt-entries) (org-encrypt-entries)")
        #expect(again == sealed)
        // And reads what orgstar sealed.
        #expect(try OrgCryptTests.emacs(sealed, "(org-decrypt-entries)") == file)
    }
}
