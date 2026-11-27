import Foundation

/// A command the user wrote: an exported function of a JavaScript module in the configuration
/// folder's `commands/`, declared in `commands.toml`. Running it is the app's work, so `run`
/// always asks for it as `.external(.userCommand)`.
public struct UserCommand: OrgCommand, Equatable {
    public let name: String
    /// Shown as written; titles aren't translated.
    public let title: String
    /// The module, relative to `commands/`.
    public let file: String
    public let function: String
    /// A `KeyContext` name; nil applies everywhere.
    public let when: String?
    /// Seconds, at most `UserCommands.maximumTimeout`.
    public let timeout: Int

    public init(name: String, title: String, file: String, function: String, when: String? = nil, timeout: Int = UserCommands.defaultTimeout) {
        self.name = name
        self.title = title
        self.file = file
        self.function = function
        self.when = when
        self.timeout = timeout
    }

    public var id: String { UserCommands.commandPrefix + name }

    public func applies(in context: EditContext) -> Bool {
        when.map { KeyContext.holds($0, in: context) } ?? true
    }

    public func run(in context: EditContext) -> CommandStep {
        .external(.userCommand(UserCommandRequest(command: self, revision: context.revision, selection: context.selection)))
    }
}

/// A user command to run against the buffer at `revision` with `selection`.
public struct UserCommandRequest: Sendable, Equatable {
    public let command: UserCommand
    public let revision: Int
    public let selection: [Range<Int>]

    public init(command: UserCommand, revision: Int, selection: [Range<Int>]) {
        self.command = command
        self.revision = revision
        self.selection = selection
    }
}

/// The commands of `commands.toml`, which the app reads from the configuration folder.
public final class UserCommands: @unchecked Sendable {
    public static let shared = UserCommands()
    public static let commandPrefix = "user."
    public static let fileName = "commands.toml"
    /// The folder beside `commands.toml` that holds the modules.
    public static let folderName = "commands"
    /// The newest `api` this version runs.
    public static let apiVersion = 1
    public static let defaultTimeout = 2
    public static let maximumTimeout = 30

    private let lock = NSLock()
    private var commands: [UserCommand] = []
    private var modules: URL?

    public init() {}

    /// In file order.
    public var all: [UserCommand] { lock.withLock { commands } }

    /// The `commands` folder the modules are in; nil before a file was read.
    public var folder: URL? { lock.withLock { modules } }

    public func command(_ id: String) -> UserCommand? {
        guard id.hasPrefix(Self.commandPrefix) else { return nil }
        let name = id.dropFirst(Self.commandPrefix.count)
        return lock.withLock { commands.first { $0.name == name } }
    }

    /// Replaces every command, as from the file, with the folder their modules are in.
    public func replace(_ all: [UserCommand], folder: URL?) {
        lock.withLock {
            commands = all
            modules = folder
        }
    }

    static let keys: Set<String> = ["name", "title", "file", "function", "when", "timeout"]

    /// The commands of a `commands.toml`. Entries that can't be used are skipped and reported in
    /// `problems`; with a missing or newer `api`, none is used. `exists` says whether a module
    /// path (relative to `commands/`) is there. A file that isn't valid TOML throws.
    public static func parse(_ toml: String, problems: inout [String], exists: (String) -> Bool) throws -> [UserCommand] {
        let tables = try TOML.parse(toml)
        var api: Int?
        var result: [UserCommand] = []
        var names = Set<String>()
        for table in tables {
            if table.name.isEmpty {
                for key in table.keys where key != "api" { problems.append("unknown key \(key)") }
                if let value = table.values["api"] {
                    guard let number = value.integer else {
                        problems.append("api must be a number")
                        continue
                    }
                    api = number
                }
                continue
            }
            guard table.name == "command", table.isArrayElement else {
                problems.append("line \(table.line): unknown table [\(table.name)]")
                continue
            }
            guard let name = table.values["name"]?.string, NamedMacros.isValidName(name) else {
                problems.append("line \(table.line): command needs a name of letters, digits, - and _")
                continue
            }
            func problem(_ text: String) { problems.append("command \(name): \(text)") }
            for key in table.keys where !keys.contains(key) { problem("unknown key \(key)") }
            guard names.insert(name).inserted else {
                problem("defined twice")
                continue
            }
            guard let file = table.values["file"]?.string, !file.isEmpty else {
                problem("missing file")
                continue
            }
            guard isModulePath(file) else {
                problem("file must be a .js or .mjs file in \(folderName)/")
                continue
            }
            guard exists(file) else {
                problem("no file \(folderName)/\(file)")
                continue
            }
            guard let function = table.values["function"]?.string, isIdentifier(function) else {
                problem("function must be the name of an exported function")
                continue
            }
            let when = table.values["when"]?.string
            if let when, !KeyContext.names.contains(when) {
                problem("unknown context \(when)")
                continue
            }
            var timeout = defaultTimeout
            if let value = table.values["timeout"] {
                guard let seconds = value.integer, (1...maximumTimeout).contains(seconds) else {
                    problem("timeout must be 1 to \(maximumTimeout) seconds")
                    continue
                }
                timeout = seconds
            }
            if let value = table.values["title"], value.string == nil { problem("title must be a string") }
            let title = table.values["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? name
            result.append(UserCommand(name: name, title: title, file: file, function: function, when: when, timeout: timeout))
        }
        guard let api else {
            if !result.isEmpty || tables.contains(where: { $0.name == "command" }) { problems.append("missing api = \(apiVersion)") }
            return []
        }
        guard api == apiVersion else {
            problems.append(api > apiVersion ? "api \(api) needs a newer orgstar" : "unknown api \(api)")
            return []
        }
        return result
    }

    /// A path of `.js` or `.mjs` file below `commands/`, without `.`, `..` or empty parts.
    public static func isModulePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(where: { "?#%\\".contains($0) }) }
            && (path.hasSuffix(".js") || path.hasSuffix(".mjs"))
    }

    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$") }
    }
}
