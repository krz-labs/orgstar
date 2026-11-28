import Foundation
import OrgConfig
import OrgCore

/// `orgstar agenda [view]`: the agenda or a view of views.toml, as text the way Emacs's agenda
/// buffer shows it, or as JSON.
@MainActor
enum AgendaCommand {
    static let help = """
    Usage: orgstar agenda [<view>] [--json]

    Prints the agenda over the agenda files, with the span and start of Settings ▸ Agenda, or a
    view by name: "TODO List", "Stuck Projects", or a [[view]] of views.toml.

    Options:
      --json    the views, days and entries as JSON, with each entry's file and line
    """

    static func run(_ words: [String], _ workspace: Workspace) throws(Failure) {
        let arguments = try Arguments(words, command: "agenda", flags: ["--json"])
        try arguments.expect(0, 1, "agenda")
        let defaults = workspace.defaults
        let (views, problems) = AgendaViewLoader.load(userFile: workspace.configFile("views.toml"), defaults: defaults)
        for problem in problems { workspace.host.error("orgstar: \(problem)\n") }
        let name = arguments.positional.first ?? "Agenda"
        guard let view = views.first(where: { $0.name == name }) ?? views.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw Failure(.notFound, "No agenda view named \(name). Views: " + views.map(\.name).joined(separator: ", "))
        }
        let blocks = compute(view, views: views, workspace)
        if arguments.flags.contains("--json") {
            workspace.host.output(JSONOutput.data(json(view: view.name, blocks, workspace)))
        } else {
            workspace.host.print(text(blocks, today: today(workspace), showAllDates: OrgPreferences.agendaShowAllDates(workspace.defaults)))
        }
    }

    struct Block {
        let mode: AgendaMode
        let header: String?
        var first = 0
        var span = 0
        var days: [AgendaDay] = []
        var list: [AgendaItem] = []
    }

    static func today(_ workspace: Workspace) -> Int { Days.absolute(workspace.host.now, calendar: workspace.host.calendar) }

    /// The view's blocks, computed as the agenda window computes them.
    static func compute(_ view: AgendaViewDefinition, views: [AgendaViewDefinition], _ workspace: Workspace) -> [Block] {
        let defaults = workspace.defaults
        let host = workspace.host
        let now = host.now
        let calendar = host.calendar
        let today = today(workspace)
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        let base = OrgPreferences.agendaOptions(AgendaOptions.terminal, defaults)
        let viewSettings = AgendaViewLoader.settings(views)
        var jobs: [(mode: AgendaMode, options: AgendaOptions, header: String?)] = []
        if case .blocks(let blocks) = view.mode {
            for block in blocks { jobs.append((block.mode, block.settings.apply(to: base, view: block.mode.viewKey), block.settings.header)) }
        } else {
            jobs.append((view.mode, viewSettings[view.mode]?.apply(to: base, view: view.mode.viewKey) ?? base, view.settings.header))
        }
        let sources = sources(workspace, options: base)
        return jobs.map { job in
            var block = Block(mode: job.mode, header: job.header)
            switch job.mode {
            case .agenda(let span, let start):
                var first = today + (start ?? OrgPreferences.agendaStartOffset(defaults))
                let days = span ?? OrgPreferences.agendaSpan(defaults)
                if days == 7 || days == 14 { first = Days.weekStart(first, on: OrgPreferences.agendaStartOnWeekday(defaults)) }
                block.first = first
                block.span = days
                block.days = Agenda.list(sources, start: first, days: days, today: today, now: (clock.hour ?? 0, clock.minute ?? 0), options: job.options)
            case .todo(let keywords):
                block.list = Agenda.todoList(sources, keywords: keywords, options: job.options, today: today)
            case .match(let match, let todoOnly):
                block.list = Agenda.tagsMatch(sources, match: match, todoOnly: todoOnly, now: now, calendar: calendar, options: job.options)
            case .search(let string, let todoOnly):
                block.list = Agenda.textSearch(sources, string: string, todoOnly: todoOnly, options: job.options)
            case .stuck(let definition):
                block.list = Agenda.stuckProjects(sources, definition ?? job.options.stuckProjects, now: now, calendar: calendar, options: job.options)
            case .query(let query, let sort):
                block.list = Agenda.query(sources, query: query, sort: sort, today: today, options: job.options) ?? []
            case .blocks:
                break
            }
            return block
        }
    }

    /// The agenda files, parsed, without the files others archive to when
    /// `agenda-exclude-archives` is on.
    static func sources(_ workspace: Workspace, options: AgendaOptions) -> [AgendaSource] {
        let blocking = options.dimBlockedTasks != .off && (options.enforceTodoDependencies || options.enforceTodoCheckboxDependencies)
        var sources = workspace.agendaFiles.compactMap { path -> AgendaSource? in
            guard let text = try? workspace.text(path) else { return nil }
            return AgendaSource(path: path, text: text, defaults: workspace.settings(for: text, path: path), checksBlocking: blocking)
        }
        if OrgPreferences.agendaExcludeArchives(workspace.defaults) {
            let location = OrgPreferences.options(workspace.defaults).archiveLocation ?? "%s_archive::"
            let archives = Set(sources.flatMap { $0.archiveFiles(location: location) })
            sources.removeAll { archives.contains($0.path) }
        }
        return sources
    }

    // MARK: - Text

    /// Days without entries are left out unless `showAllDates`; today always shows.
    static func text(_ blocks: [Block], today: Int, showAllDates: Bool) -> String {
        var out: [String] = []
        for (index, block) in blocks.enumerated() {
            if index > 0 { out.append(String(repeating: "=", count: 80)) }
            out.append(header(block))
            if case .agenda = block.mode {
                for day in block.days where showAllDates || day.isToday || !day.items.isEmpty {
                    out.append(day.header)
                    for item in day.items { out.append(line(item, today: today)) }
                }
            } else {
                out += block.list.map { line($0, today: today) }
            }
        }
        return out.joined(separator: "\n")
    }

    static func line(_ item: AgendaItem, today: Int) -> String {
        item.habit.map { Habit.insertGraph($0.graph(today: today), into: item.line) } ?? item.line
    }

    /// The block's first line, as Emacs writes it unless the view overrides it.
    static func header(_ block: Block) -> String {
        if let header = block.header { return header }
        switch block.mode {
        case .agenda:
            let name = switch block.span {
            case 1: "Day"
            case 7: "Week"
            case 14: "Fortnight"
            case 30, 31: "Month"
            case 365: "Year"
            default: "\(block.span) days"
            }
            var header = name + "-agenda"
            if block.span < 350 {
                let first = week(block.first)
                let last = week(block.first + block.span - 1)
                header += first == last ? String(format: " (W%02d)", first) : String(format: " (W%02d-W%02d)", first, last)
            }
            return header + ":"
        case .todo(let keywords): return "Global list of TODO items of type: \(keywords ?? "ALL")"
        case .match(let match, _): return "Headlines with TAGS match: \(match)"
        case .search(let string, _): return "Search words: \(string)"
        case .stuck: return "List of stuck projects:"
        case .query(let query, _): return "Query: \(query)"
        case .blocks: return ""
        }
    }

    /// The ISO week of a day as `Days` numbers it.
    static func week(_ day: Int) -> Int {
        let d = Days.date(day)
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) ?? Date()
        return calendar.component(.weekOfYear, from: date)
    }

    // MARK: - JSON

    static func json(view: String, _ blocks: [Block], _ workspace: Workspace) -> [String: Any] {
        var texts: [String: String] = [:]
        func entry(_ item: AgendaItem) -> [String: Any] {
            var value: [String: Any] = [
                "kind": item.kind.rawValue, "category": item.category, "title": item.text, "tags": item.tags, "done": item.isDone,
                "text": line(item, today: today(workspace)),
            ]
            if !item.time.trimmingCharacters(in: .whitespaces).isEmpty { value["time"] = item.time.trimmingCharacters(in: .whitespaces) }
            if !item.extra.trimmingCharacters(in: .whitespaces).isEmpty { value["extra"] = item.extra.trimmingCharacters(in: .whitespaces) }
            if let todo = item.todo { value["todo"] = todo }
            if let effort = item.effort { value["effort"] = effort }
            if let path = item.path, let offset = item.headingOffset {
                value["file"] = path
                value["offset"] = offset
                if texts[path] == nil { texts[path] = try? workspace.text(path) }
                if let text = texts[path] { value["line"] = Workspace.line(of: offset, in: text) }
            }
            return value
        }
        let list = blocks.map { block -> [String: Any] in
            var value: [String: Any] = ["header": header(block), "type": type(block.mode)]
            if case .agenda = block.mode {
                value["days"] = block.days.map { day -> [String: Any] in
                    let d = Days.date(day.day)
                    return ["date": String(format: "%04d-%02d-%02d", d.year, d.month, d.day), "today": day.isToday, "header": day.header,
                            "entries": day.items.map(entry)]
                }
            } else {
                value["entries"] = block.list.map(entry)
            }
            return value
        }
        return ["view": view, "blocks": list]
    }

    static func type(_ mode: AgendaMode) -> String {
        switch mode {
        case .agenda: "agenda"
        case .todo: "todo"
        case .match(_, let todoOnly): todoOnly ? "todo-match" : "match"
        case .search(_, let todoOnly): todoOnly ? "todo-search" : "search"
        case .stuck: "stuck"
        case .query: "query"
        case .blocks: "blocks"
        }
    }
}

enum JSONOutput {
    static func data(_ value: Any) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }
}
