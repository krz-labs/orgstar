import Foundation

/// The `orgstar` command, which scripts/build-app.sh puts in the app as `Contents/Helpers/orgstar`,
/// linked into a folder on the PATH by Settings ▸ General ▸ Install Command-Line Tool….
public enum CommandLineTool {
    public enum Failure: Error, Equatable {
        /// This copy of the app has no command, as a build run from SwiftPM.
        case missing
        /// `path` is there and isn't a link.
        case occupied(path: String)
        /// The link can't be made in the folder.
        case unwritable(folder: String, reason: String)
    }

    /// The command in the app at `app`.
    public static func helper(in app: URL = Bundle.main.bundleURL) -> URL {
        app.appendingPathComponent("Contents/Helpers/orgstar")
    }

    /// Where choosing a folder starts: `~/.local/bin` when it's there, else `/usr/local/bin`
    /// when it's there, else the home folder.
    public static func suggestedFolder(home: String = NSHomeDirectory()) -> URL {
        let local = (home as NSString).appendingPathComponent(".local/bin")
        for path in [local, "/usr/local/bin"] where FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: home)
    }

    /// Links `folder/orgstar` to `helper`, replacing a link already there. Returns the link.
    @discardableResult
    public static func install(_ helper: URL, in folder: URL) throws(Failure) -> URL {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: helper.path) else { throw .missing }
        let link = folder.appendingPathComponent("orgstar")
        if let attributes = try? manager.attributesOfItem(atPath: link.path) {
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { throw .occupied(path: link.path) }
        }
        let temporary = folder.appendingPathComponent(".orgstar-\(UUID().uuidString)")
        do {
            try manager.createSymbolicLink(at: temporary, withDestinationURL: helper)
            // rename(2) replaces a link that's there in one step.
            guard rename(temporary.path, link.path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? manager.removeItem(at: temporary)
                throw Failure.unwritable(folder: folder.path, reason: reason)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .unwritable(folder: folder.path, reason: (error as NSError).localizedFailureReason ?? error.localizedDescription)
        }
        return link
    }
}
