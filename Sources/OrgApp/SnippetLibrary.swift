import Foundation
import Observation
import OrgCore

/// The snippets of `snippets.toml` in the configuration folder, read at launch and whenever
/// the file changes. A file that isn't valid TOML is reported and the snippets read before
/// stay; a snippet with a problem is reported and left out.
///
/// For the iOS key bar and other places that offer snippets: `snippets` lists them, and
/// `Snippet.commandID` (`org.snippet:<trigger>`) is a command any editor runs to expand one at
/// the caret. `org.snippet.next-field` and `org.snippet.previous-field` move between fields.
@MainActor
@Observable
public final class SnippetLibrary {
    public static let shared = SnippetLibrary()

    /// Snippets and file templates, in the file's order.
    public private(set) var snippets: [Snippet] = []
    /// Problems in the file, from the last time it was read, each starting with its name.
    public private(set) var problems: [String] = []
    /// File templates waiting for their new file to open in an editor, by path.
    @ObservationIgnored private var pending: [String: Snippet] = [:]

    public init() {}

    public static var userFile: URL { UserConfig.file(Snippets.fileName) }

    /// The snippets typed in files, without the file templates.
    public var typed: [Snippet] { snippets.filter { !$0.file } }
    /// The templates New File from Template… offers.
    public var templates: [Snippet] { snippets.filter(\.file) }

    /// Reads `file`; `read` returns nil when there is none, which leaves no snippets.
    public func reload(from file: URL = userFile, read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) {
        guard let text = read(file) else {
            snippets = []
            problems = []
            return
        }
        do {
            let parsed = try Snippets.parse(text)
            if parsed.snippets != snippets { snippets = parsed.snippets }
            problems = parsed.problems.map { "\(Snippets.fileName) \($0)" }
        } catch {
            problems = ["\(Snippets.fileName) \(error)"]
        }
    }

    /// Notes that the new file at `path` is to be filled from `template` when it opens.
    public func expand(_ template: Snippet, intoNewFile path: String) {
        pending[URL(fileURLWithPath: path).standardizedFileURL.path] = template
    }

    /// The template that fills the new file at `path`, once; nil for other files. Its editor
    /// performs `ExpandNamedSnippet(snippet:)` at the start.
    public func takeTemplate(for path: String) -> Snippet? {
        pending.removeValue(forKey: URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    /// The folders a new file can go in: the added folders and the folders holding their files,
    /// each with its name below its added folder's.
    public static func folders(in workspace: WorkspaceModel) -> [(path: String, title: String)] {
        let roots = workspace.rootPaths
        var paths = Set(roots)
        for file in workspace.files { paths.insert((file.path as NSString).deletingLastPathComponent) }
        return paths.compactMap { path -> (path: String, title: String)? in
            guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return nil }
            let name = (root as NSString).lastPathComponent
            return (path, path == root ? name : name + "/" + path.dropFirst(root.count + 1))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Creates the file `name` in `folder`, as New File does, and notes that `template` fills
    /// it when it opens. Returns its path.
    public func createFile(named name: String, in folder: String, from template: Snippet, workspace: WorkspaceModel) async throws -> String {
        let path = try await workspace.createFile(named: name, in: folder)
        expand(template, intoNewFile: path)
        return path
    }
}
