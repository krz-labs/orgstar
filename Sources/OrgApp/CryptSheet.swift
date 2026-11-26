import Foundation
import OrgCore
import OrgDocument
import SwiftUI

/// What an org-crypt command does with the entry at `offset` in the file at `path`.
public struct CryptRequest: Identifiable, Sendable {
    public enum Mode: Sendable {
        /// `org-encrypt-entry`.
        case encrypt
        /// `org-encrypt-entries`, with `org-crypt-tag-matcher`'s tag.
        case encryptAll(tag: String)
        /// The decrypted text, to read and change; the file keeps it encrypted.
        case open
        /// `org-decrypt-entry`: the decrypted text in the file.
        case decryptInPlace
        /// The passphrase a held save needs, to encrypt the tagged entries as the file is saved.
        case encryptOnSave
        /// The passphrase of an encrypted file (`.org.gpg`), to open it.
        case openFile
        /// The passphrase a new encrypted file is saved with.
        case newFile
    }

    public let id = UUID()
    public let mode: Mode
    public let path: String
    public let offset: Int

    public init(mode: Mode, path: String, offset: Int) {
        self.mode = mode
        self.path = path
        self.offset = offset
    }

    var encrypting: Bool {
        switch mode {
        case .encrypt, .encryptAll, .encryptOnSave, .newFile: true
        default: false
        }
    }

    /// The passphrase goes to the session, which checks it and saves or opens the file.
    var unlocks: Bool {
        switch mode {
        case .encryptOnSave, .openFile, .newFile: true
        default: false
        }
    }

    /// The request for what keeps `path` from being saved.
    public static func save(_ path: String, hold: CryptHold) -> CryptRequest {
        CryptRequest(mode: hold == .file ? .newFile : .encryptOnSave, path: path, offset: 0)
    }
}

/// The passphrase for an org-crypt command, from the Keychain when it was remembered, then for
/// `open` the decrypted entry to edit. `text` is the file's text now; `apply` puts a new text
/// in its place; `done` closes the sheet with a message. `session` learns the passphrase, so
/// saves encrypt with it without asking again.
public struct CryptSheet: View {
    let request: CryptRequest
    let session: DocumentSession?
    let text: () -> String
    let apply: (String) -> Void
    let done: (String?) -> Void
    @State private var passphrase = ""
    @State private var repeated = ""
    @State private var remember = false
    @State private var problem: String?
    /// The decrypted entry being edited, and the passphrase it came with.
    @State private var editing: (original: String, passphrase: String)?
    @State private var plaintext = ""

    public init(request: CryptRequest, session: DocumentSession? = nil, text: @escaping () -> String, apply: @escaping (String) -> Void, done: @escaping (String?) -> Void) {
        self.request = request
        self.session = session
        self.text = text
        self.apply = apply
        self.done = done
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editing != nil {
                Text("Encrypted Entry").font(.headline)
                TextEditor(text: $plaintext)
                    .font(.body.monospaced())
                    .frame(minHeight: 220)
                if let problem { Text(problem).foregroundStyle(.red).font(.callout) }
                HStack {
                    Button("Decrypt in File") { decryptEdited() }
                    Spacer()
                    Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                    Button("Save") { save() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text(title).font(.headline)
                if let explanation { Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                SecureField("Passphrase", text: $passphrase).onSubmit(submit)
                if asksTwice { SecureField("Repeat passphrase", text: $repeated).onSubmit(submit) }
                Toggle("Remember in the Keychain", isOn: $remember)
                if let problem { Text(problem).foregroundStyle(.red).font(.callout) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { cancel() }.keyboardShortcut(.cancelAction)
                    Button(request.encrypting ? "Encrypt" : "Decrypt") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(passphrase.isEmpty)
                }
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 460)
        #else
        .frame(maxHeight: .infinity, alignment: .top)
        #endif
        .task {
            if let stored = await CryptPassphrases.stored(for: request.path) { run(stored, remembered: true) }
        }
    }

    private var title: String {
        switch request.mode {
        case .encrypt: "Encrypt Entry"
        case .encryptAll: "Encrypt Tagged Entries"
        case .open, .decryptInPlace: "Decrypt Entry"
        case .encryptOnSave: String(localized: "Encrypt Tagged Entries")
        case .openFile: String(localized: "Decrypt File")
        case .newFile: String(localized: "Set Passphrase")
        }
    }

    private var name: String { (request.path as NSString).lastPathComponent }

    private var explanation: String? {
        switch request.mode {
        case .encryptOnSave: String(localized: "\(name) is saved with its tagged entries encrypted.")
        case .openFile: String(localized: "\(name) is encrypted.")
        case .newFile: String(localized: "\(name) is saved encrypted with this passphrase.")
        default: nil
        }
    }

    /// A new passphrase is typed twice; one that must open what's encrypted already, once.
    private var asksTwice: Bool {
        switch request.mode {
        case .encryptOnSave: OrgCrypt.firstMessage(text()) == nil
        case .openFile: false
        default: request.encrypting
        }
    }

    private func submit() {
        guard !passphrase.isEmpty else { return }
        if asksTwice, passphrase != repeated { return problem = "The passphrases differ" }
        run(passphrase, remembered: false)
    }

    private func cancel() {
        if case .openFile = request.mode { session?.cancelUnlock() }
        done(nil)
    }

    private func run(_ passphrase: String, remembered: Bool) {
        if request.unlocks {
            if let failure = session?.unlock(passphrase, for: request.path) { return problem = failure }
            switch request.mode {
            case .encryptOnSave: return finish(String(localized: "Tagged entries encrypted and saved"), passphrase: passphrase, remembered: remembered)
            case .newFile: return finish(String(localized: "Saved encrypted"), passphrase: passphrase, remembered: remembered)
            default: return finish(nil, passphrase: passphrase, remembered: remembered)
            }
        }
        let current = text()
        do {
            switch request.mode {
            case .encrypt:
                guard let encrypted = try OrgCrypt.encrypt(current, at: request.offset, passphrase: passphrase) else {
                    return finish("The entry is encrypted already", passphrase: passphrase, remembered: remembered)
                }
                apply(encrypted)
                finish("Entry encrypted", passphrase: passphrase, remembered: remembered)
            case .encryptAll(let tag):
                let (encrypted, count) = try OrgCrypt.encryptAll(current, passphrase: passphrase, tag: tag)
                if count > 0 { apply(encrypted) }
                finish("Encrypted \(count) \(count == 1 ? "entry" : "entries")", passphrase: passphrase, remembered: remembered)
            case .open:
                let plain = try OrgCrypt.decrypt(current, at: request.offset, passphrase: passphrase).plaintext
                if remember, !remembered { CryptPassphrases.store(passphrase, for: request.path) }
                session?.cryptUsed(passphrase, for: request.path)
                plaintext = plain
                editing = (plain, passphrase)
                problem = nil
            case .decryptInPlace:
                let message = OrgCrypt.encryptedRange(current, at: request.offset).map { (current as NSString).substring(with: NSRange($0)) }
                let decrypted = try OrgCrypt.decryptInPlace(current, at: request.offset, passphrase: passphrase)
                // Saved unchanged with org-crypt-use-before-save-magic, the entry gets its message back.
                if let message, let body = OrgCrypt.bodyRange(decrypted, at: request.offset) {
                    session?.cryptDecrypted(message: message, plaintext: (decrypted as NSString).substring(with: NSRange(body)), for: request.path)
                }
                apply(decrypted)
                finish("Entry decrypted", passphrase: passphrase, remembered: remembered)
            case .encryptOnSave, .openFile, .newFile:
                break
            }
        } catch {
            problem = "\(error)"
        }
    }

    private func finish(_ message: String?, passphrase: String, remembered: Bool) {
        if remember, !remembered { CryptPassphrases.store(passphrase, for: request.path) }
        if !request.unlocks { session?.cryptUsed(passphrase, for: request.path) }
        done(message)
    }

    /// The edited text encrypted again in the message's place; nothing changes if it wasn't edited.
    private func save() {
        guard let editing else { return }
        guard plaintext != editing.original else { return done(nil) }
        var plain = plaintext
        if !plain.isEmpty, !plain.hasSuffix("\n") { plain += "\n" }
        do {
            apply(try OrgCrypt.replacing(text(), at: request.offset, with: plain, passphrase: editing.passphrase))
            done("Entry encrypted again")
        } catch {
            problem = "\(error)"
        }
    }

    /// `org-decrypt-entry` with the text as edited.
    private func decryptEdited() {
        guard let editing else { return }
        var plain = plaintext
        if !plain.isEmpty, !plain.hasSuffix("\n") { plain += "\n" }
        do {
            let replaced = try OrgCrypt.replacing(text(), at: request.offset, with: plain, passphrase: editing.passphrase)
            apply(try OrgCrypt.decryptInPlace(replaced, at: request.offset, passphrase: editing.passphrase))
            done("Entry decrypted")
        } catch {
            problem = "\(error)"
        }
    }
}
