import CryptoKit
import Foundation
import LocalAuthentication
import OrgDocument
import Security

/// Where passphrases are saved: the Keychain, or a stand-in in tests.
@MainActor
public protocol PassphraseKeychain: AnyObject {
    /// Whether a passphrase is saved for `path`, without asking for authentication.
    func contains(_ path: String) -> Bool
    /// The passphrase saved for `path`, once `context` has authenticated the person; nil otherwise.
    func read(_ path: String, context: LAContext) async -> String?
    /// Saves `passphrase` for `path`. A message to show when it wasn't kept; nil otherwise.
    func write(_ passphrase: String, for path: String) -> String?
    func delete(_ path: String)
    /// The paths passphrases are saved for, without asking for authentication.
    func paths() -> [String]
}

/// Passphrases for encrypted entries and files, saved in the Keychain by file path while "Use
/// Face ID to Decrypt" is on. Off or undecided, the Keychain isn't read or written: a passphrase
/// is typed and kept in memory while its file is open. Items are readable only on this device
/// while it's unlocked, and only after Touch ID, Face ID or the device's password
/// (`.userPresence`), asked once per file while it's open.
@MainActor
@Observable
public final class CryptPassphrases {
    public static let shared = CryptPassphrases()

    /// "Use Face ID to Decrypt", kept in user defaults on this device, not in `config.toml`.
    public enum Setting: String, Sendable {
        case undecided, on, off
    }

    nonisolated static let settingKey = "decryptWithBiometrics"
    nonisolated static let service = "sh.krz.orgstar.crypt.v2"
    /// Where earlier versions kept passphrases, readable without authentication.
    nonisolated static let legacyService = "sh.krz.orgstar.crypt"

    @ObservationIgnored private let keychain: PassphraseKeychain
    @ObservationIgnored private let defaults: UserDefaults
    public private(set) var setting: Setting
    /// The question waits to be asked at launch: passphrases saved by an earlier version.
    public var asking = false
    /// The files with a saved passphrase, as Settings lists them.
    public private(set) var savedPaths: [String] = []

    public init(keychain: PassphraseKeychain = SystemKeychain(), defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
        setting = defaults.string(forKey: Self.settingKey).flatMap(Setting.init) ?? .undecided
    }

    private func set(_ setting: Setting) {
        self.setting = setting
        defaults.set(setting.rawValue, forKey: Self.settingKey)
    }

    /// Whether this build can keep passphrases limited to this device: the Developer ID Mac app
    /// has no Keychain entitlement and keeps them in the login keychain.
    public static var protectsItems: Bool {
        #if os(macOS) && !APPSTORE
        false
        #else
        true
        #endif
    }

    /// Said beside the setting where `protectsItems` is false.
    public static var caveat: String {
        String(localized: "This version of orgstar keeps remembered passphrases in your login keychain without limiting them to this Mac; Touch ID or your password is still asked before one is used.")
    }

    /// Face ID, Touch ID or Optic ID, as this device has it; the Mac's is Touch ID.
    public static var biometryName: String {
        #if os(macOS)
        return "Touch ID"
        #else
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return switch context.biometryType {
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: "Face ID"
        }
        #endif
    }

    /// The setting's name.
    public static var title: String { String(localized: "Use \(biometryName) to Decrypt") }

    /// The question asked the first time a passphrase is typed, and at launch.
    public static var question: String { String(localized: "Use \(biometryName) to Decrypt?") }

    /// What the setting does, in the question and in Settings.
    public static var explanation: String {
        let name = biometryName
        #if os(macOS)
        return String(localized: "Passphrases you type for encrypted files and entries are saved in the Keychain, and \(name) or your password unlocks them. \(name) can then decrypt anything whose passphrase is saved in your Keychain. Otherwise a passphrase is typed when it's needed and kept only while its file is open.")
        #else
        return String(localized: "Passphrases you type for encrypted files and entries are saved in the Keychain, and \(name) or your passcode unlocks them. \(name) can then decrypt anything whose passphrase is saved in your Keychain. Otherwise a passphrase is typed when it's needed and kept only while its file is open.")
        #endif
    }

    /// What turning the setting off removes, for its confirmation.
    public static func removal(_ count: Int) -> String {
        count == 1
            ? String(localized: "The passphrase saved for 1 file is removed from the Keychain.")
            : String(localized: "The passphrases saved for \(count) files are removed from the Keychain.")
    }

    // MARK: - The setting

    /// Whether a typed passphrase waits for the question before it can be saved.
    public var asksFirst: Bool { setting == .undecided }

    /// The answer to the question: Enable turns the setting on, Not Now off.
    public func answer(enable: Bool) {
        set(enable ? .on : .off)
        asking = false
    }

    /// Turns the setting on from Settings.
    public func turnOn() {
        set(.on)
    }

    /// Turns the setting off and removes every saved passphrase; Settings confirms first when
    /// there are any.
    public func turnOff() {
        set(.off)
        for path in keychain.paths() { forget(path) }
        refresh()
    }

    /// At launch: passphrases saved by an earlier version, while the setting is undecided, ask
    /// the question.
    public func askIfSavedBefore() {
        guard setting == .undecided, !keychain.paths().isEmpty else { return }
        asking = true
    }

    /// Reads the files with a saved passphrase again, for Settings.
    public func refresh() {
        savedPaths = keychain.paths().sorted()
    }

    // MARK: - Passphrases

    /// One authentication per file while it's open; `endSession` ends it.
    @ObservationIgnored private var contexts: [String: LAContext] = [:]

    func context(for path: String) -> LAContext {
        if let context = contexts[path] { return context }
        let context = LAContext()
        contexts[path] = context
        return context
    }

    /// The file closed: its authentication no longer reads its passphrase.
    public func endSession(for path: String) {
        contexts.removeValue(forKey: path)?.invalidate()
    }

    /// A passphrase typed for `path` that opened or encrypted it: saved while the setting is on.
    /// A message to show when it wasn't kept; nil otherwise.
    @discardableResult
    public func keep(_ passphrase: String, for path: String) -> String? {
        guard setting == .on else { return nil }
        let note = keychain.write(passphrase, for: path)
        refresh()
        return note
    }

    /// Forget Encryption Passphrase, or Forget in Settings: the saved passphrase is removed.
    public func forget(_ path: String) {
        endSession(for: path)
        keychain.delete(path)
        savedPaths.removeAll { $0 == path }
    }

    /// Whether a passphrase is saved for `path` and may be used, without asking for authentication.
    public func hasStored(_ path: String) -> Bool {
        setting == .on && keychain.contains(path)
    }

    /// The saved passphrase, once the person has proved who they are; nil otherwise, and always
    /// while the setting isn't on.
    public func stored(for path: String) async -> String? {
        guard setting == .on, keychain.contains(path) else { return nil }
        return await keychain.read(path, context: context(for: path))
    }
}

/// The Keychain. New items are this device only, unlocked, after user presence. Items earlier
/// versions saved without that move over at their first read. A build without a Keychain
/// entitlement (the Developer ID Mac app) can't make such items and keeps the old kind.
@MainActor
public final class SystemKeychain: PassphraseKeychain {
    public init() {}

    /// A Keychain query handed to the thread that waits on it; nothing else uses it meanwhile.
    struct Request: @unchecked Sendable {
        let query: [String: Any]
    }

    nonisolated static func query(_ path: String?, service: String = CryptPassphrases.service) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let path { query[kSecAttrAccount as String] = path }
        if service == CryptPassphrases.service { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    /// The new item for `passphrase`: this device only, unlocked, after user presence.
    nonisolated static func newItem(_ passphrase: String, for path: String) -> [String: Any]? {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil) else { return nil }
        var item = query(path)
        item[kSecValueData as String] = Data(passphrase.utf8)
        item[kSecAttrAccessControl as String] = access
        item[kSecAttrLabel as String] = "orgstar: passphrase for " + (path as NSString).lastPathComponent
        return item
    }

    /// Adds `item`, in place of one there already.
    nonisolated static func add(_ item: [String: Any], replacing query: [String: Any]) -> OSStatus {
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemDelete(query as CFDictionary)
            status = SecItemAdd(item as CFDictionary, nil)
        }
        return status
    }

    public func write(_ passphrase: String, for path: String) -> String? {
        let refused = String(localized: "The passphrase wasn't remembered: the Keychain refused it.")
        guard let item = Self.newItem(passphrase, for: path) else { return refused }
        let status = Self.add(item, replacing: Self.query(path))
        if status == errSecSuccess {
            SecItemDelete(Self.query(path, service: CryptPassphrases.legacyService) as CFDictionary)
            return nil
        }
        guard status == errSecMissingEntitlement else { return refused }
        var legacy = Self.query(path, service: CryptPassphrases.legacyService)
        legacy[kSecValueData as String] = Data(passphrase.utf8)
        legacy[kSecAttrLabel as String] = item[kSecAttrLabel as String]
        guard Self.add(legacy, replacing: Self.query(path, service: CryptPassphrases.legacyService)) == errSecSuccess else { return refused }
        SecItemDelete(Self.query(path) as CFDictionary)
        return nil
    }

    public func delete(_ path: String) {
        SecItemDelete(Self.query(path) as CFDictionary)
        SecItemDelete(Self.query(path, service: CryptPassphrases.legacyService) as CFDictionary)
    }

    /// `query` for attributes only, without asking for authentication.
    nonisolated static func quiet(_ query: [String: Any]) -> [String: Any] {
        var q = query
        let quiet = LAContext()
        quiet.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = quiet
        q[kSecReturnAttributes as String] = true
        return q
    }

    /// Whether an item exists, without asking for authentication.
    nonisolated static func exists(_ query: [String: Any]) -> Bool {
        let status = SecItemCopyMatching(quiet(query) as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public func contains(_ path: String) -> Bool {
        Self.exists(Self.query(path)) || Self.exists(Self.query(path, service: CryptPassphrases.legacyService))
    }

    public func paths() -> [String] {
        var paths: Set<String> = []
        for service in [CryptPassphrases.service, CryptPassphrases.legacyService] {
            var q = Self.quiet(Self.query(nil, service: service))
            q[kSecMatchLimit as String] = kSecMatchLimitAll
            var result: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { continue }
            for item in items { if let account = item[kSecAttrAccount as String] as? String { paths.insert(account) } }
        }
        return Array(paths)
    }

    public func read(_ path: String, context: LAContext) async -> String? {
        let reason = "unlock the passphrase for " + (path as NSString).lastPathComponent
        if Self.exists(Self.query(path)) {
            var q = Self.query(path)
            q[kSecReturnData as String] = true
            context.localizedReason = reason
            q[kSecUseAuthenticationContext as String] = context
            let request = Request(query: q)
            // The read waits for Touch ID or the password, off the main thread.
            return await Task.detached { () -> String? in
                var result: AnyObject?
                guard SecItemCopyMatching(request.query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
                return String(decoding: data, as: UTF8.self)
            }.value
        }
        let legacyQuery = Self.query(path, service: CryptPassphrases.legacyService)
        guard Self.exists(legacyQuery) else { return nil }
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return nil }
        var q = legacyQuery
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let passphrase = String(decoding: data, as: UTF8.self)
        // Moved to the protected kind of item; kept as it was where that can't be made.
        if let item = Self.newItem(passphrase, for: path), Self.add(item, replacing: Self.query(path)) == errSecSuccess {
            SecItemDelete(legacyQuery as CFDictionary)
        }
        return passphrase
    }
}

/// The key clock history hashes encrypted headings' titles with, made once and kept in the
/// Keychain, on this device only, without asking for authentication.
public enum ClockTitleKey {
    static let service = "sh.krz.orgstar.clock-title-key"

    static func query(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "key"]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    /// The key, made and kept the first time; nil when the Keychain keeps none.
    public static func loadOrCreate() -> SymmetricKey? {
        for dataProtection in [true, false] {
            var q = query(dataProtection: dataProtection)
            q[kSecReturnData as String] = true
            var result: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        for dataProtection in [true, false] {
            var item = query(dataProtection: dataProtection)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "orgstar: clock history key"
            if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return key }
        }
        return nil
    }
}

extension CryptHold {
    /// Whether giving the passphrase lets the file be saved.
    public var takesPassphrase: Bool {
        if case .blocked = self { return false }
        return true
    }

    /// What the held file's notice says.
    public func notice(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return switch self {
        case .entries(1): String(localized: "1 tagged entry isn't encrypted. Changes to \(name) aren't saved until it is.")
        case .entries(let count): String(localized: "\(count) tagged entries aren't encrypted. Changes to \(name) aren't saved until they are.")
        case .file: String(localized: "\(name) isn't saved until it has a passphrase.")
        case .blocked(let reason): reason + ". " + String(localized: "Changes to \(name) aren't saved until that's fixed.")
        }
    }
}

extension SaveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileKeepsChanging: String(localized: "The file keeps changing on disk; nothing was saved.")
        case .otherVersionRestored: String(localized: "The file changed on disk; nothing was changed.")
        }
    }
}

extension CryptHold: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .entries(1): String(localized: "1 tagged entry isn't encrypted")
        case .entries(let count): String(localized: "\(count) tagged entries aren't encrypted")
        case .file: String(localized: "The file has no passphrase yet")
        case .blocked(let reason): reason
        }
    }
}

extension CryptReadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .locked: String(localized: "The file is encrypted, and its passphrase isn't known")
        case .wrongPassphrase: String(localized: "Wrong passphrase")
        case .failed(let reason): reason
        }
    }
}
