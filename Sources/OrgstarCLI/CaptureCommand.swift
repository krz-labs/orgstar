import Foundation
import OrgConfig
import OrgCore

/// `orgstar capture <key> [text]`: a template of capture.toml filled and filed at once, as
/// Shortcuts' Capture to Orgstar does.
@MainActor
enum CaptureCommand {
    static let help = """
    Usage: orgstar capture <key> [<text>] [--set <prompt>=<value>]...

    Files an entry with the capture template <key> of capture.toml, without the capture window.
    The text is %i: the argument, or standard input when there is none.

    A template's %^{Prompt} questions take their answers from --set Prompt=value, or their default
    (%^{Prompt|default}). A question with neither stops the capture, naming what to set. %^g and
    %^G add no tags, %^t and the other dates are today, unless set (--set Tags=work:urgent,
    --set Date=+2d). %a, %c, %x and %f are empty.

    Options:
      --set <prompt>=<value>   answer a question; may be repeated
    """

    static func run(_ words: [String], _ workspace: Workspace) throws(Failure) {
        let arguments = try Arguments(words, command: "capture", flags: [], options: ["--set"])
        try arguments.expect(1, 2, "capture")
        let key = arguments.positional[0]
        var answers: [String: String] = [:]
        for pair in arguments.options["--set"] ?? [] {
            guard let equals = pair.firstIndex(of: "=") else { throw Failure(.usage, "capture: --set takes prompt=value, not \(pair)") }
            answers[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        let (templates, _, problems) = CaptureTemplates.load(userFile: workspace.configFile("capture.toml"))
        for problem in problems { workspace.host.error("orgstar: \(problem)\n") }
        guard let template = templates.first(where: { $0.key == key }) else {
            throw Failure(.notFound, "No capture template \"\(key)\". Templates: " + templates.map { "\($0.key) (\($0.name))" }.joined(separator: ", "))
        }
        if template.options.denote { throw Failure(.refused, "Template \"\(key)\" makes a Denote note; capture with it in orgstar.") }
        var initial = arguments.positional.count > 1 ? arguments.positional[1] : workspace.host.input() ?? ""
        if initial.hasSuffix("\n") { initial.removeLast() }

        let running = ClockCommand.running(workspace)
        var context = CaptureContext(
            now: workspace.host.now, calendar: workspace.host.calendar, initial: initial, userName: NSFullUserName(),
            clockHeading: running?.title ?? "", clockLink: running.map { "[[file:\($0.path)::*\($0.title)][\($0.title)]]" } ?? "",
            tagsColumn: workspace.options.tagsColumn
        )
        context.readsTemplateFiles(from: workspace.configDirectory)
        let questions = Capture.questions(template.template, context: context)
        var replies: [String] = []
        var missing: [String] = []
        for question in questions {
            if let answer = answers[question.prompt] {
                replies.append(answer)
                continue
            }
            switch question.kind {
            case .text, .property:
                if question.defaultValue.isEmpty { missing.append(question.prompt) }
                replies.append(question.defaultValue)
            case .tags, .date, .clipboard:
                replies.append("")
            }
        }
        if !missing.isEmpty {
            let names = missing.map { "\"\($0)\"" }.joined(separator: ", ")
            throw Failure(.refused, "Template \"\(key)\" asks \(names). Answer with --set, as: --set '\(missing[0])=…'")
        }
        guard case .success(let filled) = Capture.fill(template.template, context: context, answers: replies) else {
            throw Failure(.failure, "Can't fill template \"\(key)\"")
        }

        var chosen = template
        let path: String
        switch template.target {
        case .id(let id):
            path = try workspace.target("id:" + id).path
        case .clock:
            guard let running else { throw Failure(.notFound, "Template \"\(key)\" files under the running clock, and no clock runs.") }
            let text = try workspace.text(running.path)
            let line = (text as NSString).range(of: "CLOCK: [\(running.start)]").location
            guard let heading = workspace.headings(text, path: running.path).last(where: { $0.headingRange.lowerBound <= line }) else {
                throw Failure(.notFound, "The running clock's heading wasn't found.")
            }
            chosen = template.retargeted(.heading(file: running.path, offset: heading.headingRange.lowerBound))
            path = running.path
        default:
            path = CaptureTemplates.path(template.target.file, root: workspace.roots.first)
        }
        if !FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: URL(fileURLWithPath: path))
            } catch {
                throw Failure(.failure, "Can't create \(path): \(error.localizedDescription)")
            }
        }
        let (result, text) = try workspace.perform(CapturePlacement(text: filled.text, template: chosen), path: path, at: 0)
        let offset = result.selection?.first?.lowerBound ?? 0
        workspace.host.print("Captured to \(path):\(Workspace.line(of: offset, in: text))")
        // A template's clock-in, kept running: the capture is filed at once, so without
        // clock-keep the clock would stop as it starts.
        let headings = workspace.headings(text, path: path)
        if template.options.clockIn, template.options.clockKeep, let index = headings.lastIndex(where: { $0.headingRange.lowerBound <= offset }) {
            let entry = ClockTask(path: path, title: headings[index].title, ordinal: index, id: headings[index].id)
            try ClockCommand.clockIn(workspace) { () throws(Failure) in
                guard let start = entry.locate(in: try workspace.text(path)) else { throw Failure(.notFound, "The captured entry wasn't found.") }
                return Workspace.Target(path: path, offset: start, title: entry.title)
            }
        }
    }
}
