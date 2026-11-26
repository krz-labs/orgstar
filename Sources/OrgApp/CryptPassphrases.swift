import Foundation
import LocalAuthentication
import OrgDocument
import Security

/// Passphrases for encrypted entries and files, kept in the Keychain by file path when asked.
/// Items are readable only on this device while it's unlocked, and only after Touch ID, Face
/// ID or the device's password (`.userPresence`), asked once per file while it's open. Items
/// earlier versions stored without that move over at their first read. A build without a
/// Keychain entitlement (the Developer ID Mac app) can't make such items and keeps the old kind.
@MainActor
public enum CryptPassphrases {
    nonisolated static let service = "sh.krz.orgstar.crypt.v2"
    /// Where earlier versions kept passphrases, readable without authentication.
    nonisolated static let legacyService = "sh.krz.orgstar.crypt"
    /// Set once the person was told this build keeps passphrases the old way.
    static let toldLegacyKey = "cryptKeychainLegacyTold"

    /// A Keychain query handed to the thread that waits on it; nothing else uses it meanwhile.
    struct Request: @unchecked Sendable {
        let query: [String: Any]
    }

    /// One authentication per file while it's open; `endSession` ends it.
    private static var contexts: [String: LAContext] = [:]

    static func context(for path: String) -> LAContext {
        if let context = contexts[path] { return context }
        let context = LAContext()
        contexts[path] = context
        return context
    }

    /// The file closed: its authentication no longer reads its passphrase.
    public static func endSession(for path: String) {
        contexts.removeValue(forKey: path)?.invalidate()
    }

    nonisolated static func query(_ path: String, service: String = service) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: path]
        if service == Self.service { query[kSecUseDataProtectionKeychain as String] = true }
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

    /// Remembers `passphrase` for `path`. A message to show when it wasn't kept, or (once) when
    /// this build keeps it without device-only protection; nil otherwise.
    @discardableResult
    public static func store(_ passphrase: String, for path: String, defaults: UserDefaults = .standard) -> String? {
        guard let item = newItem(passphrase, for: path) else { return String(localized: "The passphrase wasn't remembered: the Keychain refused it.") }
        let status = add(item, replacing: query(path))
        if status == errSecSuccess {
            SecItemDelete(query(path, service: legacyService) as CFDictionary)
            return nil
        }
        guard status == errSecMissingEntitlement else { return String(localized: "The passphrase wasn't remembered: the Keychain refused it.") }
        var legacy = query(path, service: legacyService)
        legacy[kSecValueData as String] = Data(passphrase.utf8)
        legacy[kSecAttrLabel as String] = item[kSecAttrLabel as String]
        guard add(legacy, replacing: query(path, service: legacyService)) == errSecSuccess else {
            return String(localized: "The passphrase wasn't remembered: the Keychain refused it.")
        }
        SecItemDelete(query(path) as CFDictionary)
        guard !defaults.bool(forKey: toldLegacyKey) else { return nil }
        defaults.set(true, forKey: toldLegacyKey)
        return String(localized: "This version of orgstar keeps remembered passphrases in your login keychain without limiting them to this Mac; Touch ID or your password is still asked before one is used.")
    }

    public static func forget(_ path: String) {
        endSession(for: path)
        SecItemDelete(query(path) as CFDictionary)
        SecItemDelete(query(path, service: legacyService) as CFDictionary)
    }

    /// Whether an item exists, without asking for authentication.
    nonisolated static func exists(_ query: [String: Any]) -> Bool {
        var q = query
        let quiet = LAContext()
        quiet.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = quiet
        q[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public static func hasStored(_ path: String) -> Bool {
        exists(query(path)) || exists(query(path, service: legacyService))
    }

    /// The stored passphrase, once the person has proved who they are; nil otherwise.
    public static func stored(for path: String) async -> String? {
        let reason = "unlock the passphrase for " + (path as NSString).lastPathComponent
        let context = context(for: path)
        if exists(query(path)) {
            var q = query(path)
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
        guard exists(query(path, service: legacyService)) else { return nil }
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return nil }
        var q = query(path, service: legacyService)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let passphrase = String(decoding: data, as: UTF8.self)
        // Moved to the protected kind of item; kept as it was where that can't be made.
        if let item = newItem(passphrase, for: path), add(item, replacing: query(path)) == errSecSuccess {
            SecItemDelete(query(path, service: legacyService) as CFDictionary)
        }
        return passphrase
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
