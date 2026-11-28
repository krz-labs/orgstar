import Foundation
import Observation
import OrgConfig
import OrgCore
import OrgDocument

/// Triage: captured entries one at a time, each scheduled, given a deadline, tagged, given a
/// TODO state, refiled, archived or deleted, then the next. The entries are those in the
/// default capture template's target, or those `triage-view` lists, as they were when the
/// queue was loaded. Actions run through `DocumentSession` as the agenda's do, so repeaters,
/// logging, TODO hooks and the editor's undo apply; `undo()` takes back the last one.
@MainActor
@Observable
public final class TriageModel {
    /// The queue, in order; entries before `position` are behind.
    public private(set) var items: [AgendaItem] = []
    public private(set) var position = 0
    /// What is being triaged: the target file and heading, or the view's name.
    public private(set) var title = ""
    /// Why there is nothing to triage, when something is wrong.
    public private(set) var problem: String?
    /// Entries skipped since loading because they changed elsewhere.
    public private(set) var skipped = 0
    public private(set) var isLoading = false

    public var current: AgendaItem? { position < items.count ? items[position] : nil }
    /// The entries left, the current one included.
    public var remaining: Int { max(0, items.count - position) }
    public var canUndo: Bool { last != nil }

    /// What an action changed: each file's text before and after, and the queue before.
    private struct Record {
        let files: [(path: String, before: String?, after: String?)]
        let items: [AgendaItem]
        let position: Int
    }

    private var last: Record?
    private let session: DocumentSession
    private let workspace: WorkspaceModel

    public init(session: DocumentSession, workspace: WorkspaceModel) {
        self.session = session
        self.workspace = workspace
    }

    // MARK: - The queue

    /// Loads the queue: the view `triage-view` names, from `views`, or else the first of
    /// `templates`' target. A view is computed with `agenda`'s files and settings.
    public func load(views: [AgendaViewDefinition], templates: [CaptureTemplate], agenda: AgendaModel, defaults: UserDefaults = .standard,
                     now: Date = Date()) async {
        (items, position, skipped, last, problem) = ([], 0, 0, nil, nil)
        isLoading = true
        defer { isLoading = false }
        let name = OrgPreferences.triageView(defaults)
        if !name.isEmpty {
            guard let view = views.first(where: { $0.name == name }) else {
                title = name
                problem = String(localized: "No view is named \(name); triage-view in config.toml names the view Triage goes through.")
                return
            }
            title = view.name
            items = await entries(of: view, views: views, like: agenda, now: now)
        } else {
            guard let template = templates.first else {
                problem = String(localized: "There is no capture template to triage.")
                return
            }
            guard let scope = TriageScope(template.target) else {
                title = template.name
                problem = String(localized: "The first capture template files to the running clock; set triage-view in config.toml to triage a view.")
                return
            }
            let path: String
            if case .id(let id) = template.target {
                guard let location = try? workspace.index.headings(withID: id).first else {
                    title = template.name
                    problem = String(localized: "Can't find the capture target ID \(id).")
                    return
                }
                path = location.path
            } else {
                path = DocumentSession.resolve(template.target.file, root: workspace.rootPaths.first)
            }
            title = Self.title(path: path, scope: scope)
            if let source = source(path) { items = Triage.entries(source, scope: scope, options: agenda.options) }
        }
        settle()
    }

    /// `path`, the target heading or outline path after it.
    static func title(path: String, scope: TriageScope) -> String {
        let name = (path as NSString).lastPathComponent
        switch scope {
        case .headline(let heading): return name + " ▸ " + heading
        case .outline(let path), .datetree(let path): return ([name] + path).joined(separator: " ▸ ")
        case .file, .id: return name
        }
    }

    /// The entries `view` lists, once each, in its order.
    private func entries(of view: AgendaViewDefinition, views: [AgendaViewDefinition], like agenda: AgendaModel, now: Date) async -> [AgendaItem] {
        let model = AgendaModel(workspace: workspace, cache: agenda.cache)
        model.mode = view.mode
        model.viewSettings = AgendaViewLoader.settings(views)
        model.span = agenda.span
        model.startOffset = agenda.startOffset
        model.startOnWeekday = agenda.startOnWeekday
        model.includeSubfolders = agenda.includeSubfolders
        model.excludeArchives = agenda.excludeArchives
        model.hiddenFolders = agenda.hiddenFolders
        model.agendaFiles = agenda.agendaFiles
        model.options = agenda.options
        model.options.logMode = false
        await model.refresh(open: session.openTexts, now: now)
        let all = model.list + model.days.flatMap(\.items) + model.blocks.flatMap { $0.list + $0.days.flatMap(\.items) }
        var seen: Set<String> = []
        return all.filter { item in
            guard let path = item.path, let offset = item.headingOffset, item.headingLine != nil else { return false }
            return seen.insert("\(offset):\(path)").inserted
        }
    }

    /// The file's entries as the agenda reads them, from its buffer when it is open.
    private func source(_ path: String) -> AgendaSource? {
        guard let text = session.text(of: path) else { return nil }
        let defaults = workspace.settings.org
        return AgendaSource(path: path, text: text, defaults: defaults.resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile), checksBlocking: false)
    }

    /// Drops the entries at `position` that changed elsewhere, so that the current one is
    /// where its heading line is now.
    private func settle() {
        while position < items.count {
            let item = items[position]
            if let path = item.path, let line = item.headingLine, let near = item.headingOffset,
               let offset = session.locateHeading(path: path, line: line, near: near) {
                if offset != near, let source = source(path), let moved = Triage.entry(source, at: offset) { items[position] = moved }
                return
            }
            items.remove(at: position)
            skipped += 1
        }
    }

    /// Moves to the next entry.
    public func next() {
        guard position < items.count else { return }
        position += 1
        settle()
    }

    /// The current entry's text under its heading line, from the file as it is now.
    public func body() -> String {
        guard let item = current, let path = item.path, let offset = item.headingOffset, let source = source(path) else { return "" }
        return Triage.body(source, at: offset) ?? ""
    }

    /// The TODO keywords of the current entry's file, active then done.
    public func keywords() -> [String] {
        guard let path = current?.path, let source = source(path) else { return [] }
        return Triage.keywords(source)
    }

    // MARK: - Actions

    /// Runs `command` at the current entry, as the agenda runs it. A prompt is for the caller
    /// to ask and run again with the answer; nothing has changed yet. The entry stays current
    /// with its new text.
    public func perform(_ command: any OrgCommand, answers: [String: String] = [:], now: Date = Date()) -> CommandStep {
        guard let item = current, let path = item.path else { return .failed(String(localized: "Nothing to triage.")) }
        // The heading starts where it was found; the command changes it in place.
        let start = item.headingLine.flatMap { session.locateHeading(path: path, line: $0, near: item.headingOffset ?? 0) }
        var step = CommandStep.failed("")
        let changed = record([path]) { step = session.perform(command, on: item, answers: answers, now: now) }
        if changed, let start, let source = source(path) {
            if let updated = Triage.entry(source, at: start) { items[position] = updated }
        } else if case .failed = step {
            settle()
        }
        return step
    }

    /// Schedules the current entry on `day` (as `Days` numbers it), or sets its deadline,
    /// keeping its time of day. `answers` answer the prompts it led to, such as a note.
    public func plan(day: Int, deadline: Bool, answers: [String: String] = [:], now: Date = Date()) -> CommandStep {
        let date = Days.date(day)
        let answers = answers.merging(["date": String(format: "%04d-%02d-%02d", date.year, date.month, date.day)]) { a, _ in a }
        return perform(SetPlanning(deadline: deadline, keepTime: true), answers: answers, now: now)
    }

    /// Refiles the current entry under the target labelled `label`, then moves on. Returns a
    /// message.
    @discardableResult
    public func refile(to label: String, now: Date = Date()) -> String? {
        guard let item = current, let path = item.path else { return nil }
        let targets = workspace.refileTargets(openPath: path, document: session.copy(of: path))
        guard let target = targets.first(where: { $0.label == label }) else { return String(localized: "Can't find \(label) any more.") }
        var message: String?
        let moved = record([path, target.path]) {
            message = session.refile(item, to: label, targets: { [workspace] path, document in workspace.refileTargets(openPath: path, document: document) }, now: now)
        }
        return finish(moved, message)
    }

    /// Archives the current entry where `org-archive-subtree` would, then moves on. Returns a
    /// message.
    @discardableResult
    public func archive(now: Date = Date()) -> String? {
        guard let item = current, let path = item.path, let line = item.headingLine, let near = item.headingOffset else { return nil }
        guard let offset = session.locateHeading(path: path, line: line, near: near) else { return finish(false, String(localized: "The entry changed elsewhere and was skipped.")) }
        var message: String?
        let paths = [path] + (session.archiveFile(from: (path, offset), now: now).map { [$0] } ?? [])
        let moved = record(paths) { message = session.archive(from: (path, offset), now: now) }
        return finish(moved, message)
    }

    /// Deletes the current entry and its subtree, as Cut Subtree does, then moves on.
    @discardableResult
    public func delete(now: Date = Date()) -> String? {
        guard let item = current, let path = item.path else { return nil }
        var step = CommandStep.failed("")
        let removed = record([path]) { step = session.perform(CopySubtree(cut: true), on: item, now: now) }
        if case .failed(let message) = step { return finish(false, message) }
        return finish(removed, String(localized: "Deleted"))
    }

    /// After an action that takes the entry out of the queue: moves on when it did.
    private func finish(_ done: Bool, _ message: String?) -> String? {
        if done {
            items.remove(at: position)
        }
        settle()
        return message
    }

    /// Runs `action`, keeping what it changed in `paths` for `undo()`. Whether it changed any.
    private func record(_ paths: [String], _ action: () -> Void) -> Bool {
        let paths = paths.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let before = paths.map { session.text(of: $0) }
        let queue = (items, position)
        action()
        let files = zip(paths, before).map { (path: $0, before: $1, after: session.text(of: $0)) }.filter { $0.before != $0.after }
        guard !files.isEmpty else { return false }
        last = Record(files: files, items: queue.0, position: queue.1)
        return true
    }

    /// Takes back the last action: each file it changed goes back to its text before, and
    /// the queue to where it was. Refused when one of the files has changed since. Returns a
    /// message.
    @discardableResult
    public func undo(now: Date = Date()) -> String? {
        guard let record = last else { return String(localized: "Nothing to undo") }
        for file in record.files where session.text(of: file.path) != file.after {
            return String(localized: "\((file.path as NSString).lastPathComponent) changed since, so the last action can't be undone.")
        }
        for file in record.files {
            guard let after = file.after else { continue }
            if let message = session.applyChanges(lineEdits(from: after, to: file.before ?? ""), to: file.path, expecting: after, now: now) { return message }
        }
        last = nil
        (items, position) = (record.items, record.position)
        settle()
        return String(localized: "Undone")
    }
}
