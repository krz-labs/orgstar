import Foundation
import OrgCore

/// yasnippet's org-mode snippets, from `snippets/org-mode/` beside the configuration read.
extension EmacsImport {
    /// One yasnippet file: `# key:`, `# name:` and the body after `# --`. A file without that
    /// line is all body, keyed by its name, as yasnippet reads it.
    public struct Yasnippet: Sendable, Equatable {
        public var key: String
        public var name: String
        public var body: String
        /// Why it can't be used without Emacs, or nil.
        public var lisp: String?
    }

    public static func yasnippet(_ text: String, fileName: String) -> Yasnippet {
        var key: String?
        var name: String?
        var type: String?
        var body = text
        let lines = text.components(separatedBy: "\n")
        if let separator = lines.firstIndex(where: { $0.range(of: "^#[ \\t]*--[ \\t]*$", options: .regularExpression) != nil }) {
            for line in lines[..<separator] {
                guard line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
                let field = line[line.index(after: line.startIndex)..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch field {
                case "key": key = value
                case "name": name = value
                case "type": type = value
                default: break
                }
            }
            body = lines[(separator + 1)...].joined(separator: "\n")
        }
        let trigger = key ?? fileName
        var lisp: String?
        if type == "command" {
            lisp = "a command snippet, which is Emacs Lisp"
        } else if body.range(of: "(?<!\\\\)`", options: .regularExpression) != nil {
            lisp = "has Emacs Lisp in backquotes"
        } else if body.contains("$(") {
            lisp = "has an Emacs Lisp transformation"
        }
        return Yasnippet(key: trigger, name: name ?? trigger, body: body, lisp: lisp)
    }

    /// The `[[snippet]]` table for `snippet`.
    static func snippetTable(_ snippet: Yasnippet) -> String {
        var out = "[[snippet]]\ntrigger = \(UserConfig.format(.string(snippet.key)))\n"
        if snippet.name != snippet.key { out += "description = \(UserConfig.format(.string(snippet.name)))\n" }
        // A literal multi-line string keeps the body as it is, unless it holds the delimiter.
        if snippet.body.contains("'''") || snippet.body.contains("\r") {
            out += "body = \(UserConfig.format(.string(snippet.body)))\n"
        } else {
            out += "body = '''\n\(snippet.body)'''\n"
        }
        return out
    }

    /// Where yasnippet keeps org-mode snippets for a configuration in `folders`.
    static func snippetFolders(_ folders: [URL]) -> [URL] {
        var seen: Set<String> = []
        return folders.map { $0.appendingPathComponent("snippets/org-mode") }
            .filter { seen.insert($0.standardizedFileURL.path).inserted && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Reads the snippets in `folders` into items; those with Emacs Lisp are listed as not
    /// imported.
    mutating func addSnippets(from folders: [URL]) {
        var next = (items.map(\.id) + unsupported.map(\.id) + unreadable.map(\.id)).max() ?? 0
        func id() -> Int { next += 1; return next }
        var triggers: Set<String> = []
        for folder in folders {
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                let source = "snippets/org-mode/" + file.lastPathComponent
                guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                    problems.append("Can't read \(file.path)")
                    continue
                }
                let snippet = Self.yasnippet(text, fileName: file.lastPathComponent)
                if let reason = snippet.lisp {
                    unsupported.append(Note(id: id(), name: "snippet \(snippet.key)", reason: reason, source: source))
                    snippetsSkipped += 1
                    continue
                }
                let parsed = try? Snippets.parse(Self.snippetTable(snippet))
                guard let parsed, parsed.problems.isEmpty else {
                    let problem = parsed?.problems.first.map { $0.replacingOccurrences(of: "^line [0-9]+: ", with: "", options: .regularExpression) }
                    unsupported.append(Note(id: id(), name: "snippet \(snippet.key)", reason: problem ?? "not readable", source: source))
                    snippetsSkipped += 1
                    continue
                }
                guard triggers.insert(snippet.key).inserted else { continue }
                items.append(Item(id: id(), name: snippet.key, summary: snippet.name, source: source, change: .snippet(trigger: snippet.key, toml: Self.snippetTable(snippet))))
            }
        }
    }
}
