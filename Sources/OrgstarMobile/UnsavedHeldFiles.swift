import Foundation

/// The files held for their passphrase when the app went to the background. iOS may end the
/// app there without asking, and their edits, kept only in memory, are lost: the next launch
/// says so.
enum UnsavedHeldFiles {
    static let key = "heldFilesInBackground"

    static func record(_ paths: [String]) {
        if paths.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(paths.map { ($0 as NSString).lastPathComponent }, forKey: key)
        }
    }

    /// The message for files whose edits were lost when the app last ended; read once, at launch.
    static let atLaunch: String? = {
        guard let names = UserDefaults.standard.stringArray(forKey: key), !names.isEmpty else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return String(localized: "Edits to \(names.joined(separator: ", ")) weren't saved: they were waiting for a passphrase when orgstar was closed.")
    }()
}
