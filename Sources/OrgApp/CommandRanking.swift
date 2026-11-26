import Foundation
import OrgCore

/// The commands run from the command palette: the last ten, most recent first, and how often
/// each was run, kept in `UserDefaults` by command id.
public final class CommandUsage: Sendable {
    public static let shared = CommandUsage()
    /// The recents the palette lists for an empty query.
    public static let recentLimit = 10
    /// Uses past this count add nothing more to a command's rank.
    public static let usesCounted = 20

    private nonisolated(unsafe) let defaults: UserDefaults
    private static let recentKey = "commandRecents"
    private static let countsKey = "commandUseCounts"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Command ids, most recent first.
    public var recent: [String] { defaults.stringArray(forKey: Self.recentKey) ?? [] }

    public func uses(of id: String) -> Int {
        (defaults.dictionary(forKey: Self.countsKey)?[id] as? Int) ?? 0
    }

    public func record(_ id: String) {
        defaults.set(Array(([id] + recent.filter { $0 != id }).prefix(Self.recentLimit)), forKey: Self.recentKey)
        var counts = defaults.dictionary(forKey: Self.countsKey) ?? [:]
        counts[id] = ((counts[id] as? Int) ?? 0) + 1
        defaults.set(counts, forKey: Self.countsKey)
    }

    /// What frequent use adds to a `FuzzyMatch.score`: at most one word-start match, so a
    /// frequent command wins a tie and never beats a clearly better match.
    public func bonus(for id: String) -> Int {
        min(uses(of: id), Self.usesCounted) * FuzzyMatch.wordStartBonus * 100 / Self.usesCounted
    }
}

/// The command palette's order, on the Mac and on iOS.
public enum CommandRanking {
    /// For an empty query, the recent commands among `items` and then the rest by title; for a
    /// query, no recents and the matches best first, frequent use breaking near ties.
    public static func rank<Item>(_ items: [Item], query: String, usage: CommandUsage = .shared,
                                  id: (Item) -> String, titles: (Item) -> [String]) -> (recent: [Item], rest: [Item]) {
        func title(_ item: Item) -> String { titles(item).first ?? id(item) }
        if query.allSatisfy(\.isWhitespace) {
            let recentIDs = usage.recent
            let recent = recentIDs.compactMap { wanted in items.first { id($0) == wanted } }
            let rest = items.filter { !recentIDs.contains(id($0)) }
                .sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
            return (recent, rest)
        }
        let scored: [(item: Item, score: Int)] = items.compactMap { item in
            guard let score = titles(item).compactMap({ FuzzyMatch.score(query, $0) }).max() else { return nil }
            return (item, score + usage.bonus(for: id(item)))
        }
        let ranked = scored.sorted { a, b in
            a.score != b.score ? a.score > b.score : title(a.item).localizedStandardCompare(title(b.item)) == .orderedAscending
        }
        return ([], ranked.map(\.item))
    }
}

/// Commands by subject: the Org menu's submenus on the Mac and iPad, and the sections of the
/// iOS Commands list.
public enum CommandGroups {
    public struct Group: Sendable {
        public let title: String
        /// A command belongs to the first group with a prefix its id starts with.
        public let prefixes: [String]
    }

    /// The Org menu's submenus, in menu order.
    public static let orgMenu: [Group] = [
        Group(title: String(localized: "Visibility", comment: "Org menu submenu"), prefixes: ["org.cycle", "org.fold.", "org.narrow.", "org.widen", "org.sparse-tree", "org.toggle-inline-images", "org.latex-preview"]),
        Group(title: String(localized: "Headings", comment: "Org menu submenu"), prefixes: ["org.heading.", "org.subtree.", "org.element.", "org.goto", "org.sort", "org.archive.", "app.refile", "app.archive"]),
        Group(title: String(localized: "TODO and Tags", comment: "Org menu submenu"), prefixes: ["org.todo.", "org.priority.", "org.tags.", "org.effort.", "app.rename-"]),
        Group(title: String(localized: "Properties and Columns", comment: "Org menu submenu"), prefixes: ["org.property.", "org.columns", "org.drawer."]),
        Group(title: String(localized: "Dates and Timers", comment: "Org menu submenu"), prefixes: ["org.schedule", "org.deadline", "org.timestamp.", "org.timer."]),
        Group(title: String(localized: "Lists", comment: "Org menu submenu"), prefixes: ["org.item.", "org.checkbox."]),
        Group(title: String(localized: "Tables", comment: "Org menu submenu"), prefixes: ["org.table", "app.table-", "app.plot"]),
        Group(title: String(localized: "Links and Footnotes", comment: "Org menu submenu"), prefixes: ["org.link.", "org.id.", "org.footnote."]),
        Group(title: String(localized: "Blocks", comment: "Org menu submenu"), prefixes: ["org.babel.", "org.structure-template", "org.edit-special", "org.dblock.", "org.clock.report", "org.denote."]),
        Group(title: String(localized: "Text", comment: "Org menu submenu"), prefixes: ["org.emphasize", "org.fill-", "org.snippet"]),
        Group(title: String(localized: "Attachments", comment: "Org menu submenu"), prefixes: ["app.attach."]),
        Group(title: String(localized: "Notes", comment: "Org menu submenu"), prefixes: ["app.dailies.", "app.node.", "app.backlinks"]),
        Group(title: String(localized: "Encryption", comment: "Org menu submenu"), prefixes: ["app.crypt."]),
    ]

    /// The Org menu's groups and the app's commands outside the Org menu.
    public static let commandList: [Group] = orgMenu + [
        Group(title: String(localized: "Clock", comment: "Commands list section"), prefixes: ["app.clock."]),
        Group(title: String(localized: "Export", comment: "Commands list section"), prefixes: ["app.export", "app.copy-rich-text", "app.publish", "app.share-subtree"]),
        Group(title: String(localized: "File", comment: "Commands list section"), prefixes: ["app.save", "app.word-count", "app.recovery", "app.sync-conflicts", "app.lint", "app.working-copy"]),
        Group(title: String(localized: "Edit", comment: "Commands list section"), prefixes: ["edit.", "macro."]),
        Group(title: String(localized: "View", comment: "Commands list section"), prefixes: ["app.toggle-markup", "editor.", "app.split-", "app.pane-"]),
    ]

    /// The index in `groups` of the group `id` belongs to, or nil for none.
    public static func group(of id: String, in groups: [Group] = orgMenu) -> Int? {
        groups.firstIndex { $0.prefixes.contains { id.hasPrefix($0) } }
    }
}

/// Why a command doesn't apply at the caret, for a list that shows it greyed: what it needs
/// that the caret isn't in, or that there is nothing for it to do there.
public enum CommandReason {
    public static func reason(for id: String, in context: EditContext) -> String {
        func starts(_ prefixes: String...) -> Bool { prefixes.contains { id.hasPrefix($0) } }
        if starts("org.table", "app.table-export", "app.plot"), !KeyContext.holds("table", in: context) {
            return String(localized: "No table at point")
        }
        if starts("org.item.", "org.checkbox."), !KeyContext.holds("item", in: context) {
            return String(localized: "Not in a list", comment: "Why a command is greyed in the Commands list")
        }
        if starts("org.babel."), !KeyContext.holds("src", in: context) {
            return String(localized: "Not in a code block", comment: "Why a command is greyed in the Commands list")
        }
        if starts("org.link.open"), !OpenLinkAtPoint().applies(in: context) {
            return String(localized: "Not on a link", comment: "Why a command is greyed in the Commands list")
        }
        if starts("org.timestamp.up", "org.timestamp.down", "org.timestamp.day-", "org.timestamp.evaluate-range"), !KeyContext.holds("timestamp", in: context) {
            return String(localized: "Not on a timestamp", comment: "Why a command is greyed in the Commands list")
        }
        if starts("app.crypt.open-entry", "app.crypt.decrypt-entry"), OrgCrypt.encryptedRange(context.text, at: context.caret) == nil {
            return String(localized: "Not an encrypted entry")
        }
        if starts("org.heading.", "org.subtree.", "org.todo.", "org.priority.", "org.tags.", "org.property.", "org.effort.",
                  "org.schedule", "org.deadline", "org.archive.", "app.refile", "app.archive", "app.crypt.encrypt-entry"),
           context.tree.root.child(containing: context.caret)?.kind != .section {
            return String(localized: "Not in a subtree")
        }
        return String(localized: "Nothing to do here", comment: "Why a command is greyed in the Commands list")
    }
}
