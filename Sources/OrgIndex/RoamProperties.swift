import Foundation

/// A node's `ROAM_ALIASES`, `ROAM_REFS` and `ROAM_EXCLUDE` as written, read as org-roam 2.3's
/// `org-roam-db-update-file` reads them.
public struct RoamProperties: Sendable, Equatable {
    public var aliases: String?
    public var refs: String?
    public var exclude: String?

    public init(aliases: String? = nil, refs: String? = nil, exclude: String? = nil) {
        self.aliases = aliases
        self.refs = refs
        self.exclude = exclude
    }

    /// From a heading's own property rows; inherited values don't count.
    init(_ rows: [PropertyRow]) {
        func own(_ key: String) -> String? { rows.first { $0.key == key && !$0.inherited }?.value }
        self.init(aliases: own("ROAM_ALIASES"), refs: own("ROAM_REFS"), exclude: own("ROAM_EXCLUDE"))
    }

    /// `org-roam-db-node-p`: `(org-entry-get (point) "ROAM_EXCLUDE")` is non-nil, which any
    /// value but `nil` is.
    public var excluded: Bool { exclude.map { $0.trimmingCharacters(in: .whitespaces) != "nil" } ?? false }

    public var aliasList: [String] { aliases.map(Self.split) ?? [] }

    /// `org-roam-db-insert-refs`: `@key` and the keys of `[cite:…]` as `cite:key`, and links,
    /// bracketed or plain, as their targets. Anything else is skipped, as org-roam skips it
    /// with a warning.
    public var refList: [String] {
        var result: [String] = []
        for ref in refs.map(Self.split) ?? [] {
            if ref.hasPrefix("@") {
                result.append("cite:" + ref.dropFirst())
            } else if ref.hasPrefix("[cite:") {
                result += ref.matches(of: /@([^\s;\]]+)/).map { "cite:" + $0.1 }
            } else if let bracket = ref.firstMatch(of: /\[\[([^\]]+)\](?:\[[^\]]*\])?\]/) {
                result.append(String(bracket.1))
            } else if let plain = ref.firstMatch(of: Self.plainLink) {
                result.append(String(plain.0))
            }
        }
        return result
    }

    /// Link types `org-link-plain-re` knows without other packages loaded.
    nonisolated(unsafe) static let plainLink = /(?:https?|ftp|mailto|doi|file|news|shell|elisp|help|info|id|attachment|bbdb|docview|gnus|irc|rmail|w3m|eww):[^\s\[\]<>]+/

    /// `split-string-and-unquote`: words separated by whitespace, a double-quoted string read as
    /// one, with its escapes.
    public static func split(_ string: String) -> [String] {
        var words: [String] = []
        var current = ""
        var chars = string.makeIterator()
        func flush() {
            if !current.isEmpty { words.append(current) }
            current = ""
        }
        while let c = chars.next() {
            if c == "\"" {
                flush()
                var quoted = ""
                while let q = chars.next(), q != "\"" {
                    if q == "\\", let escaped = chars.next() {
                        switch escaped {
                        case "n": quoted.append("\n")
                        case "t": quoted.append("\t")
                        case "\n": break
                        default: quoted.append(escaped)
                        }
                    } else {
                        quoted.append(q)
                    }
                }
                words.append(quoted)
            } else if c.isWhitespace {
                flush()
            } else {
                current.append(c)
            }
        }
        flush()
        return words
    }
}
