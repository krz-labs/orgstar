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
        var seen: [String: String] = [:]
        var pending = [file]
        while let path = pending.popLast() {
            guard seen[path] == nil else { continue }
            #if canImport(WebKit)
            let data = CommandHost.Files.file(path, in: modules)
            #else
            let data = FileManager.default.contents(atPath: modules.appendingPathComponent(path).path)
            #endif
            guard let data, let text = String(data: data, encoding: .utf8) else {
                if path == file { return nil }
                seen[path] = "(missing)"
                continue
            }
            seen[path] = text
            pending += imports(text, from: path)
        }
        return seen.keys.sorted().map { "// \($0)\n\(seen[$0]!)" }.joined(separator: "\n")
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
    static var runOnce: String { String(localized: "Run Once", comment: "Answer to the question before a user command runs") }
    static var always: String { String(localized: "Always", comment: "Answer to the question before a user command runs") }
    static var dontRun: String { String(localized: "Don't Run", comment: "Answer to the question before a user command runs") }

    /// Runs `run` at once when the command's file and its imports are trusted, else asks: Run
    /// Once runs it, Always trusts the files as they are now and runs it, anything else says
    /// why nothing ran through `refuse`.
    public static func check(_ command: UserCommand, modules: URL, trust: TrustStore,
                             ask: @MainActor (Prompt, @escaping (String?) -> Void) -> Void,
                             run: @escaping () -> Void, refuse: @escaping (String) -> Void) {
        guard let text = UserCommandFile.trustedText(command.file, modules: modules) else {
            return refuse("No file \(UserCommands.folderName)/\(command.file)")
        }
        let path = modules.appendingPathComponent(command.file).path
        if trust.isTrusted(path: path, content: text) { return run() }
        let choices = [runOnce, always, dontRun]
        let file = "\(UserCommands.folderName)/\(command.file)"
        let message = String(localized: "Run commands from \(file)?",
                             comment: "Asked before a user command from a file not yet trusted on this device runs")
        ask(Prompt(key: "confirm", message: message, choices: choices)) { answer in
            switch answer {
            case runOnce: run()
            case always:
                trust.trust(path: path, content: text)
                run()
            default: refuse(String(localized: "Not run"))
            }
        }
    }
}
