import Foundation
import LocalAuthentication
import OrgDocument
import Security

/// Passphrases for encrypted entries and files, kept in the Keychain by file path when asked.
/// Items are readable only on this device while it's unlocked, and only after Touch ID, Face
/// ID or the device's password (`.userPresence`); one authentication covers the reads that
/// follow for a while. Items earlier versions stored without that move over at their first read.
public enum CryptPassphrases {
    static let service = "sh.krz.orgstar.crypt.v2"
    /// Where earlier versions kept passphrases, readable without authentication.
    static let legacyService = "sh.krz.orgstar.crypt"

    /// The authentication reads share.
    nonisolated(unsafe) static let context: LAContext = {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration
        return context
    }()

    static func query(_ path: String, service: String = service) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: path]
        if service == Self.service { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    /// The new item for `passphrase`: this device only, unlocked, after user presence.
    static func newItem(_ passphrase: String, for path: String) -> [String: Any]? {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil) else { return nil }
        var item = query(path)
        item[kSecValueData as String] = Data(passphrase.utf8)
        item[kSecAttrAccessControl as String] = access
        item[kSecAttrLabel as String] = "orgstar: passphrase for " + (path as NSString).lastPathComponent
        return item
    }

    public static func store(_ passphrase: String, for path: String) {
        forget(path)
        guard let item = newItem(passphrase, for: path) else { return }
        if SecItemAdd(item as CFDictionary, nil) == errSecMissingEntitlement {
            // A build without a Keychain entitlement (development) keeps the old kind of item.
            var legacy = query(path, service: legacyService)
            legacy[kSecValueData as String] = Data(passphrase.utf8)
            legacy[kSecAttrLabel as String] = item[kSecAttrLabel as String]
            SecItemAdd(legacy as CFDictionary, nil)
        }
    }

    public static func forget(_ path: String) {
        SecItemDelete(query(path) as CFDictionary)
        SecItemDelete(query(path, service: legacyService) as CFDictionary)
    }

    /// Whether an item exists, without asking for authentication.
    static func exists(_ query: [String: Any]) -> Bool {
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
        if exists(query(path)) {
            var q = query(path)
            q[kSecReturnData as String] = true
            let context = Self.context
            context.localizedReason = reason
            q[kSecUseAuthenticationContext as String] = context
            let request = q
            // The read waits for Touch ID or the password, off the main thread.
            return await Task.detached { () -> String? in
                var result: AnyObject?
                guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
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
        if let item = newItem(passphrase, for: path), SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            SecItemDelete(query(path, service: legacyService) as CFDictionary)
        }
        return passphrase
    }
}

extension CryptHold {
    /// What the held file's notice says.
    public func notice(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return switch self {
        case .entries(1): String(localized: "1 tagged entry isn't encrypted. Changes to \(name) aren't saved until it is.")
        case .entries(let count): String(localized: "\(count) tagged entries aren't encrypted. Changes to \(name) aren't saved until they are.")
        case .file: String(localized: "\(name) isn't saved until it has a passphrase.")
        }
    }
}

extension CryptHold: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .entries(1): String(localized: "1 tagged entry isn't encrypted")
        case .entries(let count): String(localized: "\(count) tagged entries aren't encrypted")
        case .file: String(localized: "The file has no passphrase yet")
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
