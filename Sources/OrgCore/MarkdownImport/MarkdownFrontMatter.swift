import Foundation

/// YAML front matter between `---` lines at the top of a Markdown file. Reads the subset notes
/// use: `key: value`, quoted strings, `[a, b]` and `- item` lists, and `|` and `>` blocks.
/// Nested maps are kept as `nested`.
enum MarkdownFrontMatter {
    enum Value: Equatable, Sendable {
        case scalar(String)
        case list([String])
        case nested
    }

    /// The entries and the text after the front matter; no entries and the whole text when
    /// there is none.
    static func split(_ text: String) -> (entries: [(key: String, value: Value)], body: String) {
        guard text.hasPrefix("---") else { return ([], text) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return ([], text) }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (parse(lines[1..<end].map(String.init)), body)
    }

    static func parse(_ lines: [String]) -> [(key: String, value: Value)] {
        var entries: [(key: String, value: Value)] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("#"), let colon = keyColon(line) else { continue }
            let key = unquote(String(line[..<colon]).trimmingCharacters(in: .whitespaces))
            let rest = stripComment(String(line[line.index(after: colon)...])).trimmingCharacters(in: .whitespaces)
            var nested: [String] = []
            while i < lines.count, lines[i].hasPrefix(" ") || lines[i].hasPrefix("-") || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                nested.append(lines[i])
                i += 1
            }
            while nested.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { nested.removeLast() }
            if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
                let indent = nested.compactMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.prefix { $0 == " " }.count }.min() ?? 0
                let body = nested.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
                entries.append((key, .scalar(body.joined(separator: rest.hasPrefix("|") ? "\n" : " "))))
            } else if !rest.isEmpty {
                if rest.hasPrefix("["), rest.hasSuffix("]") {
                    entries.append((key, .list(flowItems(String(rest.dropFirst().dropLast())))))
                } else if rest.hasPrefix("{") {
                    entries.append((key, .nested))
                } else {
                    entries.append((key, .scalar(unquote(rest))))
                }
            } else if nested.isEmpty {
                entries.append((key, .scalar("")))
            } else if nested.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") || $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let items = nested.compactMap { line -> String? in
                    let item = line.trimmingCharacters(in: .whitespaces)
                    guard item.hasPrefix("-") else { return nil }
                    return unquote(stripComment(String(item.dropFirst())).trimmingCharacters(in: .whitespaces))
                }
                entries.append((key, .list(items.filter { !$0.isEmpty })))
            } else {
                entries.append((key, .nested))
            }
        }
        return entries
    }

    /// The colon ending a key: the first one outside quotes followed by a space or the end.
    private static func keyColon(_ line: String) -> String.Index? {
        var quote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if let open = quote {
                if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == ":" {
                let next = line.index(after: index)
                if next == line.endIndex || line[next] == " " { return index }
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func stripComment(_ value: String) -> String {
        guard !value.trimmingCharacters(in: .whitespaces).hasPrefix("\""), !value.trimmingCharacters(in: .whitespaces).hasPrefix("'"),
              let range = value.range(of: " #") else { return value }
        return String(value[..<range.lowerBound])
    }

    static func unquote(_ value: String) -> String {
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            let inner = String(value.dropFirst().dropLast())
            return first == "'" ? inner.replacingOccurrences(of: "''", with: "'")
                : inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return value
    }

    private static func flowItems(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for char in text {
            if let open = quote {
                current.append(char)
                if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
                current.append(char)
            } else if char == "," {
                items.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        items.append(current)
        return items.map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }
}
