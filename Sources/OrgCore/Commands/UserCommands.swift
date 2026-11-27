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
    /// `workspace = true`: the command may also search the folders, read other files' outlines
    /// and the agenda, and capture.
    public let workspace: Bool

    public init(name: String, title: String, file: String, function: String, when: String? = nil, timeout: Int = UserCommands.defaultTimeout,
                workspace: Bool = false) {
        self.name = name
        self.title = title
        self.file = file
        self.function = function
        self.when = when
        self.timeout = timeout
        self.workspace = workspace
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

/// A function of a module in `commands/` that runs when something happens rather than from a
/// key, declared as `[[hook]]` in `commands.toml`. There are no per-keystroke hooks.
public struct UserHook: Sendable, Equatable {
    public enum Event: String, Sendable, CaseIterable {
        /// `org-after-todo-state-change-hook`: after a command changed an entry's TODO keyword.
        case afterTodoStateChange = "after-todo-state-change"
        /// `org-capture-before-finalize-hook`: before a capture is filed.
        case captureBeforeFinalize = "capture-before-finalize"
    }

    public let event: Event
    /// The module, relative to `commands/`.
    public let file: String
    public let function: String
    /// Seconds, at most `UserCommands.maximumTimeout`.
    public let timeout: Int
    /// `workspace = true`, as for commands.
    public let workspace: Bool

    public init(event: Event, file: String, function: String, timeout: Int = UserCommands.defaultTimeout, workspace: Bool = false) {
        self.event = event
        self.file = file
        self.function = function
        self.timeout = timeout
        self.workspace = workspace
    }

    /// How messages name it: `logDone in commands/todo.js`.
    public var title: String { "\(function) in \(UserCommands.folderName)/\(file)" }
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
    private var hookList: [UserHook] = []
    private var modules: URL?

    public init() {}

    /// In file order.
    public var all: [UserCommand] { lock.withLock { commands } }

    /// The `commands` folder the modules are in; nil before a file was read.
    public var folder: URL? { lock.withLock { modules } }

    /// The hooks for `event`, in file order.
    public func hooks(_ event: UserHook.Event) -> [UserHook] {
        lock.withLock { hookList.filter { $0.event == event } }
    }

    public func command(_ id: String) -> UserCommand? {
        guard id.hasPrefix(Self.commandPrefix) else { return nil }
        let name = id.dropFirst(Self.commandPrefix.count)
        return lock.withLock { commands.first { $0.name == name } }
    }

    /// Replaces every command and hook, as from the file, with the folder their modules are in.
    public func replace(_ all: [UserCommand], hooks: [UserHook] = [], folder: URL?) {
        lock.withLock {
            commands = all
            hookList = hooks
            modules = folder
        }
    }

    static let keys: Set<String> = ["name", "title", "file", "function", "when", "timeout", "workspace"]
    static let hookKeys: Set<String> = ["event", "file", "function", "timeout", "workspace"]

    /// The commands of a `commands.toml`, as `manifest` reads them.
    public static func parse(_ toml: String, problems: inout [String], exists: (String) -> Bool) throws -> [UserCommand] {
        try manifest(toml, problems: &problems, exists: exists).commands
    }

    /// The commands and hooks of a `commands.toml`. Entries that can't be used are skipped and
    /// reported in `problems`; with a missing or newer `api`, none is used. `exists` says
    /// whether a module path (relative to `commands/`) is there. A file that isn't valid TOML
    /// throws.
    public static func manifest(_ toml: String, problems: inout [String], exists: (String) -> Bool) throws
        -> (commands: [UserCommand], hooks: [UserHook]) {
        let tables = try TOML.parse(toml)
        var api: Int?
        var result: [UserCommand] = []
        var hooks: [UserHook] = []
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
            guard ["command", "hook"].contains(table.name), table.isArrayElement else {
                problems.append("line \(table.line): unknown table [\(table.name)]")
                continue
            }
            if table.name == "hook" {
                func problem(_ text: String) { problems.append("hook at line \(table.line): \(text)") }
                for key in table.keys where !hookKeys.contains(key) { problem("unknown key \(key)") }
                guard let name = table.values["event"]?.string else {
                    problem("missing event")
                    continue
                }
                guard let event = UserHook.Event(rawValue: name) else {
                    problem("unknown event \(name); the events are \(UserHook.Event.allCases.map(\.rawValue).joined(separator: " and "))")
                    continue
                }
                guard let module = module(table, exists: exists, problem: problem) else { continue }
                hooks.append(UserHook(event: event, file: module.file, function: module.function, timeout: module.timeout, workspace: module.workspace))
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
            guard let module = module(table, exists: exists, problem: problem) else { continue }
            let when = table.values["when"]?.string
            if let when, !KeyContext.names.contains(when) {
                problem("unknown context \(when)")
                continue
            }
            if let value = table.values["title"], value.string == nil { problem("title must be a string") }
            let title = table.values["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? name
            result.append(UserCommand(name: name, title: title, file: module.file, function: module.function, when: when,
                                      timeout: module.timeout, workspace: module.workspace))
        }
        guard let api else {
            if !result.isEmpty || !hooks.isEmpty || tables.contains(where: { ["command", "hook"].contains($0.name) }) {
                problems.append("missing api = \(apiVersion)")
            }
            return ([], [])
        }
        guard api == apiVersion else {
            problems.append(api > apiVersion ? "api \(api) needs a newer orgstar" : "unknown api \(api)")
            return ([], [])
        }
        return (result, hooks)
    }

    /// The `file`, `function`, `timeout` and `workspace` of a command or hook; nil once the
    /// first that can't be used is reported.
    private static func module(_ table: TOML.Table, exists: (String) -> Bool, problem: (String) -> Void)
        -> (file: String, function: String, timeout: Int, workspace: Bool)? {
        guard let file = table.values["file"]?.string, !file.isEmpty else {
            problem("missing file")
            return nil
        }
        guard isModulePath(file) else {
            problem("file must be a .js or .mjs file in \(folderName)/")
            return nil
        }
        guard exists(file) else {
            problem("no file \(folderName)/\(file)")
            return nil
        }
        guard let function = table.values["function"]?.string, isIdentifier(function) else {
            problem("function must be the name of an exported function")
            return nil
        }
        var timeout = defaultTimeout
        if let value = table.values["timeout"] {
            guard let seconds = value.integer, (1...maximumTimeout).contains(seconds) else {
                problem("timeout must be 1 to \(maximumTimeout) seconds")
                return nil
            }
            timeout = seconds
        }
        var workspace = false
        if let value = table.values["workspace"] {
            guard let flag = value.bool else {
                problem("workspace must be true or false")
                return nil
            }
            workspace = flag
        }
        return (file, function, timeout, workspace)
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
