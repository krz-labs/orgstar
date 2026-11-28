import Foundation
import Observation
import OrgCore
import OrgIndex
import OrgPresentation

/// What one view of a block agenda shows.
public struct AgendaBlockResult: Equatable, Sendable {
    public let header: String
    public let mode: AgendaMode
    public var days: [AgendaDay] = []
    public var list: [AgendaItem] = []
    public var events: [AgendaEvent] = []

    public var isAgenda: Bool {
        if case .agenda = mode { return true }
        return false
    }
}

/// Parsed agenda files by path, kept while the file's modification date and size and the
/// settings it was parsed with hold. Agenda models over one workspace can share one.
@MainActor
public final class AgendaSourceCache {
    var entries: [String: (mtime: Date, size: Int, defaults: OrgSettings, blocking: Bool, source: AgendaSource)] = [:]
    /// Open buffers' sources, kept while their text is the same.
    var open: [String: (defaults: OrgSettings, blocking: Bool, source: AgendaSource)] = [:]

    public init() {}
}

/// The day/week agenda over the workspace's agenda files. Sources are read from disk and
/// cached in `cache`; the open file's come from its buffer, so the agenda shows unsaved edits.
@MainActor
@Observable
public final class AgendaModel {
    public private(set) var days: [AgendaDay] = []
    /// The entries of a TODO list, match or search view.
    public private(set) var list: [AgendaItem] = []
    /// A block agenda's views, in order.
    public private(set) var blocks: [AgendaBlockResult] = []
    public var mode: AgendaMode = .agenda(span: nil, startOffset: nil)
    /// The first day shown, as `Days` numbers it; nil follows today.
    public var start: Int?
    public var span = 10
    /// Where the view starts relative to today, as `org-agenda-start-day` (`"-3d"` is -3).
    public var startOffset = 0
    /// `org-agenda-start-on-weekday`: 7- and 14-day spans start on this weekday (0 is Sunday);
    /// nil starts them on the first day.
    public var startOnWeekday: Int? = 1
    /// Files below the top level of each folder are agenda files too.
    public var includeSubfolders = false
    /// Files other agenda files archive to are left out.
    public var excludeArchives = OrgPreferences.agendaExcludeArchives()
    /// Files in these folders (root paths) are left out; see `HiddenFolders`.
    public var hiddenFolders: Set<String> = []
    /// `org-agenda-files`: when not empty, the agenda reads these instead of the folders' files.
    public var agendaFiles = OrgPreferences.agendaFiles()
    public var options = AgendaOptions()
    /// The settings of the views in `views.toml`, applied while `mode` is theirs.
    public var viewSettings: [AgendaMode: AgendaViewSettings] = [:]
    public private(set) var isComputing = false
    /// Calendar events over the days shown, from `calendarEvents` (nil reads none) and the
    /// calendars in `calendarNames` (all when empty).
    public private(set) var events: [AgendaEvent] = []
    public var calendarEvents: CalendarEvents?
    public var calendarNames: [String] = []
    /// Reminders due by the last day shown, from `reminderLists` (nil reads none) and the lists
    /// in `reminderListNames` (all when empty), among the events.
    public var reminderLists: ReminderLists?
    public var reminderListNames: [String] = []
    /// Birthdays and other dates from Contacts over the days shown, from `contactDates` (nil
    /// reads none), among the events.
    public var contactDates: ContactDates?
    /// Today and the calendar of the last refresh.
    public private(set) var today = Days.absolute(Date(), calendar: .current)
    @ObservationIgnored private var calendar = Calendar.current

    private let workspace: WorkspaceModel
    @ObservationIgnored public let cache: AgendaSourceCache
    @ObservationIgnored private var generation = 0
    /// Called with each file's path before it is checked on disk. For tests.
    @ObservationIgnored var willStat: (@Sendable (String) -> Void)?

    public init(workspace: WorkspaceModel, cache: AgendaSourceCache = AgendaSourceCache()) {
        self.workspace = workspace
        self.cache = cache
    }

    /// Org files directly in each folder (or below it, with `includeSubfolders`), by path, as
    /// Emacs lists a directory in `org-agenda-files`.
    public var files: [String] {
        let paths = workspace.agendaFilePaths(list: agendaFiles, includeSubfolders: includeSubfolders)
        return hiddenFolders.isEmpty ? paths : paths.filter { !HiddenFolders.hides(hiddenFolders, path: $0) }
    }

    /// Recomputes the days. `open` is the open buffers' text by path.
    public func refresh(open: [String: String], now: Date = Date(), calendar: Calendar = .current) async {
        let interval = Perf.begin("agenda.refresh")
        defer { interval.end("\(files.count) files") }
        generation += 1
        let id = generation
        isComputing = true
        let today = Days.absolute(now, calendar: calendar)
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        let mode = self.mode
        let options = viewSettings[mode]?.apply(to: self.options, view: mode.viewKey) ?? self.options
        // What each view computes: the mode, its options, and for days the first and the span.
        var jobs: [(mode: AgendaMode, options: AgendaOptions, first: Int, span: Int, header: String)] = []
        if case .blocks(let blocks) = mode {
            for block in blocks {
                let (first, span) = shown(today: today, mode: block.mode, start: nil)
                jobs.append((block.mode, block.settings.apply(to: self.options, view: block.mode.viewKey), first, span, block.settings.header ?? block.mode.title))
            }
        } else {
            let (first, span) = shown(today: today)
            jobs.append((mode, options, first, span, ""))
        }
        let provider = calendarEvents
        let names = calendarNames
        let contacts = contactDates
        let all = await sources(open: open)
        let agendaEnd = jobs.filter { if case .agenda = $0.mode { true } else { false } }.map { $0.first + $0.span }.max()
        var reminders: [AgendaEvent] = []
        if let agendaEnd, let reminderLists {
            reminders = await reminderLists.reminders(before: Self.date(agendaEnd, calendar: calendar), chosen: reminderListNames, calendar: calendar)
        }
        let results = await Task.detached {
            jobs.map { job in
                var result = AgendaBlockResult(header: job.header, mode: job.mode)
                switch job.mode {
                case .agenda:
                    result.days = Agenda.list(all, start: job.first, days: job.span, today: today, now: (clock.hour ?? 0, clock.minute ?? 0), options: job.options)
                    if let provider {
                        let from = Self.date(job.first, calendar: calendar)
                        result.events = provider.events(from: from, to: Self.date(job.first + job.span, calendar: calendar), chosen: names)
                    }
                    result.events += reminders
                    if let contacts {
                        result.events += contacts.events(first: job.first, days: job.span, calendar: calendar)
                    }
                case .todo(let keywords):
                    result.list = Agenda.todoList(all, keywords: keywords, options: job.options, today: today)
                case .match(let match, let todoOnly):
                    result.list = Agenda.tagsMatch(all, match: match, todoOnly: todoOnly, now: now, calendar: calendar, options: job.options)
                case .search(let string, let todoOnly):
                    result.list = Agenda.textSearch(all, string: string, todoOnly: todoOnly, options: job.options)
                case .stuck(let definition):
                    result.list = Agenda.stuckProjects(all, definition ?? job.options.stuckProjects, now: now, calendar: calendar, options: job.options)
                case .query(let query, let sort):
                    result.list = Agenda.query(all, query: query, sort: sort, today: today, options: job.options) ?? []
                case .blocks:
                    break
                }
                return result
            }
        }.value
        guard id == generation else { return }
        // Unchanged results leave the views alone: a new value redraws the whole list.
        let isBlocks = { if case .blocks = mode { true } else { false } }()
        let single = isBlocks ? AgendaBlockResult(header: "", mode: mode) : results[0]
        let blocks = isBlocks ? results : []
        if days != single.days { days = single.days }
        if list != single.list { list = single.list }
        if events != single.events { events = single.events }
        if self.blocks != blocks { self.blocks = blocks }
        if self.today != today { self.today = today }
        if self.calendar != calendar { self.calendar = calendar }
        isComputing = false
    }

    /// Reminders for the timed entries of the next `days` days, each with the folder it is in.
    public func reminders(open: [String: String], now: Date = Date(), calendar: Calendar = .current, days: Int = 7, lead: Int = 12) async -> [Reminder] {
        let all = await sources(open: open)
        let roots = workspace.rootPaths
        return await Task.detached {
            Reminders.upcoming(all, now: now, calendar: calendar, days: days, lead: lead).map { reminder in
                var reminder = reminder
                reminder.folder = roots.first { HiddenFolders.hides([$0], path: reminder.path) }
                return reminder
            }
        }.value
    }

    /// The habits of the agenda files, file by file.
    public func habits(open: [String: String]) async -> [HabitSnapshot.Entry] {
        await sources(open: open).flatMap { source in
            source.habits.map {
                HabitSnapshot.Entry(title: $0.title, path: source.path, offset: $0.offset, headingLine: $0.line, doneKeyword: $0.doneKeyword, habit: $0.habit)
            }
        }
    }

    /// Entries for the table and kanban views, and the keywords their files use.
    public func board(open: [String: String], match: String) async -> (entries: [BoardEntry], keywords: [String]) {
        let all = await sources(open: open)
        return await Task.detached { (Board.entries(all, match: match), Board.keywords(all)) }.value
    }

    /// The agenda files' sources: the open file's from its text, the others from the cache
    /// while they and the settings are unchanged.
    private func sources(open: [String: String]) async -> [AgendaSource] {
        let interval = Perf.begin("agenda.sources")
        defer { interval.end("\(files.count) files") }
        let defaults = workspace.settings.org
        let blocking = options.dimBlockedTasks != .off && (options.enforceTodoDependencies || options.enforceTodoCheckboxDependencies)
        let files = files
        let (openCache, diskCache) = (cache.open, cache.entries)
        let willStat = willStat
        let loaded = await Task.detached {
            var sources: [(path: String, mtime: Date, size: Int, source: AgendaSource, fromDisk: Bool)] = []
            for path in files {
                if let text = open[path] {
                    // The same text parsed before, as the buffer or as the file on disk.
                    func reusable(_ source: AgendaSource?, _ parsedWith: OrgSettings?, _ parsedBlocking: Bool?) -> AgendaSource? {
                        guard let source, parsedWith == defaults, parsedBlocking == blocking, !source.readsSetupFiles, source.text == text else { return nil }
                        return source
                    }
                    let fromOpen = openCache[path]
                    let fromDisk = diskCache[path]
                    let cached = reusable(fromOpen?.source, fromOpen?.defaults, fromOpen?.blocking) ?? reusable(fromDisk?.source, fromDisk?.defaults, fromDisk?.blocking)
                    sources.append((path, .distantPast, -1, cached ?? AgendaSource(path: path, text: text, defaults: defaults.resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile), checksBlocking: blocking), false))
                    continue
                }
                willStat?(path)
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let mtime = attributes?[.modificationDate] as? Date ?? .distantPast
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
                // A file reading setup files is read again: they may have changed.
                let cached = diskCache[path].flatMap { entry in
                    entry.mtime == mtime && entry.size == size && entry.defaults == defaults && entry.blocking == blocking && !entry.source.readsSetupFiles ? entry.source : nil
                }
                if let cached {
                    sources.append((path, mtime, size, cached, true))
                } else if let data = FileManager.default.contents(atPath: path) {
                    let text = SourceText(bytes: [UInt8](data)).text
                    sources.append((path, mtime, size, AgendaSource(path: path, text: text, defaults: defaults.resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile), checksBlocking: blocking), true))
                }
            }
            return sources
        }.value
        for source in loaded {
            if source.fromDisk {
                cache.entries[source.path] = (source.mtime, source.size, defaults, blocking, source.source)
            } else {
                cache.open[source.path] = (defaults, blocking, source.source)
            }
        }
        var sources = loaded.map(\.source)
        if excludeArchives {
            let location = OrgPreferences.options().archiveLocation ?? "%s_archive::"
            let archives = Set(sources.flatMap { $0.archiveFiles(location: location) })
            sources.removeAll { archives.contains($0.path) }
        }
        return sources
    }

    /// The days as rows with the events, empty days hidden unless `showAllDates`; see
    /// `AgendaRows.groups`.
    public func groups(showAllDates: Bool = false, keep: (AgendaItem) -> Bool = { _ in true }) -> [AgendaDayGroup] {
        AgendaRows.groups(days, events: events, today: today, showAllDates: showAllDates, calendar: calendar, keep: keep)
    }

    /// A block's days as rows, as `groups` does for the view's.
    public func groups(_ block: AgendaBlockResult, showAllDates: Bool, filter: AgendaFilter) -> [AgendaDayGroup] {
        AgendaRows.groups(block.days, events: block.events, today: today, showAllDates: showAllDates, calendar: calendar, keep: filter.keeps)
    }

    /// `groups` with `filter`, kept while the days, events and arguments are the same, as
    /// views ask on every redraw.
    public func groups(showAllDates: Bool, filter: AgendaFilter) -> [AgendaDayGroup] {
        let key = GroupsKey(days: days, events: events, today: today, showAllDates: showAllDates, filter: filter)
        if let groupsMemo, groupsMemo.key == key { return groupsMemo.groups }
        let groups = groups(showAllDates: showAllDates, keep: filter.keeps)
        groupsMemo = (key, groups)
        return groups
    }

    private struct GroupsKey: Equatable {
        let days: [AgendaDay]
        let events: [AgendaEvent]
        let today: Int
        let showAllDates: Bool
        let filter: AgendaFilter
    }

    @ObservationIgnored private var groupsMemo: (key: GroupsKey, groups: [AgendaDayGroup])?

    nonisolated static func date(_ day: Int, calendar: Calendar) -> Date {
        let d = Days.date(day)
        return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) ?? Date()
    }

    public func showToday() { start = nil }

    /// The first day the agenda shows and how many, as `org-agenda-list` works them out: the
    /// view's span and start, or the settings', with 7- and 14-day spans moved back to
    /// `startOnWeekday`.
    public func shown(today: Int) -> (first: Int, span: Int) { shown(today: today, mode: mode, start: start) }

    /// `shown(today:)` for `mode`, from `start` when it isn't nil.
    func shown(today: Int, mode: AgendaMode, start: Int?) -> (first: Int, span: Int) {
        var span = self.span
        var startOffset = self.startOffset
        if case .agenda(let viewSpan, let viewStart) = mode {
            span = viewSpan ?? span
            startOffset = viewStart ?? startOffset
        }
        var first = start ?? today + startOffset
        if span == 7 || span == 14 { first = Days.weekStart(first, on: startOnWeekday) }
        return (first, span)
    }

    /// Moves the view by a whole span, forward or back.
    public func shift(forward: Bool, now: Date = Date(), calendar: Calendar = .current) {
        let (current, span) = shown(today: Days.absolute(now, calendar: calendar))
        start = current + (forward ? span : -span)
    }
}
