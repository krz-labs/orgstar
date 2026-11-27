import Foundation
import Observation
import OrgConfig
import OrgCore
import OrgDocument

extension DocumentSession {
    /// Places captured `text` with `template`: through the buffer when the target is open,
    /// otherwise in the file, created if missing, through the save path. `id` and `clock`
    /// targets must be resolved first (`file` names the ID's file). Returns the file and where
    /// the entry starts.
    public func capture(_ text: String, template: CaptureTemplate, root: String?, file: String? = nil, now: Date = Date()) -> Result<(path: String, offset: Int), CaptureError> {
        let path = file ?? Self.resolve(template.target.file, root: root)
        if !isOpen(path), !FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: URL(fileURLWithPath: path))
            } catch {
                return .failure(CaptureError(message: "Can't create \(path): \(error.localizedDescription)"))
            }
        }
        switch perform(CapturePlacement(text: text, template: template), path: path, at: 0, expect: nil, now: now) {
        case .commit(let result): return .success((path, result.selection?.first?.lowerBound ?? 0))
        case .failed(let message): return .failure(CaptureError(message: message))
        default: return .failure(CaptureError(message: "Can't capture there."))
        }
    }

    /// A template's file: absolute, `~/…`, or relative to `root`.
    public static func resolve(_ file: String, root: String?) -> String {
        CaptureTemplates.path(file, root: root)
    }

    /// `%a`: a link to the heading at the caret, as `org-store-link` makes one.
    public func captureAnnotation() -> String {
        guard let path, self.document != nil else { return "" }
        let abbreviated = path.hasPrefix(OrgPaths.home) ? "~" + path.dropFirst(OrgPaths.home.count) : Substring(path)
        guard let entry = outline.last(where: { $0.start <= caret }) else { return "[[file:\(abbreviated)]]" }
        return "[[file:\(abbreviated)::*\(entry.title)][\(entry.title)]]"
    }
}

public struct CaptureError: Error, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

extension DocumentSession {
    /// Shortcuts' "Capture to Orgstar": `text` as `%i` in the template keyed `key` (the first
    /// when nil or empty), its prompts taking their defaults, filed without the capture window.
    /// The template used.
    public func capture(
        _ text: String, templateKey key: String?, templates: [CaptureTemplate], workspace: WorkspaceModel, clock: ClockModel,
        clipboard: String, userName: String
    ) -> Result<CaptureTemplate, CaptureError> {
        capture(text, templateKey: key, templates: templates, workspace: workspace, clock: clock, clipboard: clipboard, userName: userName).map(\.template)
    }

    /// `capture(_:templateKey:…)` with prompts answered by their prompt text (`%^{What}` by
    /// `answers["What"]`, empty when missing) and org-protocol's link properties for `%a`,
    /// `%:link` and the like. The template used, and the file and offset of the entry.
    public func capture(
        _ text: String, templateKey key: String?, templates: [CaptureTemplate], workspace: WorkspaceModel, clock: ClockModel,
        clipboard: String, userName: String, answers: [String: String] = [:], properties: [String: String] = [:]
    ) -> Result<(template: CaptureTemplate, path: String, offset: Int), CaptureError> {
        filled(text, templateKey: key, templates: templates, workspace: workspace, clipboard: clipboard, userName: userName,
               answers: answers, properties: properties).flatMap { chosen, filled in
            file(filled, with: chosen, workspace: workspace, clock: clock)
        }
    }

    /// `capture(_:templateKey:…)` with the `capture-before-finalize` hooks run on the filled
    /// template first. A hook from a file not trusted here is skipped, since nothing asks.
    public func captureRunningHooks(
        _ text: String, templateKey key: String?, templates: [CaptureTemplate], workspace: WorkspaceModel, clock: ClockModel,
        clipboard: String, userName: String, answers: [String: String] = [:], properties: [String: String] = [:]
    ) async -> Result<(template: CaptureTemplate, path: String, offset: Int), CaptureError> {
        let chosen: CaptureTemplate, filledText: String
        switch filled(text, templateKey: key, templates: templates, workspace: workspace, clipboard: clipboard, userName: userName,
                      answers: answers, properties: properties) {
        case .failure(let error): return .failure(error)
        case .success(let prepared): (chosen, filledText) = prepared
        }
        switch await runCaptureHooks(filledText, template: chosen.key, interactive: false) {
        case .failure(let error): return .failure(error)
        case .success(let text): return file(text, with: chosen, workspace: workspace, clock: clock)
        }
    }

    private func file(_ text: String, with chosen: CaptureTemplate, workspace: WorkspaceModel, clock: ClockModel)
        -> Result<(template: CaptureTemplate, path: String, offset: Int), CaptureError> {
        chosen.resolved(workspace: workspace, session: self, clock: clock).flatMap { resolved in
            capture(text, template: resolved.template, root: workspace.rootPaths.first, file: resolved.file)
        }.map { (chosen, $0.path, $0.offset) }
    }

    /// The template keyed `key` and its text filled as `capture(_:templateKey:…)` fills it.
    private func filled(
        _ text: String, templateKey key: String?, templates: [CaptureTemplate], workspace: WorkspaceModel,
        clipboard: String, userName: String, answers: [String: String], properties: [String: String]
    ) -> Result<(CaptureTemplate, String), CaptureError> {
        let key = key.flatMap { $0.isEmpty ? nil : $0 }
        guard let chosen = key.map({ key in templates.first { $0.key == key } }) ?? templates.first else {
            return .failure(CaptureError(message: "No capture template \"\(key ?? "")\""))
        }
        var context = CaptureContext(initial: text, clipboard: clipboard, userName: userName, allTags: (try? workspace.index.tags()) ?? [])
        if let annotation = properties["annotation"] { context.annotation = annotation }
        context.linkProperties = properties
        context.readsTemplateFiles()
        let answers = Capture.questions(chosen.template, context: context).map { answers[$0.prompt] ?? "" }
        guard case .success(let filled) = Capture.fill(chosen.template, context: context, answers: answers) else {
            return .failure(CaptureError(message: "Can't fill template \"\(chosen.key)\""))
        }
        return .success((chosen, filled.text))
    }
}

extension CaptureTemplate {
    /// `id` and `clock` targets as a file and a heading.
    @MainActor
    public func resolved(
        workspace: WorkspaceModel, session: DocumentSession, clock: ClockModel
    ) -> Result<(template: CaptureTemplate, file: String?), CaptureError> {
        switch target {
        case .id(let id):
            guard let location = try? workspace.index.headings(withID: id).first else {
                return .failure(CaptureError(message: "Cannot find target ID \"\(id)\""))
            }
            return .success((self, location.path))
        case .clock:
            guard let entry = clock.entry(session) else { return .failure(CaptureError(message: "No running clock")) }
            return .success((retargeted(.heading(file: entry.path, offset: entry.offset)), entry.path))
        default:
            return .success((self, nil))
        }
    }
}
