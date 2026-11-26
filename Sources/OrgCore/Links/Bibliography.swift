import Foundation

/// An entry of a bibliography file, as Insert Citation… offers it and following a citation
/// shows it.
public struct BibEntry: Sendable, Equatable {
    public var key: String
    /// Field names in lower case; values as `org-cite-basic` reads them, braces kept.
    public var fields: [String: String]
    /// The bibliography file the entry is in.
    public var file: String

    public init(key: String, fields: [String: String], file: String) {
        self.key = key
        self.fields = fields
        self.file = file
    }

    public var author: String? { field("author") ?? field("editor") }
    public var title: String? { field("title") }

    /// The `year` field, else the year of `date`, as `org-cite-basic--get-year` reads them.
    public var year: String? {
        if let year = field("year") { return year }
        return fields["date"].flatMap { $0.firstMatch(of: /^([0-9]{4})(?:[^0-9]|$)/) }.map { String($0.1) }
    }

    /// A field without braces and with blanks collapsed; nil when missing or empty.
    public func field(_ name: String) -> String? {
        fields[name].flatMap(Self.clean)
    }

    static func clean(_ value: String) -> String? {
        let clean = value.replacingOccurrences(of: "[{}]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : clean
    }

    /// The line a chooser shows: the key, then the authors (`;` between them), the year and
    /// the title, as `org-cite-basic`'s completion table has them.
    public var label: String {
        [key, authors, year, title].compactMap { $0 }.joined(separator: "  ")
    }

    /// The authors (else the editors) separated by `;`: split at each `and` outside braces.
    public var authors: String? {
        guard let raw = fields["author"] ?? fields["editor"] else { return nil }
        var names: [String] = []
        var current = ""
        var depth = 0
        var rest = Substring(raw)
        while let c = rest.first {
            if depth == 0, rest.hasPrefix(" and ") {
                names.append(current)
                current = ""
                rest = rest.dropFirst(5)
                continue
            }
            if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) }
            current.append(c)
            rest = rest.dropFirst()
        }
        names.append(current)
        let clean = names.compactMap(Self.clean)
        return clean.isEmpty ? nil : clean.joined(separator: "; ")
    }

    /// Authors, year, title and where it was published, for showing the entry.
    public var summary: String {
        var parts: [String] = []
        let who = [author, year.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        if !who.isEmpty { parts.append(who) }
        if let title { parts.append(title) }
        if let from = field("journal") ?? field("journaltitle") ?? field("booktitle") ?? field("container-title") ?? field("publisher")
            ?? field("institution") ?? field("school") {
            parts.append(from)
        }
        return parts.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }

    /// The `file` field's files: separated by `;`, each a path or JabRef's and Zotero's
    /// `description:path:type`, relative to the bibliography's folder unless absolute.
    public var files: [String] {
        guard let value = fields["file"] else { return [] }
        let folder = (file as NSString).deletingLastPathComponent
        return value.components(separatedBy: ";").compactMap { part in
            var path = part.trimmingCharacters(in: .whitespaces)
            if !FileManager.default.fileExists(atPath: OrgPaths.expandingTilde(path)), let m = path.firstMatch(of: /^[^:]*:(.+):[^:]*$/) {
                path = String(m.1)
            }
            path = path.replacingOccurrences(of: "\\:", with: ":")
            guard !path.isEmpty else { return nil }
            let expanded = OrgPaths.expandingTilde(path)
            return expanded.hasPrefix("/") ? expanded : ((folder as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
        }
    }

    /// The DOI without a resolver in front.
    public var doi: String? {
        field("doi").map { $0.replacingOccurrences(of: "^(?:https?://(?:dx\\.)?doi\\.org/|doi:)", with: "", options: [.regularExpression, .caseInsensitive]) }
    }

    public var url: String? { field("url") }
}

/// Bibliography files (BibTeX, BibLaTeX and CSL-JSON) read for Insert Citation…, key
/// completion and following citations.
public enum Bibliography {
    /// The files a buffer's `#+bibliography:` lines name, one each, quotes removed and
    /// relative to `directory`, then the global ones, each once, as
    /// `org-cite-list-bibliography-files` lists them.
    public static func files(in text: String, directory: String?, global: [String] = []) -> [String] {
        var files: [String] = []
        if text.containsIgnoringASCIICase("#+bibliography") {
            for m in text.matches(of: #/(?mi)^[ \t]*#\+bibliography:[ \t]*(.*?)[ \t]*$/#) {
                var name = String(m.1)
                if name.count > 1, name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
                guard !name.isEmpty else { continue }
                let path = OrgPaths.expandingTilde(name)
                files.append(path.hasPrefix("/") ? path : ((directory ?? "/") as NSString).appendingPathComponent(path))
            }
        }
        var seen = Set<String>()
        return (files + global.map { OrgPaths.expandingTilde($0) }).filter { seen.insert($0).inserted }
    }

    /// The entries of a file: CSL-JSON for `.json`, BibTeX otherwise, with `@string`s expanded
    /// and `crossref` fields filled in, sorted by key.
    public static func entries(_ data: Data, path: String) -> [BibEntry] {
        if (path as NSString).pathExtension.lowercased() == "json" {
            return CiteProcessor.parseJSON(data).map { key, fields in
                BibEntry(key: key, fields: Dictionary(fields.map { ($0.key.lowercased(), $0.value) }) { a, _ in a }, file: path)
            }.sorted { $0.key < $1.key }
        }
        let parsed = resolvingCrossrefs(CiteProcessor.parseBibTeX(String(decoding: data, as: UTF8.self)))
        return parsed.map { BibEntry(key: $0.key, fields: $0.value, file: path) }.sorted { $0.key < $1.key }
    }

    /// BibTeX's `crossref`: fields an entry lacks come from the entry it names; that entry's
    /// `title` becomes `booktitle`, as BibLaTeX maps it.
    static func resolvingCrossrefs(_ entries: [String: CiteProcessor.Entry]) -> [String: CiteProcessor.Entry] {
        var result = entries
        let lowered = Dictionary(entries.map { ($0.key.lowercased(), $0.value) }) { a, _ in a }
        for (key, entry) in entries {
            guard let target = entry["crossref"]?.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")), let parent = lowered[target.lowercased()] else { continue }
            var filled = entry
            for (field, value) in parent where !["id", "type", "crossref"].contains(field) {
                if field == "title" {
                    if filled["booktitle"] == nil { filled["booktitle"] = value }
                    if filled["title"] == nil { filled["title"] = value }
                } else if filled[field] == nil {
                    filled[field] = value
                }
            }
            result[key] = filled
        }
        return result
    }

    /// The line (from 1) an entry starts on in a BibTeX file's text, or `"id"`'s object in a
    /// CSL-JSON file, as `org-cite-basic-goto` finds it.
    public static func line(of key: String, in text: String, json: Bool) -> Int? {
        let quoted = NSRegularExpression.escapedPattern(for: key)
        let pattern = json ? "\"id\":[ \\t]*\"\(quoted)\"" : "@[A-Za-z]+[ \\t\\n]*[{(][ \\t\\n]*\(quoted)[ \\t\\n]*,"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return text[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}

/// Parsed bibliography files kept by modification date, so a file is read again only when it
/// changes.
public final class BibliographyCache: @unchecked Sendable {
    public static let shared = BibliographyCache()

    private let lock = NSLock()
    private var files: [String: (modified: Date, entries: [BibEntry])] = [:]
    private let modified: (String) -> Date?
    private let read: (String) -> Data?

    public init(
        modified: @escaping (String) -> Date? = { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date },
        read: @escaping (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    ) {
        self.modified = modified
        self.read = read
    }

    /// The entries of `paths`, the first file's entry winning for a key in several. Files that
    /// can't be read are left out. Reads files, so callers run it off the main thread.
    public func entries(_ paths: [String]) -> [BibEntry] {
        var seen = Set<String>()
        var all: [BibEntry] = []
        for path in paths {
            for entry in entries(of: (path as NSString).resolvingSymlinksInPath, as: path) where seen.insert(entry.key).inserted { all.append(entry) }
        }
        return all
    }

    /// `entries` on another thread.
    @concurrent
    public func load(_ paths: [String]) async -> [BibEntry] {
        entries(paths)
    }

    private func entries(of real: String, as path: String) -> [BibEntry] {
        guard let date = modified(real) else { return [] }
        lock.lock()
        let cached = files[real]
        lock.unlock()
        if let cached, cached.modified == date { return cached.entries.map { var e = $0; e.file = path; return e } }
        guard let data = read(real) else { return [] }
        let parsed = Bibliography.entries(data, path: real)
        lock.lock()
        files[real] = (date, parsed)
        lock.unlock()
        return parsed.map { var e = $0; e.file = path; return e }
    }
}
