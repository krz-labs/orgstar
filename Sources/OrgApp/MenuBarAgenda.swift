import Foundation
import OrgCore
import OrgPresentation

/// What the Mac menu bar item shows: the running clock's title, and today's entries.
public enum MenuBarAgenda {
    /// `menu-bar-clock`: what the title shows beside the clock symbol while a clock runs.
    public enum ClockTitle: String, CaseIterable, Sendable {
        /// The time and the heading, as `org-clock-get-clock-string` gives them for the mode
        /// line: `[0:25] (Write the report)`.
        case heading
        /// The time since clocking in: `0:25`.
        case time
        /// The symbol only.
        case none
    }

    /// Characters of the heading the title shows before cutting it short with "…".
    public static let headingLimit = 30

    /// The title for `running` at `now`. With an Effort, `heading` shows the entry's clocked
    /// time (`effort.clocked`, from `ClockModel.effort`) plus this clock's over the Effort, as
    /// Org does: `[1:10/2:00] (Write the report)`.
    public static func clockTitle(_ running: ClockModel.Running, effort: (effort: Int, clocked: Int)?, style: ClockTitle, now: Date) -> String {
        func duration(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }
        let minutes = max(0, Int(now.timeIntervalSince(running.startedAt) / 60))
        switch style {
        case .none:
            return ""
        case .time:
            return duration(minutes)
        case .heading:
            let time = effort.map { "\(duration($0.clocked + minutes))/\(duration($0.effort))" } ?? duration(minutes)
            let heading = running.heading.count > headingLimit ? String(running.heading.prefix(headingLimit - 1)) + "…" : running.heading
            return "[\(time)] (\(heading))"
        }
    }

    /// An entry of today's agenda.
    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String
        /// `AgendaRow.gutter`: the time or a short status.
        public var gutter: String
        public var todo: String?
        public var title: String
        public var path: String?
        /// Where the heading started when the agenda was read.
        public var headingOffset: Int?
        public var headingLine: String?
        /// Where the entry's date is, for entries without a heading.
        public var markerOffset: Int?
        /// The keyword Mark Done sets.
        public var doneKeyword: String?
        public var isEvent: Bool

        public init(
            id: String, gutter: String, todo: String?, title: String, path: String?, headingOffset: Int?, headingLine: String?,
            markerOffset: Int?, doneKeyword: String?, isEvent: Bool
        ) {
            self.id = id
            self.gutter = gutter
            self.todo = todo
            self.title = title
            self.path = path
            self.headingOffset = headingOffset
            self.headingLine = headingLine
            self.markerOffset = markerOffset
            self.doneKeyword = doneKeyword
            self.isEvent = isEvent
        }

        /// The menu's line: the gutter, the keyword and the title.
        public var label: String { [gutter, todo ?? "", title].filter { !$0.isEmpty }.joined(separator: "  ") }

        public var link: AppLink? {
            guard let path, let offset = headingOffset ?? markerOffset else { return nil }
            return .entry(path: path, offset: offset)
        }

        /// An Org heading, not a calendar event, reminder or contact date.
        public var canClockIn: Bool { !isEvent && path != nil && headingOffset != nil && headingLine != nil }
        public var canBeDone: Bool { canClockIn && todo != nil && doneKeyword != nil }

        /// Whether the running clock's entry, found by `ClockModel.entry`, is this one.
        public func isClocked(_ clocked: (path: String, offset: Int)?) -> Bool {
            guard let clocked, let path, let headingOffset else { return false }
            return clocked.path == path && clocked.offset == headingOffset
        }
    }

    /// Today's entries that aren't done, overdue ones first.
    public static func today(_ groups: [AgendaDayGroup], today: Int) -> [Entry] {
        guard let group = groups.first(where: { $0.day == today }) else { return [] }
        return (group.overdue + group.rows).filter { !$0.isDone }.map { row in
            let item = row.item
            return Entry(
                id: row.id, gutter: row.gutter, todo: row.todo, title: row.title, path: item?.path, headingOffset: item?.headingOffset,
                headingLine: item?.headingLine, markerOffset: item?.markerOffset, doneKeyword: item?.doneKeyword, isEvent: row.isEvent
            )
        }
    }
}

/// The menu bar item's actions, which run without bringing orgstar forward: Mark Done and
/// Clock In as a notification's actions run them (`EntryActions`), Clock Out, and capture
/// without the capture window. Changed files are saved at once.
@MainActor
public struct MenuBarActions {
    public let workspace: WorkspaceModel
    public let session: DocumentSession
    public let clock: ClockModel
    public var templates: () -> [CaptureTemplate] = { CaptureTemplates.load().templates }
    /// `menu-bar-capture-template`.
    public var defaultTemplate: () -> String = { OrgPreferences.menuBarCaptureTemplate() }
    public var clipboard: () -> String = { "" }
    public var userName = ""

    public init(workspace: WorkspaceModel, session: DocumentSession, clock: ClockModel) {
        self.workspace = workspace
        self.session = session
        self.clock = clock
    }

    private var entries: EntryActions {
        let workspace = workspace
        return EntryActions(session: session, clock: clock, paths: { workspace.files.filter { $0.kind == .org }.map(\.path) })
    }

    /// Where the entry's heading is now, after other edits.
    private func locate(_ entry: MenuBarAgenda.Entry) -> (path: String, start: Int, line: String)? {
        guard let path = entry.path, let line = entry.headingLine, let near = entry.headingOffset,
              let start = session.locateHeading(path: path, line: line, near: near) else { return nil }
        return (path, start, line)
    }

    public func markDone(_ entry: MenuBarAgenda.Entry, now: Date = Date()) -> ReminderActionOutcome {
        guard let keyword = entry.doneKeyword, let path = entry.path, let line = entry.headingLine, let offset = entry.headingOffset else { return .notFound }
        let outcome = session.markDone(EntryDone(path: path, offset: offset, headingLine: line, keyword: keyword), now: now)
        entries.saveChanged()
        return outcome
    }

    public func clockIn(_ entry: MenuBarAgenda.Entry, now: Date = Date()) async -> ReminderActionOutcome {
        guard let found = locate(entry) else { return .notFound }
        let actions = entries
        let outcome = await actions.clockIn(path: found.path, at: found.start, now: now)
        actions.saveChanged()
        return outcome
    }

    /// `org-clock-out`; the message it gives.
    public func clockOut(now: Date = Date()) -> String {
        let message = clock.clockOut(session, now: now)
        entries.saveChanged()
        return message
    }

    /// What capturing from the menu came to.
    public enum CaptureOutcome: Equatable, Sendable {
        case filed(template: String, path: String)
        /// The capture window is needed, for the template with this key: the template has
        /// prompts, makes a Denote note or asks for a date tree's day, or there is no text.
        case window(template: String)
        case failed(String)
    }

    /// Files `text` with the template keyed `key`, else `menu-bar-capture-template`'s, else
    /// the first, running its `capture-before-finalize` hooks, as Shortcuts' Capture does.
    public func capture(_ text: String, template key: String? = nil) async -> CaptureOutcome {
        let templates = templates()
        let key = key ?? defaultTemplate()
        guard let template = key.isEmpty ? templates.first : templates.first(where: { $0.key == key }) else {
            return .failed("No capture template \"\(key)\"")
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || template.options.denote || template.asksTreeDate
            || !XCallbackRunner.unanswered(template, text: text, properties: [:], given: []).isEmpty {
            return .window(template: template.key)
        }
        let placed = await session.captureRunningHooks(
            text, templateKey: template.key, templates: templates, workspace: workspace, clock: clock, clipboard: clipboard(), userName: userName
        )
        entries.saveChanged()
        switch placed {
        case .failure(let error): return .failed(error.message)
        case .success(let placed): return .filed(template: placed.template.key, path: placed.path)
        }
    }
}
