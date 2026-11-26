import Foundation
import OrgCore

/// An org-roam capture template, from `capture.toml`:
///
/// ```toml
/// [[roam-template]]            # org-roam-capture-templates
/// key = "d"
/// name = "default"
/// type = "plain"               # as for [[template]]; plain unless set
/// template = "%?"
/// file = "%<%Y%m%d%H%M%S>-${slug}.org"
/// head = "#+title: ${title}\n"
/// olp = "Projects/Active"      # file+head+olp; the headings are made when missing
/// ```
///
/// `[[roam-dailies-template]]` (`org-roam-dailies-capture-templates`) is the same, an `entry`
/// unless set, with `file` in the daily-notes folder; `[[roam-ref-template]]`
/// (`org-roam-capture-ref-templates`) is for org-protocol's `roam-ref`. `${title}`, `${slug}`
/// and `${id}` fill in the node's title, slug and ID, and for a ref, `${ref}` and `${body}`.
/// The other properties of `[[template]]` apply.
public struct RoamTemplate: Sendable, Equatable {
    public enum Set: String, Sendable {
        case node = "roam-template", dailies = "roam-dailies-template", ref = "roam-ref-template"
    }

    public var key: String
    public var name: String
    public var kind: CaptureTemplate.Kind
    public var template: String
    public var file: String
    public var head: String
    public var olp: [String]
    public var options: CaptureTemplate.Options

    public init(key: String, name: String, kind: CaptureTemplate.Kind, template: String, file: String, head: String, olp: [String] = [],
                options: CaptureTemplate.Options = CaptureTemplate.Options()) {
        self.key = key
        self.name = name
        self.kind = kind
        self.template = template
        self.file = file
        self.head = head
        self.olp = olp
        self.options = options
    }

    /// org-roam's defaults; for daily notes, the `org-roam-dailies-…` settings.
    public static func defaults(_ set: Set, defaults: UserDefaults = .standard) -> [RoamTemplate] {
        switch set {
        case .node: [RoamTemplate(key: "d", name: "default", kind: .plain, template: "%?", file: "%<%Y%m%d%H%M%S>-${slug}.org", head: "#+title: ${title}\n")]
        case .dailies: [RoamTemplate(key: "d", name: "default", kind: .entry, template: OrgPreferences.dailiesEntry(defaults),
                                     file: OrgPreferences.dailiesFile(defaults), head: OrgPreferences.dailiesHead(defaults))]
        case .ref: [RoamTemplate(key: "r", name: "ref", kind: .plain, template: "%?", file: "${slug}.org", head: "#+title: ${title}")]
        }
    }

    /// The set's templates in `capture.toml`, or the defaults when it has none, and what was
    /// wrong with the tables left out.
    public static func load(_ set: Set, userFile: URL = UserConfig.file("capture.toml"), defaults: UserDefaults = .standard) -> (templates: [RoamTemplate], problems: [String]) {
        guard let text = try? String(contentsOf: userFile, encoding: .utf8), let tables = try? TOML.parse(text) else { return (Self.defaults(set, defaults: defaults), []) }
        var templates: [RoamTemplate] = [], problems: [String] = []
        let fallback = Self.defaults(set, defaults: defaults)[0]
        for table in tables where table.name == set.rawValue {
            let values = table.values
            guard let key = values["key"]?.string, !key.isEmpty, let body = values["template"]?.string else {
                problems.append("capture.toml line \(table.line): a [[\(set.rawValue)]] needs key and template")
                continue
            }
            guard let kind = CaptureTemplate.Kind(rawValue: values["type"]?.string ?? fallback.kind.rawValue) else {
                problems.append("capture.toml line \(table.line): unknown type")
                continue
            }
            templates.append(RoamTemplate(
                key: key, name: values["name"]?.string ?? key, kind: kind, template: body, file: values["file"]?.string ?? fallback.file,
                head: values["head"]?.string ?? (values["file"] == nil ? fallback.head : ""),
                olp: values["olp"]?.string.map { $0.split(separator: "/").map(String.init) } ?? [], options: CaptureTemplates.options(values)))
        }
        return (templates.isEmpty ? Self.defaults(set, defaults: defaults) : templates, problems)
    }

    /// `org-roam-format-template`: `${name}` for each field there is a value for.
    static func fill(_ text: String, _ fields: [String: String]) -> String {
        text.replacing(/\$\{([^}:]+)(?::[^}]*)?\}/) { match in fields[String(match.1)] ?? String(match.0) }
    }
}

/// An org-roam capture (`org-roam-capture-`) waiting for the capture window: the templates to
/// choose from, each aimed at its file. Filing makes the file when it's new, with the head and
/// an `ID`, or gives an existing one an `ID` when it has none, then places the entry as
/// `org-capture` does and calls back with the node's ID.
@MainActor
public final class RoamCapture: Identifiable {
    public let templates: [CaptureTemplate]
    /// The date the templates' escapes use: a daily note's day, else when capture began.
    public let now: Date
    /// Each template's head, filled in, by key.
    let heads: [String: String]
    /// Put in a new file's property drawer after the ID: a ref capture's `ROAM_REFS`.
    let properties: [(key: String, value: String)]
    let session: DocumentSession
    let refresh: () -> Void
    let filed: (_ path: String, _ offset: Int, _ id: String) -> Void
    /// A new file's ID.
    let newID: String
    /// Whether the file gets an `ID`; not for a Denote journal entry.
    let ids: Bool

    /// `templates` filled in for a node titled `title`, their files under `directory`.
    public init(
        _ templates: [RoamTemplate], title: String, directory: String, now: Date = Date(), fields: [String: String] = [:],
        properties: [(key: String, value: String)] = [], ids: Bool = true, session: DocumentSession, refresh: @escaping () -> Void,
        newID: String = UUID().uuidString.lowercased(), filed: @escaping (_ path: String, _ offset: Int, _ id: String) -> Void
    ) {
        let fields = ["title": title, "slug": RoamNode.slug(title), "id": newID].merging(fields) { $1 }
        var context = CaptureContext(now: now, userName: NSFullUserName())
        context.readsTemplateFiles()
        var heads: [String: String] = [:]
        self.templates = templates.map { template in
            let name = Dailies.expandTime(RoamTemplate.fill(template.file, fields), now).trimmingCharacters(in: .whitespaces)
            let path = OrgAttach.expand(name, in: directory)
            let head = RoamTemplate.fill(template.head, fields)
            if case .success(let filled) = Capture.fill(head, context: context) { heads[template.key] = filled.text } else { heads[template.key] = Dailies.expandTime(head, now) }
            return CaptureTemplate(key: template.key, name: template.name, kind: template.kind,
                                   target: template.olp.isEmpty ? .file(path) : .outline(file: path, path: template.olp),
                                   template: RoamTemplate.fill(template.template, fields), options: template.options)
        }
        self.now = now
        self.heads = heads
        self.properties = properties
        self.session = session
        self.refresh = refresh
        self.newID = newID
        self.ids = ids
        self.filed = filed
    }

    /// The template's file: `head` filled in at the top of a new file.
    public func isNew(_ template: CaptureTemplate) -> Bool {
        !session.isOpen(template.target.file) && !FileManager.default.fileExists(atPath: template.target.file)
    }

    /// Files `text`, the capture window's text, with `template`.
    public func file(_ text: String, with template: CaptureTemplate) -> Result<(path: String, offset: Int), CaptureError> {
        let path = template.target.file
        var olp: [String] = []
        if case .outline(_, let path) = template.target { olp = path }
        let created = isNew(template)
        let id: String
        if created {
            var head = heads[template.key] ?? ""
            if !head.isEmpty, !head.hasSuffix("\n") { head += "\n" }
            let prepared = ids ? RoamTarget.prepare(head, properties: properties, olp: olp) { newID } : (text: head, id: "")
            do {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data(prepared.text.utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            } catch {
                return .failure(CaptureError(message: "Can't make \((path as NSString).lastPathComponent): \(error.localizedDescription)"))
            }
            id = prepared.id
        } else {
            guard let text = session.text(of: path) else { return .failure(CaptureError(message: "Can't read \((path as NSString).lastPathComponent)")) }
            let prepared = ids ? RoamTarget.prepare(text, olp: olp) { newID } : (text: text, id: "")
            if prepared.text != text, case .failed(let message) = session.perform(ReplaceText(old: text, new: prepared.text), path: path, at: 0, expect: nil) {
                return .failure(CaptureError(message: message))
            }
            id = prepared.id
        }
        let placed = session.capture(text, template: template, root: nil, file: path, now: now)
        if case .success(let entry) = placed {
            if created { refresh() }
            filed(entry.path, entry.offset, id)
        }
        return placed
    }

    /// Files the first template's text with its questions unanswered, without the capture
    /// window.
    public func fileFirst() -> Result<(path: String, offset: Int), CaptureError> {
        guard let template = templates.first else { return .failure(CaptureError(message: "No template")) }
        var context = CaptureContext(now: now, userName: NSFullUserName())
        context.readsTemplateFiles()
        let answers = Capture.questions(template.template, context: context).map { _ in "" }
        switch Capture.fill(template.template, context: context, answers: answers) {
        case .success(let filled): return file(filled.text, with: template)
        case .failure(.message(let message)): return .failure(CaptureError(message: message))
        }
    }
}
