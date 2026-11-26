import Foundation
import OrgCore

/// Why a file can't be written: what it would put on disk unencrypted.
public enum CryptHold: Error, Equatable, Sendable {
    /// This many crypt-tagged entries with text aren't encrypted, and their passphrase isn't known.
    case entries(Int)
    /// An encrypted file (`.org.gpg`) whose passphrase isn't known.
    case file
    /// Saving failed for a reason a passphrase can't fix, said here: an entry with text below
    /// a message that the file's passphrase doesn't open.
    case blocked(String)
}

/// Why an encrypted file can't be read.
public enum CryptReadError: Error, Equatable, Sendable {
    /// Its passphrase isn't known.
    case locked
    case wrongPassphrase
    case failed(String)
}

/// What the session knows about encrypted text, by file: the passphrases unlocked while the
/// file is open, and for entries org-crypt encrypts on save (`org-crypt-use-before-save-magic`)
/// the messages and the text each holds. Through `CryptFileSystem`, buffers keep the
/// decrypted text while the file holds messages.
public final class CryptVault: @unchecked Sendable {
    private let lock = NSLock()
    private var entries = false
    private var entryTag = "crypt"
    private var passphrases: [String: String] = [:]
    /// By file: messages for entry texts by checksum, to give an unchanged entry its message again.
    private var reuse: [String: [String: String]] = [:]
    /// By file: the text of each message this session wrote, to read the file back as the buffer has it.
    private var revealed: [String: [String: String]] = [:]
    /// By file: whether the encrypted file was armored when read.
    private var armored: [String: Bool] = [:]
    /// Files that seal tagged entries until they close, whatever the setting says now: those
    /// it was on for, so that turning it off never writes what was encrypted in plaintext.
    private var sealing: Set<String> = []
    /// Files open in a buffer. Only they keep what the vault knows past a write.
    private var open: Set<String> = []
    /// By file: the bytes the last write replaced, as they were on disk.
    private var replacedBytes: [String: [UInt8]] = [:]

    /// The bytes the last write to `path` replaced, as they were on disk; given once.
    public func takeReplaced(for path: String) -> [UInt8]? {
        let key = Self.key(path)
        return locked { replacedBytes.removeValue(forKey: key) }
    }

    func noteReplaced(_ bytes: [UInt8]?, for path: String) {
        let key = Self.key(path)
        locked { replacedBytes[key] = bytes }
    }

    /// By encrypted file: its bytes on disk and their text, last read or written.
    private var lastFile: [String: (encrypted: [UInt8], plain: [UInt8])] = [:]

    public init() {}

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    /// Whether `path` is a whole encrypted file, as EasyPG's `epa-file` opens `.gpg` files.
    public static func isEncryptedFile(_ path: String) -> Bool { path.hasSuffix(".gpg") }

    /// `org-crypt-use-before-save-magic`.
    public var encryptsTaggedEntries: Bool {
        get { locked { entries } }
        set { locked { entries = newValue } }
    }

    /// `org-crypt-tag-matcher`.
    public var tag: String {
        get { locked { entryTag } }
        set { locked { entryTag = newValue } }
    }

    public func passphrase(for path: String) -> String? {
        locked { passphrases[Self.key(path)] }
    }

    /// Whether saving `key` seals its tagged entries: the setting is on, or was while the
    /// file was open. Call with the lock held.
    private func seals(_ key: String) -> Bool {
        if entries, open.contains(key) { sealing.insert(key) }
        return entries || sealing.contains(key) || !(revealed[key]?.isEmpty ?? true)
    }

    /// Whether saving `path` encrypts its tagged entries.
    public func sealsEntries(for path: String) -> Bool {
        let key = Self.key(path)
        return locked { seals(key) }
    }

    /// `passphrase` encrypts and decrypts `path` until it's forgotten. Messages kept for reuse
    /// under another passphrase are dropped.
    public func unlock(_ passphrase: String, for path: String) {
        let key = Self.key(path)
        locked {
            if passphrases[key] != passphrase {
                reuse[key] = nil
                lastFile[key] = nil
            }
            passphrases[key] = passphrase
            _ = seals(key)
        }
    }

    /// Drops the passphrase of `path`; the next save that needs it is held.
    public func forgetPassphrase(for path: String) {
        let key = Self.key(path)
        locked {
            passphrases[key] = nil
            reuse[key] = nil
        }
    }

    private func dropIfClosed(_ key: String) {
        locked {
            guard !open.contains(key) else { return }
            passphrases[key] = nil
            reuse[key] = nil
            revealed[key] = nil
            armored[key] = nil
            lastFile[key] = nil
            sealing.remove(key)
        }
    }

    /// Whether the vault keeps anything for `path`.
    public func keepsAnything(for path: String) -> Bool {
        let key = Self.key(path)
        return locked { passphrases[key] != nil || !(revealed[key]?.isEmpty ?? true) || !(reuse[key]?.isEmpty ?? true) || lastFile[key] != nil || sealing.contains(key) }
    }

    /// `path` is open in a buffer.
    public func opened(_ path: String) {
        let key = Self.key(path)
        locked { _ = open.insert(key) }
    }

    /// Drops everything kept for `path`, as when its buffer closes.
    public func close(_ path: String) {
        let key = Self.key(path)
        locked {
            open.remove(key)
            passphrases[key] = nil
            reuse[key] = nil
            revealed[key] = nil
            armored[key] = nil
            sealing.remove(key)
            lastFile[key] = nil
        }
    }

    /// The entry of `path` holding `plaintext` was decrypted from `message`: while it stays
    /// so, saving writes `message` back unchanged.
    public func remember(message: String, plaintext: String, for path: String) {
        let key = Self.key(path)
        locked {
            reuse[key, default: [:]][OrgCrypt.checksum(plaintext)] = message
            _ = seals(key)
        }
    }

    /// What keeps `text`, the buffer of `path`, from being written: tagged entries without a
    /// known passphrase, or an encrypted file without one. Nil when it can be written.
    public func hold(_ text: String, for path: String) -> CryptHold? {
        let key = Self.key(path)
        let (passphrase, entries, tag) = locked { (passphrases[key], seals(key), entryTag) }
        guard passphrase == nil else { return nil }
        if Self.isEncryptedFile(path) { return .file }
        guard entries else { return nil }
        let count = OrgCrypt.unencrypted(text, tag: tag).count
        return count > 0 ? .entries(count) : nil
    }

    /// Whether `text`, the buffer of `path`, holds anything that isn't on disk as it shows:
    /// an encrypted file, or entries decrypted that saving encrypts. Such a buffer is left out
    /// of what other views read and keep (`DocumentSession.openTexts`).
    public func isPrivate(_ text: String, for path: String) -> Bool {
        if Self.isEncryptedFile(path) { return true }
        let key = Self.key(path)
        let (entries, tag, revealing) = locked { (seals(key), entryTag, !(revealed[key]?.isEmpty ?? true)) }
        return revealing || (entries && !OrgCrypt.unencrypted(text, tag: tag).isEmpty)
    }

    // MARK: - Reading and writing

    /// The text of messages this session wrote for `path`.
    public func revealedMessages(for path: String) -> [String: String] {
        locked { revealed[Self.key(path)] ?? [:] }
    }

    /// `bytes` from disk as the buffer of `path` has them: the file decrypted, and the
    /// messages this session wrote (`messages`, by default those known now) back to their text.
    public func plain(_ bytes: [UInt8], for path: String, messages: [String: String]? = nil) throws -> [UInt8] {
        var bytes = bytes
        if Self.isEncryptedFile(path) { bytes = try decryptFile(bytes, for: path) }
        let known = messages ?? revealedMessages(for: path)
        guard !known.isEmpty, var text = Self.text(bytes), text.contains("-----BEGIN PGP MESSAGE-----") else { return bytes }
        for (message, plaintext) in known where text.contains(message) {
            text = text.replacingOccurrences(of: message, with: plaintext)
        }
        return Array(text.utf8)
    }

    /// `bytes`, the buffer of `path`, as the file holds them: tagged entries encrypted, then
    /// the file encrypted, and the messages written for entries. Throws `CryptHold` when a
    /// passphrase is needed and not known.
    public func cipher(_ bytes: [UInt8], for path: String) throws -> (bytes: [UInt8], messages: [(message: String, plaintext: String)], plain: [UInt8]?) {
        let key = Self.key(path)
        let (passphrase, entries, tag, known) = locked { (passphrases[key], seals(key), entryTag, reuse[key] ?? [:]) }
        var bytes = bytes
        var messages: [(String, String)] = []
        if entries, let text = Self.text(bytes), text.contains(tag) {
            if let passphrase {
                let sealed = try OrgCrypt.seal(text, passphrase: passphrase, tag: tag, reuse: { known[$0] })
                bytes = Array(sealed.text.utf8)
                messages = sealed.messages
            } else {
                let count = OrgCrypt.unencrypted(text, tag: tag).count
                if count > 0 { throw CryptHold.entries(count) }
            }
        }
        if Self.isEncryptedFile(path) {
            guard let passphrase else { throw CryptHold.file }
            let plain = bytes
            // The text the file holds already (a snapshot of it) is its bytes on disk, without
            // another key's 65 MB of hashing.
            if let last = locked({ lastFile[key] }), last.plain == plain { return (last.encrypted, messages, plain) }
            let message = try OpenPGP.encryptedMessage(Data(bytes), passphrase: passphrase)
            bytes = locked { armored[key] ?? false } ? Array(OpenPGP.armor(message).utf8) : [UInt8](message)
            return (bytes, messages, plain)
        }
        return (bytes, messages, nil)
    }

    /// `cipher`'s result was written to `path`: reading it back gives the messages' text, and
    /// an unchanged entry keeps its message at the next save. Messages no longer in the file
    /// are forgotten.
    public func didWrite(_ written: (bytes: [UInt8], messages: [(message: String, plaintext: String)], plain: [UInt8]?), to path: String) {
        let key = Self.key(path)
        locked {
            // A file that isn't open keeps nothing (passphrase, messages, text) once the
            // write's own reads are done.
            if !open.contains(key) {
                DispatchQueue.main.async { [weak self] in self?.dropIfClosed(key) }
            }
            revealed[key] = Dictionary(written.messages.map { ($0.message, $0.plaintext) }, uniquingKeysWith: { a, _ in a })
            reuse[key] = Dictionary(written.messages.map { (OrgCrypt.checksum($0.plaintext), $0.message) }, uniquingKeysWith: { a, _ in a })
            if let plain = written.plain { lastFile[key] = (written.bytes, plain) }
        }
    }

    /// Whether `passphrase` opens the encrypted file `bytes`; an empty file takes any.
    public static func opens(_ bytes: [UInt8], passphrase: String) -> Bool {
        bytes.isEmpty || (try? OpenPGP.decryptFile(Data(bytes), passphrase: passphrase)) != nil
    }

    private func decryptFile(_ bytes: [UInt8], for path: String) throws -> [UInt8] {
        // New File makes an empty file: it has no passphrase until it's first saved.
        guard !bytes.isEmpty else { return [] }
        let key = Self.key(path)
        guard let passphrase = locked({ passphrases[key] }) else { throw CryptReadError.locked }
        // Saving reads the file two or three times; each key costs 65 MB of hashing.
        if let last = locked({ lastFile[key] }), last.encrypted == bytes { return last.plain }
        let data = Data(bytes)
        do {
            let plain = [UInt8](try OpenPGP.decryptFile(data, passphrase: passphrase))
            locked {
                armored[key] = OpenPGP.isArmored(data)
                lastFile[key] = (bytes, plain)
            }
            return plain
        } catch let failure as OpenPGP.Failure {
            throw failure == OpenPGP.wrongPassphrase ? CryptReadError.wrongPassphrase : CryptReadError.failed(failure.description)
        }
    }

    /// `bytes` as text when they are UTF-8 exactly, a BOM included.
    private static func text(_ bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.utf8.elementsEqual(bytes) ? text : nil
    }
}

/// Files read and written through a `CryptVault`: what the buffer holds decrypted goes to
/// disk encrypted, and comes back as the buffer has it.
public struct CryptFileSystem: FileSystem {
    public let base: FileSystem
    public let vault: CryptVault

    public init(base: FileSystem, vault: CryptVault) {
        self.base = base
        self.vault = vault
    }

    public func read(_ url: URL) throws -> [UInt8]? {
        try base.read(url).map { try vault.plain($0, for: url.path) }
    }

    public func replace(_ url: URL, with bytes: [UInt8]) throws -> [UInt8]? {
        let known = vault.revealedMessages(for: url.path)
        let written = try vault.cipher(bytes, for: url.path)
        let replaced = try base.replace(url, with: written.bytes)
        vault.noteReplaced(replaced, for: url.path)
        // The version replaced, as it read before this write's messages were known (and while
        // the encrypted file's last bytes still decrypt from memory).
        let previous = replaced.map { (try? vault.plain($0, for: url.path, messages: known)) ?? $0 }
        vault.didWrite(written, to: url.path)
        return previous
    }
}

/// Recovery versions and snapshots through a `CryptVault`: kept encrypted as the file is. When
/// that needs a passphrase that isn't known, `keep` throws `CryptHold`, so a caller that
/// promises a copy stops; a snapshot is skipped.
public struct CryptRecoveryStore: RecoveryStore {
    public let base: RecoveryStore
    public let vault: CryptVault

    public init(base: RecoveryStore, vault: CryptVault) {
        self.base = base
        self.vault = vault
    }

    public func keep(_ bytes: [UInt8], for url: URL, label: String) throws {
        try base.keep(try vault.cipher(bytes, for: url.path).bytes, for: url, label: label)
    }

    public func keepSnapshot(_ bytes: [UInt8], for url: URL) throws {
        guard let encrypted = try? vault.cipher(bytes, for: url.path).bytes else { return }
        try base.keepSnapshot(encrypted, for: url)
    }
}
