import Foundation
import Security

/// Syncing a folder that is a git repository in Working Copy, through its x-callback-url
/// commands (https://workingcopyapp.com/url-schemes.html): commit everything changed, pull,
/// then push, with the answer coming back to `orgstar://working-copy/…`.
public enum WorkingCopy {
    public static let scheme = "working-copy"
    /// The host of the callbacks in orgstar's own scheme.
    public static let callbackHost = "working-copy"

    /// The commit message.
    public static let message = "Update from orgstar"

    /// The `chain` command that commits every changed file in `repo`, pulls and pushes, with
    /// `key` (Working Copy's URL key) and callbacks naming `repo`.
    public static func syncURL(repo: String, key: String, message: String = message) -> URL {
        let back = { (result: String) in
            "\(AppLink.scheme)://\(callbackHost)/\(result)?repo=\(encode(repo))"
        }
        // Parameters before the first `command` apply to every command; `x-success` is used by
        // the last one.
        let query = [
            ("repo", repo), ("key", key), ("x-success", back("success")), ("x-error", back("error")),
            ("command", "commit"), ("message", message), ("limit", "999"),
            ("command", "pull"),
            ("command", "push"),
        ]
        var components = URLComponents()
        components.scheme = scheme
        components.host = "x-callback-url"
        components.path = "/chain"
        components.percentEncodedQuery = query.map { "\($0)=\(encode($1))" }.joined(separator: "&")
        return components.url!
    }

    /// Spaces as `%20`, not `+`, and every reserved character encoded, as Working Copy asks.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Working Copy's answer to a sync.
    public enum Callback: Equatable, Sendable {
        case success(repo: String)
        /// With Working Copy's `errorMessage`, when it gave one.
        case failure(repo: String, message: String?)
    }

    /// The callback `url` is, or nil for another URL.
    public static func callback(_ url: URL) -> Callback? {
        guard url.scheme == AppLink.scheme, url.host == callbackHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let repo = components.queryItems?.first(where: { $0.name == "repo" })?.value else { return nil }
        switch url.lastPathComponent {
        case "success": return .success(repo: repo)
        case "error":
            let message = components.queryItems?.first { $0.name == "errorMessage" }?.value
            return .failure(repo: repo, message: message.flatMap { $0.isEmpty ? nil : $0 })
        default: return nil
        }
    }

    /// Whether `root` holds a git repository: a `.git` folder or file (a worktree's) at its top.
    /// Working Copy's own File Provider may leave `.git` out, so a folder can be set up without it.
    public static func isRepository(_ root: String) -> Bool {
        FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git"))
    }

    // MARK: - Settings

    /// How a folder syncs: the repository's name in Working Copy, and whether it syncs each time
    /// the app opens. A folder without settings doesn't sync.
    public struct Folder: Codable, Equatable, Sendable {
        public var repository: String
        public var syncOnOpen: Bool

        public init(repository: String, syncOnOpen: Bool = false) {
            self.repository = repository
            self.syncOnOpen = syncOnOpen
        }
    }

    /// The folders set up on this device, by root path. Kept on the device: roots are at
    /// different paths on each.
    public struct Folders {
        static let key = "workingCopyFolders"
        let defaults: UserDefaults

        public init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        public var all: [String: Folder] {
            guard let data = defaults.data(forKey: Self.key) else { return [:] }
            return (try? JSONDecoder().decode([String: Folder].self, from: data)) ?? [:]
        }

        public func folder(_ root: String) -> Folder? { all[root] }

        /// Sets up `root`, or with nil stops syncing it.
        public func set(_ folder: Folder?, for root: String) {
            var all = all
            all[root] = folder
            defaults.set(try? JSONEncoder().encode(all), forKey: Self.key)
        }

        /// The root set up with `repository`.
        public func root(of repository: String) -> String? {
            all.filter { $0.value.repository == repository }.map(\.key).sorted().first
        }
    }

    // MARK: - The key

    /// Working Copy's URL key, which every command needs. Kept in the Keychain on this device
    /// only, never in settings or logs.
    public enum Key {
        static let service = "sh.krz.orgstar.working-copy"

        static var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "url-key"]
        }

        public static func stored() -> String? {
            var q = query
            q[kSecReturnData as String] = true
            var result: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            let key = String(decoding: data, as: UTF8.self)
            return key.isEmpty ? nil : key
        }

        /// Stores `key`, or removes it when it is nil or empty. False when the Keychain refused.
        @discardableResult
        public static func store(_ key: String?) -> Bool {
            SecItemDelete(query as CFDictionary)
            guard let key, !key.isEmpty else { return true }
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrLabel as String] = "orgstar: Working Copy URL key"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
    }
}
