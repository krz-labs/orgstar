import Foundation
import OrgCore

/// Capture templates from `capture.toml`, and capturing into their targets:
///
/// ```toml
/// [[template]]
/// key = "t"
/// name = "Personal todo"
/// type = "entry"            # entry, item, checkitem, plain or table-line
/// file = "todo.org"         # relative to the first folder, or ~/… or /…
/// headline = "Inbox"        # or olp = "Projects/Work"; neither for the end of the file
/// template = "* TODO %?\n%i\n%a"
/// prepend = false
/// ```
///
/// Other targets: `datetree = true` (under `olp` if given; `tree-type` "day", "week",
/// "month", or groups such as "year quarter month"), `regexp = "…"` with `file`,
/// `id = "…"` without `file`, `clock = true` without `file`. Other properties, as in
/// `org-capture-templates`: `immediate-finish`, `empty-lines`, `empty-lines-before`,
/// `empty-lines-after`, `jump-to-captured`, `clock-in`, `clock-keep`, `clock-resume`,
/// `table-line-pos`, `time-prompt`.
///
/// A `[[template]]` with only `key` and `name` is a group: the templates whose keys start
/// with its key are listed under it.
@MainActor
public enum CaptureTemplates {
    public static var userFile: URL { UserConfig.file("capture.toml") }

    /// The tables `RoamTemplate` reads.
    static let roamTables: Set<String> = ["roam-template", "roam-dailies-template", "roam-ref-template"]

    /// The templates in your Doom configuration.
    public static let defaults = [
        CaptureTemplate(key: "t", name: "Personal todo", target: .headline(file: "todo.org", headline: "Inbox"), template: "* TODO %?\n%i\n%a"),
        CaptureTemplate(key: "n", name: "Personal notes", target: .headline(file: "notes.org", headline: "Inbox"), template: "* %u %?\n%i\n%a"),
    ]

    public static func load(userFile: URL = userFile) -> (templates: [CaptureTemplate], groups: [CaptureGroup], problems: [String]) {
        guard let text = try? String(contentsOf: userFile, encoding: .utf8) else { return (defaults, [], []) }
        let tables: [TOML.Table]
        do {
            tables = try TOML.parse(text)
        } catch {
            return (defaults, [], ["capture.toml: \(error)"])
        }
        var templates: [CaptureTemplate] = []
        var groups: [CaptureGroup] = []
        var problems: [String] = []
        for table in tables where !(table.name.isEmpty && table.values.isEmpty) && !roamTables.contains(table.name) {
            guard table.name == "template", table.isArrayElement else {
                problems.append("capture.toml line \(table.line): expected [[template]]")
                continue
            }
            let values = table.values
            if let key = values["key"]?.string, let name = values["name"]?.string, values.count == 2 {
                groups.append(CaptureGroup(key: key, name: name))
                continue
            }
            let fileless = values["id"]?.string != nil || values["clock"]?.bool == true || values["denote"]?.bool == true
            guard let key = values["key"]?.string, let body = values["template"]?.string, let file = values["file"]?.string ?? (fileless ? "" : nil) else {
                problems.append("capture.toml line \(table.line): a template needs key, file and template")
                continue
            }
            guard let kind = CaptureTemplate.Kind(rawValue: table.values["type"]?.string ?? "entry") else {
                problems.append("capture.toml line \(table.line): unknown type")
                continue
            }
            let olp = values["olp"]?.string.map { $0.split(separator: "/").map(String.init) }
            let target: CaptureTemplate.Target
            if let id = values["id"]?.string {
                target = .id(id)
            } else if values["clock"]?.bool == true {
                target = .clock
            } else if values["datetree"]?.bool == true {
                guard let tree = CaptureTemplate.TreeType(rawValue: values["tree-type"]?.string ?? "day") else {
                    problems.append("capture.toml line \(table.line): tree-type is day, week, month, or some of year, quarter, month, week and day")
                    continue
                }
                target = .datetree(file: file, path: olp ?? [], tree: tree)
            } else if let regexp = values["regexp"]?.string {
                target = .regexp(file: file, regexp: regexp)
            } else if let headline = values["headline"]?.string {
                target = .headline(file: file, headline: headline)
            } else if let olp {
                target = .outline(file: file, path: olp)
            } else {
                target = .file(file)
            }
            templates.append(CaptureTemplate(key: key, name: values["name"]?.string ?? key, kind: kind, target: target, template: body, options: options(values)))
        }
        return (templates.isEmpty ? defaults : templates, templates.isEmpty ? [] : groups, problems)
    }

    /// A table's template properties beyond the target.
    public nonisolated static func options(_ values: [String: TOML.Value]) -> CaptureTemplate.Options {
        func flag(_ name: String) -> Bool { values[name]?.bool ?? false }
        func lines(_ name: String) -> Int? { values[name]?.integer }
        return CaptureTemplate.Options(
            prepend: flag("prepend"), immediateFinish: flag("immediate-finish"), emptyLines: lines("empty-lines"),
            emptyLinesBefore: lines("empty-lines-before"), emptyLinesAfter: lines("empty-lines-after"),
            jumpToCaptured: flag("jump-to-captured"), clockIn: flag("clock-in"), clockKeep: flag("clock-keep"), clockResume: flag("clock-resume"),
            tableLinePos: values["table-line-pos"]?.string, timePrompt: flag("time-prompt"), denote: flag("denote")
        )
    }

    /// What `org-capture` lists after the keys typed so far: the groups and templates one key
    /// longer, in the templates' order. A template with no group for its prefix is listed
    /// too, so that it can be reached.
    public static func menu(_ templates: [CaptureTemplate], groups: [CaptureGroup], typed: String) -> [CaptureMenuItem] {
        let depth = typed.count + 1
        var items: [CaptureMenuItem] = []
        var shown: Set<String> = []
        for template in templates where template.key.hasPrefix(typed) {
            if template.key.count > depth, let group = groups.first(where: { $0.key == String(template.key.prefix(depth)) }) {
                if shown.insert(group.key).inserted { items.append(.group(group)) }
            } else {
                items.append(.template(template))
            }
        }
        for group in groups where group.key.hasPrefix(typed) && group.key.count == depth && !shown.contains(group.key) { items.append(.group(group)) }
        return items
    }

    /// The template's name after the names of the groups above it: `Work › Meeting`.
    public static func label(_ template: CaptureTemplate, groups: [CaptureGroup]) -> String {
        let names = (1..<max(1, template.key.count)).compactMap { n in groups.first { $0.key == String(template.key.prefix(n)) }?.name }
        return (names + [template.name]).joined(separator: " › ")
    }
}

/// A key and a description with no template: `("w" "Work")` in `org-capture-templates`.
public struct CaptureGroup: Sendable, Equatable, Identifiable {
    public let key: String
    public let name: String
    public var id: String { key }
    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

public enum CaptureMenuItem: Identifiable {
    case group(CaptureGroup)
    case template(CaptureTemplate)
    public var key: String {
        switch self {
        case .group(let g): g.key
        case .template(let t): t.key
        }
    }
    public var id: String { key }
}

extension CaptureContext {
    /// `%[file]` reads the file, a relative path from the configuration folder.
    public mutating func readsTemplateFiles(from directory: URL = UserConfig.directory) {
        self.directory = directory.path
        readFile = { try? String(contentsOfFile: $0, encoding: .utf8) }
    }
}

extension CaptureTemplates {
    /// A template's file: absolute, `~/…`, or relative to `root`.
    public nonisolated static func path(_ file: String, root: String?) -> String {
        if file.hasPrefix("/") { return file }
        if file.hasPrefix("~") { return OrgPaths.expandingTilde(file) }
        return ((root ?? OrgPaths.home) as NSString).appendingPathComponent(file)
    }
}

/// The edit `Capture.place` makes, as a command so the save path applies it. The selection
/// it leaves is the captured entry's start.
public struct CapturePlacement: OrgCommand {
    let text: String
    let template: CaptureTemplate

    public init(text: String, template: CaptureTemplate) {
        self.text = text
        self.template = template
    }

    public var id: String { "internal.capture" }
    public var title: String { "Capture" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        switch Capture.placement(text, template: template, in: context.text, settings: context.tree.settings, now: context.now, calendar: context.calendar) {
        case .failure(.message(let message)):
            return .failed(message)
        case .success(let placed):
            return .commit(EditResult(baseRevision: context.revision, edits: TextEdit.between(context.text, placed.text), selection: [placed.start..<placed.start]))
        }
    }
}
