import Foundation

/// A Markdown document's blocks, as `MarkdownBlocks.parse` reads them: CommonMark's block
/// structure plus GFM tables, task items and footnotes, and Obsidian's callouts and `%%`
/// comments when `obsidian` is set.
indirect enum MarkdownBlock: Equatable, Sendable {
    /// An ATX or setext heading; `text` is the raw inline text.
    case heading(level: Int, text: String)
    /// Raw lines, inline markup unconverted.
    case paragraph([String])
    /// A fenced block (`lang` from its info string) or an indented one (`fenced` false).
    case code(lang: String, lines: [String], fenced: Bool)
    /// `$$ … $$` on lines of their own.
    case math([String])
    /// `%% … %%` (Obsidian) or `<!-- … -->` on lines of their own.
    case comment([String])
    case html([String])
    case quote([MarkdownBlock])
    /// `> [!type] title`; `type` lowercased.
    case callout(type: String, title: String, blocks: [MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [MarkdownItem])
    case table(header: [String], rows: [[String]])
    case rule
}

struct MarkdownItem: Equatable, Sendable {
    /// The character between a task item's brackets, `nil` for a plain item.
    var task: Character?
    var blocks: [MarkdownBlock]
}

/// What a parse found besides blocks: footnote definitions and link reference definitions.
struct MarkdownDefinitions {
    var footnotes: [(label: String, blocks: [MarkdownBlock])] = []
    /// Lowercased, whitespace-collapsed label to destination.
    var links: [String: String] = [:]
}

struct MarkdownBlocks {
    let obsidian: Bool
    var definitions = MarkdownDefinitions()

    init(obsidian: Bool) { self.obsidian = obsidian }

    static func parse(_ text: String, obsidian: Bool) -> (blocks: [MarkdownBlock], definitions: MarkdownDefinitions) {
        var parser = MarkdownBlocks(obsidian: obsidian)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map { expandTabs(String($0)) }
        let blocks = parser.blocks(lines)
        return (blocks, parser.definitions)
    }

    /// Tabs to spaces at four-column stops, in the leading whitespace only.
    static func expandTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var out = ""
        var column = 0
        var leading = true
        for char in line {
            if leading, char == "\t" {
                let width = 4 - column % 4
                out += String(repeating: " ", count: width)
                column += width
            } else {
                if char != " " { leading = false }
                out.append(char)
                column += 1
            }
        }
        return out
    }

    // MARK: - Line tests

    static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
    static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " } }

    static func fence(_ line: String) -> (char: Character, count: Int, indent: Int, info: String)? {
        let indent = indent(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let char = rest.first, char == "`" || char == "~" else { return nil }
        let count = rest.prefix { $0 == char }.count
        guard count >= 3 else { return nil }
        let info = rest.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if char == "`", info.contains("`") { return nil }
        return (char, count, indent, info)
    }

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        let indent = indent(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // A closing sequence of #s preceded by a space.
        if let closing = text.lastIndex(where: { $0 != "#" }) {
            let tail = text[text.index(after: closing)...]
            if !tail.isEmpty, text[closing] == " " { text = String(text[...closing]).trimmingCharacters(in: .whitespaces) }
        } else {
            text = ""
        }
        return (level, text)
    }

    static func isRule(_ line: String) -> Bool {
        guard indent(line) <= 3 else { return false }
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    static func setextLevel(_ line: String) -> Int? {
        guard indent(line) <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "=" || first == "-", trimmed.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    struct ListMarker {
        var ordered: Bool
        /// `-`, `+`, `*`, `.` or `)`.
        var delimiter: Character
        var start: Int
        var indent: Int
        /// Columns from the line's start to the item's content.
        var contentIndent: Int
        var empty: Bool
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = indent(line)
        let rest = Array(line.dropFirst(indent))
        guard let first = rest.first else { return nil }
        var width: Int
        var marker: ListMarker
        if "-+*".contains(first) {
            width = 1
            marker = ListMarker(ordered: false, delimiter: first, start: 1, indent: indent, contentIndent: 0, empty: false)
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), digits.count < rest.count else { return nil }
            let delimiter = rest[digits.count]
            guard delimiter == "." || delimiter == ")" else { return nil }
            width = digits.count + 1
            marker = ListMarker(ordered: true, delimiter: delimiter, start: Int(String(digits)) ?? 1, indent: indent, contentIndent: 0, empty: false)
        }
        let after = rest.dropFirst(width)
        if after.isEmpty {
            marker.empty = true
            marker.contentIndent = indent + width + 1
            return marker
        }
        guard after.first == " " else { return nil }
        let spaces = after.prefix { $0 == " " }.count
        if spaces == after.count {
            marker.empty = true
            marker.contentIndent = indent + width + 1
        } else {
            marker.contentIndent = indent + width + (spaces > 4 ? 1 : spaces)
        }
        return marker
    }

    static func isQuote(_ line: String) -> Bool {
        indent(line) <= 3 && line.drop { $0 == " " }.first == ">"
    }

    static func stripQuote(_ line: String) -> String {
        var rest = line.drop { $0 == " " }.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    static func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for char in text {
            if escaped {
                if char == "|" {
                    current.append("\u{1}")
                } else {
                    current.append("\\")
                    current.append(char)
                }
                escaped = false
                continue
            }
            switch char {
            case "\\": escaped = true
            case "`":
                inCode.toggle()
                current.append(char)
            case "|" where !inCode:
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default: current.append(char)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func isDelimiterRow(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            var body = Substring(cell)
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    static func tableStarts(_ lines: [String], at i: Int) -> Bool {
        i + 1 < lines.count && indent(lines[i]) <= 3 && lines[i].contains("|") && isDelimiterRow(lines[i + 1])
            && tableCells(lines[i]).count == tableCells(lines[i + 1]).count
    }

    static let htmlBlockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "div", "dl", "fieldset", "figcaption", "figure",
        "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "iframe", "li", "main", "nav", "ol", "p", "pre",
        "section", "summary", "table", "tbody", "td", "th", "thead", "tr", "ul", "video", "audio", "picture", "script", "style", "br", "img"
    ]

    static func htmlBlockStart(_ line: String) -> Bool {
        guard indent(line) <= 3 else { return false }
        let rest = line.drop { $0 == " " }
        guard rest.hasPrefix("<") else { return false }
        if rest.hasPrefix("<!--") { return true }
        let name = rest.dropFirst().drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber || $0 == "-" }.lowercased()
        guard !name.isEmpty else { return false }
        if htmlBlockTags.contains(name) { return true }
        // Any other tag alone on its line.
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix(">") && !trimmed.dropFirst().contains("<")
    }

    static func footnoteDefinition(_ line: String) -> (label: String, rest: String)? {
        guard indent(line) <= 3 else { return nil }
        let rest = line.drop { $0 == " " }
        guard rest.hasPrefix("[^"), let close = rest.firstIndex(of: "]") else { return nil }
        let label = rest[rest.index(rest.startIndex, offsetBy: 2)..<close]
        let after = rest[rest.index(after: close)...]
        guard !label.isEmpty, !label.contains(" "), after.hasPrefix(":") else { return nil }
        return (String(label), after.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    static func linkDefinition(_ line: String) -> (label: String, destination: String)? {
        guard indent(line) <= 3 else { return nil }
        let rest = line.drop { $0 == " " }
        guard rest.hasPrefix("["), !rest.hasPrefix("[^"), let close = rest.firstIndex(of: "]") else { return nil }
        let label = rest[rest.index(after: rest.startIndex)..<close]
        let after = rest[rest.index(after: close)...]
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty, after.hasPrefix(":") else { return nil }
        let body = after.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        var destination: String
        var remainder: Substring
        if body.hasPrefix("<"), let end = body.firstIndex(of: ">") {
            destination = String(body[body.index(after: body.startIndex)..<end])
            remainder = body[body.index(after: end)...]
        } else {
            destination = String(body.prefix { $0 != " " })
            remainder = body.dropFirst(destination.count)
        }
        let title = remainder.trimmingCharacters(in: .whitespaces)
        guard title.isEmpty || title.first == "\"" || title.first == "'" || title.first == "(" else { return nil }
        if destination.isEmpty { destination = "" }
        return (normalizeLabel(String(label)), destination)
    }

    static func normalizeLabel(_ label: String) -> String {
        label.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
    }

    /// Whether `line` starts a block that ends a paragraph above it.
    func interruptsParagraph(_ lines: [String], at i: Int) -> Bool {
        let line = lines[i]
        if Self.atxHeading(line) != nil || Self.fence(line) != nil || Self.isQuote(line) || Self.isRule(line) || Self.htmlBlockStart(line) {
            return true
        }
        if let marker = Self.listMarker(line), !marker.empty, marker.indent <= 3, !marker.ordered || marker.start == 1 { return true }
        if Self.tableStarts(lines, at: i) { return true }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("$$") { return true }
        return false
    }

    // MARK: - Blocks

    mutating func blocks(_ lines: [String]) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if Self.isBlank(line) {
                i += 1
                continue
            }
            if let fence = Self.fence(line) {
                var body: [String] = []
                i += 1
                while i < lines.count {
                    if let close = Self.fence(lines[i]), close.char == fence.char, close.count >= fence.count, close.info.isEmpty { break }
                    let content = lines[i]
                    body.append(String(content.dropFirst(min(fence.indent, Self.indent(content)))))
                    i += 1
                }
                i += 1
                let lang = fence.info.split(separator: " ").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "{}.")) } ?? ""
                out.append(.code(lang: lang, lines: body, fenced: true))
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("$$") {
                var body: [String] = []
                var first = String(trimmed.dropFirst(2))
                if first.hasSuffix("$$"), first.count >= 2 {
                    first.removeLast(2)
                    out.append(.math([first.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty }))
                    i += 1
                    continue
                }
                if !first.trimmingCharacters(in: .whitespaces).isEmpty { body.append(first) }
                i += 1
                while i < lines.count {
                    let current = lines[i].trimmingCharacters(in: .whitespaces)
                    if current.hasSuffix("$$") {
                        let last = String(current.dropLast(2))
                        if !last.trimmingCharacters(in: .whitespaces).isEmpty { body.append(last) }
                        break
                    }
                    body.append(lines[i])
                    i += 1
                }
                i += 1
                out.append(.math(body))
                continue
            }
            if obsidian, trimmed.hasPrefix("%%") {
                var body: [String] = []
                var first = String(trimmed.dropFirst(2))
                if first.hasSuffix("%%") {
                    first.removeLast(2)
                    out.append(.comment([first.trimmingCharacters(in: .whitespaces)]))
                    i += 1
                    continue
                }
                if !first.isEmpty { body.append(first) }
                i += 1
                while i < lines.count {
                    let current = lines[i].trimmingCharacters(in: .whitespaces)
                    if current.hasSuffix("%%") {
                        let last = String(current.dropLast(2))
                        if !last.isEmpty { body.append(last) }
                        break
                    }
                    body.append(lines[i])
                    i += 1
                }
                i += 1
                out.append(.comment(body))
                continue
            }
            if trimmed.hasPrefix("<!--") {
                var body: [String] = []
                while i < lines.count {
                    body.append(lines[i])
                    i += 1
                    if body.last!.contains("-->") { break }
                }
                var text = body.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
                if text.hasSuffix("-->"), text.hasPrefix("<!--") {
                    text = String(text.dropFirst(4).dropLast(3))
                    out.append(.comment(text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                        .drop { $0.isEmpty }.reversed().drop { $0.isEmpty }.reversed()))
                } else {
                    out.append(.html(body))
                }
                continue
            }
            if let heading = Self.atxHeading(line) {
                out.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }
            if Self.isRule(line) {
                out.append(.rule)
                i += 1
                continue
            }
            if Self.isQuote(line) {
                var inner: [String] = []
                while i < lines.count {
                    let current = lines[i]
                    if Self.isQuote(current) {
                        inner.append(Self.stripQuote(current))
                    } else if !Self.isBlank(current), let last = inner.last, !Self.isBlank(last), !interruptsParagraph(lines, at: i) {
                        inner.append(current)
                    } else {
                        break
                    }
                    i += 1
                }
                out.append(quote(inner))
                continue
            }
            if let marker = Self.listMarker(line), marker.indent <= 3 {
                out.append(list(lines, at: &i, first: marker))
                continue
            }
            if Self.htmlBlockStart(line) {
                var body: [String] = []
                while i < lines.count, !Self.isBlank(lines[i]) {
                    body.append(lines[i])
                    i += 1
                }
                out.append(.html(body))
                continue
            }
            if Self.indent(line) >= 4 {
                var body: [String] = []
                while i < lines.count, Self.isBlank(lines[i]) || Self.indent(lines[i]) >= 4 {
                    body.append(String(lines[i].dropFirst(min(4, Self.indent(lines[i])))))
                    i += 1
                }
                while body.last.map(Self.isBlank) == true { body.removeLast() }
                out.append(.code(lang: "", lines: body, fenced: false))
                continue
            }
            if let footnote = Self.footnoteDefinition(line) {
                var inner = [footnote.rest]
                i += 1
                while i < lines.count {
                    let current = lines[i]
                    if Self.isBlank(current) {
                        if i + 1 < lines.count, Self.indent(lines[i + 1]) >= 4 {
                            inner.append("")
                            i += 1
                            continue
                        }
                        break
                    }
                    if Self.indent(current) >= 4 {
                        inner.append(String(current.dropFirst(4)))
                    } else if Self.footnoteDefinition(current) == nil, !interruptsParagraph(lines, at: i) {
                        inner.append(current)
                    } else {
                        break
                    }
                    i += 1
                }
                definitions.footnotes.append((footnote.label, blocks(inner)))
                continue
            }
            if Self.tableStarts(lines, at: i) {
                let header = Self.tableCells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, !Self.isBlank(lines[i]), lines[i].contains("|") || !interruptsParagraph(lines, at: i) {
                    if interruptsParagraph(lines, at: i), !lines[i].contains("|") { break }
                    var cells = Self.tableCells(lines[i])
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(header.count)))
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
                continue
            }
            // A paragraph, after any link reference definitions at its start.
            var paragraph: [String] = []
            while i < lines.count, !Self.isBlank(lines[i]) {
                if paragraph.isEmpty, let definition = Self.linkDefinition(lines[i]) {
                    if definitions.links[definition.label] == nil { definitions.links[definition.label] = definition.destination }
                    i += 1
                    continue
                }
                if !paragraph.isEmpty {
                    if let level = Self.setextLevel(lines[i]) {
                        out.append(.heading(level: level, text: paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")))
                        paragraph = []
                        i += 1
                        break
                    }
                    if interruptsParagraph(lines, at: i) { break }
                } else if Self.footnoteDefinition(lines[i]) != nil {
                    break
                }
                paragraph.append(String(lines[i].drop { $0 == " " }))
                i += 1
            }
            if !paragraph.isEmpty { out.append(.paragraph(paragraph)) }
        }
        return out
    }

    private mutating func quote(_ inner: [String]) -> MarkdownBlock {
        if obsidian, let first = inner.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("[!"), let close = first.firstIndex(of: "]") {
            let type = first[first.index(first.startIndex, offsetBy: 2)..<close]
            if !type.isEmpty, type.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                var title = first[first.index(after: close)...]
                if title.first == "+" || title.first == "-" { title = title.dropFirst() }
                return .callout(type: type.lowercased(), title: title.trimmingCharacters(in: .whitespaces), blocks: blocks(Array(inner.dropFirst())))
            }
        }
        return .quote(blocks(inner))
    }

    /// A list starting at `i` with `first`'s marker; its items continue while lines are
    /// indented to an item's content, or start another item with the same kind of marker.
    private mutating func list(_ lines: [String], at i: inout Int, first: ListMarker) -> MarkdownBlock {
        var items: [MarkdownItem] = []
        var marker = first
        while true {
            let line = lines[i]
            var content: [String] = [marker.empty ? "" : String(line.dropFirst(marker.contentIndent))]
            i += 1
            while i < lines.count {
                let current = lines[i]
                if Self.isBlank(current) {
                    // A blank line continues the item when an indented line follows.
                    var j = i
                    while j < lines.count, Self.isBlank(lines[j]) { j += 1 }
                    if j < lines.count, Self.indent(lines[j]) >= marker.contentIndent {
                        content += Array(repeating: "", count: j - i)
                        i = j
                        continue
                    }
                    break
                }
                if Self.indent(current) >= marker.contentIndent {
                    content.append(String(current.dropFirst(marker.contentIndent)))
                    i += 1
                    continue
                }
                if Self.listMarker(current) != nil || interruptsParagraph(lines, at: i) { break }
                // A lazy continuation line of the item's paragraph.
                if let last = content.last, !Self.isBlank(last), Self.fence(content.first ?? "") == nil {
                    content.append(String(current.drop { $0 == " " }))
                    i += 1
                    continue
                }
                break
            }
            var task: Character?
            if let head = content.first {
                let chars = Array(head)
                if chars.count >= 3, chars[0] == "[", chars[2] == "]", chars.count == 3 || chars[3] == " " {
                    task = chars[1]
                    content[0] = String(head.dropFirst(min(4, chars.count)))
                }
            }
            items.append(MarkdownItem(task: task, blocks: blocks(content)))
            // A blank line between items is allowed.
            var j = i
            while j < lines.count, Self.isBlank(lines[j]) { j += 1 }
            guard j < lines.count, let next = Self.listMarker(lines[j]), next.ordered == first.ordered, next.delimiter == first.delimiter,
                  next.indent <= 3, next.indent < first.contentIndent else { break }
            i = j
            marker = next
        }
        return .list(ordered: first.ordered, start: first.start, items: items)
    }
}
