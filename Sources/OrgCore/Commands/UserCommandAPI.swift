import Foundation

/// Version 1 of the API user commands call (`org.text()`, `org.heading()`, …) and of the value
/// they return. Answers are JSON values (`String`, `Int`, `Bool`, `NSNull`, arrays and
/// dictionaries of them) computed from the context the command started with; offsets are UTF-16,
/// as JavaScript strings count them.
public enum UserCommandAPI {
    /// The answer to a call that reads the buffer: `text`, `selection`, `heading`, `outline`,
    /// `file` or `settings`; nil for any other name. `file` is the file's path relative to its
    /// folder.
    public static func answer(_ name: String, _ value: Any, context: EditContext, file: String?) -> Any? {
        switch name {
        case "text": return context.text
        case "selection": return context.selection.map(range)
        case "heading":
            let at = (value as? NSNumber).flatMap { integer($0) } ?? context.caret
            let model = DocumentModel(tree: context.tree)
            return heading(at: at, model: model, context: context).map { describe($0, model: model, context: context) } ?? NSNull()
        case "outline":
            let model = DocumentModel(tree: context.tree)
            return model.headings.indices.map { describe($0, model: model, context: context) }
        case "file": return file ?? NSNull()
        case "settings": return settings(context)
        default: return nil
        }
    }

    static func range(_ range: Range<Int>) -> [String: Any] {
        ["from": range.lowerBound, "to": range.upperBound]
    }

    /// The innermost heading whose subtree holds `offset`.
    static func heading(at offset: Int, model: DocumentModel, context: EditContext) -> Int? {
        let length = context.text.utf16.count
        return model.headings.indices.last { index in
            let section = model.headings[index].sectionRange
            return section.contains(offset) || (offset == section.upperBound && offset == length)
        }
    }

    static func describe(_ index: Int, model: DocumentModel, context: EditContext) -> [String: Any] {
        let info = model.headings[index]
        let text = context.text as NSString
        var lineEnd = info.headingRange.upperBound
        if lineEnd > info.headingRange.lowerBound, text.character(at: lineEnd - 1) == 0x0A { lineEnd -= 1 }
        var node = context.tree.root
        while node.kind != .heading, let child = node.child(containing: info.headingRange.lowerBound) { node = child }
        let title = node.kind == .heading ? node.firstChild(.title)?.range : nil
        var properties: [String: Any] = [:]
        for property in info.properties { properties[property.key] = property.value }
        var described: [String: Any] = [
            "level": info.level,
            "keyword": info.todo ?? NSNull(),
            "done": info.isDone,
            "priority": info.priority ?? NSNull(),
            "title": info.title,
            "tags": info.localTags,
            "start": info.sectionRange.lowerBound,
            "end": info.sectionRange.upperBound,
            "titleStart": title?.lowerBound ?? lineEnd,
            "titleEnd": title?.upperBound ?? lineEnd,
            "properties": properties,
        ]
        let planning = Self.planning(text.substring(with: NSRange(location: info.headingRange.upperBound, length: max(0, nextLineEnd(after: info.headingRange.upperBound, in: text) - info.headingRange.upperBound))))
        for kind in ["scheduled", "deadline", "closed"] { described[kind] = planning[kind] ?? NSNull() }
        return described
    }

    static func nextLineEnd(after offset: Int, in text: NSString) -> Int {
        guard offset < text.length else { return offset }
        let line = text.lineRange(for: NSRange(location: offset, length: 0))
        return NSMaxRange(line)
    }

    private static let planningPattern = try! NSRegularExpression(pattern: #"\b(SCHEDULED|DEADLINE|CLOSED):\s*([<\[][^>\]\n]*[>\]])"#)

    /// The timestamps of a planning line, by lowercased keyword; empty for any other line.
    static func planning(_ line: String) -> [String: String] {
        guard line.trimmingCharacters(in: .whitespaces).range(of: #"^(SCHEDULED|DEADLINE|CLOSED):"#, options: .regularExpression) != nil else { return [:] }
        var result: [String: String] = [:]
        let ns = line as NSString
        for match in planningPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            result[ns.substring(with: match.range(at: 1)).lowercased()] = ns.substring(with: match.range(at: 2))
        }
        return result
    }

    static func settings(_ context: EditContext) -> [String: Any] {
        let settings = context.tree.settings
        return [
            "todoKeywords": settings.todoSequences.flatMap { $0.active.map(\.name) },
            "doneKeywords": settings.todoSequences.flatMap { $0.done.map(\.name) },
            "priorities": ["highest": settings.priorities.highest, "lowest": settings.priorities.lowest, "default": settings.priorities.default],
            "fileTags": DocumentModel(tree: context.tree).fileTags,
            "tags": context.knownTags(),
            "fillColumn": context.options.fillColumn,
            "tagsColumn": context.options.tagsColumn,
        ]
    }

    // MARK: - Results

    /// What a command returned, as JSON, read into a result for the context it ran in: `edits`
    /// (`{from, to, text}` in the text it was given, non-overlapping), `selection` (`{from, to}`,
    /// a list of them or an offset, in the text after the edits), `message` and `copy`. Null is
    /// no change. A message saying what is wrong when the value can't be used.
    public static func result(_ json: String, in context: EditContext) -> Result<EditResult, Problem> {
        guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed) else {
            return .failure(Problem("returned something that isn't JSON"))
        }
        if value is NSNull { return .success(EditResult(baseRevision: context.revision, edits: [])) }
        guard let object = value as? [String: Any] else { return .failure(Problem("returned something other than an object")) }
        if let key = object.keys.sorted().first(where: { !["edits", "selection", "message", "copy"].contains($0) }) {
            return .failure(Problem("returned an unknown key \(key)"))
        }
        let text = context.text as NSString
        var edits: [TextEdit] = []
        if let raw = object["edits"], !(raw is NSNull) {
            guard let list = raw as? [Any] else { return .failure(Problem("edits must be a list")) }
            for (number, item) in zip(1..., list) {
                guard let edit = item as? [String: Any], let from = (edit["from"] as? NSNumber).flatMap(integer) else {
                    return .failure(Problem("edit \(number) needs a from offset"))
                }
                let to = edit["to"].map { ($0 as? NSNumber).flatMap(integer) } ?? from
                guard let to else { return .failure(Problem("edit \(number) has a to that isn't an offset")) }
                let replacement = edit["text"] ?? ""
                guard let replacement = replacement as? String else { return .failure(Problem("edit \(number) has a text that isn't a string")) }
                guard 0 <= from, from <= to, to <= text.length else { return .failure(Problem("edit \(number) is outside the text")) }
                guard !splits(from, text), !splits(to, text) else { return .failure(Problem("edit \(number) splits a character")) }
                edits.append(TextEdit(range: from..<to, replacement: replacement))
            }
        }
        let sorted = edits.enumerated().sorted { ($0.element.range.lowerBound, $0.offset) < ($1.element.range.lowerBound, $1.offset) }.map(\.element)
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.range.lowerBound < a.range.upperBound || b.range.lowerBound == a.range.lowerBound {
            return .failure(Problem("edits overlap"))
        }
        let length = text.length + sorted.reduce(0) { $0 + $1.replacement.utf16.count - $1.range.count }
        var selection: [Range<Int>]?
        if let raw = object["selection"], !(raw is NSNull) {
            let items: [Any] = (raw as? [Any]) ?? [raw]
            var ranges: [Range<Int>] = []
            for item in items {
                let bounds: (Int, Int)?
                if let offset = (item as? NSNumber).flatMap(integer) {
                    bounds = (offset, offset)
                } else if let range = item as? [String: Any], let from = (range["from"] as? NSNumber).flatMap(integer) {
                    bounds = range["to"].map { ($0 as? NSNumber).flatMap(integer).map { (from, $0) } } ?? (from, from)
                } else {
                    bounds = nil
                }
                guard let (from, to) = bounds, 0 <= min(from, to), max(from, to) <= length else {
                    return .failure(Problem("selection is outside the text"))
                }
                ranges.append(min(from, to)..<max(from, to))
            }
            if !ranges.isEmpty { selection = ranges }
        }
        var effects: [Effect] = []
        for key in ["message", "copy"] {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            guard let string = raw as? String else { return .failure(Problem("\(key) must be a string")) }
            effects.append(key == "message" ? .message(string) : .copy(string))
        }
        return .success(EditResult(baseRevision: context.revision, edits: sorted, selection: selection, effects: effects))
    }

    public struct Problem: Error, Equatable {
        public let message: String
        init(_ message: String) { self.message = message }
    }

    /// Whether `offset` falls between the two halves of a surrogate pair.
    static func splits(_ offset: Int, _ text: NSString) -> Bool {
        offset > 0 && offset < text.length && (0xDC00...0xDFFF).contains(text.character(at: offset))
    }

    static func integer(_ number: NSNumber) -> Int? {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 1e15 else { return nil }
        return Int(double)
    }

    // MARK: - Prompts

    /// A prompt from the value of `org.prompt(...)`: `message`, `initial`, `choices`,
    /// `requireMatch` (default false) and `date`.
    public static func prompt(_ value: Any) -> Prompt {
        let options = value as? [String: Any] ?? [:]
        let message = (options["message"] as? String) ?? (value as? String) ?? ""
        let choices = (options["choices"] as? [Any])?.compactMap { $0 as? String } ?? []
        let date = (options["date"] as? Bool) == true
        return Prompt(
            key: "user", message: message, initial: options["initial"] as? String ?? "", choices: choices,
            requireMatch: (options["requireMatch"] as? Bool) == true && !choices.isEmpty,
            date: date ? .init(defaultDate: nil) : nil
        )
    }

    /// The answer the command gets: the text typed, or for a date prompt the date read from it,
    /// `YYYY-MM-DD` or `YYYY-MM-DD HH:MM`.
    public static func answer(_ text: String, to prompt: Prompt, now: Date, calendar: Calendar) -> String {
        guard prompt.date != nil else { return text }
        let read = ReadDate.read(text, default: nil, now: now, calendar: calendar)
        let day = String(format: "%04d-%02d-%02d", read.year, read.month, read.day)
        return read.timeGiven ? day + String(format: " %02d:%02d", read.hour, read.minute) : day
    }
}
