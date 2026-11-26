import Foundation

/// Rename Tag: a tag renamed in heading tag lists, realigned as `org-set-tags` leaves them, and
/// in `#+TAGS` and `#+FILETAGS` lines; never in other text. A name already there merges.
public enum TagRename {
    /// Characters a tag can hold (`org-tag-re`).
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || "_@#%".contains($0) }
    }

    public static func changes(in text: String, tree: OrgTree, from old: String, to new: String, options: EditingOptions, skipping: [Range<Int>] = []) -> [ProposedChange] {
        let ns = text as NSString
        let lines = LineStarts(ns)
        var edits: [(edit: TextEdit, shown: TextEdit)] = []
        for node in tree.root.descendants() {
            switch node.kind {
            case .heading:
                guard let token = node.tokens.first(where: { $0.kind == .tags }) else { continue }
                let tags = token.text.split(separator: ":").map(String.init)
                guard tags.contains(old) else { continue }
                var renamed: [String] = []
                for tag in tags.map({ $0 == old ? new : $0 }) where !renamed.contains(tag) { renamed.append(tag) }
                let content = lines.content(ofLine: lines.line(of: node.range.lowerBound))
                let line = ns.substring(with: NSRange(content))
                let buffer = EmacsBuffer(line, point: 0, settings: tree.settings, options: options)
                guard (try? SetTags.set(renamed, in: buffer)) != nil else { continue }
                if let edit = LineStarts.edit(lineStart: content.lowerBound, from: line, to: buffer.string) {
                    edits.append((edit, TextEdit(range: token.range, replacement: renamed.isEmpty ? "" : ":" + renamed.joined(separator: ":") + ":")))
                }
            case .keyword:
                guard let (key, content, line) = keywordLine(node, lines) else { continue }
                let value = key.value
                let renamed: String? = switch key.name {
                case "TAGS": renamedTagsValue(String(line[value]), from: old, to: new)
                case "FILETAGS": renamedFileTagsValue(String(line[value]), from: old, to: new)
                default: nil
                }
                guard let renamed else { continue }
                let newLine = String(line[..<value.lowerBound]) + renamed
                if let edit = LineStarts.edit(lineStart: content.lowerBound, from: line, to: newLine) { edits.append((edit, lines.wholeWords(edit))) }
            default:
                break
            }
        }
        return edits.filter { !EncryptedText.overlaps($0.edit.range, skipping) }.enumerated().map { lines.change(id: $0.offset, $0.element.edit, shown: $0.element.shown) }
    }

    /// Lines of `org-tag-alist` in `#+TAGS` syntax with `old` renamed; nil when none names it.
    public static func renamedTagAlist(_ alist: String, from old: String, to new: String) -> String? {
        renamedLines(alist) { renamedTagsValue($0, from: old, to: new) }
    }

    /// A `#+TAGS` value with the tag `old` renamed, keeping its fast-selection key, or removed
    /// when `new` is there already; nil when it doesn't name `old`.
    static func renamedTagsValue(_ value: String, from old: String, to new: String) -> String? {
        let name = "[\\p{L}\\p{N}_@#%"
        func token(_ tag: String) -> String { "(?<!\(name)(])" + NSRegularExpression.escapedPattern(for: tag) + "(?!\(name)])" }
        return renamedValue(value, old: token(old), new: token(new), key: "(?:\\([^)]*\\))?", separators: "\\s", replacement: new)
    }

    /// A `#+FILETAGS` value (`:a:b:` or `a b`) with `old` renamed, or removed when `new` is
    /// there already; nil when it doesn't name `old`.
    static func renamedFileTagsValue(_ value: String, from old: String, to new: String) -> String? {
        func token(_ tag: String) -> String { "(?<![^\\s:])" + NSRegularExpression.escapedPattern(for: tag) + "(?![^\\s:])" }
        return renamedValue(value, old: token(old), new: token(new), key: "", separators: "[\\s:]", replacement: new)
    }
}

/// Rename TODO Keyword: a keyword renamed where it is a keyword, in heading keyword position
/// and in `#+TODO`, `#+SEQ_TODO` and `#+TYP_TODO` lines, with the heading's tags realigned;
/// never in other text. A name already there merges; a rename across done and not-done states
/// is refused.
public enum KeywordRename {
    /// A keyword is a word without parentheses or a bar, which `#+TODO` syntax gives meaning.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "|" && !name.contains { $0.isWhitespace || $0 == "(" || $0 == ")" }
    }

    /// Whether `old` and `new` are both keywords under `settings`, one a done state and the
    /// other not.
    public static func crossesStates(_ settings: OrgSettings, from old: String, to new: String) -> Bool {
        let names = settings.todoKeywordNames
        return names.contains(old) && names.contains(new) && settings.isDone(old) != settings.isDone(new)
    }

    /// Where a file's keyword is defined.
    public enum Source: Sendable, Equatable {
        /// The file's own `#+TODO` lines.
        case file
        /// A `#+SETUPFILE` it names.
        case setupFile
        /// No TODO lines: the keywords for files without them (`org-todo-keywords`).
        case defaults
        /// It isn't a keyword in the file.
        case none
    }

    public static func source(of keyword: String, in tree: OrgTree) -> Source {
        let keys: Set<String> = ["TODO", "SEQ_TODO", "TYP_TODO"]
        func names(_ value: Substring) -> [String] { SettingsScanner.todoSequence(value, kind: .sequence).map { ($0.active + $0.done).map(\.name) } ?? [] }
        let text = tree.text as NSString
        let lines = LineStarts(text)
        for node in tree.root.descendants() where node.kind == .keyword {
            guard let (key, _, line) = keywordLine(node, lines), keys.contains(key.name) else { continue }
            if names(line[key.value]).contains(keyword) { return .file }
        }
        for (key, value) in SetupFile.keywords(tree.settings.setupKeywords) where keys.contains(key) && names(value).contains(keyword) {
            return .setupFile
        }
        return tree.settings.todoKeywordNames.contains(keyword) ? .defaults : .none
    }

    /// The changes renaming `old` to `new` in `text`: the TODO keyword lines, and with
    /// `headings` the headings' keywords.
    public static func changes(in text: String, tree: OrgTree, from old: String, to new: String, headings: Bool, options: EditingOptions, skipping: [Range<Int>] = []) -> [ProposedChange] {
        let ns = text as NSString
        let lines = LineStarts(ns)
        var edits: [(edit: TextEdit, shown: TextEdit)] = []
        for node in tree.root.descendants() {
            switch node.kind {
            case .heading where headings:
                guard let token = node.tokens.first(where: { $0.kind == .todoKeyword }), token.text == old else { continue }
                let content = lines.content(ofLine: lines.line(of: node.range.lowerBound))
                let line = ns.substring(with: NSRange(content))
                let at = NSRange(location: token.range.lowerBound - content.lowerBound, length: token.range.count)
                var buffer = LineBuffer((line as NSString).replacingCharacters(in: at, with: new), caret: nil)
                // `org-todo` realigns the tags after the keyword changed the title's width.
                if node.tokens.contains(where: { $0.kind == .tags }) { alignTags(&buffer, options: options) }
                if let edit = LineStarts.edit(lineStart: content.lowerBound, from: line, to: buffer.string) {
                    edits.append((edit, TextEdit(range: token.range, replacement: new)))
                }
            case .keyword:
                guard let (key, content, line) = keywordLine(node, lines), ["TODO", "SEQ_TODO", "TYP_TODO"].contains(key.name),
                      let renamed = renamedTodoValue(String(line[key.value]), from: old, to: new) else { continue }
                let newLine = String(line[..<key.value.lowerBound]) + renamed
                if let edit = LineStarts.edit(lineStart: content.lowerBound, from: line, to: newLine) { edits.append((edit, lines.wholeWords(edit))) }
            default:
                break
            }
        }
        return edits.filter { !EncryptedText.overlaps($0.edit.range, skipping) }.enumerated().map { lines.change(id: $0.offset, $0.element.edit, shown: $0.element.shown) }
    }

    /// `org-todo-keywords` in `#+TODO` syntax, a sequence a line, with `old` renamed; nil when
    /// none names it.
    public static func renamedTodoKeywords(_ lines: String, from old: String, to new: String) -> String? {
        renamedLines(lines) { renamedTodoValue($0, from: old, to: new) }
    }

    /// A `#+TODO` value with the keyword `old` renamed, keeping its key and logging flags, or
    /// removed when `new` is there already; nil when it doesn't name `old`.
    static func renamedTodoValue(_ value: String, from old: String, to new: String) -> String? {
        func token(_ name: String) -> String { "(?<!\\S)" + NSRegularExpression.escapedPattern(for: name) + "(?=\\(|\\s|$)" }
        return renamedValue(value, old: token(old), new: token(new), key: "(?:\\([^)]*\\))?", separators: "\\s", replacement: new)
    }
}

/// A keyword line's name, upper-cased, and where its value starts in the line.
struct KeywordLine {
    let name: String
    let value: Range<String.Index>
}

/// The keyword node's line, its range in the text, and its name and value.
func keywordLine(_ node: SyntaxNode, _ lines: LineStarts) -> (KeywordLine, Range<Int>, String)? {
    let content = lines.content(ofLine: lines.line(of: node.range.lowerBound))
    let line = lines.text.substring(with: NSRange(content))
    guard let match = line.firstMatch(of: /^[ \t]*#\+([^:\s]+):/) else { return nil }
    return (KeywordLine(name: match.1.uppercased(), value: match.range.upperBound..<line.endIndex), content, line)
}

/// `value` with the token `old` (a pattern) and its `key` suffix renamed to `replacement`, or,
/// when the token `new` is in it too, removed with the separators on one side of it. Nil when
/// `old` isn't in it.
private func renamedValue(_ value: String, old: String, new: String, key: String, separators: String, replacement: String) -> String? {
    guard let oldRegex = try? NSRegularExpression(pattern: old), let newRegex = try? NSRegularExpression(pattern: new) else { return nil }
    let ns = value as NSString
    let whole = NSRange(location: 0, length: ns.length)
    guard oldRegex.firstMatch(in: value, range: whole) != nil else { return nil }
    if newRegex.firstMatch(in: value, range: whole) == nil {
        return oldRegex.stringByReplacingMatches(in: value, range: whole, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
    // Merging: the separators after the token go with it, else those before it.
    guard let withKey = try? NSRegularExpression(pattern: "(" + old + key + ")(" + separators + "+)?") else { return nil }
    var result = value
    while let match = withKey.firstMatch(in: result, range: NSRange(location: 0, length: (result as NSString).length)) {
        var range = match.range
        if match.range(at: 2).location == NSNotFound {
            let text = result as NSString
            var start = range.location
            while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)),
                  String(scalar).range(of: "^" + separators + "$", options: .regularExpression) != nil { start -= 1 }
            range = NSRange(location: start, length: NSMaxRange(range) - start)
        }
        result = (result as NSString).replacingCharacters(in: range, with: "")
    }
    return result
}

/// `text`'s lines, each through `rename`; nil when it renamed none.
private func renamedLines(_ text: String, _ rename: (String) -> String?) -> String? {
    var changed = false
    let lines = text.components(separatedBy: "\n").map { line -> String in
        guard let renamed = rename(line) else { return line }
        changed = true
        return renamed
    }
    return changed ? lines.joined(separator: "\n") : nil
}
