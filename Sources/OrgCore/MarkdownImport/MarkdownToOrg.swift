import Foundation

/// How links to other files are written; the importer knows where each file ends up.
public struct MarkdownTargets: Sendable {
    /// A Markdown link or image destination as written → the org link path, or `nil` to
    /// write it as it is (`file:` added to a relative path).
    public var link: @Sendable (_ destination: String, _ image: Bool) -> String?
    /// An Obsidian wikilink or embed: the target as written (empty for the same note) and the
    /// part after `#` → the org link path and whether it's an image; `nil` when it can't be
    /// found, which writes the link's text.
    public var wikilink: @Sendable (_ target: String, _ fragment: String?, _ embed: Bool) -> (path: String, image: Bool)?

    public init(link: @escaping @Sendable (String, Bool) -> String?,
                wikilink: @escaping @Sendable (String, String?, Bool) -> (path: String, image: Bool)?) {
        self.link = link
        self.wikilink = wikilink
    }

    /// Wikilinks to `target.org` beside the file; other links as written.
    public static let none = MarkdownTargets(link: { _, _ in nil }, wikilink: { target, _, _ in
        guard !target.isEmpty else { return nil }
        let ext = (target as NSString).pathExtension.lowercased()
        if ext.isEmpty || ext == "md" { return ("file:" + (ext.isEmpty ? target : (target as NSString).deletingPathExtension) + ".org", false) }
        return ("file:" + target, MarkdownToOrg.imageExtensions.contains(ext))
    })
}

/// Something in a Markdown file that wasn't converted, or was converted with a loss.
public enum MarkdownImportIssue: Hashable, Sendable {
    /// A wikilink or embed whose target isn't in the vault.
    case unresolvedLink(String)
    /// A link to a heading or block that isn't in the target file; the link goes to the file.
    case missingHeading(String)
    /// A front matter key with a nested map as its value.
    case frontMatter(String)
    /// A Tasks plugin recurrence (`🔁`), kept as text.
    case recurrence
    /// A task status other than space, `x` and `/`; the item is an open checkbox.
    case taskStatus(String)
    /// A heading inside a list or quote, written as a bold line.
    case nestedHeading(String)
    /// An attachment that couldn't be read.
    case attachment(String)
}

/// Converts a Markdown file (CommonMark with GFM tables, task lists, strikethrough and
/// footnotes, and YAML front matter) to an org file; with `obsidian`, Obsidian's wikilinks,
/// embeds, callouts, `#tags`, highlights, comments, block IDs and Tasks plugin dates too.
///
/// Front matter: `title` → `#+title:`, `date` → `#+date:`, `tags` → `#+filetags:`,
/// `aliases` → `ROAM_ALIASES`, and every other key → a property in a property drawer at the
/// top of the file.
public enum MarkdownToOrg {
    public struct Parsed: Sendable {
        let blocks: [MarkdownBlock]
        let footnotes: [(label: String, blocks: [MarkdownBlock])]
        let links: [String: String]
        let frontMatter: [(key: String, value: MarkdownFrontMatter.Value)]
        let obsidian: Bool
        /// Each top-level heading's text as written and as an org title, for links to it.
        public let headings: [(source: String, title: String)]
        /// Obsidian block IDs (`^id`) in the file.
        public let blockIDs: Set<String>
    }

    public struct Result: Sendable {
        public var text: String
        public var headings: Int
        public var links: Int
        public var issues: [MarkdownImportIssue]
    }

    public static func parse(_ markdown: String, obsidian: Bool) -> Parsed {
        let (frontMatter, body) = MarkdownFrontMatter.split(markdown)
        let (blocks, definitions) = MarkdownBlocks.parse(body, obsidian: obsidian)
        let inline = MarkdownInline(obsidian: obsidian, definitions: definitions.links, targets: .none)
        var headings: [(source: String, title: String)] = []
        var ids = Set<String>()
        func collectIDs(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .paragraph(let lines): if let id = blockID(lines.last ?? "")?.id { ids.insert(id) }
                case .list(_, _, let items): items.forEach { collectIDs($0.blocks) }
                case .quote(let inner), .callout(_, _, let inner): collectIDs(inner)
                default: break
                }
            }
        }
        for block in blocks {
            if case .heading(_, let text) = block {
                headings.append((text, headingTitle(text, inline: inline).title))
            }
        }
        if obsidian { collectIDs(blocks) }
        return Parsed(blocks: blocks, footnotes: definitions.footnotes, links: definitions.links, frontMatter: frontMatter,
                      obsidian: obsidian, headings: headings, blockIDs: ids)
    }

    /// `parsed` as an org file. `title` is the fallback for `#+title:` when the front matter
    /// has none.
    public static func render(_ parsed: Parsed, title: String? = nil, targets: MarkdownTargets = .none) -> Result {
        var renderer = Renderer(parsed: parsed, inline: MarkdownInline(obsidian: parsed.obsidian, definitions: parsed.links, targets: targets))
        return renderer.document(title: title)
    }

    public static func convert(_ markdown: String, obsidian: Bool = false, title: String? = nil, targets: MarkdownTargets = .none) -> Result {
        render(parse(markdown, obsidian: obsidian), title: title, targets: targets)
    }

    /// The org title of the heading `fragment` names (its text, or GitHub's anchor for it).
    public static func heading(_ fragment: String, in headings: [(source: String, title: String)]) -> String? {
        let wanted = squash(fragment.removingPercentEncoding ?? fragment)
        guard !wanted.isEmpty else { return nil }
        return headings.first { squash($0.source) == wanted }?.title ?? headings.first { squash($0.title) == wanted }?.title
    }

    private static func squash(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Shared pieces

    static func escapeLinkPath(_ path: String) -> String {
        path.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    static func footnoteLabel(_ label: String) -> String {
        String(label.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    /// An org tag for an Obsidian or front matter tag: characters org doesn't allow become `_`.
    static func tag(_ tag: String) -> String {
        String(tag.drop { $0 == "#" }.map { $0.isLetter || $0.isNumber || "_@#%".contains($0) ? $0 : "_" })
    }

    /// A trailing Obsidian block ID (` ^id`).
    static func blockID(_ line: String) -> (id: String, rest: String)? {
        guard let caret = line.range(of: " ^", options: .backwards) ?? (line.hasPrefix("^") ? line.startIndex..<line.index(after: line.startIndex) : nil) else { return nil }
        let id = line[caret.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }) else { return nil }
        return (id, String(line[..<caret.lowerBound]))
    }

    /// A heading's org title and the `#tags` at its end.
    static func headingTitle(_ text: String, inline: MarkdownInline) -> (title: String, tags: [String]) {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var trailing: [String] = []
        if inline.obsidian {
            while let last = words.last, last.hasPrefix("#"), last.count > 1, last.dropFirst().contains(where: { !$0.isNumber }),
                  last.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || "_-/".contains($0) }) {
                trailing.insert(tag(last), at: 0)
                words.removeLast()
            }
        }
        _ = inline.takeTags()
        let title = inline.convert(words.joined(separator: " ").trimmingCharacters(in: .whitespaces))
        return (title, trailing + inline.takeTags().filter { !trailing.contains($0) })
    }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "tif", "tiff", "heic", "avif"]

    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// `<2024-01-05 Fri>` for `2024-01-05`, with `[` `]` when not active.
    static func timestamp(_ date: String, active: Bool) -> String? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, date.count == 10 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        let name = weekdays[calendar.component(.weekday, from: day) - 1]
        return (active ? "<" : "[") + date + " " + name + (active ? ">" : "]")
    }

    // MARK: - Rendering

    struct Renderer {
        let parsed: Parsed
        let inline: MarkdownInline
        var lines: [String] = []
        var headings = 0
        var issues: [MarkdownImportIssue] = []
        /// Output line of each heading, and the tags found in its section.
        var headingLines: [(line: Int, tags: [String])] = []
        var fileTags: [String] = []

        init(parsed: Parsed, inline: MarkdownInline) {
            self.parsed = parsed
            self.inline = inline
        }

        mutating func document(title fallback: String?) -> Result {
            var previous: MarkdownBlock?
            for block in parsed.blocks {
                defer { previous = block }
                if !lines.isEmpty {
                    if case .heading = previous {} else { lines.append("") }
                    if Self.listsInARow(previous, block) { lines.append("") }
                }
                if case .heading(let level, let text) = block {
                    let heading = MarkdownToOrg.headingTitle(text, inline: inline)
                    headingLines.append((lines.count, heading.tags))
                    lines.append(String(repeating: "*", count: level) + " " + heading.title)
                    headings += 1
                    continue
                }
                lines += render(block, indent: "")
                let tags = inline.takeTags()
                if headingLines.isEmpty { fileTags += tags } else { headingLines[headingLines.count - 1].tags += tags }
            }
            for (label, blocks) in parsed.footnotes {
                if !lines.isEmpty { lines.append("") }
                var body = blocks.enumerated().flatMap { index, block in (index > 0 ? [""] : []) + render(block, indent: "") }
                if body.isEmpty { body = [""] }
                body[0] = "[fn:" + MarkdownToOrg.footnoteLabel(label) + "] " + body[0].drop { $0 == " " }
                lines += body
                let tags = inline.takeTags()
                if headingLines.isEmpty { fileTags += tags } else { headingLines[headingLines.count - 1].tags += tags }
            }
            for (line, tags) in headingLines {
                let unique = tags.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                if !unique.isEmpty { lines[line] += " :" + unique.joined(separator: ":") + ":" }
            }
            let header = header(fallback: fallback)
            var text = header.joined(separator: "\n")
            if !header.isEmpty, !lines.isEmpty { text += "\n\n" }
            text += lines.joined(separator: "\n")
            if !text.isEmpty { text += "\n" }
            return Result(text: text, headings: headings, links: inline.links, issues: issues + inline.issues)
        }

        mutating func header(fallback: String?) -> [String] {
            var drawer: [String] = []
            var title: String?
            var date: String?
            var tags: [String] = []
            func multi(_ items: [String]) -> String {
                items.map { $0.contains(" ") || $0.contains("\"") ? "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : $0 }.joined(separator: " ")
            }
            func split(_ value: String) -> [String] {
                value.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            }
            for (key, value) in parsed.frontMatter {
                let name = key.lowercased()
                switch (name, value) {
                case (_, .nested): issues.append(.frontMatter(key))
                case ("title", .scalar(let text)): title = text
                case ("title", .list(let items)): title = items.joined(separator: " ")
                case ("date", .scalar(let text)): date = text
                case ("tags", .scalar(let text)), ("tag", .scalar(let text)): tags += split(text).map(MarkdownToOrg.tag)
                case ("tags", .list(let items)), ("tag", .list(let items)): tags += items.flatMap(split).map(MarkdownToOrg.tag)
                case ("aliases", .scalar(let text)), ("alias", .scalar(let text)):
                    drawer.append(":ROAM_ALIASES: " + multi(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }))
                case ("aliases", .list(let items)), ("alias", .list(let items)): drawer.append(":ROAM_ALIASES: " + multi(items))
                case (_, .scalar(let text)):
                    drawer.append(":" + property(key) + ": " + text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))
                case (_, .list(let items)): drawer.append(":" + property(key) + ": " + multi(items))
                }
            }
            tags += fileTags
            tags = tags.filter { !$0.isEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            var out: [String] = []
            if !drawer.isEmpty { out = [":PROPERTIES:"] + drawer.map { $0.hasSuffix(": ") ? String($0.dropLast()) : $0 } + [":END:"] }
            if let title = title ?? fallback, !title.isEmpty { out.append("#+title: " + title) }
            if let date, !date.isEmpty { out.append("#+date: " + date) }
            if !tags.isEmpty { out.append("#+filetags: :" + tags.joined(separator: ":") + ":") }
            return out
        }

        func property(_ key: String) -> String {
            String(key.map { $0 == " " || $0 == ":" ? "_" : $0 })
        }

        // MARK: Blocks

        mutating func render(_ block: MarkdownBlock, indent: String) -> [String] {
            switch block {
            case .heading(_, let text):
                // A heading can't be inside a list or quote in org.
                issues.append(.nestedHeading(text))
                return paragraph(["**" + text + "**"], indent: indent)
            case .paragraph(let lines):
                return paragraph(lines, indent: indent)
            case .code(let lang, let body, let fenced):
                let name = lang.lowercased()
                let example = !fenced || name.isEmpty || ["text", "txt", "plain", "plaintext"].contains(name)
                let language = String(lang.filter { !$0.isWhitespace })
                let open = example ? "#+begin_example" : "#+begin_src " + language
                let close = example ? "#+end_example" : "#+end_src"
                return [indent + open] + body.map { $0.isEmpty ? "" : indent + escapeCode($0) } + [indent + close]
            case .math(let body):
                return [indent + "\\["] + body.map { indent + $0 } + [indent + "\\]"]
            case .comment(let body):
                return [indent + "#+begin_comment"] + body.map { $0.isEmpty ? "" : indent + escapeCode($0) } + [indent + "#+end_comment"]
            case .html(let body):
                return [indent + "#+begin_export html"] + body.map { $0.isEmpty ? "" : indent + escapeCode($0) } + [indent + "#+end_export"]
            case .quote(let inner):
                return [indent + "#+begin_quote"] + blocks(inner, indent: indent) + [indent + "#+end_quote"]
            case .callout(let type, let title, let inner):
                var name = type
                if ["example", "src", "export", "verse", "center", "comment"].contains(name) { name = "callout-" + name }
                var body: [String] = []
                if !title.isEmpty { body = paragraph(["**" + title + "**"], indent: indent) }
                let rest = blocks(inner, indent: indent)
                if !body.isEmpty, !rest.isEmpty { body.append("") }
                return [indent + "#+begin_" + name] + body + rest + [indent + "#+end_" + name]
            case .list(let ordered, let start, let items):
                return list(ordered: ordered, start: start, items: items, indent: indent)
            case .table(let header, let rows):
                return table(header: header, rows: rows, indent: indent)
            case .rule:
                return [indent + "-----"]
            }
        }

        static func isParagraph(_ block: MarkdownBlock) -> Bool {
            switch block {
            case .paragraph, .heading: true
            default: false
            }
        }

        /// Two lists in a row: org would read them as one unless two blank lines part them.
        static func listsInARow(_ previous: MarkdownBlock?, _ block: MarkdownBlock) -> Bool {
            if case .list = previous, case .list = block { return true }
            return false
        }

        /// Blocks separated by blank lines.
        mutating func blocks(_ blocks: [MarkdownBlock], indent: String, tight: Bool = false) -> [String] {
            var out: [String] = []
            var previous: MarkdownBlock?
            for block in blocks {
                let separate: Bool
                if tight {
                    if case .paragraph = previous, case .paragraph = block { separate = true } else { separate = false }
                } else {
                    separate = previous != nil
                }
                if separate { out.append("") }
                if Self.listsInARow(previous, block) { out += separate ? [""] : ["", ""] }
                out += render(block, indent: indent)
                previous = block
            }
            return out
        }

        /// `,` before lines org would read as a heading or keyword inside a block.
        func escapeCode(_ line: String) -> String {
            let lead = line.prefix { $0 == " " }
            let rest = line.dropFirst(lead.count)
            let commas = rest.prefix { $0 == "," }
            let after = rest.dropFirst(commas.count)
            if (lead.isEmpty && after.hasPrefix("*")) || after.hasPrefix("#+") { return lead + "," + rest }
            return line
        }

        mutating func paragraph(_ source: [String], indent: String) -> [String] {
            var raw = source
            // Hard line breaks: two trailing spaces or a backslash.
            for k in raw.indices.dropLast() {
                if raw[k].hasSuffix("  ") {
                    raw[k] = raw[k].trimmingCharacters(in: .whitespaces) + "\u{2}"
                } else if raw[k].hasSuffix("\\"), !raw[k].hasSuffix("\\\\") {
                    raw[k] = String(raw[k].dropLast()) + "\u{2}"
                }
            }
            raw[raw.count - 1] = raw[raw.count - 1].trimmingCharacters(in: .whitespaces)
            var prefix: [String] = []
            var target = ""
            if parsed.obsidian, let id = MarkdownToOrg.blockID(raw[raw.count - 1]) {
                raw[raw.count - 1] = id.rest
                target = " <<" + id.id + ">>"
            }
            if parsed.obsidian, indent.isEmpty {
                let only = raw.joined(separator: "\n")
                if only.hasPrefix("![["), only.hasSuffix("]]"), !only.dropFirst(3).contains("[["), let bar = only.lastIndex(of: "|") {
                    let size = only[only.index(after: bar)..<only.index(only.endIndex, offsetBy: -2)]
                    let width = size.split(separator: "x").first.map(String.init) ?? ""
                    if !width.isEmpty, width.allSatisfy(\.isNumber) { prefix.append(indent + "#+attr_org: :width " + width) }
                }
            }
            let joined = raw.joined(separator: "\n")
            if indent.isEmpty, joined.hasPrefix("!["), joined.hasSuffix(")"), let close = joined.firstIndex(of: "]"), !joined.contains("\n") {
                let alt = joined[joined.index(joined.startIndex, offsetBy: 2)..<close]
                if !alt.isEmpty, !alt.contains("]"), joined[joined.index(after: close)] == "(" { prefix.append(indent + "#+attr_html: :alt " + alt) }
            }
            let converted = inline.convert(joined).replacingOccurrences(of: "\u{2}", with: " \\\\") + target
            var out: [String] = []
            for line in converted.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(line)
                if out.isEmpty {
                    out.append(Self.startsElement(line, topLevel: indent.isEmpty) ? "\u{200B}" + line : line)
                } else if Self.startsElement(line, topLevel: indent.isEmpty) {
                    out[out.count - 1] += " " + line
                } else {
                    out.append(line)
                }
            }
            return prefix + out.map { indent + $0 }
        }

        /// Whether org would read `line` at the start of a paragraph line as another element.
        static func startsElement(_ line: String, topLevel: Bool) -> Bool {
            if topLevel, line.hasPrefix("*"), line.drop(while: { $0 == "*" }).first == " " { return true }
            let text = line.drop { $0 == " " }
            if text.hasPrefix("- ") || text.hasPrefix("+ ") || text == "-" || text == "+" || text.hasPrefix("#+") || text.hasPrefix("# ") || text == "#" || text.hasPrefix("|")
                || text.hasPrefix(": ") || text == ":" || text.hasPrefix("-----") || text.hasPrefix("[fn:") || text.hasPrefix("\\begin{") {
                return true
            }
            if !topLevel, text.hasPrefix("* ") { return true }
            let digits = text.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, let next = text.dropFirst(digits.count).first, next == "." || next == ")" {
                let after = text.dropFirst(digits.count + 1)
                return after.isEmpty || after.first == " "
            }
            if text.hasPrefix(":"), text.dropFirst().contains(":"), text.hasSuffix(":"), !text.contains(" ") { return true }
            return false
        }

        mutating func list(ordered: Bool, start: Int, items: [MarkdownItem], indent: String) -> [String] {
            var out: [String] = []
            for (k, item) in items.enumerated() {
                let bullet = ordered ? "\(start + k)." : "-"
                var head = indent + bullet + " "
                if ordered, k == 0, start != 1 { head += "[@\(start)] " }
                if let task = item.task {
                    switch task {
                    case " ": head += "[ ] "
                    case "x", "X": head += "[X] "
                    case "/": head += "[-] "
                    default:
                        issues.append(.taskStatus(String(task)))
                        head += "[ ] "
                    }
                }
                let inner = indent + String(repeating: " ", count: bullet.count + 1)
                var body = blocks(item.blocks, indent: inner, tight: true)
                if parsed.obsidian, item.task != nil, let first = body.first { body[0] = taskDates(first) }
                if let first = body.first, item.blocks.first.map(Self.isParagraph) == true {
                    var text = first.dropFirst(inner.count)
                    if text.first == "\u{200B}" { text = text.dropFirst() }
                    out.append(head + text)
                    out += body.dropFirst()
                } else {
                    out.append(head.hasSuffix(" ") ? String(head.dropLast()) : head)
                    out += body
                }
            }
            return out
        }

        /// The Tasks plugin's `📅` due, `⏳` scheduled and `✅` done dates as org keywords and
        /// timestamps; `🛫` start and `➕` created dates as plain timestamps.
        mutating func taskDates(_ line: String) -> String {
            var text = line
            let marks: [(String, String?, Bool)] = [("📅", "DEADLINE: ", true), ("⏳", "SCHEDULED: ", true), ("✅", "CLOSED: ", false),
                                                     ("🛫", nil, true), ("➕", nil, false), ("❌", nil, false)]
            for (mark, keyword, active) in marks {
                while let range = text.range(of: mark) {
                    let after = text[range.upperBound...].drop { $0 == " " }
                    let date = String(after.prefix(10))
                    guard let stamp = MarkdownToOrg.timestamp(date, active: active) else { break }
                    let end = after.index(after.startIndex, offsetBy: 10)
                    text.replaceSubrange(range.lowerBound..<end, with: (keyword ?? "") + stamp)
                }
            }
            if text.contains("🔁") { issues.append(.recurrence) }
            return text
        }

        mutating func table(header: [String], rows: [[String]], indent: String) -> [String] {
            func cell(_ text: String) -> String {
                inline.convert(text).replacingOccurrences(of: "\u{1}", with: "\\vert{}")
            }
            let all = [header.map(cell)] + rows.map { $0.map(cell) }
            var widths = Array(repeating: 1, count: header.count)
            for row in all {
                for (k, text) in row.enumerated() where k < widths.count { widths[k] = max(widths[k], text.count) }
            }
            func line(_ row: [String]) -> String {
                indent + "| " + row.enumerated().map { k, text in text + String(repeating: " ", count: widths[k] - text.count) }.joined(separator: " | ") + " |"
            }
            return [line(all[0]), indent + "|" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "|"] + all.dropFirst().map(line)
        }
    }
}
