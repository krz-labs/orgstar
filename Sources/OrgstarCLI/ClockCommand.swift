import Foundation
import OrgCore

/// `orgstar clock in|out|status`. The running clock is the open `CLOCK:` line in the files, as
/// in Emacs: the tool changes only the org file, and the app, which watches its folders, takes
/// a clock started or stopped here as the running one. The app's own record (`clock.json` in
/// the data folder) is read, never written, so the two never write the same file.
@MainActor
enum ClockCommand {
    static let help = """
    Usage: orgstar clock in <file>::<heading>
           orgstar clock in <file>::id:<id> | id:<id>
           orgstar clock out
           orgstar clock status [--json]

    Starts and stops the clock as Org does: clock in writes a CLOCK line under the heading,
    stopping the running clock first; clock out closes the running clock's line. The heading is
    its title (with or without a leading *), #custom-id or id:ID.

    The running clock is the one orgstar shows, else the most recently started open CLOCK line in
    the agenda files. orgstar picks up a clock started or stopped here when it sees the file change.

    Options:
      --json    clock status as JSON
    """

    struct Running {
        let path: String
        let start: String
        let startedAt: Date
        let title: String
    }

    static func run(_ words: [String], _ workspace: Workspace) throws(Failure) {
        guard let verb = words.first else { throw Failure(.usage, "clock: in, out or status; see orgstar clock --help") }
        let command = "clock " + verb
        switch verb {
        case "in":
            let arguments = try Arguments(Array(words.dropFirst()), command: command, flags: [])
            try arguments.expect(1, 1, command)
            try clockIn(arguments.positional[0], workspace)
        case "out":
            try Arguments(Array(words.dropFirst()), command: command, flags: []).expect(0, 0, command)
            try clockOut(workspace)
        case "status":
            let arguments = try Arguments(Array(words.dropFirst()), command: command, flags: ["--json"])
            try arguments.expect(0, 0, command)
            try status(json: arguments.flags.contains("--json"), workspace)
        default:
            throw Failure(.usage, "clock: unknown subcommand \(verb); see orgstar clock --help")
        }
    }

    static func clockIn(_ spec: String, _ workspace: Workspace) throws(Failure) {
        try clockIn(workspace) { () throws(Failure) in try workspace.target(spec) }
    }

    /// Clocks in at the heading `resolve` finds, asked again after the running clock stops.
    static func clockIn(_ workspace: Workspace, target resolve: () throws(Failure) -> Workspace.Target) throws(Failure) {
        var target = try resolve()
        guard target.offset != nil else { throw Failure(.usage, "clock in: name a heading, as file.org::Heading") }
        if let running = running(workspace) {
            if running.path == target.path, try heading(of: running, workspace)?.headingRange.lowerBound == target.offset {
                workspace.host.print("Clock continues in \"\(running.title)\"")
                return
            }
            workspace.host.print(try stop(running, workspace))
            // Clocking out may have moved the heading.
            target = try resolve()
        }
        guard let offset = target.offset else { return }
        let (_, text) = try workspace.perform(ClockIn(), path: target.path, at: offset)
        guard let start = ClockIn.runningStart(in: text, near: offset) else { throw Failure(.failure, "The clock line wasn't found after clocking in.") }
        workspace.host.print("Clock starts at [\(start)] in \"\(target.title ?? "")\"")
    }

    static func clockOut(_ workspace: Workspace) throws(Failure) {
        guard let running = running(workspace) else { throw Failure(.notFound, "No active clock") }
        workspace.host.print(try stop(running, workspace))
    }

    private static func stop(_ running: Running, _ workspace: Workspace) throws(Failure) -> String {
        let (_, text) = try workspace.perform(ClockOut(start: running.start), path: running.path, at: 0)
        let minutes = max(0, Int(workspace.host.now.timeIntervalSince(running.startedAt) / 60))
        let removed = !text.contains("CLOCK: [\(running.start)]")
        return String(format: "Clock stopped after %d:%02d", minutes / 60, minutes % 60) + (removed ? " => LINE REMOVED" : "") + " in \"\(running.title)\""
    }

    static func status(json: Bool, _ workspace: Workspace) throws(Failure) {
        let running = running(workspace)
        if json {
            let value: [String: Any] = running.map { running in
                ["running": [
                    "file": running.path, "heading": running.title, "start": running.start,
                    "minutes": max(0, Int(workspace.host.now.timeIntervalSince(running.startedAt) / 60)),
                ] as [String: Any]]
            } ?? ["running": NSNull()]
            workspace.host.output(JSONOutput.data(value))
        } else if let running {
            let minutes = max(0, Int(workspace.host.now.timeIntervalSince(running.startedAt) / 60))
            workspace.host.print(String(format: "%d:%02d ", minutes / 60, minutes % 60) + "\(running.title) (\(running.path)) since [\(running.start)]")
        } else {
            workspace.host.print("No active clock")
        }
        if running == nil { throw Failure(.notFound, "") }
    }

    /// The clock the app shows, while its line is still open; else the most recently started
    /// open clock in the agenda files.
    static func running(_ workspace: Workspace) -> Running? {
        let saved = savedRunning(workspace)
        var paths = workspace.agendaFiles
        if let saved, !paths.contains(saved.path) { paths.append(saved.path) }
        var newest: Running?
        for path in paths {
            guard let text = try? workspace.text(path), text.contains("CLOCK: [") else { continue }
            for clock in ClockResolution.openClocks(in: text) {
                guard let startedAt = ClockResolution.date(of: clock.start, calendar: workspace.host.calendar) else { continue }
                let heading = workspace.headings(text, path: path).last { $0.headingRange.lowerBound <= clock.offset }
                let found = Running(path: path, start: clock.start, startedAt: startedAt, title: heading?.title ?? "")
                if saved?.path == path, saved?.start == clock.start { return found }
                if newest.map({ startedAt > $0.startedAt }) ?? true { newest = found }
            }
        }
        return newest
    }

    private static func heading(of running: Running, _ workspace: Workspace) throws(Failure) -> HeadingInfo? {
        let text = try workspace.text(running.path)
        let offset = (text as NSString).range(of: "CLOCK: [\(running.start)]").location
        guard offset != NSNotFound else { return nil }
        return workspace.headings(text, path: running.path).last { $0.headingRange.lowerBound <= offset }
    }

    /// The running clock in the app's `clock.json`.
    private static func savedRunning(_ workspace: Workspace) -> (path: String, start: String)? {
        struct Clock: Decodable {
            let path: String
            let start: String
        }
        struct Saved: Decodable {
            let running: Clock?
        }
        guard let data = try? Data(contentsOf: workspace.dataDirectory.appendingPathComponent("clock.json")) else { return nil }
        let clock = (try? JSONDecoder().decode(Saved.self, from: data))?.running ?? (try? JSONDecoder().decode(Clock.self, from: data))
        return clock.map { ($0.path, $0.start) }
    }
}
