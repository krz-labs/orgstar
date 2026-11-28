import Foundation
import Testing
@testable import OrgstarCLI

/// A configuration folder, a data folder and a folder of notes in a temporary folder, and the
/// tool run over them at a fixed time.
@MainActor
final class Sandbox {
    let folder: URL
    let config: URL
    let data: URL
    let notes: URL
    var now: Date
    var calendar: Calendar
    var opened: [[String]] = []

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-cli-\(UUID().uuidString)").resolvingSymlinksInPath()
        config = folder.appendingPathComponent("config")
        data = folder.appendingPathComponent("data")
        notes = folder.appendingPathComponent("notes")
        for url in [config, data, notes] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Thursday 26 November 2026, 10:00.
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 10))!
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func write(_ text: String, _ name: String, in folder: URL? = nil) throws {
        let url = (folder ?? notes).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: notes.appendingPathComponent(name), encoding: .utf8)
    }

    func run(_ arguments: String..., input: String? = nil, environment: [String: String] = [:]) -> (status: Int32, out: String, err: String) {
        var out = Data()
        var err = ""
        var host = Host(
            environment: ["ORGSTAR_CONFIG_DIR": config.path, "ORGSTAR_DATA_DIR": data.path, "ORGSTAR_ROOT": notes.path, "PATH": folder.path]
                .merging(environment) { $1 },
            now: now, calendar: calendar, currentDirectory: notes.path,
            input: { input }, output: { out.append($0) }, error: { err += $0 }, open: { _ in 0 },
            executable: folder.appendingPathComponent("orgstar")
        )
        host.open = { [weak self] arguments in
            self?.opened.append(arguments)
            return 0
        }
        let status = Tool.run(arguments, host: host)
        return (status, String(decoding: out, as: UTF8.self), err)
    }
}

@MainActor
struct AgendaTests {
    static let tasks = """
    #+TITLE: Tasks
    * TODO Write report
    SCHEDULED: <2026-11-26 Thu>
    * TODO Pay rent :home:
    DEADLINE: <2026-11-27 Fri>
    * TODO Call Sam
    * DONE Old thing
    """

    @Test func printsTheDayAsEmacsDoes() throws {
        let sandbox = try Sandbox()
        try sandbox.write("org-agenda-span = 1\n", "config.toml", in: sandbox.config)
        try sandbox.write(Self.tasks, "tasks.org")
        let (status, out, err) = sandbox.run("agenda")
        #expect(status == 0, "\(err)")
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.first == "Day-agenda (W48):")
        #expect(lines.contains("Thursday   26 November 2026"))
        #expect(lines.contains { $0.hasPrefix("  tasks:") && $0.hasSuffix("Scheduled:  TODO Write report") })
        #expect(lines.contains { $0.contains("In   1 d.:  TODO Pay rent") && $0.hasSuffix(":home:") })
        #expect(!out.contains("Call Sam"))
    }

    @Test func listsAViewAsJSONWithLines() throws {
        let sandbox = try Sandbox()
        try sandbox.write(Self.tasks, "tasks.org")
        let (status, out, _) = sandbox.run("agenda", "todo list", "--json")
        #expect(status == 0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(json["view"] as? String == "TODO List")
        let block = try #require((json["blocks"] as? [[String: Any]])?.first)
        #expect(block["type"] as? String == "todo")
        let entries = try #require(block["entries"] as? [[String: Any]])
        #expect(entries.map { $0["title"] as? String } == ["TODO Write report", "TODO Pay rent", "TODO Call Sam"])
        #expect(entries.map { $0["line"] as? Int } == [2, 4, 6])
        #expect(entries[1]["tags"] as? [String] == ["home"])
        #expect(entries[0]["file"] as? String == sandbox.notes.appendingPathComponent("tasks.org").path)
    }

    @Test func runsAViewOfViewsToml() throws {
        let sandbox = try Sandbox()
        try sandbox.write(Self.tasks, "tasks.org")
        try sandbox.write("[[view]]\nname = \"Home\"\ntype = \"match\"\nmatch = \"home\"\n", "views.toml", in: sandbox.config)
        let (status, out, _) = sandbox.run("agenda", "Home")
        #expect(status == 0)
        #expect(out.hasPrefix("Headlines with TAGS match: home\n"))
        #expect(out.contains("TODO Pay rent"))
        #expect(!out.contains("Write report"))
        let missing = sandbox.run("agenda", "Nope")
        #expect(missing.status == 3)
        #expect(missing.err.contains("No agenda view named Nope"))
    }

    @Test func runsAQueryViewOfViewsToml() throws {
        let sandbox = try Sandbox()
        try sandbox.write(Self.tasks, "tasks.org")
        try sandbox.write("[[view]]\nname = \"Planned\"\ntype = \"query\"\nquery = \"todo: ts:\"\nsort = \"date\"\n", "views.toml", in: sandbox.config)
        let (status, out, _) = sandbox.run("agenda", "Planned", "--json")
        #expect(status == 0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let block = try #require((json["blocks"] as? [[String: Any]])?.first)
        #expect(block["type"] as? String == "query")
        #expect(block["header"] as? String == "Query: todo: ts:")
        #expect((block["entries"] as? [[String: Any]])?.map { $0["title"] as? String } == ["TODO Write report", "TODO Pay rent"])
    }
}

@MainActor
struct CaptureTests {
    static let templates = """
    [[template]]
    key = "t"
    name = "Todo"
    file = "inbox.org"
    headline = "Inbox"
    template = "* TODO %?%i"

    [[template]]
    key = "m"
    name = "Meeting"
    file = "inbox.org"
    headline = "Meetings"
    template = "* %^{Who} %^{Where|office}\\n%i"
    """

    @Test func filesTheTextUnderTheHeadline() throws {
        let sandbox = try Sandbox()
        try sandbox.write(Self.templates, "capture.toml", in: sandbox.config)
        try sandbox.write("* Inbox\n* Meetings\n", "inbox.org")
        let (status, out, err) = sandbox.run("capture", "t", "Buy milk")
        #expect(status == 0, "\(err)")
        #expect(out == "Captured to \(sandbox.notes.appendingPathComponent("inbox.org").path):2\n")
        #expect(try sandbox.read("inbox.org") == "* Inbox\n** TODO Buy milk\n* Meetings\n")
        let piped = sandbox.run("capture", "t", input: "Call the bank\n")
        #expect(piped.status == 0)
        #expect(try sandbox.read("inbox.org") == "* Inbox\n** TODO Buy milk\n** TODO Call the bank\n* Meetings\n")
    }

    @Test func refusesQuestionsWithoutAnswers() throws {
        let sandbox = try Sandbox()
        try sandbox.write(Self.templates, "capture.toml", in: sandbox.config)
        try sandbox.write("* Inbox\n* Meetings\n", "inbox.org")
        let refused = sandbox.run("capture", "m", "Notes")
        #expect(refused.status == 4)
        #expect(refused.err.contains("asks \"Who\""))
        #expect(try sandbox.read("inbox.org") == "* Inbox\n* Meetings\n")
        let answered = sandbox.run("capture", "m", "Notes", "--set", "Who=Sam")
        #expect(answered.status == 0, "\(answered.err)")
        #expect(try sandbox.read("inbox.org") == "* Inbox\n* Meetings\n** Sam office\nNotes\n")
    }

    @Test func createsAMissingFileAndNamesUnknownTemplates() throws {
        let sandbox = try Sandbox()
        try sandbox.write("[[template]]\nkey = \"j\"\nname = \"Journal\"\nfile = \"journal/log.org\"\ntemplate = \"* %i\"\n", "capture.toml", in: sandbox.config)
        #expect(sandbox.run("capture", "j", "First").status == 0)
        #expect(try sandbox.read("journal/log.org") == "* First\n")
        let unknown = sandbox.run("capture", "x", "text")
        #expect(unknown.status == 3)
        #expect(unknown.err.contains("j (Journal)"))
    }

    /// Capture hooks run only in the app: the tool files without them and says so.
    @Test func filesWithoutCaptureHooks() throws {
        let sandbox = try Sandbox()
        try sandbox.write(Self.templates, "capture.toml", in: sandbox.config)
        try sandbox.write("api = 1\n[[hook]]\nevent = \"capture-before-finalize\"\nfile = \"check.js\"\nfunction = \"check\"\n", "commands.toml", in: sandbox.config)
        try sandbox.write("* Inbox\n* Meetings\n", "inbox.org")
        let (status, _, err) = sandbox.run("capture", "t", "Buy milk")
        #expect(status == 0)
        #expect(err == "orgstar: capture-before-finalize hooks in commands.toml run only in the app; captured without them\n")
        #expect(try sandbox.read("inbox.org") == "* Inbox\n** TODO Buy milk\n* Meetings\n")
    }
}

@MainActor
struct ClockTests {
    @Test func clocksInAndOutAndSwitches() throws {
        let sandbox = try Sandbox()
        try sandbox.write("* Report\n* Email\n", "work.org")
        #expect(sandbox.run("clock", "status").status == 3)
        let clockIn = sandbox.run("clock", "in", "work.org::Report")
        #expect(clockIn.status == 0, "\(clockIn.err)")
        #expect(clockIn.out == "Clock starts at [2026-11-26 Thu 10:00] in \"Report\"\n")
        #expect(try sandbox.read("work.org") == "* Report\n:LOGBOOK:\nCLOCK: [2026-11-26 Thu 10:00]\n:END:\n* Email\n")

        sandbox.now += 25 * 60
        let status = sandbox.run("clock", "status", "--json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(status.out.utf8)) as? [String: Any])
        let running = try #require(json["running"] as? [String: Any])
        #expect(running["heading"] as? String == "Report")
        #expect(running["minutes"] as? Int == 25)

        sandbox.now += 5 * 60
        let switched = sandbox.run("clock", "in", "work.org::*Email")
        #expect(switched.status == 0, "\(switched.err)")
        #expect(switched.out == "Clock stopped after 0:30 in \"Report\"\nClock starts at [2026-11-26 Thu 10:30] in \"Email\"\n")

        sandbox.now += 60 * 60
        let out = sandbox.run("clock", "out")
        #expect(out.out == "Clock stopped after 1:00 in \"Email\"\n")
        #expect(try sandbox.read("work.org") == """
        * Report
        :LOGBOOK:
        CLOCK: [2026-11-26 Thu 10:00]--[2026-11-26 Thu 10:30] =>  0:30
        :END:
        * Email
        :LOGBOOK:
        CLOCK: [2026-11-26 Thu 10:30]--[2026-11-26 Thu 11:30] =>  1:00
        :END:

        """)
        let none = sandbox.run("clock", "out")
        #expect(none.status == 3)
        #expect(none.err == "orgstar: No active clock\n")
    }

    @Test func clocksInByID() throws {
        let sandbox = try Sandbox()
        try sandbox.write("* Report\n:PROPERTIES:\n:ID: abc-123\n:END:\n", "work.org")
        #expect(sandbox.run("clock", "in", "id:abc-123").status == 0)
        #expect(try sandbox.read("work.org").contains(":END:\n:LOGBOOK:\nCLOCK: [2026-11-26 Thu 10:00]\n:END:\n"))
        #expect(sandbox.run("clock", "in", "work.org::Nothing").status == 3)
    }

    @Test func keepsAVersionInRecovery() throws {
        let sandbox = try Sandbox()
        try sandbox.write("* Report\n", "work.org")
        #expect(sandbox.run("clock", "in", "work.org::Report").status == 0)
        let recovery = sandbox.data.appendingPathComponent("Recovery")
        let kept = try FileManager.default.subpathsOfDirectory(atPath: recovery.path).filter { $0.hasSuffix("work.org") }
        #expect(kept.count == 1)
    }
}

@MainActor
struct ExportTests {
    static let text = "#+TITLE: Notes\n* One\nSome *bold* text.\n"

    @Test func exportsBesideTheFile() throws {
        let sandbox = try Sandbox()
        try sandbox.write(Self.text, "notes.org")
        for (format, ext, contains) in [("html", "html", "<strong>bold</strong>"), ("md", "md", "**bold**"), ("latex", "tex", "\\textbf{bold}"), ("txt", "txt", "*bold*"), ("reveal", "html", "One")] {
            let (status, out, err) = sandbox.run("export", "notes.org", "--to", format)
            #expect(status == 0, "\(format): \(err)")
            let path = sandbox.notes.appendingPathComponent("notes.\(ext)").path
            #expect(out == "Exported to \(path)\n")
            #expect(try String(contentsOfFile: path, encoding: .utf8).contains(contains), "\(format)")
        }
        #expect(sandbox.run("export", "notes.org", "--to", "odt", "-o", "out/notes.odt").status == 0)
        let odt = try Data(contentsOf: sandbox.notes.appendingPathComponent("out/notes.odt"))
        #expect(odt.prefix(2) == Data("PK".utf8))
    }

    @Test func writesToStandardOutput() throws {
        let sandbox = try Sandbox()
        try sandbox.write(Self.text, "notes.org")
        let (status, out, _) = sandbox.run("export", "notes.org", "--to=md", "-o", "-")
        #expect(status == 0)
        #expect(out.contains("# One"))
        #expect(!FileManager.default.fileExists(atPath: sandbox.notes.appendingPathComponent("notes.md").path))
    }

    @Test(.enabled(if: !FileManager.default.fileExists(atPath: "/Library/TeX/texbin/pdflatex"))) func pdfWithoutTeXSaysWhatItNeeds() throws {
        let sandbox = try Sandbox()
        try sandbox.write(Self.text, "notes.org")
        let (status, _, err) = sandbox.run("export", "notes.org", "--to", "pdf")
        #expect(status == 1)
        #expect(err.contains("needs TeX"))
    }

    @Test func tanglesBlocks() throws {
        let sandbox = try Sandbox()
        try sandbox.write("* Script\n#+begin_src sh :tangle out/run.sh :mkdirp yes\necho hi\n#+end_src\n", "code.org")
        let (status, out, err) = sandbox.run("tangle", "code.org")
        #expect(status == 0, "\(err)")
        #expect(out == "Tangled 1 code block from code.org\n")
        #expect(try sandbox.read("out/run.sh") == "echo hi\n")
    }
}

@MainActor
struct ArgumentTests {
    @Test func usageErrorsExitWithTwo() throws {
        let sandbox = try Sandbox()
        try sandbox.write("* A\n", "a.org")
        #expect(sandbox.run().status == 2)
        #expect(sandbox.run("frobnicate").status == 2)
        #expect(sandbox.run("agenda", "--bogus").status == 2)
        #expect(sandbox.run("agenda", "one", "two").status == 2)
        #expect(sandbox.run("export", "a.org").status == 2)
        #expect(sandbox.run("export", "a.org", "--to", "doc").status == 2)
        #expect(sandbox.run("export", "a.org", "--to").status == 2)
        #expect(sandbox.run("capture").status == 2)
        #expect(sandbox.run("capture", "t", "x", "--set", "novalue").status == 2)
        #expect(sandbox.run("clock").status == 2)
        #expect(sandbox.run("clock", "in").status == 2)
        #expect(sandbox.run("clock", "in", "a.org").status == 2)
        #expect(sandbox.run("export", "missing.org", "--to", "md").status == 3)
    }

    @Test func helpAndVersion() throws {
        let sandbox = try Sandbox()
        let help = sandbox.run("--help")
        #expect(help.status == 0)
        #expect(help.out.contains("Exit status:"))
        for command in ["agenda", "capture", "clock", "export", "tangle", "open"] {
            let result = sandbox.run(command, "--help")
            #expect(result.status == 0)
            #expect(result.out.hasPrefix("Usage: orgstar \(command)"))
        }
        #expect(sandbox.run("help", "clock").out.hasPrefix("Usage: orgstar clock"))
        #expect(sandbox.run("--version").out == "orgstar (development build)\n")
    }

    @Test func opensTheEntryInTheApp() throws {
        let sandbox = try Sandbox()
        try sandbox.write("* A\n* B\n", "a.org")
        #expect(sandbox.run("open", "a.org::B").status == 0)
        let path = sandbox.notes.appendingPathComponent("a.org").path
        var link = URLComponents()
        link.scheme = "orgstar"
        link.host = "entry"
        link.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "offset", value: "4")]
        #expect(sandbox.opened == [[link.url!.absoluteString]])
    }
}
