import Foundation
import LocalAuthentication
import OrgDocument
import Security

/// Passphrases for encrypted entries, kept in the Keychain by file when asked, and given back
/// only after Touch ID, Face ID or the device's password.
public enum CryptPassphrases {
    static let service = "sh.krz.orgstar.crypt"

    static func query(_ path: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: path]
    }

    public static func store(_ passphrase: String, for path: String) {
        forget(path)
        var item = query(path)
        item[kSecValueData as String] = Data(passphrase.utf8)
        item[kSecAttrLabel as String] = "orgstar: passphrase for " + (path as NSString).lastPathComponent
        SecItemAdd(item as CFDictionary, nil)
    }

    public static func forget(_ path: String) {
        SecItemDelete(query(path) as CFDictionary)
    }

    public static func hasStored(_ path: String) -> Bool {
        var q = query(path)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// The stored passphrase, once the person has proved who they are; nil otherwise.
    public static func stored(for path: String) async -> String? {
        guard hasStored(path) else { return nil }
        let context = LAContext()
        let reason = "unlock the passphrase for " + (path as NSString).lastPathComponent
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return nil }
        var q = query(path)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
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
