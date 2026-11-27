import Foundation

/// Reading a configuration file in order to change it: only a file that isn't there counts as
/// empty, so that one that can't be read is never written over.
public enum UserFile {
    /// The file's text, or nil when there is no such file. Any other failure is thrown.
    public static func text(at url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        }
    }

    /// Writes what `change` makes of the file's text, "" when there is no such file. Throws,
    /// leaving the file alone, when it can't be read. With `coordinated`, in coordination with
    /// the app that syncs the file.
    public static func update(_ url: URL, coordinated: Bool = false, _ change: (String) -> String) throws {
        func write(_ url: URL) throws {
            try change(text(at: url) ?? "").write(to: url, atomically: true, encoding: .utf8)
        }
        guard coordinated else { return try write(url) }
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordination) { url in
            do { try write(url) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }
}
