import Foundation
import OrgCore

/// `commands.toml` in the configuration folder and the modules in `commands/` beside it.
public enum UserCommandFile {
    /// Reads `commands.toml` in `folder` into `store`, without running anything. The problems
    /// found, each starting with the file's name; a missing file is none. A module iCloud hasn't
    /// downloaded is reported and its download started; its command is kept.
    @discardableResult
    public static func load(into store: UserCommands = .shared, folder: URL, read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) -> [String] {
        let modules = folder.appendingPathComponent(UserCommands.folderName)
        guard let text = read(folder.appendingPathComponent(UserCommands.fileName)) else {
            store.replace([], folder: nil)
            return []
        }
        var problems: [String] = []
        var commands: [UserCommand] = []
        do {
            commands = try UserCommands.parse(text, problems: &problems) { path in
                FileManager.default.fileExists(atPath: modules.appendingPathComponent(path).path) || placeholder(modules.appendingPathComponent(path)) != nil
            }
        } catch {
            problems.append("\(error)")
        }
        for file in Set(commands.map(\.file)).sorted() where needsDownload(modules.appendingPathComponent(file)) {
            problems.append("\(UserCommands.folderName)/\(file) isn't downloaded from iCloud yet")
        }
        store.replace(commands, folder: commands.isEmpty ? nil : modules)
        return problems.map { "\(UserCommands.fileName): \($0)" }
    }

    /// The `.name.icloud` file iCloud leaves for `url` until it is downloaded, when there is one.
    static func placeholder(_ url: URL) -> URL? {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: placeholder.path) ? placeholder : nil
    }

    /// Whether `url` is in iCloud and not downloaded; if so its download is started.
    static func needsDownload(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        let missing = placeholder(url) != nil
            || values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus.map { $0 != .current } == true
        if missing { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        return missing
    }

    /// `path` relative to the folder of `roots` it's in, for `org.file()`; its name when it's
    /// in none.
    public static func relativePath(_ path: String, roots: [String]) -> String {
        let root = roots.filter { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.max { $0.count < $1.count }
        guard let root else { return (path as NSString).lastPathComponent }
        return String(path.dropFirst(root.count).drop { $0 == "/" })
    }

    // MARK: - Trust

    /// The text trust is kept for: `file` and every module it imports, each under its path, in
    /// path order. Nil when `file` can't be read.
    @MainActor
    public static func trustedText(_ file: String, modules: URL) -> String? {
        moduleTexts(file, modules: modules).map(trustedText)
    }

    static func trustedText(_ texts: [String: String?]) -> String {
        texts.keys.sorted().map { "// \($0)\n\(texts[$0]! ?? "(missing)")" }.joined(separator: "\n")
    }

    /// `file` and every module it imports, directly or through another, by path in `modules`;
    /// nil for an import that can't be read. Nil when `file` can't be read.
    @MainActor
    static func moduleTexts(_ file: String, modules: URL) -> [String: String?]? {
        var seen: [String: String?] = [:]
        var pending = [file]
        while let path = pending.popLast() {
            guard !seen.keys.contains(path) else { continue }
            #if canImport(WebKit)
            let data = CommandHost.Files.file(path, in: modules)
            #else
            let data = FileManager.default.contents(atPath: modules.appendingPathComponent(path).path)
            #endif
            guard let data, let text = String(data: data, encoding: .utf8) else {
                if path == file { return nil }
                seen[path] = .some(nil)
                continue
            }
            seen[path] = text
            pending += imports(text, from: path)
        }
        return seen
    }

    private static let importPatterns = [
        #"\b(?:import|export)\s[^;'"]*?\bfrom\s*['"]([^'"\n]+)['"]"#,
        #"\bimport\s*['"]([^'"\n]+)['"]"#,
        #"\bimport\s*\(\s*['"]([^'"\n]+)['"]\s*\)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// The modules `text`, at `path` in `commands/`, imports by relative path, as paths in
    /// `commands/`; imports that leave the folder are left out, since they can't load.
    static func imports(_ text: String, from path: String) -> [String] {
        let ns = text as NSString
        var result: [String] = []
        for pattern in importPatterns {
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let specifier = ns.substring(with: match.range(at: 1))
                guard specifier.hasPrefix("./") || specifier.hasPrefix("../") else { continue }
                var parts = path.split(separator: "/").dropLast().map(String.init)
                var inside = true
                for part in specifier.split(separator: "/") {
                    switch part {
                    case ".": continue
                    case "..": if parts.popLast() == nil { inside = false }
                    default: parts.append(String(part))
                    }
                }
                let resolved = parts.joined(separator: "/")
                if inside, UserCommands.isModulePath(resolved) { result.append(resolved) }
            }
        }
        return result
    }
}

/// The question before a command from a file this device hasn't trusted runs.
@MainActor
public enum UserCommandTrust {
    public enum Answer: CaseIterable, Sendable {
        case runOnce, always, dontRun

        public var title: String {
            switch self {
            case .runOnce: String(localized: "Run Once", comment: "Answer to the question before a user command runs")
            case .always: String(localized: "Always", comment: "Answer to the question before a user command runs")
            case .dontRun: String(localized: "Don't Run", comment: "Answer to the question before a user command runs")
            }
        }
    }

    public struct Question: Equatable, Sendable {
        /// The command's file, as `commands/review.js`.
        public let file: String
        /// The modules it imports, directly or through another, as `commands/lib/dates.js`, in
        /// path order. Trust covers them with the file.
        public let imports: [String]
        /// Its commands can also read every file in the folders and capture to them.
        public let workspace: Bool

        public init(file: String, imports: [String] = [], workspace: Bool = false) {
            self.file = file
            self.imports = imports
            self.workspace = workspace
        }

        public var title: String {
            String(localized: "Run commands from \(file)?", comment: "Asked before a user command from a file not yet trusted on this device runs")
        }

        /// The modules it imports, if any, and what its commands can do, a line each.
        public var message: String {
            var lines: [String] = []
            if !imports.isEmpty {
                let list = ListFormatter.localizedString(byJoining: imports)
                lines.append(String(localized: "It imports \(list).", comment: "The modules a user command's file imports, in the question before it runs"))
            }
            lines.append(workspace
                ? String(localized: "They can read and change the file you run them in, read every file in your folders and capture to them, but not use the network.",
                         comment: "What user commands with access to the folders can do, in the question before they run")
                : String(localized: "They can read and change the file you run them in, and nothing else: no other files and no network.",
                         comment: "What user commands can do, in the question before they run"))
            return lines.joined(separator: "\n")
        }
    }

    /// Runs `run` at once when the command's file and its imports are trusted, else asks: Run
    /// Once runs it, Always trusts the files as they are now and runs it, anything else says
    /// why nothing ran through `refuse`.
    public static func check(_ command: UserCommand, modules: URL, trust: TrustStore,
                             ask: @MainActor (Question, @escaping (Answer?) -> Void) -> Void,
                             run: @escaping () -> Void, refuse: @escaping (String) -> Void) {
        guard let texts = UserCommandFile.moduleTexts(command.file, modules: modules) else {
            return refuse("No file \(UserCommands.folderName)/\(command.file)")
        }
        let text = UserCommandFile.trustedText(texts)
        let path = modules.appendingPathComponent(command.file).path
        if trust.isTrusted(path: path, content: text) { return run() }
        let imports = texts.filter { $0.key != command.file && $0.value != nil }.keys.sorted()
        let question = Question(file: "\(UserCommands.folderName)/\(command.file)",
                                imports: imports.map { "\(UserCommands.folderName)/\($0)" })
        ask(question) { answer in
            switch answer {
            case .runOnce: run()
            case .always:
                trust.trust(path: path, content: text)
                run()
            case .dontRun, nil: refuse(String(localized: "Not run"))
            }
        }
    }
}
