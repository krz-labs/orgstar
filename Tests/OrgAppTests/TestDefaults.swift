import Foundation

/// A defaults suite named `<prefix>-<UUID>`, kept in the temporary folder rather than
/// `~/Library/Preferences` and removed with its plist when released. cfprefsd may write a
/// plist again after it is removed, so the suite is a path outside the preferences folder.
final class TestDefaults: UserDefaults, @unchecked Sendable {
    let name: String
    private let path: String

    init(_ prefix: String) {
        name = "\(prefix)-\(UUID().uuidString)"
        path = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        super.init(suiteName: path)!
    }

    deinit {
        removePersistentDomain(forName: path)
        try? FileManager.default.removeItem(atPath: path + ".plist")
    }
}
