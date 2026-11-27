import Foundation

/// Emacs's keyboard macros (kmacro): the keys typed while recording, as they reach the keymap,
/// with each prompt's answer kept as the keys typed into it and RET. Replaying feeds the keys
/// to the same dispatch, and a prompt opened on the way reads its answer from them.
public struct MacroRecorder: Sendable {
    public struct Failure: Error, Equatable {
        public let message: String
    }

    /// An answer read from a macro's keys.
    public enum Reply: Equatable, Sendable {
        case answer(String)
        /// C-g.
        case quit
    }

    public private(set) var isRecording = false
    public private(set) var keys: [KeyChord] = []
    /// Where the key sequence being typed began in `keys`.
    private var sequenceStart = 0
    /// `last-kbd-macro`.
    public var last: [KeyChord]?
    /// `kmacro-counter`, which F3 inserts and steps while recording or replaying.
    public private(set) var counter = 0

    public init() {}

    /// `kmacro-start-macro`: recording starts, and the counter is 0 again.
    public mutating func start() throws {
        if isRecording { throw Failure(message: "Already defining keyboard macro") }
        isRecording = true
        keys = []
        sequenceStart = 0
        counter = 0
    }

    /// A key typed while recording; `begins` when it starts a key sequence.
    public mutating func record(_ key: KeyChord, begins: Bool) {
        guard isRecording else { return }
        if begins { sequenceStart = keys.count }
        keys.append(key)
    }

    /// A prompt's answer while recording: its text as typed and RET, or C-g for none.
    public mutating func record(answer: String?) {
        guard isRecording else { return }
        keys += answer.map { Self.keys(typing: $0) + [KeyChord("RET")] } ?? [KeyDispatcher.quit]
    }

    /// `kmacro-end-macro`. With `byKey`, the key sequence that ended it is left out. The message
    /// to show.
    public mutating func end(byKey: Bool) throws -> String {
        guard isRecording else { throw Failure(message: "Not defining kbd macro") }
        isRecording = false
        if byKey { keys.removeSubrange(min(sequenceStart, keys.count)...) }
        defer { keys = [] }
        guard !keys.isEmpty else { return "Ignore empty macro" }
        last = keys
        return "Keyboard macro defined"
    }

    /// The last macro, to replay.
    public func lastMacro() throws -> [KeyChord] {
        guard let last else { throw Failure(message: "No kbd macro has been defined") }
        return last
    }

    /// `kmacro-insert-counter`: the counter's text; the counter steps by one.
    public mutating func insertCounter() -> String {
        defer { counter += 1 }
        return String(counter)
    }

    /// The keys that type `text`.
    public static func keys(typing text: String) -> [KeyChord] {
        text.map { character in
            switch character {
            case " ": KeyChord("SPC")
            case "\t": KeyChord("TAB")
            case "\n": KeyChord("j", .control)
            default: KeyChord(String(character))
            }
        }
    }

    /// The answer at the front of `keys`: what they type before RET, or C-g; with the number of
    /// keys it used. Nil when neither RET nor C-g comes.
    public static func reply(from keys: some Collection<KeyChord>) -> (reply: Reply, used: Int)? {
        var text = ""
        var used = 0
        for key in keys {
            used += 1
            switch key {
            case KeyChord("RET"): return (.answer(text), used)
            case KeyDispatcher.quit: return (.quit, used)
            case KeyChord("SPC"): text.append(" ")
            case KeyChord("TAB"): text.append("\t")
            case KeyChord("j", .control): text.append("\n")
            case KeyChord("DEL"): if !text.isEmpty { text.removeLast() }
            default:
                if key.modifiers.isEmpty, key.key.count == 1 { text += key.key }
            }
        }
        return nil
    }
}

/// Work a replayed key started that the replay waits for before its next key, as a user
/// command running. It ends once, with the message it failed with or nil.
@MainActor
public final class MacroWait {
    private var outcome: String??
    private var waiting: [CheckedContinuation<String?, Never>] = []

    public init() {}

    public func finish(_ failure: String?) {
        guard outcome == nil else { return }
        outcome = .some(failure)
        for continuation in waiting { continuation.resume(returning: failure) }
        waiting = []
    }

    /// The failure, once the work has ended.
    public var value: String? {
        get async {
            if let outcome { return outcome }
            return await withCheckedContinuation { waiting.append($0) }
        }
    }
}

/// Where a macro replay stopped: at its end, with the error that ended it or nil, or at work
/// it waits for.
public enum MacroStep {
    case ended(String?)
    case waiting(MacroWait)
}

/// Macros named with `kmacro-name-last-macro`, kept in `macros.toml` in the configuration
/// folder. Each runs as the command `macro.named.<name>`, which `keymap.toml` can bind.
public final class NamedMacros: @unchecked Sendable {
    public static let shared = NamedMacros()
    public static let commandPrefix = "macro.named."
    public static let fileName = "macros.toml"
    /// The table of `macros.toml` that holds them.
    public static let table = "macros"

    private let lock = NSLock()
    private var macros: [String: [KeyChord]] = [:]
    private var saver: (@Sendable (String, [KeyChord]) throws -> Void)?

    public init() {}

    /// Names, sorted.
    public var names: [String] {
        lock.withLock { macros.keys.sorted() }
    }

    public func keys(_ name: String) -> [KeyChord]? {
        lock.withLock { macros[name] }
    }

    /// Replaces every macro, as from the file.
    public func replace(_ all: [String: [KeyChord]]) {
        lock.withLock { macros = all }
    }

    /// Writes a named macro where it is kept; set by the app.
    public func setSaver(_ saver: (@Sendable (String, [KeyChord]) throws -> Void)?) {
        lock.withLock { self.saver = saver }
    }

    /// Names `keys` and writes it with the saver, if there is one.
    public func name(_ name: String, _ keys: [KeyChord]) throws {
        let saver = lock.withLock {
            macros[name] = keys
            return self.saver
        }
        try saver?(name, keys)
    }

    /// Letters, digits, `-` and `_`, as a TOML key and a command id allow.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    /// The `[macros]` table of a `macros.toml`: `name = "keys"`. Entries that can't be used are
    /// skipped and reported in `problems`; a file that isn't valid TOML throws.
    public static func parse(_ toml: String, problems: inout [String]) throws -> [String: [KeyChord]] {
        var result: [String: [KeyChord]] = [:]
        for table in try TOML.parse(toml) where !(table.name.isEmpty && table.values.isEmpty) {
            guard table.name == Self.table, !table.isArrayElement else {
                problems.append("line \(table.line): unknown table [\(table.name)]")
                continue
            }
            for name in table.keys {
                guard isValidName(name) else {
                    problems.append("\(name): bad name")
                    continue
                }
                guard let text = table.values[name]?.string, let keys = KeySequence.parse(text) else {
                    problems.append("\(name): bad keys")
                    continue
                }
                result[name] = keys
            }
        }
        return result
    }
}
