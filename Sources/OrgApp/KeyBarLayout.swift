import Foundation
import OrgCore

/// The iOS key bar's buttons, `[key-bar]` in config.toml: `iphone` and `ipad`, each a list of
/// command ids in order. The Mac has no key bar and only reads the table, so the file is the
/// same on both.
public enum KeyBarLayout {
    public static let table = "key-bar"

    /// Which list a bar uses: `iphone` where the editor is narrow (iPhone, and iPad in Slide
    /// Over or a narrow split), `ipad` where it is wide.
    public enum Width: String, CaseIterable, Sendable {
        case iphone, ipad

        /// Where the list is kept, its ids one per line; absent means the default.
        public var defaultsKey: String { self == .iphone ? "keyBarIPhone" : "keyBarIPad" }

        public var defaultIDs: [String] {
            ["commands", "fold", "promote", "demote", "move-up", "move-down", "new-heading", "todo", "act"]
                + (self == .ipad ? ["schedule", "deadline", "tags"] : ["plan"]) + ["hide-keyboard"]
        }
    }

    public static let nextField = "org.snippet.next-field"
    public static let previousField = "org.snippet.previous-field"

    /// The list `defaults` holds for `width`, or nil for the default. Repeated ids count once.
    public static func stored(_ width: Width, in defaults: UserDefaults) -> [String]? {
        defaults.string(forKey: width.defaultsKey).map(ids)
    }

    /// The ids of a stored list, each once.
    public static func ids(_ stored: String) -> [String] {
        var seen = Set<String>()
        return stored.split(separator: "\n").map(String.init).filter { seen.insert($0).inserted }
    }

    public static func store(_ ids: [String]?, _ width: Width, in defaults: UserDefaults) {
        guard let ids else { return defaults.removeObject(forKey: width.defaultsKey) }
        let joined = ids.joined(separator: "\n")
        if defaults.string(forKey: width.defaultsKey) != joined { defaults.set(joined, forKey: width.defaultsKey) }
    }

    /// The problems of a list whose ids `known` doesn't know, which the bar skips.
    public static func problems(_ ids: [String], _ width: Width, known: (String) -> Bool) -> [String] {
        ids.filter { !known($0) }.map { "config.toml: \(table).\(width.rawValue) has no command \($0)" }
    }

    /// While a snippet's fields are filled in: Previous Field and Next Field in place of
    /// Promote and Demote, which act on the heading or item rather than the snippet, or first
    /// when the bar lacks them. A bar that has them already is unchanged.
    public static func withSnippetFields(_ ids: [String]) -> [String] {
        var out = ids
        for (field, replaced) in [(previousField, "promote"), (nextField, "demote")] where !out.contains(field) {
            if let index = out.firstIndex(of: replaced) { out[index] = field }
        }
        return [previousField, nextField].filter { !out.contains($0) } + out
    }

    /// The buttons that fit in `available` slots, in order, and the rest, which go in a More
    /// button that takes a slot. A button takes `slots(id)` slots; past the first that doesn't
    /// fit, none show, so the order stays.
    public static func fit(_ ids: [String], available: Int, slots: (String) -> Int) -> (shown: [String], more: [String]) {
        guard ids.reduce(0, { $0 + slots($1) }) > available else { return (ids, []) }
        var used = 1
        var shown: [String] = []
        for id in ids {
            used += slots(id)
            guard used <= available else { break }
            shown.append(id)
        }
        return (shown, Array(ids.dropFirst(shown.count)))
    }

    /// The text on a button for a command without a symbol: its title without the `…` that
    /// says it asks something.
    public static func face(title: String) -> String {
        title.hasSuffix("…") ? String(title.dropLast()) : title
    }

    /// A button's width in slots: one for a symbol or a word of up to four letters, as TODO,
    /// two for longer text, which wraps onto two lines.
    public static func slots(symbol: Bool, face: String) -> Int {
        symbol || face.count <= 4 ? 1 : 2
    }
}
