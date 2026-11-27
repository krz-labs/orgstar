import Foundation

/// Denote's file naming, as `denote-retrieve-filename-identifier` reads it: the identifier
/// starts the name (`20261119T120000--title__keywords.org`), or follows `@@` when
/// `denote-file-name-components-order` puts it elsewhere.
public enum Denote {
    /// The identifier in the file name at `path`, or nil when it has none.
    public static func identifier(ofFile path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if let match = name.firstMatch(of: /^(\d{8}T\d{6})(?:--|__|==|@@|\.|$)/) { return String(match.1) }
        if let match = name.firstMatch(of: /@@([^.]+?)(?=--|__|==|@@|\.|$)/) { return String(match.1) }
        return nil
    }

    /// The files under `directories` whose names have an identifier, as Denote lists them.
    public static func files(in directories: [String]) -> [String] { DenoteBlocks.files(in: directories).map(\.path) }

    /// A query link's regexp, `denote:query-contents:REGEXP` (contents) or
    /// `denote:query-filenames:REGEXP`; nil for a link to an identifier.
    public static func query(_ path: String) -> (contents: Bool, regexp: String)? {
        if path.hasPrefix("query-contents:") { return (true, String(path.dropFirst("query-contents:".count))) }
        if path.hasPrefix("query-filenames:") { return (false, String(path.dropFirst("query-filenames:".count))) }
        return nil
    }

    /// A `denote:` link's path split at `::` into the identifier and the search.
    public static func split(_ path: String) -> (identifier: String, search: String?) {
        guard let range = path.range(of: "::") else { return (path, nil) }
        return (String(path[..<range.lowerBound]), String(path[range.upperBound...]))
    }

    /// The file `denote-get-path-by-id` finds: the one whose name has `identifier`, an Org
    /// file before any other.
    public static func file(withIdentifier identifier: String, in paths: [String]) -> String? {
        let matches = paths.filter { Self.identifier(ofFile: $0) == identifier }
        return matches.first { ($0 as NSString).pathExtension == "org" } ?? matches.first
    }

    // MARK: - Naming new files

    /// `denote-excluded-punctuation-regexp`.
    static let punctuation = Set("[]{}!@#$%^&*()+'\"?,.|;:~`‘’“”=/")

    /// `denote-sluggify-title`: without punctuation, spaces and underscores as one `-`, none
    /// at either end, lower case.
    public static func slug(_ title: String) -> String {
        var out = ""
        for character in title.lowercased() where !punctuation.contains(character) {
            if character.isWhitespace || character == "_" || character == "-" {
                if !out.isEmpty, out.last != "-" { out.append("-") }
            } else {
                out.append(character)
            }
        }
        while out.last == "-" { out.removeLast() }
        return out
    }

    /// `denote-sluggify-keyword`: one word, lower case, without punctuation or spaces.
    public static func keyword(_ word: String) -> String {
        String(word.lowercased().filter { !punctuation.contains($0) && !$0.isWhitespace && $0 != "_" && $0 != "-" })
    }

    /// `denote-sluggify-signature`: like a title, with `=` between words.
    public static func signature(_ text: String) -> String {
        var out = ""
        for character in text.lowercased() where character == "=" || !punctuation.contains(character) && character != "-" {
            if character.isWhitespace || character == "_" || character == "=" {
                if !out.isEmpty, out.last != "=" { out.append("=") }
            } else {
                out.append(character)
            }
        }
        while out.last == "=" { out.removeLast() }
        return out
    }

    /// Keywords as `denote-keywords-sort` keeps them: sluggified, without empties or repeats,
    /// sorted.
    public static func keywords(_ words: [String]) -> [String] {
        Array(Set(words.map(keyword).filter { !$0.isEmpty })).sorted()
    }

    /// `%Y%m%dT%H%M%S` in `calendar`'s time zone.
    public static func identifier(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// `denote-format-file-name` in the default component order: identifier, signature,
    /// title, keywords.
    public static func fileName(identifier: String, signature: String? = nil, title: String, keywords: [String], extension ext: String = "org") -> String {
        var name = identifier
        if let signature, !signature.isEmpty { name += "==" + signature }
        let slug = slug(title)
        if !slug.isEmpty { name += "--" + slug }
        if !keywords.isEmpty { name += "__" + keywords.joined(separator: "_") }
        return name + "." + ext
    }

    // MARK: - File types

    /// `denote-file-types`: the formats Denote writes notes in.
    public enum FileType: String, Sendable, CaseIterable {
        case org
        /// Markdown with YAML front matter between `---` lines.
        case markdownYAML = "markdown-yaml"
        /// Markdown with TOML front matter between `+++` lines.
        case markdownTOML = "markdown-toml"
        /// Plain text, the front matter ended by a line of dashes.
        case text

        /// The extension, without the dot.
        public var ext: String {
            switch self {
            case .org: "org"
            case .markdownYAML, .markdownTOML: "md"
            case .text: "txt"
            }
        }

        public var isMarkdown: Bool { self == .markdownYAML || self == .markdownTOML }

        /// `denote-file-type` of a file: by its extension, `.md` by whether `text` starts with
        /// `---` or `+++`, else `preferred` when that is a Markdown type, else YAML. Nil for a
        /// file Denote has no type for.
        public init?(path: String, text: String? = nil, preferred: FileType = .org) {
            switch (path as NSString).pathExtension {
            case "org": self = .org
            case "txt": self = .text
            case "md":
                if text?.hasPrefix("---") == true { self = .markdownYAML }
                else if text?.hasPrefix("+++") == true { self = .markdownTOML }
                else { self = preferred.isMarkdown ? preferred : .markdownYAML }
            default: return nil
            }
        }
    }

    /// A front matter line, in the template's order.
    enum Component: CaseIterable { case title, date, keywords, identifier, signature }

    /// The key a component's line starts with, as `denote-file-types`'s key regexps match it.
    static func key(_ component: Component, _ type: FileType) -> String {
        let name = switch component {
        case .title: "title"
        case .date: "date"
        case .keywords: type == .org ? "filetags" : "tags"
        case .identifier: "identifier"
        case .signature: "signature"
        }
        return type == .org ? "#+" + name : name
    }

    /// The key as the template writes it, separator and padding included.
    static func written(_ component: Component, _ type: FileType) -> String {
        let key = key(component, type)
        let padding = String(repeating: " ", count: max(0, (type == .org ? 12 : 10) - key.count))
        return type == .markdownTOML ? key + padding + " = " : key + ":" + padding + " "
    }

    /// Where the value starts on `line` when it is `component`'s line: after the key, the
    /// spaces before the separator, the separator and the spaces after it. Keys match without
    /// case; an Org key may be indented.
    static func valueStart(_ line: Substring, _ component: Component, _ type: FileType) -> String.Index? {
        var rest = type == .org ? line.drop { $0 == " " || $0 == "\t" } : line
        let key = key(component, type)
        guard rest.prefix(key.count).lowercased() == key else { return nil }
        rest = rest.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
        guard rest.first == (type == .markdownTOML ? "=" : ":") else { return nil }
        return rest.dropFirst().drop { $0 == " " || $0 == "\t" }.startIndex
    }

    /// `%S` of a string: quoted, with `"` and `\` escaped.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A date as the type's `:date-value-function` writes it: an inactive Org timestamp,
    /// RFC 3339 for Markdown, ISO 8601 for text.
    static func stamp(_ date: Date, _ type: FileType, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        switch type {
        case .org:
            return String(format: "[%@ %@ %02d:%02d]", day, ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][c.weekday! - 1], c.hour!, c.minute!)
        case .markdownYAML, .markdownTOML:
            let offset = calendar.timeZone.secondsFromGMT(for: date) / 60
            return String(format: "%@T%02d:%02d:%02d%@%02d:%02d", day, c.hour!, c.minute!, c.second!, offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60)
        case .text:
            return day
        }
    }

    /// Each component's value as the type writes it; nil for the date when `date` is nil.
    static func values(title: String, date: Date?, keywords: [String], identifier: String, signature: String, type: FileType, calendar: Calendar) -> [Component: String] {
        let md = type.isMarkdown
        let tags = switch type {
        case .org: keywords.isEmpty ? "" : ":" + keywords.joined(separator: ":") + ":"
        case .markdownYAML, .markdownTOML: "[" + keywords.map(quoted).joined(separator: ", ") + "]"
        case .text: keywords.joined(separator: "  ")
        }
        var values: [Component: String] = [.title: md ? quoted(title) : title, .keywords: tags, .identifier: md ? quoted(identifier) : identifier,
                                           .signature: md ? quoted(signature) : signature]
        values[.date] = date.map { stamp($0, type, calendar: calendar) }
        return values
    }

    /// The front matter of a new note, as `denote--format-front-matter` writes the type's
    /// template (`denote-org-front-matter` and the others): every line, except the signature's
    /// when there is none, then a blank line.
    public static func frontMatter(
        title: String, date: Date, keywords: [String], identifier: String, signature: String = "", type: FileType = .org, calendar: Calendar = .current
    ) -> String {
        let values = values(title: title, date: date, keywords: keywords, identifier: identifier, signature: signature, type: type, calendar: calendar)
        let lines = Component.allCases.filter { $0 != .signature || !signature.isEmpty }.map { written($0, type) + values[$0]! }
        let (open, close): ([String], [String]) = switch type {
        case .org: ([], [])
        case .markdownYAML: (["---"], ["---"])
        case .markdownTOML: (["+++"], ["+++"])
        case .text: ([], ["---------------------------"])
        }
        return (open + lines + close).map { $0 + "\n" }.joined() + "\n"
    }

    /// `denote-rewrite-front-matter`: `text` with its front matter set to these values. A line
    /// that is there keeps its key and spacing and gets the new value; an empty signature's
    /// line goes; a missing line with a value is added after the line before it in the
    /// template, else before the one after it. A nil `date` keeps the date line. Without front
    /// matter, `denote-prepend-front-matter`: all of it before the text, dated `date` or `now`.
    public static func rewritingFrontMatter(
        _ text: String, title: String, keywords: [String], signature: String, date: Date?, identifier: String, now: Date = Date(),
        type: FileType = .org, calendar: Calendar = .current
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        let values = values(title: title, date: date, keywords: keywords, identifier: identifier, signature: signature, type: type, calendar: calendar)
        func index(_ component: Component) -> Int? {
            lines.prefix(40).firstIndex { valueStart($0[...], component, type) != nil }
        }
        guard Component.allCases.contains(where: { index($0) != nil }) else {
            return frontMatter(title: title, date: date ?? now, keywords: keywords, identifier: identifier, signature: signature, type: type, calendar: calendar) + text
        }
        let all = Component.allCases
        for (position, component) in all.enumerated() {
            let hasValue = switch component {
            case .title: !title.isEmpty
            case .date: date != nil
            case .keywords: !keywords.isEmpty
            case .identifier: !identifier.isEmpty
            case .signature: !signature.isEmpty
            }
            if let at = index(component) {
                if component == .signature, !hasValue {
                    lines.remove(at: at)
                } else if let value = values[component], let start = valueStart(lines[at][...], component, type) {
                    lines[at] = String(lines[at][..<start]) + value
                }
            } else if hasValue, let value = values[component] {
                let before = all[..<position].reversed().compactMap { index($0) }.first
                let after = all[(position + 1)...].compactMap { index($0) }.first
                lines.insert(written(component, type) + value, at: before.map { $0 + 1 } ?? after ?? 0)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Reading names and front matter

    /// The parts of a Denote file name, in any component order.
    public struct Name: Sendable, Equatable {
        public var identifier: String?
        public var signature: String?
        public var title: String?
        public var keywords: [String]
        public var ext: String
    }

    public static func name(ofFile path: String) -> Name {
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension
        let stem = ext.isEmpty ? file : String(file.dropLast(ext.count + 1))
        var name = Name(identifier: identifier(ofFile: file), keywords: [], ext: ext)
        for match in stem.matches(of: /(--|__|==)(.+?)(?=--|__|==|@@|$)/) {
            let value = String(match.2)
            switch match.1 {
            case "--": name.title = value
            case "__": name.keywords = value.split(separator: "_").map(String.init)
            default: name.signature = value
            }
        }
        return name
    }


    /// A component's value on its first line among the first 40, untrimmed.
    static func rawValue(_ component: Component, in text: String, type: FileType) -> Substring? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
            if let start = valueStart(line, component, type) { return line[start...] }
        }
        return nil
    }

    /// The title, keywords, identifier and signature of a file's front matter, read as the
    /// type's `:…-value-reverse-function`s read them: Markdown values without the whitespace
    /// and quotes around them, keywords split at colons, commas and spaces.
    public static func frontMatter(of text: String, type: FileType = .org) -> (title: String?, keywords: [String]?, identifier: String?, signature: String?) {
        func value(_ component: Component) -> String? {
            guard let raw = rawValue(component, in: text, type: type) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            return type.isMarkdown ? trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) : trimmed
        }
        let keywords = rawValue(.keywords, in: text, type: type).map { raw in
            type == .org ? raw.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : raw.split { $0 == ":" || $0 == "," || $0.isWhitespace }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] \"'")) }.filter { !$0.isEmpty }
        }
        return (value(.title), keywords, value(.identifier)?.nonEmptyOrNil, value(.signature))
    }

    /// The front matter of the file at `path`, read in its type; Org's for a file Denote has
    /// no type for.
    public static func frontMatter(ofFile path: String, text: String) -> (title: String?, keywords: [String]?, identifier: String?, signature: String?) {
        frontMatter(of: text, type: FileType(path: path, text: text) ?? .org)
    }

    /// The front matter's date in `calendar`'s time zone: an Org timestamp, or for the other
    /// types `YYYY-MM-DD`, optionally with a time and a UTC offset.
    public static func date(of text: String, type: FileType = .org, calendar: Calendar = .current) -> Date? {
        if type == .org {
            guard let match = text.firstMatch(of: /(?im)^[ \t]*#\+date:[ \t]*[\[<](\d{4})-(\d{2})-(\d{2})(?:[^\]>\d]*(\d{1,2}):(\d{2}))?/) else { return nil }
            return calendar.date(from: DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3),
                                                      hour: match.4.flatMap { Int($0) } ?? 0, minute: match.5.flatMap { Int($0) } ?? 0))
        }
        guard let raw = rawValue(.date, in: text, type: type),
              let match = raw.firstMatch(of: /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?[ \t]*(Z|[+-]\d{2}:?\d{2})?/) else { return nil }
        var components = DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3),
                                        hour: match.4.flatMap { Int($0) } ?? 0, minute: match.5.flatMap { Int($0) } ?? 0, second: match.6.flatMap { Int($0) } ?? 0)
        if let zone = match.7 {
            let digits = zone.filter(\.isNumber)
            let minutes = zone == "Z" ? 0 : (Int(digits.prefix(2))! * 60 + Int(digits.suffix(2))!) * (zone.hasPrefix("-") ? -1 : 1)
            components.timeZone = TimeZone(secondsFromGMT: minutes * 60)
        }
        return calendar.date(from: components)
    }

    /// `denote-rename-file-using-front-matter`: the path the file at `path` takes from its
    /// front matter's title, keywords and signature, each empty when its line is missing, and
    /// its text with the front matter rewritten from those values, keywords sorted. Nil for a
    /// file Denote has no type for, one without front matter, or one without an identifier in
    /// it or its name.
    public static func renamed(_ path: String, text: String) -> (path: String, text: String)? {
        guard let type = FileType(path: path, text: text) else { return nil }
        let current = name(ofFile: path)
        let front = frontMatter(of: text, type: type)
        guard front.title != nil || front.keywords != nil || front.identifier != nil || front.signature != nil,
              let identifier = front.identifier ?? current.identifier else { return nil }
        let keywords = Self.keywords(front.keywords ?? []), signature = signature(front.signature ?? ""), title = front.title ?? ""
        let date = rawValue(.date, in: text, type: type) == nil ? nil : date(of: text, type: type)
        let file = fileName(identifier: identifier, signature: signature, title: title, keywords: keywords, extension: current.ext)
        return (((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(file),
                rewritingFrontMatter(text, title: title, keywords: keywords, signature: signature, date: date, identifier: identifier, type: type))
    }

    // MARK: - Links in Markdown and text notes

    /// A link to `link` described by `description`, as `denote-format-link` writes it in the
    /// file at `path`: `[description](denote:ID)` in Markdown (`denote-md-link-format`), Org's
    /// bracket link elsewhere, and `[[denote:ID]]` without a description.
    public static func linkText(_ link: String, description: String, inFile path: String?) -> String {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.hasPrefix("denote:"), let path, FileType(path: path)?.isMarkdown == true else { return Links.makeString(link, description) }
        return description.isEmpty ? "[[" + link + "]]" : "[" + description + "](" + link + ")"
    }

    static let orgLink = try! NSRegularExpression(pattern: #"\[\[(denote:[^\[\]\n]+)\](?:\[[^\]\n]*\])?\]"#)
    static let markdownLink = try! NSRegularExpression(pattern: #"\[[^\]\n]*\]\((denote:[^()\[\]\s]+)\)"#)

    /// The `denote:` links in a Markdown or text note, as UTF-16 ranges and what they link to:
    /// `[[denote:ID]]` and `[[denote:ID][description]]` in both, as Denote's link regexps find
    /// them, and `[description](denote:ID)` in Markdown.
    public static func links(in text: String, markdown: Bool) -> [(range: Range<Int>, target: String)] {
        guard text.contains("denote:") else { return [] }
        let ns = text as NSString, whole = NSRange(location: 0, length: ns.length)
        return ((markdown ? [orgLink, markdownLink] : [orgLink]).flatMap { $0.matches(in: text, range: whole) })
            .sorted { $0.range.location < $1.range.location }
            .map { (Range($0.range)!, ns.substring(with: $0.range(at: 1))) }
    }

    /// The `denote:` link at `offset` in a Markdown or text note.
    public static func link(at offset: Int, in text: String, markdown: Bool) -> OrgLink? {
        links(in: text, markdown: markdown).first { $0.range.contains(offset) || $0.range.upperBound == offset }.map { Links.parse(plain: $0.target) }
    }
}

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
