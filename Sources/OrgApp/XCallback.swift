import Foundation
import Observation
import OrgCore
import OrgPresentation

/// An x-callback-url 1.0 request on the app's scheme:
/// `orgstar://x-callback-url/<action>?…&x-success=…&x-error=…&x-cancel=…&x-source=…`.
public struct XCallbackRequest: Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        case capture, open, agenda
        case clockIn = "clock-in"
        case clockOut = "clock-out"
        case clockStatus = "clock-status"
    }

    public static let host = "x-callback-url"

    /// The path after the host, as given.
    public let action: String
    /// The query's parameters other than the `x-` ones; the first of repeated names wins.
    public let parameters: [String: String]
    public let success: URL?
    public let failure: URL?
    public let cancel: URL?
    /// `x-source`: the calling app's name, as it gives it.
    public let source: String?

    public init?(url: URL) {
        guard url.scheme?.lowercased() == AppLink.scheme, url.host?.lowercased() == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        action = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] where parameters[item.name] == nil {
            parameters[item.name] = item.value ?? ""
        }
        func callback(_ name: String) -> URL? {
            parameters.removeValue(forKey: name).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        }
        success = callback("x-success")
        failure = callback("x-error")
        cancel = callback("x-cancel")
        source = parameters.removeValue(forKey: "x-source").flatMap { $0.isEmpty ? nil : $0 }
        self.parameters = parameters
    }

    public var known: Action? { Action(rawValue: action) }

    /// A parameter, nil when missing or empty.
    public func value(_ name: String) -> String? {
        parameters[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The URL to open for `reply`: its callback with the reply's parameters added; nil when the
    /// request gave none or its scheme is refused (`XCallback.allows`).
    public func callbackURL(for reply: XCallbackReply) -> URL? {
        let url: URL?
        switch reply {
        case .success(let parameters): url = success.flatMap { XCallback.url($0, adding: parameters) }
        case .failure(let code, let message): url = failure.flatMap { XCallback.url($0, adding: ["errorCode": code, "errorMessage": message]) }
        case .cancel: url = cancel
        }
        return url.flatMap { XCallback.allows($0) ? $0 : nil }
    }

    /// Who an approval is for: the name the request gives and the schemes its callbacks open.
    public var approvalSource: XCallbackApprovals.Source {
        let schemes = Set([success, failure, cancel].compactMap { $0?.scheme?.lowercased() })
        return XCallbackApprovals.Source(name: source ?? "", schemes: schemes.sorted())
    }
}

/// What an action ends with.
public enum XCallbackReply: Equatable, Sendable {
    /// For `x-success`, with the result's parameters.
    case success([String: String])
    /// For `x-error`, as `errorCode` and `errorMessage`.
    case failure(code: String, message: String)
    /// For `x-cancel`.
    case cancel

    public static func failure(_ code: XCallback.ErrorCode, _ message: String) -> XCallbackReply {
        .failure(code: code.rawValue, message: message)
    }
}

public enum XCallback {
    public enum ErrorCode: String, Sendable {
        case unknownAction = "unknown-action"
        case missingParameter = "missing-parameter"
        case invalidParameter = "invalid-parameter"
        case notFound = "not-found"
        case captureFailed = "capture-failed"
        case clockFailed = "clock-failed"
        case noClock = "no-clock"
        case notAllowed = "not-allowed"
        case needsPro = "needs-orgstar-plus"
        case notReady = "not-ready"
    }

    /// Callback schemes never opened: the app's own (a loop), org-protocol (it would capture),
    /// and web and file URLs, which would hand results to a web server or download a file.
    public static let refusedSchemes: Set<String> = ["orgstar", "org-protocol", "http", "https", "file", "ftp", "javascript", "data", "about", "blob"]

    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !refusedSchemes.contains(scheme)
    }

    /// Characters left as they are in a query value: `&`, `=`, `+`, `?`, `#` and `/` are encoded.
    static let valueCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    /// `base` with `parameters` added to its query, after any it has, in name order.
    public static func url(_ base: URL, adding parameters: [String: String]) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let added = parameters.sorted { $0.key < $1.key }.map { name, value in
            URLQueryItem(name: name.addingPercentEncoding(withAllowedCharacters: valueCharacters) ?? name,
                         value: value.addingPercentEncoding(withAllowedCharacters: valueCharacters) ?? value)
        }
        guard !added.isEmpty else { return base }
        components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? []) + added
        return components.url
    }
}

/// The apps allowed to capture, clock and read the agenda and clock through x-callback-url
/// links, kept on the device. An app is the name it gives in `x-source` with the schemes its
/// callbacks open, so a link that names an allowed app but sends results elsewhere asks again.
@MainActor
@Observable
public final class XCallbackApprovals {
    public static let shared = XCallbackApprovals()
    static let key = "xCallbackApprovals"

    public struct Source: Codable, Hashable, Sendable, Identifiable {
        public let name: String
        public let schemes: [String]
        public var id: String { ([name] + schemes).joined(separator: "\u{0}") }

        public init(name: String, schemes: [String]) {
            self.name = name
            self.schemes = schemes
        }
    }

    public private(set) var sources: [Source] = []
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Source].self, from: data) { sources = saved }
    }

    public func allows(_ source: Source) -> Bool { sources.contains(source) }

    public func allow(_ source: Source) {
        guard !allows(source) else { return }
        sources.append(source)
        save()
    }

    public func forget(_ source: Source) {
        sources.removeAll { $0 == source }
        save()
    }

    private func save() {
        if sources.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// Runs x-callback-url actions against the app's models. What needs the app (a sheet, a
/// question, showing a file) comes back as a step for it to take.
@MainActor
public struct XCallbackRunner {
    public let workspace: WorkspaceModel
    public let session: DocumentSession
    public let clock: ClockModel
    public var approvals: XCallbackApprovals
    public var templates: () -> [CaptureTemplate] = { CaptureTemplates.load().templates }
    public var views: () -> [AgendaViewDefinition] = { AgendaViewLoader.load().views }
    public var isUnlocked: () -> Bool = { ProAccess.shared.isUnlocked }
    /// `%c` and `%n` for captures without the sheet.
    public var clipboard: () -> String = { "" }
    public var userName = ""
    public var now: () -> Date = Date.init
    public var calendar = Calendar.current

    /// Agenda entries returned when the request sets no `limit`, and the most it may set.
    public static let defaultLimit = 50
    public static let maximumLimit = 200

    public init(workspace: WorkspaceModel, session: DocumentSession, clock: ClockModel, approvals: XCallbackApprovals = .shared) {
        self.workspace = workspace
        self.session = session
        self.clock = clock
        self.approvals = approvals
    }

    public enum Step: Equatable {
        /// Open the reply's callback, if any.
        case reply(XCallbackReply)
        /// Ask whether the request's source may write to files and read them through links;
        /// then `allow` and run again, or reply `notAllowed`.
        case approve(XCallbackApprovals.Source)
        /// Show the capture sheet or window with this template (nil for the list) and link
        /// properties; reply with `captured` when it files, `.cancel` when it is dismissed.
        case capture(template: String?, properties: [String: String])
        /// Show the entry, then reply.
        case open(path: String, offset: Int, reply: XCallbackReply)
    }

    public func run(_ request: XCallbackRequest, ask: @escaping ClockModel.Ask = { _ in nil }) async -> Step {
        guard let action = request.known else {
            return .reply(.failure(.unknownAction, "Unknown action \"\(request.action)\""))
        }
        // Capture and open show what they do; the others write to files or send what they hold
        // to the caller without showing anything.
        let interactive: Bool
        switch action {
        case .open: interactive = true
        case .capture: interactive = captureNeedsSheet(request)
        case .agenda, .clockIn, .clockOut, .clockStatus: interactive = false
        }
        if !interactive {
            guard isUnlocked() else { return .reply(.failure(.needsPro, "x-callback-url actions need orgstar+")) }
            guard approvals.allows(request.approvalSource) else { return .approve(request.approvalSource) }
        }
        // A link that launched the app can come before the folders were first read.
        if workspace.files.isEmpty { await workspace.refresh() }
        switch action {
        case .capture: return capture(request, sheet: interactive)
        case .open: return open(request)
        case .agenda: return .reply(await agenda(request))
        case .clockIn: return .reply(await clockIn(request, ask: ask))
        case .clockOut: return .reply(clockOut())
        case .clockStatus: return .reply(.success(clockStatus()))
        }
    }

    // MARK: - Capture

    /// The template a capture names, its link properties and its text as org-protocol gives
    /// them: `%a`, `%i`, `%:link`, `%:description`.
    static func properties(_ request: XCallbackRequest) -> [String: String] {
        let link = OrgProtocol.captureURL(template: nil, url: request.value("url"), title: request.value("title") ?? "", body: request.value("text") ?? "")
        guard case .capture(_, let properties)? = OrgProtocol.parse(link) else { return [:] }
        return properties
    }

    static let reservedCaptureParameters: Set<String> = ["template", "text", "url", "title"]

    /// Without the sheet only when the template and text are given and every prompt in the
    /// template has a parameter named for it; templates that make a Denote note or ask for a
    /// date tree's day always show it.
    func captureNeedsSheet(_ request: XCallbackRequest) -> Bool {
        guard let key = request.value("template"), let text = request.parameters["text"],
              let template = templates().first(where: { $0.key == key }) else { return true }
        if template.options.denote || template.asksTreeDate { return true }
        return !Self.unanswered(template, text: text, properties: Self.properties(request), given: Set(request.parameters.keys)).isEmpty
    }

    /// The prompts of `template` that `given` has no answer for, by prompt text, in order.
    static func unanswered(_ template: CaptureTemplate, text: String, properties: [String: String], given: Set<String>) -> [String] {
        var context = CaptureContext(initial: text)
        context.linkProperties = properties
        return Capture.questions(template.template, context: context).compactMap { question in
            if case .clipboard = question.kind { return nil }
            return given.contains(question.prompt) ? nil : question.prompt
        }
    }

    private func capture(_ request: XCallbackRequest, sheet: Bool) -> Step {
        let properties = Self.properties(request)
        if sheet { return .capture(template: request.value("template"), properties: properties) }
        var answers = request.parameters
        for name in Self.reservedCaptureParameters { answers[name] = nil }
        let placed = session.capture(
            request.parameters["text"] ?? "", templateKey: request.value("template"), templates: templates(), workspace: workspace, clock: clock,
            clipboard: clipboard(), userName: userName, answers: answers, properties: properties
        )
        switch placed {
        case .failure(let error): return .reply(.failure(.captureFailed, error.message))
        case .success(let placed): return .reply(captured(placed.template, path: placed.path))
        }
    }

    /// The reply to a capture filed from the sheet or without it.
    public func captured(_ template: CaptureTemplate, path: String) -> XCallbackReply {
        .success(["template": template.key, "file": relative(path)])
    }

    // MARK: - Open

    private func open(_ request: XCallbackRequest) -> Step {
        switch target(request) {
        case .failed(let reply): return .reply(reply)
        case .none: return .reply(.failure(.missingParameter, "Give file or id"))
        case .found(let path, let offset): return .open(path: path, offset: offset, reply: .success(["file": relative(path)]))
        }
    }

    /// The heading with `id`, or the file `file` (relative to a folder, or absolute inside one)
    /// and in it the first heading titled `heading`.
    func target(_ request: XCallbackRequest) -> Target {
        if let id = request.value("id") {
            guard let location = try? workspace.index.headings(withID: id).first else { return .failed(.failure(.notFound, "No heading with ID \"\(id)\"")) }
            return .found(path: location.path, offset: location.start)
        }
        guard let file = request.value("file") else { return .none }
        guard let path = resolve(file) else { return .failed(.failure(.notFound, "No file \"\(file)\" in orgstar's folders")) }
        guard let heading = request.value("heading") else { return .found(path: path, offset: 0) }
        guard let text = session.text(of: path),
              let found = DocumentModel(tree: OrgParser.parse(text)).headings.first(where: { $0.title == heading }) else {
            return .failed(.failure(.notFound, "No heading \"\(heading)\" in \(file)"))
        }
        return .found(path: path, offset: found.headingRange.lowerBound)
    }

    enum Target: Equatable {
        case found(path: String, offset: Int)
        /// The request names no entry.
        case none
        case failed(XCallbackReply)
    }

    /// A path relative to one of the folders, the first that has it, or an absolute path inside
    /// one; nil for anything else.
    func resolve(_ file: String) -> String? {
        let roots = workspace.rootPaths
        if file.hasPrefix("/") || file.hasPrefix("~") {
            let path = (OrgPaths.expandingTilde(file) as NSString).standardizingPath
            return roots.contains(where: { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) && exists(path) ? path : nil
        }
        for root in roots {
            let path = ((root as NSString).appendingPathComponent(file) as NSString).standardizingPath
            if path.hasPrefix(root.hasSuffix("/") ? root : root + "/"), exists(path) { return path }
        }
        return nil
    }

    private func exists(_ path: String) -> Bool {
        session.isOpen(path) || FileManager.default.fileExists(atPath: path)
    }

    /// `path` relative to the first folder holding it, or as it is.
    func relative(_ path: String) -> String {
        // `/tmp` and `/private/tmp` are one folder.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for root in workspace.rootPaths {
            for (path, root) in [(path, root), (resolved, URL(fileURLWithPath: root).resolvingSymlinksInPath().path)] {
                let prefix = root.hasSuffix("/") ? root : root + "/"
                if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
            }
        }
        return path
    }

    // MARK: - Agenda

    /// One agenda line as the `result` JSON gives it.
    struct Entry: Encodable, Equatable {
        var section: String?
        var date: String?
        var time: String?
        var end: String?
        var kind: String?
        var status: String
        var todo: String?
        var priority: String?
        var title: String
        var tags: [String]?
        var category: String
        var file: String?
    }

    private func agenda(_ request: XCallbackRequest) async -> XCallbackReply {
        let name = request.value("view") ?? AgendaViewLoader.builtIn[0].name
        let views = views()
        guard let view = views.first(where: { $0.name == name }) ?? views.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            return .failure(.notFound, "No agenda view \"\(name)\"")
        }
        var limit = Self.defaultLimit
        if let given = request.value("limit") {
            guard let number = Int(given), number > 0 else { return .failure(.invalidParameter, "limit must be a number above 0") }
            limit = min(number, Self.maximumLimit)
        }
        let model = AgendaModel(workspace: workspace)
        model.viewSettings = AgendaViewLoader.settings(views)
        model.mode = view.mode
        Self.configure(model)
        await model.refresh(open: session.openTexts, now: now(), calendar: calendar)
        let entries = entries(model)
        let kept = Array(entries.prefix(limit))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(kept)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return .success(["view": view.name, "result": json, "count": String(kept.count), "total": String(entries.count)])
    }

    /// The agenda settings of the app's preferences.
    static func configure(_ model: AgendaModel) {
        model.span = OrgPreferences.agendaSpan()
        model.startOffset = OrgPreferences.agendaStartOffset()
        model.startOnWeekday = OrgPreferences.agendaStartOnWeekday()
        model.includeSubfolders = OrgPreferences.agendaSubfolders()
        model.excludeArchives = OrgPreferences.agendaExcludeArchives()
        model.hiddenFolders = HiddenFolders.shared.all
        model.agendaFiles = OrgPreferences.agendaFiles()
        model.options = OrgPreferences.agendaOptions(model.options)
    }

    /// The view's lines, in order: each day's overdue entries and then its rows, or the list.
    func entries(_ model: AgendaModel) -> [Entry] {
        Self.entries(model, calendar: calendar, relative: relative)
    }

    /// `entries(_:)` with files named by `relative`.
    static func entries(_ model: AgendaModel, calendar: Calendar, relative: (String) -> String) -> [Entry] {
        let today = model.today
        func make(_ results: [(header: String?, days: [AgendaDay], list: [AgendaItem])]) -> [Entry] {
            results.flatMap { result -> [Entry] in
                let days = AgendaRows.groups(result.days, today: today, calendar: calendar).flatMap { group in
                    (group.overdue + group.rows).map { Self.line($0, day: group.day, section: result.header, relative: relative) }
                }
                let list = result.list.compactMap { AgendaRow(item: $0, day: today, today: today) }.map { Self.line($0, day: nil, section: result.header, relative: relative) }
                return days + list
            }
        }
        if case .blocks = model.mode {
            return make(model.blocks.map { ($0.header, $0.days, $0.list) })
        }
        return make([(nil, model.days, model.list)])
    }

    private static func line(_ row: AgendaRow, day: Int?, section: String?, relative: (String) -> String) -> Entry {
        func date(_ day: Int) -> String {
            let d = Days.date(day)
            return String(format: "%04d-%02d-%02d", d.year, d.month, d.day)
        }
        func time(_ hhmm: Int?) -> String? { hhmm.map { String(format: "%02d:%02d", $0 / 100, $0 % 100) } }
        return Entry(
            section: section, date: day.map(date), time: time(row.start), end: time(row.end), kind: row.icon?.rawValue, status: row.status.rawValue,
            todo: row.todo, priority: row.priority, title: row.title, tags: row.tags.isEmpty ? nil : row.tags, category: row.category,
            file: row.item?.path.map(relative)
        )
    }

    // MARK: - Clock

    private func clockIn(_ request: XCallbackRequest, ask: @escaping ClockModel.Ask) async -> XCallbackReply {
        let target: ClockModel.Target
        switch self.target(request) {
        case .failed(let reply): return reply
        case .found(let path, let offset): target = .entry(path: path, offset: offset)
        case .none: target = .last
        }
        let paths = workspace.files.filter { $0.kind == .org }.map(\.path)
        let outcome = await clock.clockIn(session, target: target, paths: paths, ask: ask, now: now)
        if let running = clock.running {
            if case .entry(let path, _) = target, running.path != path {
                return .failure(.clockFailed, outcome.messages.last ?? "Can't clock in there")
            }
            return .success(clockStatus())
        }
        return .failure(.clockFailed, outcome.messages.last ?? "Can't clock in there")
    }

    private func clockOut() -> XCallbackReply {
        guard let running = clock.running else { return .failure(.noClock, "No active clock") }
        let stopped = now()
        let message = clock.clockOut(session, now: stopped)
        guard clock.running == nil else { return .failure(.clockFailed, message) }
        return .success([
            "heading": running.heading, "file": relative(running.path),
            "minutes": String(max(0, Int(stopped.timeIntervalSince(running.startedAt) / 60))),
        ])
    }

    func clockStatus() -> [String: String] {
        guard let running = clock.running else { return ["running": "false"] }
        return [
            "running": "true", "heading": running.heading, "file": relative(running.path),
            "started": ISO8601DateFormatter().string(from: running.startedAt),
            "minutes": String(max(0, Int(now().timeIntervalSince(running.startedAt) / 60))),
        ]
    }
}
