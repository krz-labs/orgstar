import Foundation
import OrgCore

/// What the agenda window shows.
public enum AgendaMode: Hashable, Sendable {
    /// `org-agenda-list`; nil span and start use the settings.
    case agenda(span: Int?, startOffset: Int?)
    /// `org-todo-list`, optionally for `KWD1|KWD2`.
    case todo(keywords: String?)
    /// `org-tags-view`.
    case match(String, todoOnly: Bool)
    /// `org-search-view`.
    case search(String, todoOnly: Bool)
    /// `org-agenda-list-stuck-projects`; nil uses the `org-stuck-projects` setting.
    case stuck(StuckProjects?)
    /// An org-ql query (`OrgQL`), sorted by org-ql's `:sort` keys.
    case query(String, sort: [String])
    /// A block agenda: several views one after the other.
    case blocks([AgendaBlock])

    /// The key `org-agenda-prefix-format` and `org-agenda-sorting-strategy` use for this kind
    /// of view.
    public var viewKey: String {
        switch self {
        case .agenda: "agenda"
        case .todo: "todo"
        case .match, .stuck, .query: "tags"
        case .search: "search"
        case .blocks: "agenda"
        }
    }
}

/// One view of a block agenda, with its own settings.
public struct AgendaBlock: Hashable, Sendable {
    public let mode: AgendaMode
    public let settings: AgendaViewSettings

    public init(mode: AgendaMode, settings: AgendaViewSettings = AgendaViewSettings()) {
        self.mode = mode
        self.settings = settings
    }
}

/// A view's own settings, as an `org-agenda-custom-commands` entry's give them:
/// `org-agenda-prefix-format`, `org-agenda-sorting-strategy`, `org-agenda-skip-function` (as
/// `org-agenda-skip-entry-if` or `-subtree-if`) and `org-agenda-overriding-header`.
public struct AgendaViewSettings: Hashable, Sendable {
    public var prefixFormat: String?
    public var sortingStrategy: [String]?
    public var skip: AgendaSkip?
    public var header: String?

    public init(prefixFormat: String? = nil, sortingStrategy: [String]? = nil, skip: AgendaSkip? = nil, header: String? = nil) {
        self.prefixFormat = prefixFormat
        self.sortingStrategy = sortingStrategy
        self.skip = skip
        self.header = header
    }

    public func apply(to options: AgendaOptions, view: String) -> AgendaOptions {
        var options = options
        if let prefixFormat { options.prefixFormat[view] = prefixFormat }
        if let sortingStrategy { options.sortingStrategy[view] = sortingStrategy }
        if let skip { options.skip = skip }
        return options
    }

    /// These settings with `block`'s over them, as a block's settings go over its command's.
    public func merged(_ block: AgendaViewSettings) -> AgendaViewSettings {
        AgendaViewSettings(prefixFormat: block.prefixFormat ?? prefixFormat, sortingStrategy: block.sortingStrategy ?? sortingStrategy,
                           skip: block.skip ?? skip, header: block.header)
    }
}

extension AgendaMode {
    /// The heading of a list or block: `TODO items: all`, `Week agenda`.
    public var title: String {
        switch self {
        case .agenda(let span, _): Self.spanTitle(span)
        case .todo(let keywords): "TODO items: \(keywords ?? "all")"
        case .match(let match, let todoOnly): (todoOnly ? "TODO entries" : "Entries") + " matching \(match)"
        case .search(let string, let todoOnly): (todoOnly ? "TODO entries" : "Entries") + " containing \(string)"
        case .stuck: "Stuck projects"
        case .query(let query, _): "Query: \(query)"
        case .blocks: "Block agenda"
        }
    }

    /// `org-agenda-span-name`, as a title.
    static func spanTitle(_ span: Int?) -> String {
        switch span {
        case 1?: "Day agenda"
        case 7?: "Week agenda"
        case 14?: "Fortnight agenda"
        case 30?, 31?: "Month agenda"
        case 365?: "Year agenda"
        case let n?: "\(n)-day agenda"
        case nil: "Agenda"
        }
    }
}

/// A named view: the built-in ones and those in `views.toml`.
public struct AgendaViewDefinition: Hashable, Sendable, Identifiable {
    public let name: String
    public let mode: AgendaMode
    public var settings: AgendaViewSettings
    /// `triage = true`: the view links to Triage.
    public var triage: Bool
    public var id: String { name }

    public init(name: String, mode: AgendaMode, settings: AgendaViewSettings = AgendaViewSettings(), triage: Bool = false) {
        self.name = name
        self.mode = mode
        self.settings = settings
        self.triage = triage
    }
}

/// Reads `views.toml`:
///
/// ```toml
/// [[view]]
/// name = "Work"
/// type = "match"        # agenda, todo, match, todo-match, search, todo-search, stuck or query
/// match = "+work-boss"
/// ```
///
/// `agenda` views take `span` and `start` (days from today), `todo` views `keywords`
/// (`WAIT|HOLD`); a `search` view's `match` is its search string. `query` views take an org-ql
/// `query`, in the sexp or the plain form, and `sort` (org-ql's keys separated by spaces).
/// `stuck` views take `match`, `keywords`, `tags` and `regexp` as `[org-stuck-projects]` does, each defaulting
/// to that setting. Any view can set
/// `prefix-format` and `sorting-strategy` (keys separated by spaces) for itself, and
/// `triage = true` to link to Triage. A view named like a built-in one replaces it.
@MainActor
public enum AgendaViewLoader {
    public static var userFile: URL { UserConfig.file("views.toml") }

    public static var builtIn: [AgendaViewDefinition] { builtIn(.standard) }

    /// Agenda, TODO List, Stuck Projects and the Weekly Review, whose waiting-for block lists
    /// `weekly-review-waiting`.
    public static func builtIn(_ defaults: UserDefaults) -> [AgendaViewDefinition] {
        [
            AgendaViewDefinition(name: "Agenda", mode: .agenda(span: nil, startOffset: nil)),
            AgendaViewDefinition(name: "TODO List", mode: .todo(keywords: nil)),
            AgendaViewDefinition(name: "Stuck Projects", mode: .stuck(nil)),
        ] + weeklyReview(defaults)
    }

    /// The Weekly Review, read once for each keyword.
    private static var weeklyReviews: [String: [AgendaViewDefinition]] = [:]

    private static func weeklyReview(_ defaults: UserDefaults) -> [AgendaViewDefinition] {
        let waiting = OrgPreferences.weeklyReviewWaiting(defaults)
        if let views = weeklyReviews[waiting] { return views }
        let views = parse(weeklyReview(waiting: waiting), defaults: defaults).views
        weeklyReviews[waiting] = views
        return views
    }

    public static let weeklyReviewName = "Weekly Review"

    /// The built-in Weekly Review as `views.toml` writes it.
    public static func weeklyReview(waiting: String) -> String {
        let waiting = waiting.isEmpty ? "WAITING" : waiting
        return """
            [[view]]
            name = "\(weeklyReviewName)"
            triage = true

            [[view.block]]
            type = "stuck"
            header = "Stuck projects"

            [[view.block]]
            type = "query"
            header = "Scheduled in the past"
            query = '(and (scheduled :to -1) (not (done)))'
            sort = "scheduled"

            [[view.block]]
            type = "query"
            header = "Deadlines up to a week ahead"
            query = '(and (deadline :to 7) (not (done)))'
            sort = "deadline"

            [[view.block]]
            type = "todo"
            header = "Waiting for"
            keywords = \(UserConfig.format(.string(waiting)))

            [[view.block]]
            type = "query"
            header = "Completed in the last 7 days"
            query = '(closed :from -7)'
            sort = "closed"

            [[view.block]]
            type = "query"
            header = "Clocked in the last 7 days"
            query = '(clocked :from -7)'

            """
    }

    /// The views' settings by mode; the first view with a mode wins.
    public static func settings(_ views: [AgendaViewDefinition]) -> [AgendaMode: AgendaViewSettings] {
        var settings: [AgendaMode: AgendaViewSettings] = [:]
        for view in views where settings[view.mode] == nil && view.settings != AgendaViewSettings() { settings[view.mode] = view.settings }
        return settings
    }

    /// The built-in views followed by the user's, and the problems found in the file. A view
    /// of the file named like a built-in one takes its place. Stuck views start from the
    /// `[org-stuck-projects]` settings in `defaults`.
    public static func load(userFile: URL = userFile, defaults: UserDefaults = .standard) -> (views: [AgendaViewDefinition], problems: [String]) {
        let interval = Perf.begin("views.load")
        defer { interval.end() }
        var views = builtIn(defaults)
        guard let text = try? String(contentsOf: userFile, encoding: .utf8) else { return (views, []) }
        let parsed = parse(text, defaults: defaults)
        for view in parsed.views {
            if let index = views.firstIndex(where: { $0.name == view.name }) { views[index] = view } else { views.append(view) }
        }
        return (views, parsed.problems)
    }

    /// The views in the text of a `views.toml`, and its problems.
    static func parse(_ text: String, defaults: UserDefaults) -> (views: [AgendaViewDefinition], problems: [String]) {
        let tables: [TOML.Table]
        do {
            tables = try TOML.parse(text)
        } catch {
            return ([], ["views.toml: \(error)"])
        }
        var problems: [String] = []
        // Each [[view]] with the [[view.block]] tables after it.
        var parsed: [(name: String, view: TOML.Table, blocks: [TOML.Table])] = []
        for table in tables where !(table.name.isEmpty && table.values.isEmpty) {
            if table.name == "view.block", table.isArrayElement {
                if parsed.isEmpty {
                    problems.append("views.toml line \(table.line): [[view.block]] before any [[view]]")
                } else {
                    parsed[parsed.count - 1].blocks.append(table)
                }
                continue
            }
            guard table.name == "view", table.isArrayElement else {
                problems.append("views.toml line \(table.line): expected [[view]]")
                continue
            }
            guard let name = table.values["name"]?.string else {
                problems.append("views.toml line \(table.line): a view needs a name")
                continue
            }
            parsed.append((name, table, []))
        }
        var views: [AgendaViewDefinition] = []
        for (name, table, blockTables) in parsed {
            guard let settings = settings(table, &problems) else { continue }
            let triage = table.values["triage"]?.bool ?? false
            if blockTables.isEmpty {
                guard let mode = mode(table, name: name, defaults: defaults, &problems) else { continue }
                views.append(AgendaViewDefinition(name: name, mode: mode, settings: settings, triage: triage))
                continue
            }
            var blocks: [AgendaBlock] = []
            for block in blockTables {
                guard var mode = mode(block, name: name, defaults: defaults, &problems), let own = Self.settings(block, &problems) else { continue }
                // The view's span and start go to agenda blocks without their own.
                if case .agenda(let span, let start) = mode {
                    mode = .agenda(span: span ?? table.values["span"]?.integer, startOffset: start ?? table.values["start"]?.integer)
                }
                blocks.append(AgendaBlock(mode: mode, settings: settings.merged(own)))
            }
            if !blocks.isEmpty {
                views.append(AgendaViewDefinition(name: name, mode: .blocks(blocks), settings: AgendaViewSettings(header: settings.header), triage: triage))
            }
        }
        return (views, problems)
    }

    /// Why a view wasn't saved.
    public struct SaveFailure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The `[[view]]` table that makes `mode` a view named `name`; nil for a block agenda and a
    /// stuck-projects view with its own definition, which one table can't hold.
    static func table(name: String, mode: AgendaMode) -> String? {
        func line(_ key: String, _ value: String?) -> String { value.map { "\(key) = \(UserConfig.format(.string($0)))\n" } ?? "" }
        var toml = "[[view]]\n" + line("name", name)
        switch mode {
        case .agenda(let span, let start):
            toml += line("type", "agenda") + (span.map { "span = \($0)\n" } ?? "") + (start.map { "start = \($0)\n" } ?? "")
        case .todo(let keywords):
            toml += line("type", "todo") + line("keywords", keywords)
        case .match(let match, let todoOnly):
            toml += line("type", todoOnly ? "todo-match" : "match") + line("match", match)
        case .search(let string, let todoOnly):
            toml += line("type", todoOnly ? "todo-search" : "search") + line("match", string)
        case .stuck(nil):
            toml += line("type", "stuck")
        case .query(let query, let sort):
            toml += line("type", "query") + line("query", query) + line("sort", sort.isEmpty ? nil : sort.joined(separator: " "))
        case .stuck, .blocks:
            return nil
        }
        return toml
    }

    /// Adds a view of `mode` named `name` to the end of `views.toml`, making the file when it
    /// isn't there. A name another view has, the built-in ones included, is refused.
    public static func save(name: String, mode: AgendaMode, userFile: URL = userFile) throws(SaveFailure) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SaveFailure(description: String(localized: "A view needs a name.")) }
        guard !load(userFile: userFile).views.contains(where: { $0.name == name }) else {
            throw SaveFailure(description: String(localized: "There is already a view named \(name)."))
        }
        guard let table = table(name: name, mode: mode) else {
            throw SaveFailure(description: String(localized: "This view can't be saved from here; write it in views.toml."))
        }
        do {
            try FileManager.default.createDirectory(at: userFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try UserFile.update(userFile) { text in
                text + (text.isEmpty ? "" : text.hasSuffix("\n") ? "\n" : "\n\n") + table
            }
        } catch {
            throw SaveFailure(description: error.localizedDescription)
        }
    }

    /// The view a `[[view]]` or `[[view.block]]` table describes.
    static func mode(_ table: TOML.Table, name: String, defaults: UserDefaults = .standard, _ problems: inout [String]) -> AgendaMode? {
        let match = table.values["match"]?.string
        let type = table.values["type"]?.string ?? "agenda"
        switch type {
        case "agenda":
            return .agenda(span: table.values["span"]?.integer, startOffset: table.values["start"]?.integer)
        case "todo":
            return .todo(keywords: table.values["keywords"]?.string)
        case "match", "todo-match", "search", "todo-search":
            guard let match else {
                problems.append("views.toml line \(table.line): \(name) needs a match")
                return nil
            }
            return type.hasSuffix("match") ? .match(match, todoOnly: type == "todo-match") : .search(match, todoOnly: type == "todo-search")
        case "query":
            guard let query = table.values["query"]?.string else {
                problems.append("views.toml line \(table.line): \(name) needs a query")
                return nil
            }
            do {
                _ = try OrgQL.parse(query)
                let sort = try OrgQL.sortKeys((table.values["sort"]?.string ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
                return .query(query, sort: sort)
            } catch {
                problems.append("views.toml line \(table.line): \(name): \(error.description)")
                return nil
            }
        case "stuck":
            if ["match", "keywords", "tags", "regexp"].allSatisfy({ table.values[$0] == nil }) { return .stuck(nil) }
            var definition = OrgPreferences.stuckProjects(defaults)
            if let match { definition.match = match }
            if let keywords = table.values["keywords"]?.string { definition.todo = OrgPreferences.words(keywords) }
            if let tags = table.values["tags"]?.string { definition.tags = OrgPreferences.words(tags) }
            if let regexp = table.values["regexp"]?.string { definition.regexp = regexp }
            return .stuck(definition)
        default:
            problems.append("views.toml line \(table.line): unknown type \(type)")
            return nil
        }
    }

    /// The settings of a `[[view]]` or `[[view.block]]` table; nil when one can't be read.
    static func settings(_ table: TOML.Table, _ problems: inout [String]) -> AgendaViewSettings? {
        var settings = AgendaViewSettings(prefixFormat: table.values["prefix-format"]?.string, header: table.values["header"]?.string)
        if let strategy = table.values["sorting-strategy"]?.string {
            let keys = strategy.split(whereSeparator: \.isWhitespace).map(String.init)
            if let bad = keys.first(where: { !AgendaSort.keys.contains($0) }) {
                problems.append("views.toml line \(table.line): unknown sorting key \(bad)")
            }
            settings.sortingStrategy = keys.filter(AgendaSort.keys.contains)
        }
        for (key, subtree) in [("skip-entry-if", false), ("skip-subtree-if", true)] {
            guard let text = table.values[key]?.string else { continue }
            switch AgendaSkip.parse(text, subtree: subtree) {
            case .success(let skip): settings.skip = skip
            case .failure(.message(let message)):
                problems.append("views.toml line \(table.line): \(key): \(message)")
                return nil
            }
        }
        return settings
    }
}
