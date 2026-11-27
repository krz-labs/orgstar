import Foundation
import OrgCore
import OrgDocument
import OrgIndex

/// The calls a user command with `workspace = true` makes beyond its buffer: `org.search`,
/// `org.outlineOf`, `org.agenda` and `org.capture`. Reads never return text that is encrypted
/// on disk: `.gpg` files are refused or left out, buffers holding decrypted entries are read
/// from disk, and a search match in an encrypted entry has no snippet.
@MainActor
public struct UserCommandWorkspace {
    public let workspace: WorkspaceModel
    public let clock: ClockModel
    public var templates: () -> [CaptureTemplate] = { CaptureTemplates.load().templates }
    /// `%n` in capture templates.
    public var userName = ""
    public var now: () -> Date = Date.init
    public var calendar = Calendar.current

    /// The calls, by name, that need `workspace = true`.
    public static let calls: Set<String> = ["search", "outlineOf", "agenda", "capture"]
    /// The most `org.search` returns.
    public static let searchLimit = 50
    /// The most `org.agenda` returns, as many as the x-callback-url `agenda` action may.
    public static let agendaLimit = XCallbackRunner.maximumLimit
    /// The longest span `org.agenda` covers.
    public static let maximumDays = 366

    public init(workspace: WorkspaceModel, clock: ClockModel) {
        self.workspace = workspace
        self.clock = clock
    }

    public struct Failure: Error, Equatable {
        public let message: String
        init(_ message: String) { self.message = message }
    }

    /// The answer to `name`, one of `calls`, for a command running in `path`'s buffer.
    func answer(_ name: String, _ value: Any, session: DocumentSession, path: String) async throws(Failure) -> Any {
        switch name {
        case "search": return try await search(value, session: session)
        case "outlineOf": return try await outline(value, session: session)
        case "agenda": return try await agenda(value, session: session)
        case "capture": return try capture(value, session: session, path: path)
        default: throw Failure("No call \(name).")
        }
    }

    // MARK: - Search

    /// `{file, title, outline, start, heading, snippet}` for each match, best first: `outline`
    /// is the titles of the headings above it, `heading` false for a match in the text before
    /// a file's first heading (then `title` is the file's), `snippet` the text around the match
    /// or null.
    func search(_ value: Any, session: DocumentSession) async throws(Failure) -> Any {
        guard let query = value as? String else { throw Failure("org.search needs a query string.") }
        // Unsaved buffers are searched as they are, except those holding decrypted entries,
        // which are searched as they are on disk.
        let shown = session.openTexts
        let overlay = workspace.overlay(session.openDocuments.filter { shown[$0.path] != nil })
        let index = workspace.index
        let roots = workspace.rootPaths
        let limit = Self.searchLimit
        let found: [Match]
        do {
            found = try await Task.detached {
                try index.search(query, overlay: overlay, limit: limit).compactMap { location -> Match? in
                    guard !CryptVault.isEncryptedFile(location.path) else { return nil }
                    let body = try? index.text(of: location, overlay: overlay)
                    let encrypted = body?.contains("-----BEGIN PGP MESSAGE-----") == true
                    return Match(file: UserCommandFile.relativePath(location.path, roots: roots), title: location.title,
                                 outline: Array(location.outlinePath.dropLast()), start: location.start,
                                 heading: location.ordinal != HeadingLocation.fileOrdinal,
                                 snippet: encrypted ? nil : location.snippet?.text)
                }
            }.value
        } catch {
            throw Failure("Can't read the index: \(error.localizedDescription)")
        }
        return found.map { match -> [String: Any] in
            ["file": match.file, "title": match.title, "outline": match.outline, "start": match.start, "heading": match.heading,
             "snippet": match.snippet ?? NSNull()]
        }
    }

    struct Match: Sendable {
        let file: String
        let title: String
        let outline: [String]
        let start: Int
        let heading: Bool
        let snippet: String?
    }

    // MARK: - Outline of another file

    /// The headings of an org file in the folders, as `org.outline()` gives them: a path
    /// relative to a folder or absolute inside one, after symlinks are resolved.
    func outline(_ value: Any, session: DocumentSession) async throws(Failure) -> Any {
        guard let given = value as? String, !given.isEmpty else { throw Failure("org.outlineOf needs a path.") }
        guard let path = Self.resolve(given, roots: workspace.rootPaths) else { throw Failure("No file \(given) in orgstar's folders.") }
        guard !CryptVault.isEncryptedFile(path) else { throw Failure("\(given) is encrypted, so user commands can't read it.") }
        guard path.hasSuffix(".org") || path.hasSuffix(".org_archive") else { throw Failure("\(given) isn't an org file.") }
        let context: EditContext
        if session.refusesUserCommand(path) == nil, let document = session.document(of: path) {
            context = EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: [0..<0])
        } else {
            // Not open, or holding decrypted entries: what's on disk.
            let defaults = session.defaults
            guard let read = await Task.detached(operation: { () -> EditContext? in
                guard let data = FileManager.default.contents(atPath: path) else { return nil }
                let text = SourceText(bytes: [UInt8](data)).text
                return EditContext(revision: 0, text: text, tree: OrgParser.parse(text, defaults: defaults), selection: [0..<0])
            }).value else { throw Failure("Can't read \(given).") }
            context = read
        }
        return UserCommandAPI.answer("outline", NSNull(), context: context, file: nil) ?? []
    }

    /// `given` relative to the first folder that has it, or absolute (or `~/…`) inside one,
    /// when it is a file whose real path, symlinks resolved, is inside that folder's.
    nonisolated static func resolve(_ given: String, roots: [String]) -> String? {
        func real(_ path: String) -> String? {
            realpath(path, nil).map { defer { free($0) }; return String(cString: $0) }
        }
        let candidates = given.hasPrefix("/") || given.hasPrefix("~")
            ? [(OrgPaths.expandingTilde(given) as NSString).standardizingPath]
            : roots.map { ((($0 as NSString).appendingPathComponent(given)) as NSString).standardizingPath }
        for candidate in candidates {
            guard let file = real(candidate) else { continue }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file, isDirectory: &directory), !directory.boolValue else { continue }
            let inside = roots.contains { root in
                guard let root = real(root) else { return false }
                return file.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            if inside { return candidate }
        }
        return nil
    }

    // MARK: - Agenda

    /// The agenda's entries from `from` to `to` (`YYYY-MM-DD`, both included; today and `from`
    /// when not given), in the shape of the x-callback-url `agenda` action's.
    func agenda(_ value: Any, session: DocumentSession) async throws(Failure) -> Any {
        let options = value as? [String: Any] ?? [:]
        let today = Days.absolute(now(), calendar: calendar)
        func day(_ key: String) throws(Failure) -> Int? {
            guard let raw = options[key], !(raw is NSNull) else { return nil }
            guard let text = raw as? String, let day = Self.day(text) else { throw Failure("org.agenda: \(key) must be a date as YYYY-MM-DD.") }
            return day
        }
        let from = try day("from") ?? today
        let to = try day("to") ?? from
        guard to >= from else { throw Failure("org.agenda: to is before from.") }
        guard to - from < Self.maximumDays else { throw Failure("org.agenda: a span of at most \(Self.maximumDays) days.") }
        let model = AgendaModel(workspace: workspace)
        XCallbackRunner.configure(model)
        model.mode = .agenda(span: to - from + 1, startOffset: nil)
        model.start = from
        model.startOnWeekday = nil
        await model.refresh(open: session.openTexts, now: now(), calendar: calendar)
        let roots = workspace.rootPaths
        let entries = XCallbackRunner.entries(model, calendar: calendar) { UserCommandFile.relativePath($0, roots: roots) }
            .filter { $0.file.map { !CryptVault.isEncryptedFile($0) } ?? true }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(Array(entries.prefix(Self.agendaLimit))),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [Any]() }
        return json
    }

    /// The day `YYYY-MM-DD` names, as `Days` numbers it.
    nonisolated static func day(_ text: String) -> Int? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let absolute = Days.absolute(year: year, month: month, day: day)
        let back = Days.date(absolute)
        return back.month == month && back.day == day ? absolute : nil
    }

    // MARK: - Capture

    /// Files `text` with the template keyed `template`, without the capture window, as the
    /// x-callback-url `capture` action does: every prompt of the template must have an answer
    /// in `fields`, by its prompt text, or nothing is filed. `{template, file}` with the file
    /// relative to its folder.
    func capture(_ value: Any, session: DocumentSession, path: String) throws(Failure) -> Any {
        let options = value as? [String: Any] ?? [:]
        guard let key = options["template"] as? String, !key.isEmpty else { throw Failure("org.capture needs a template key.") }
        guard let text = options["text"] as? String else { throw Failure("org.capture needs the text to capture.") }
        var fields: [String: String] = [:]
        if let raw = options["fields"], !(raw is NSNull) {
            guard let given = raw as? [String: Any] else { throw Failure("org.capture: fields must be an object of strings.") }
            for (name, answer) in given {
                guard let answer = answer as? String else { throw Failure("org.capture: field \(name) must be a string.") }
                fields[name] = answer
            }
        }
        let templates = templates()
        guard let template = templates.first(where: { $0.key == key }) else { throw Failure("No capture template \"\(key)\".") }
        if template.options.denote || template.asksTreeDate {
            throw Failure("Template \"\(key)\" makes a Denote note or asks for a date tree's day, which needs the capture window.")
        }
        let missing = XCallbackRunner.unanswered(template, text: text, properties: [:], given: Set(fields.keys))
        guard missing.isEmpty else {
            throw Failure("Template \"\(key)\" asks for \(missing.joined(separator: ", ")); give \(missing.count == 1 ? "it" : "them") in fields.")
        }
        let target: String
        switch template.resolved(workspace: workspace, session: session, clock: clock) {
        case .failure(let error): throw Failure(error.message)
        case .success(let resolved): target = resolved.file ?? DocumentSession.resolve(resolved.template.target.file, root: workspace.rootPaths.first)
        }
        // Its own buffer changes only through the edits the command returns, as one undo step.
        let real = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        guard real(target) != real(path) else { throw Failure("org.capture can't file to the file the command runs in; return edits instead.") }
        switch session.capture(text, templateKey: key, templates: [template], workspace: workspace, clock: clock,
                               clipboard: "", userName: userName, answers: fields) {
        case .failure(let error): throw Failure(error.message)
        case .success(let placed):
            return ["template": key, "file": UserCommandFile.relativePath(placed.path, roots: workspace.rootPaths)]
        }
    }
}
