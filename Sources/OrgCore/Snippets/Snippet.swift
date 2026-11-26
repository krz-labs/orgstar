import Foundation

/// A snippet from `snippets.toml`:
///
/// ```toml
/// [[snippet]]
/// trigger = "meet"
/// description = "Meeting notes"
/// body = """
/// * Meeting with ${1:someone} %U
/// - $0
/// """
/// ```
///
/// The body has yasnippet's tab stops (`$1`, `${1:default}`, `$0`; a number used twice is a
/// mirror) and the capture escapes that need no capture (`%t`, `%U`, `%<…>`, `%^{prompt}`,
/// `%i` for the selected text). With `file = true` it is a template for New File from
/// Template… instead.
public struct Snippet: Sendable, Equatable, Hashable, Codable {
    public var trigger: String
    /// The description, or the trigger when there is none.
    public var name: String
    public var body: String
    /// A template for a new file rather than a snippet typed in one.
    public var file: Bool

    public init(trigger: String, name: String? = nil, body: String, file: Bool = false) {
        self.trigger = trigger
        self.name = name ?? trigger
        self.body = body
        self.file = file
    }

    /// The command that expands this snippet at the caret, for keys and the iOS key bar.
    public var commandID: String { Snippets.commandPrefix + trigger }
}

/// What a snippet's body expands to: its text, its fields and where the caret goes last, in
/// UTF-16 offsets into `text`.
public struct SnippetExpansion: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public let number: Int
        /// The field first, then its mirrors.
        public var ranges: [Range<Int>]
    }

    public var text: String
    /// By number, `$0` left out.
    public var fields: [Field]
    /// `$0`, or the end of the text; not empty for `${0:text}`, which is selected.
    public var exit: Range<Int>
}

public enum Snippets {
    public static let fileName = "snippets.toml"
    static let commandPrefix = "org.snippet:"

    /// The trigger of a `commandID`, or nil for another command.
    public static func trigger(ofCommand id: String) -> String? {
        id.hasPrefix(commandPrefix) ? String(id.dropFirst(commandPrefix.count)) : nil
    }

    public struct Problem: Error, Equatable, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "line \(line): \(message)" }
    }

    /// The snippets in a `snippets.toml`, and problems with single snippets, which are left
    /// out. Throws when the file isn't valid TOML.
    public static func parse(_ text: String) throws -> (snippets: [Snippet], problems: [String]) {
        let tables = try TOML.parse(text)
        var snippets: [Snippet] = []
        var problems: [String] = []
        var triggers: Set<String> = []
        for table in tables where !(table.name.isEmpty && table.values.isEmpty) {
            guard table.name == "snippet", table.isArrayElement else {
                problems.append("line \(table.line): expected [[snippet]]")
                continue
            }
            let values = table.values
            guard let trigger = values["trigger"]?.string, !trigger.isEmpty, let body = values["body"]?.string else {
                problems.append("line \(table.line): a snippet needs trigger and body")
                continue
            }
            guard !trigger.contains(where: \.isWhitespace) else {
                problems.append("line \(table.line): a trigger has no spaces")
                continue
            }
            for key in table.keys where !["trigger", "body", "description", "file"].contains(key) {
                problems.append("line \(table.line): unknown key \(key)")
            }
            do {
                _ = try parseBody(body)
            } catch let problem as Problem {
                problems.append("line \(table.line): \(problem.message)")
                continue
            }
            guard triggers.insert(trigger).inserted else {
                problems.append("line \(table.line): trigger \(trigger) is used twice")
                continue
            }
            snippets.append(Snippet(trigger: trigger, name: values["description"]?.string, body: body, file: values["file"]?.bool ?? false))
        }
        return (snippets, problems)
    }

    // MARK: - Triggers

    /// The snippet whose trigger is just before `caret`, and the trigger's range. As
    /// yasnippet's `yas-key-syntaxes`, the longest text back to a blank is tried first, then
    /// shorter ones starting after a character that isn't part of a word.
    public static func trigger(before caret: Int, in text: String, snippets: [Snippet]) -> (snippet: Snippet, range: Range<Int>)? {
        let candidates = snippets.filter { !$0.file }
        guard !candidates.isEmpty else { return nil }
        let ns = text as NSString
        guard caret > 0, caret <= ns.length else { return nil }
        var start = caret
        while start > 0, let scalar = UnicodeScalar(ns.character(at: start - 1)), !CharacterSet.whitespacesAndNewlines.contains(scalar) { start -= 1 }
        guard start < caret else { return nil }
        var from = start
        while from < caret {
            let typed = ns.substring(with: NSRange(location: from, length: caret - from))
            if let snippet = candidates.first(where: { $0.trigger == typed }) { return (snippet, from..<caret) }
            // The next start: after the next character that isn't a letter, digit or `_`.
            from += 1
            while from < caret, let scalar = UnicodeScalar(ns.character(at: from - 1)), CharacterSet.alphanumerics.contains(scalar) || scalar == "_" { from += 1 }
        }
        return nil
    }

    // MARK: - Bodies

    /// Tab stops and text, as `parseBody` reads a body.
    indirect enum Node: Equatable {
        case text(String)
        /// `$N` (no children) or `${N:…}`.
        case stop(Int, [Node]?)
    }

    /// Reads yasnippet's tab stops: `$N`, `${N}`, `${N:default}` with stops nested in the
    /// default, and the escapes `\$`, `\\`, `` \` `` and, in a default, `\}`.
    static func parseBody(_ body: String) throws -> [Node] {
        let chars = Array(body)
        var i = 0
        func parse(inDefault: Bool) throws -> [Node] {
            var nodes: [Node] = []
            var text = ""
            func flush() {
                if !text.isEmpty { nodes.append(.text(text)) }
                text = ""
            }
            while i < chars.count {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count, "$\\`".contains(chars[i + 1]) || (inDefault && chars[i + 1] == "}") {
                    text.append(chars[i + 1])
                    i += 2
                    continue
                }
                if inDefault, c == "}" {
                    i += 1
                    flush()
                    return nodes
                }
                guard c == "$", i + 1 < chars.count else {
                    text.append(c)
                    i += 1
                    continue
                }
                if chars[i + 1].isASCII, chars[i + 1].isNumber {
                    var j = i + 1
                    while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
                    flush()
                    nodes.append(.stop(Int(String(chars[(i + 1)..<j]))!, nil))
                    i = j
                    continue
                }
                if chars[i + 1] == "{", i + 2 < chars.count, chars[i + 2].isASCII, chars[i + 2].isNumber {
                    var j = i + 2
                    while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
                    let number = Int(String(chars[(i + 2)..<j]))!
                    guard j < chars.count, chars[j] == ":" || chars[j] == "}" else {
                        throw Problem(line: 0, message: "expected : or } after ${\(number)")
                    }
                    flush()
                    if chars[j] == "}" {
                        nodes.append(.stop(number, []))
                        i = j + 1
                        continue
                    }
                    if j + 2 < chars.count, chars[j + 1] == "$", chars[j + 2] == "(" {
                        throw Problem(line: 0, message: "Emacs Lisp in a field isn't supported")
                    }
                    i = j + 1
                    nodes.append(.stop(number, try parse(inDefault: true)))
                    continue
                }
                text.append(c)
                i += 1
            }
            if inDefault { throw Problem(line: 0, message: "a ${ isn't closed") }
            flush()
            return nodes
        }
        return try parse(inDefault: false)
    }

    /// Marks in the text a body becomes before the capture escapes are filled. Capture leaves
    /// characters in the private use area alone.
    static let fieldOpen: Character = "\u{E020}"
    static let fieldSeparator: Character = "\u{E021}"
    static let mirrorSeparator: Character = "\u{E026}"
    static let fieldClose: Character = "\u{E022}"
    static let edge: Character = "\u{E023}"
    static let tab: Character = "\u{E024}"
    static let backslash: Character = "\u{E025}"

    /// The body with its stops as marks: the first `${N:…}` of a number (else its first `$N`)
    /// is the field, the others mirrors. Tabs and literal backslashes are marked too, so that
    /// filling leaves them.
    static func marked(_ nodes: [Node]) -> String {
        var primaries: [Int: Int] = [:]
        var occurrence = 0
        var withDefault: Set<Int> = []
        func scan(_ nodes: [Node]) {
            for node in nodes {
                guard case .stop(let number, let children) = node else { continue }
                if let children {
                    if !withDefault.contains(number) {
                        withDefault.insert(number)
                        primaries[number] = occurrence
                    }
                    occurrence += 1
                    scan(children)
                } else {
                    if primaries[number] == nil { primaries[number] = occurrence }
                    occurrence += 1
                }
            }
        }
        scan(nodes)
        occurrence = 0
        func emit(_ nodes: [Node]) -> String {
            var out = ""
            for node in nodes {
                switch node {
                case .text(let text):
                    // Backslashes in capture escapes (`\\%t`, `%\\1`) stay for capture.
                    out += text.replacingOccurrences(of: "(?<!%)\\\\(?!%)", with: String(backslash), options: .regularExpression)
                        .replacingOccurrences(of: "\t", with: String(tab))
                case .stop(let number, let children):
                    let primary = primaries[number] == occurrence
                    occurrence += 1
                    out += String(fieldOpen) + String(number) + String(primary ? fieldSeparator : mirrorSeparator)
                    if primary, let children { out += emit(children) } else if let children { _ = emit(children) }
                    out += String(fieldClose)
                }
            }
            return out
        }
        return emit(nodes)
    }

    /// The `%?` of capture as `$0`, unless escaped.
    static func captureCaret(_ body: String) -> String {
        body.replacingOccurrences(of: "(?<!\\\\)%\\?", with: "\\$0", options: .regularExpression)
    }

    /// The capture prompts the body asks, in order.
    public static func questions(_ snippet: Snippet, context: CaptureContext) -> [Capture.Question] {
        guard let nodes = try? parseBody(captureCaret(snippet.body)) else { return [] }
        return Capture.questions(String(edge) + marked(nodes) + String(edge), context: context)
    }

    /// The snippet expanded with `answers` to its `questions`; lines after the first start
    /// with `indentation`.
    public static func expand(_ snippet: Snippet, context: CaptureContext, answers: [String] = [], indentation: String = "") -> Result<SnippetExpansion, Capture.Failure> {
        let nodes: [Node]
        do {
            nodes = try parseBody(captureCaret(snippet.body))
        } catch {
            return .failure(.message("\(snippet.trigger): \(error)"))
        }
        let filled: String
        switch Capture.fill(String(edge) + marked(nodes) + String(edge), context: context, answers: answers) {
        case .failure(let failure): return .failure(failure)
        case .success(let result): filled = result.text
        }
        guard let first = filled.firstIndex(of: edge), let last = filled.lastIndex(of: edge), first < last else {
            return .failure(.message("\(snippet.trigger) couldn't be expanded"))
        }
        var inner = String(filled[filled.index(after: first)..<last])
        if !indentation.isEmpty { inner = inner.replacingOccurrences(of: "\n", with: "\n" + indentation) }
        return .success(extract(inner))
    }

    /// Reads the marks out of filled text: the text with mirrors showing their field's text,
    /// and the ranges.
    static func extract(_ marked: String) -> SnippetExpansion {
        // Pieces: text, or a stop with its number, whether it is the field, and its pieces.
        indirect enum Piece {
            case text(String)
            case stop(Int, Bool, [Piece])
        }
        let chars = Array(marked)
        var i = 0
        func read() -> [Piece] {
            var pieces: [Piece] = []
            var text = ""
            while i < chars.count {
                let c = chars[i]
                if c == fieldClose {
                    i += 1
                    break
                }
                if c == fieldOpen {
                    if !text.isEmpty { pieces.append(.text(text)) }
                    text = ""
                    var j = i + 1
                    while j < chars.count, chars[j] != fieldSeparator, chars[j] != mirrorSeparator { j += 1 }
                    let number = Int(String(chars[(i + 1)..<j])) ?? 0
                    let primary = j < chars.count && chars[j] == fieldSeparator
                    i = j + 1
                    pieces.append(.stop(number, primary, read()))
                    continue
                }
                text.append(c == tab ? "\t" : c == backslash ? "\\" : c)
                i += 1
            }
            if !text.isEmpty { pieces.append(.text(text)) }
            return pieces
        }
        let pieces = read()
        // Each field's text, for its mirrors.
        var values: [Int: String] = [:]
        func flatten(_ pieces: [Piece], depth: Int = 0) -> String {
            pieces.map { piece -> String in
                switch piece {
                case .text(let text): return text
                case .stop(let number, let primary, let children):
                    if primary { return flatten(children, depth: depth) }
                    return depth > 8 ? "" : (values[number] ?? "")
                }
            }.joined()
        }
        func collect(_ pieces: [Piece]) {
            for case .stop(let number, let primary, let children) in pieces where primary {
                collect(children)
                values[number] = flatten(children)
            }
        }
        collect(pieces)
        // Mirrors inside defaults show values found after them; one more pass settles those.
        collect(pieces)
        var text = ""
        var length = 0
        var fields: [Int: (primary: Range<Int>?, mirrors: [Range<Int>])] = [:]
        func render(_ pieces: [Piece]) {
            for piece in pieces {
                switch piece {
                case .text(let s):
                    text += s
                    length += s.utf16.count
                case .stop(let number, let primary, let children):
                    let start = length
                    if primary {
                        render(children)
                        fields[number, default: (nil, [])].primary = start..<length
                    } else {
                        let value = values[number] ?? ""
                        text += value
                        length += value.utf16.count
                        fields[number, default: (nil, [])].mirrors.append(start..<length)
                    }
                }
            }
        }
        render(pieces)
        let exit = fields[0]?.primary ?? fields[0]?.mirrors.first ?? length..<length
        let list = fields.filter { $0.key != 0 }.sorted { $0.key < $1.key }.map { number, ranges in
            SnippetExpansion.Field(number: number, ranges: [ranges.primary ?? ranges.mirrors[0]] + (ranges.primary == nil ? Array(ranges.mirrors.dropFirst()) : ranges.mirrors))
        }
        return SnippetExpansion(text: text, fields: list, exit: exit)
    }
}
