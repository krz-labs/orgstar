import Foundation

/// A heading or file a link completes to: from the buffer, or from the index for other files.
public struct CompletionItem: Sendable, Hashable {
    public var title: String
    /// Its `ID`, or a Denote note's identifier; nil when the heading has none yet.
    public var id: String?
    public var path: String
    /// Where its heading starts; 0 for a file.
    public var start: Int
    /// A heading, not a file.
    public var heading: Bool

    public init(title: String, id: String?, path: String, start: Int, heading: Bool) {
        self.title = title
        self.id = id
        self.path = path
        self.start = start
        self.heading = heading
    }
}

/// What a completion asks the index, off the main thread, after the buffer's candidates show.
public enum CompletionQuery: Sendable, Hashable {
    /// Headings and files in every folder, for `[[id:`.
    case linkTargets
    /// Denote's notes, for `[[denote:`.
    case denoteNotes
    /// Values used for a property, and its `_ALL` values.
    case propertyValues(String)
    /// Words starting with the abbreviation.
    case words(String)
    /// The keys of these bibliography files, for `@` in a citation.
    case citationKeys([String])
}

/// What the index answers.
public struct CompletionResult: Sendable, Equatable {
    public var items: [CompletionItem] = []
    public var strings: [String] = []
    /// Text shown after each string, by string.
    public var annotations: [String: String] = [:]

    public init(items: [CompletionItem] = [], strings: [String] = [], annotations: [String: String] = [:]) {
        self.items = items
        self.strings = strings
        self.annotations = annotations
    }

    /// The keys of bibliography entries, each with its authors, year and title.
    public init(entries: [BibEntry]) {
        self.init(strings: entries.map(\.key), annotations: Dictionary(entries.map { entry in
            (entry.key, [entry.authors, entry.year, entry.title].compactMap { $0 }.joined(separator: "  "))
        }) { a, _ in a })
    }
}

extension OrgCompletion {
    /// `completion` with what the index answered for its query added to the buffer's
    /// candidates, matching what's typed.
    public static func filled(_ completion: Completion, with result: CompletionResult, fuzzy: Bool) -> Completion {
        var filled = completion
        switch completion.kind {
        case .idLink, .denoteLink:
            let items = completion.targets + result.items
            filled.setItems(items, fuzzy: fuzzy)
        case .propertyValue:
            filled.pool = completion.pool + result.strings
            filled.candidates = matching(filled.pool, completion.typed, fuzzy: fuzzy, ignoringCase: true, sorted: false)
        case .word:
            filled = Dabbrev.adding(result.strings, to: completion)
        case .citationKey:
            filled.pool = result.strings
            filled.annotations = result.annotations
            filled.candidates = matching(result.strings, completion.typed, fuzzy: fuzzy)
        default:
            break
        }
        filled.query = nil
        return filled
    }

    /// `[[id:` and `[[denote:`: the link type, what's typed after it, and the whole link
    /// typed so far, through `]]` after the caret.
    static func linkTarget(_ context: EditContext, lineStart: Int, toHere: String) -> (type: String, typed: Range<Int>, link: Range<Int>)? {
        guard let match = toHere.firstMatch(of: /\[\[(id|denote):([^\[\]]*)$/) else { return nil }
        let ns = context.text as NSString
        let caret = lineStart + (toHere as NSString).length
        let linkStart = lineStart + toHere.utf16.distance(from: toHere.utf16.startIndex, to: match.range.lowerBound)
        let typedStart = caret - String(match.2).utf16.count
        var end = caret
        if end + 2 <= ns.length, ns.substring(with: NSRange(location: end, length: 2)) == "]]" { end += 2 }
        return (String(match.1), typedStart..<caret, linkStart..<end)
    }

    /// The open file's headings and its own ID, for `[[id:`.
    static func bufferTargets(_ context: EditContext) -> [CompletionItem] {
        let path = context.options.filePath ?? ""
        let model = DocumentModel(tree: context.tree)
        let file = model.property("ID", of: nil).map { id in
            let title = context.text.firstMatch(of: /(?im)^[ \t]*#\+title:[ \t]*(.*?)[ \t]*$/).map { String($0.1) }
            return CompletionItem(title: title ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension, id: id.value,
                                  path: path, start: 0, heading: false)
        }
        return (file.map { [$0] } ?? []) + model.headings.map { CompletionItem(title: $0.title, id: $0.id, path: path, start: $0.headingRange.lowerBound, heading: true) }
    }

    /// Property values in the buffer: those `org-property-get-allowed-values` gives at the
    /// caret, then those headings give `name`.
    static func bufferValues(_ name: String, _ context: EditContext) -> [String] {
        let model = DocumentModel(tree: context.tree)
        let allowed = PropertyValues.allowed(name, at: context.caret, text: context.text, tree: context.tree)?.values.filter { !$0.isEmpty } ?? []
        let key = name.uppercased()
        return allowed + (model.fileProperties + model.headings.flatMap(\.properties)).filter { $0.key.uppercased() == key && !$0.value.isEmpty }.map(\.value)
    }
}

extension Completion {
    /// Candidates for link items: titles, with the file's name where titles repeat.
    mutating func setItems(_ all: [CompletionItem], fuzzy: Bool) {
        var counts: [String: Int] = [:]
        for item in all { counts[item.title, default: 0] += 1 }
        var labels: [String: CompletionItem] = [:]
        var order: [String] = []
        for item in all {
            var label = counts[item.title, default: 0] > 1 ? "\(item.title) (\((item.path as NSString).lastPathComponent))" : item.title
            var n = 2
            while labels[label] != nil {
                label = "\(item.title) (\((item.path as NSString).lastPathComponent) \(n))"
                n += 1
            }
            labels[label] = item
            order.append(label)
        }
        pool = order
        candidates = OrgCompletion.matching(order, typed, fuzzy: fuzzy, ignoringCase: true)
        items = candidates.compactMap { labels[$0] }
        targets = all
    }

    /// The item behind a candidate of a link completion.
    public func item(_ candidate: String) -> CompletionItem? {
        candidates.firstIndex(of: candidate).flatMap { items.indices.contains($0) ? items[$0] : nil }
    }

    /// The link a link completion inserts for `item`, given its ID.
    public func link(_ item: CompletionItem, id: String) -> String {
        Links.makeString((kind == .denoteLink ? "denote:" : "id:") + id, item.title)
    }
}
