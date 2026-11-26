import Foundation

/// A citation in a buffer, with the parts `org-cite-insert` tells apart.
public struct CitationAt: Sendable, Equatable {
    /// `[cite…]`, without the blanks after it.
    public var range: Range<Int>
    /// The `:` ending `[cite/style`.
    public var colon: Int
    /// Each reference, its `;` included, and its `@key`.
    public var references: [(range: Range<Int>, key: Range<Int>)]

    /// The style and variant as written (`t/c`); nil without one.
    public func style(in text: String) -> String? {
        let ns = text as NSString
        let written = ns.substring(with: NSRange(location: range.lowerBound + 5, length: colon - range.lowerBound - 5))
        return written.hasPrefix("/") ? String(written.dropFirst()) : nil
    }

    public static func == (a: CitationAt, b: CitationAt) -> Bool {
        a.range == b.range && a.colon == b.colon && a.references.map(\.range) == b.references.map(\.range) && a.references.map(\.key) == b.references.map(\.key)
    }
}

public enum Citations {
    /// The citation holding `offset`: from just after its `[` to its `]`, as
    /// `org-cite-boundaries` bounds it.
    public static func citation(at offset: Int, tree: OrgTree) -> CitationAt? {
        var node = tree.root
        while let child = node.children.first(where: { $0.range.contains(offset) }) {
            if child.kind == .citation { return citation(child) }
            node = child
        }
        return nil
    }

    static func citation(_ node: SyntaxNode) -> CitationAt? {
        let text = node.text as NSString
        let colon = text.range(of: ":")
        guard colon.location != NSNotFound else { return nil }
        let key = try! NSRegularExpression(pattern: CiteProcessor.keyPattern)
        var references: [(range: Range<Int>, key: Range<Int>)] = []
        func collect(_ node: SyntaxNode) {
            for child in node.children {
                if child.kind == .citationReference {
                    let own = child.text
                    guard let m = key.firstMatch(in: own, range: NSRange(location: 0, length: (own as NSString).length)) else { continue }
                    let start = child.range.lowerBound + m.range.location
                    references.append((child.range, start..<(start + m.range.length)))
                } else {
                    collect(child)
                }
            }
        }
        collect(node)
        return CitationAt(range: node.range, colon: node.range.lowerBound + colon.location, references: references)
    }

    /// The citation keys a caret at `offset` follows, as `org-cite-basic-goto` picks them: the
    /// reference's, or every key of the citation. Nil off a citation.
    public static func keys(at offset: Int, text: String, tree: OrgTree) -> [String]? {
        guard let citation = citation(at: offset, tree: tree) else { return nil }
        let ns = text as NSString
        let keys = citation.references.map { ns.substring(with: NSRange(location: $0.key.lowerBound + 1, length: $0.key.count - 1)) }
        if let reference = citation.references.firstIndex(where: { $0.range.contains(offset) }) { return [keys[reference]] }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// What Insert Citation… does at `offset`, as `org-cite-make-insert-processor` decides.
    public enum Place: Sendable, Equatable {
        /// Outside a citation: a new one.
        case new
        /// On `[cite/style`: a new style.
        case style
        /// Elsewhere in a citation: a reference added before or after the caret.
        case reference
        /// Inside a key: the key replaced, its prefix and suffix kept.
        case key
    }

    public static func place(at offset: Int, tree: OrgTree) -> Place {
        guard let citation = citation(at: offset, tree: tree), offset > citation.range.lowerBound else { return .new }
        if offset <= citation.colon { return .style }
        if let current = citation.references.first(where: { $0.range.contains(offset) }), offset > current.key.lowerBound, offset < current.key.upperBound {
            return .key
        }
        return .reference
    }

    /// `@key` with a prefix and suffix around it, a blank between them unless they have one.
    static func reference(_ key: String, prefix: String, suffix: String) -> String {
        var out = "@" + key
        if !prefix.isEmpty { out = prefix + (prefix.last!.isWhitespace ? "" : " ") + out }
        if !suffix.isEmpty { out += (suffix.first!.isWhitespace || ",.:".contains(suffix.first!) ? "" : " ") + suffix }
        return out
    }
}

/// Insert Citation…'s edit, once the key and style are chosen: `org-cite-insert` with the
/// basic processor. Outside a citation, `[cite/style:@key]`; on a citation's style, the style
/// replaced; on its common prefix or before a reference's `@`, a reference before; on its
/// common suffix or a reference's suffix, one after; on a key, that key replaced. A prefix
/// and suffix go around the new reference.
public struct InsertCitation: OrgCommand {
    public var key: String?
    public var style: String?
    public var prefix: String
    public var suffix: String

    public init(key: String?, style: String? = nil, prefix: String = "", suffix: String = "") {
        self.key = key
        self.style = style
        self.prefix = prefix
        self.suffix = suffix
    }

    public var id: String { "internal.insert-citation" }
    public var title: String { "Insert Citation" }

    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        let caret = context.caret
        let styleText = (style?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : "/" + $0 } ?? ""
        func commit(_ range: Range<Int>, _ replacement: String, caret: Int) -> CommandStep {
            .commit(EditResult(baseRevision: context.revision, edits: [TextEdit(range: range, replacement: replacement)], selection: [caret..<caret]))
        }
        let place = Citations.place(at: caret, tree: context.tree)
        if place == .style, let citation = Citations.citation(at: caret, tree: context.tree) {
            guard style != nil else { return .failed("Aborted") }
            // A point in the old style ends up where the deletion leaves it, at the style's start.
            let start = citation.range.lowerBound + 5
            return commit(start..<citation.colon, styleText, caret: min(caret, start))
        }
        guard let key, !key.isEmpty else { return .failed("Aborted") }
        let reference = Citations.reference(key, prefix: prefix, suffix: suffix)
        guard place != .new, let citation = Citations.citation(at: caret, tree: context.tree), let first = citation.references.first,
              let last = citation.references.last else {
            let text = "[cite\(styleText):\(reference)]"
            return commit(caret..<caret, text, caret: caret + (text as NSString).length)
        }
        let ns = context.text as NSString
        func before(_ r: (range: Range<Int>, key: Range<Int>)) -> CommandStep {
            let inserted = reference + ";"
            return commit(r.range.lowerBound..<r.range.lowerBound, inserted, caret: caret > r.range.lowerBound ? caret + (inserted as NSString).length : caret)
        }
        func after(_ r: (range: Range<Int>, key: Range<Int>)) -> CommandStep {
            let end = r.range.upperBound
            let inserted = ns.character(at: end - 1) == 59 ? reference + ";" : ";" + reference
            return commit(end..<end, inserted, caret: caret >= end ? caret + (inserted as NSString).length : caret)
        }
        guard let current = citation.references.first(where: { $0.range.contains(caret) }) else {
            // On the common prefix or suffix.
            return caret < first.range.lowerBound ? before(first) : after(last)
        }
        if caret <= current.key.lowerBound { return before(current) }
        if caret >= current.key.upperBound { return after(current) }
        return commit(current.key, "@" + key, caret: current.key.lowerBound)
    }
}
