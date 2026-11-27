import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

struct XCallbackRequestTests {
    private func request(_ string: String) -> XCallbackRequest? { XCallbackRequest(url: URL(string: string)!) }

    @Test func readsTheActionParametersAndCallbacks() throws {
        let parsed = try #require(request(
            "orgstar://x-callback-url/capture?template=t&text=Buy%20milk%20%26%20eggs&x-source=Shortcuts"
                + "&x-success=shortcuts%3A%2F%2Fx-callback-url%2Fdone%3Fid%3D1&x-error=shortcuts://error&x-cancel=shortcuts://cancel&text=second"
        ))
        #expect(parsed.action == "capture")
        #expect(parsed.known == .capture)
        #expect(parsed.parameters == ["template": "t", "text": "Buy milk & eggs"])
        #expect(parsed.success?.absoluteString == "shortcuts://x-callback-url/done?id=1")
        #expect(parsed.failure?.absoluteString == "shortcuts://error")
        #expect(parsed.cancel?.absoluteString == "shortcuts://cancel")
        #expect(parsed.source == "Shortcuts")
        #expect(parsed.approvalSource == XCallbackApprovals.Source(name: "Shortcuts", schemes: ["shortcuts"]))
    }

    @Test func otherLinksAreNotRequests() throws {
        #expect(request("orgstar://agenda") == nil)
        #expect(request("orgstar://capture?template=t") == nil)
        #expect(request("org-protocol://x-callback-url/capture") == nil)
        #expect(AppLink(url: URL(string: "orgstar://x-callback-url/agenda")!) == nil)
        let bare = try #require(request("orgstar://x-callback-url/clock-status"))
        #expect(bare.known == .clockStatus)
        #expect(bare.parameters.isEmpty && bare.success == nil && bare.source == nil)
        #expect(bare.approvalSource == XCallbackApprovals.Source(name: "", schemes: []))
        #expect(try #require(request("orgstar://x-callback-url/frobnicate")).known == nil)
    }

    @Test func buildsCallbacksWithEncodedResults() throws {
        let parsed = try #require(request(
            "orgstar://x-callback-url/agenda?x-success=myapp%3A%2F%2Fdone%3Fkeep%3D1&x-error=myapp://failed&x-cancel=myapp://cancelled"
        ))
        let success = try #require(parsed.callbackURL(for: .success(["result": "[{\"title\":\"a & b = c+d?\"}]", "count": "1"])))
        #expect(success.absoluteString == "myapp://done?keep=1&count=1&result=%5B%7B%22title%22%3A%22a%20%26%20b%20%3D%20c%2Bd%3F%22%7D%5D")
        let items = URLComponents(url: success, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "result" }?.value == "[{\"title\":\"a & b = c+d?\"}]")
        let failure = try #require(parsed.callbackURL(for: .failure(.notFound, "No file \"x.org\"")))
        #expect(failure.absoluteString == "myapp://failed?errorCode=not-found&errorMessage=No%20file%20%22x.org%22")
        #expect(parsed.callbackURL(for: .cancel)?.absoluteString == "myapp://cancelled")
    }

    @Test func refusesLoopsAndWebCallbacks() throws {
        for callback in ["orgstar://agenda", "ORGSTAR://x-callback-url/capture", "org-protocol://capture?body=x", "https://example.com/", "http://example.com/", "file:///tmp/x"] {
            let escaped = callback.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            let parsed = try #require(request("orgstar://x-callback-url/clock-status?x-success=\(escaped)&x-error=\(escaped)&x-cancel=\(escaped)"))
            #expect(parsed.callbackURL(for: .success([:])) == nil, "\(callback)")
            #expect(parsed.callbackURL(for: .failure(.notFound, "x")) == nil, "\(callback)")
            #expect(parsed.callbackURL(for: .cancel) == nil, "\(callback)")
        }
        #expect(XCallback.allows(URL(string: "shortcuts://x-callback-url/run")!))
        #expect(try #require(request("orgstar://x-callback-url/agenda")).callbackURL(for: .success([:])) == nil)
    }
}

@MainActor
struct XCallbackApprovalsTests {
    @Test func remembersAndForgetsSources() {
        let defaults = TestDefaults("xcallback")
        let approvals = XCallbackApprovals(defaults: defaults)
        let shortcuts = XCallbackApprovals.Source(name: "Shortcuts", schemes: ["shortcuts"])
        #expect(!approvals.allows(shortcuts))
        approvals.allow(shortcuts)
        approvals.allow(shortcuts)
        #expect(approvals.sources == [shortcuts])
        #expect(XCallbackApprovals(defaults: defaults).allows(shortcuts))
        // The same name sending results to another app is another source.
        #expect(!approvals.allows(XCallbackApprovals.Source(name: "Shortcuts", schemes: ["evil"])))
        approvals.forget(shortcuts)
        #expect(!XCallbackApprovals(defaults: defaults).allows(shortcuts))
    }
}

@MainActor
struct XCallbackRunnerTests {
    let notes: Folder
    let workspace: WorkspaceModel
    let session: DocumentSession
    let clock: ClockModel
    let defaults = TestDefaults("xcallback")
    var runner: XCallbackRunner

    init() async throws {
        notes = try Folder()
        try notes.write("todo.org", "* Inbox\n* Project\n:PROPERTIES:\n:ID: project-1\n:END:\n** TODO Write report\nSCHEDULED: <2026-11-26 Thu 10:00>\n* TODO Call Sam :phone:\n")
        workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        await workspace.refresh()
        session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        clock = ClockModel(file: notes.url.appendingPathComponent("clock.json"), defaults: defaults)
        runner = XCallbackRunner(workspace: workspace, session: session, clock: clock, approvals: XCallbackApprovals(defaults: defaults))
        runner.isUnlocked = { true }
        runner.templates = {
            [
                CaptureTemplate(key: "t", name: "Todo", target: .headline(file: "todo.org", headline: "Inbox"), template: "* TODO %i\n%a"),
                CaptureTemplate(key: "e", name: "Errand", target: .headline(file: "todo.org", headline: "Inbox"), template: "* TODO %^{What|Buy milk} %^g\n%i"),
            ]
        }
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-26T09:00:00Z"))
        runner.now = { now }
        runner.calendar = Calendar(identifier: .gregorian)
        runner.calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    private func request(_ string: String) -> XCallbackRequest { XCallbackRequest(url: URL(string: "orgstar://x-callback-url/" + string)!)! }

    private func allowed(_ string: String) -> XCallbackRequest {
        let parsed = request(string)
        runner.approvals.allow(parsed.approvalSource)
        return parsed
    }

    private var todo: String { (try? String(contentsOf: notes.url.appendingPathComponent("todo.org"), encoding: .utf8)) ?? "" }

    @Test func unknownActionsFail() async {
        #expect(await runner.run(request("frobnicate")) == .reply(.failure(.unknownAction, "Unknown action \"frobnicate\"")))
    }

    @Test func writesAndReadsAskOncePerSourceAndNeedPro() async {
        let status = request("clock-status?x-source=Shortcuts&x-success=shortcuts://done")
        #expect(await runner.run(status) == .approve(XCallbackApprovals.Source(name: "Shortcuts", schemes: ["shortcuts"])))
        runner.approvals.allow(status.approvalSource)
        #expect(await runner.run(status) == .reply(.success(["running": "false"])))
        // Capture through the sheet and open show what they do, so they don't ask.
        #expect(await runner.run(request("capture?template=t&x-source=Web")) == .capture(template: "t", properties: ["annotation": "", "description": "", "initial": ""]))
        var locked = runner
        locked.isUnlocked = { false }
        #expect(await locked.run(status) == .reply(.failure(.needsPro, "x-callback-url actions need orgstar+")))
    }

    @Test func capturesWithoutTheSheetWhenEverythingIsGiven() async {
        let step = await runner.run(allowed("capture?template=e&text=for%20the%20weekend&What=Buy%20bread&Tags=shop&x-source=Shortcuts"))
        #expect(step == .reply(.success(["template": "e", "file": "todo.org"])))
        #expect(todo.hasPrefix("* Inbox\n** TODO Buy bread "))
        #expect(todo.contains(" :shop:\nfor the weekend\n* Project\n"))
    }

    /// `capture-before-finalize` hooks run on captures without the sheet; one from a file not
    /// trusted here is skipped, since nothing can ask.
    @Test func captureHooksRunWithoutTheSheet() async throws {
        let config = try Folder()
        try config.write("commands.toml", "api = 1\n[[hook]]\nevent = \"capture-before-finalize\"\nfile = \"check.js\"\nfunction = \"check\"\n")
        try config.write("commands/check.js", """
            export function check(org, { text, template }) {
              if (text.includes("cancel")) throw new Error(`not with ${template}`);
              return { edits: [{ from: 0, to: text.length, text: text.replace("TODO", "NEXT") }] };
            }
            """)
        session.userCommands = UserCommands()
        #expect(UserCommandFile.load(into: session.userCommands, folder: config.url) == [])
        var reported: [String] = []
        let trust = TrustStore(file: config.url.appendingPathComponent("trusted.json"))
        session.hooks = UserHookHost(trust: trust, ask: { _, _ in Issue.record("asked") }, report: { reported.append($0) })
        #expect(await runner.run(allowed("capture?template=t&text=Skipped")) == .reply(.success(["template": "t", "file": "todo.org"])))
        #expect(reported == ["check in commands/check.js: commands/check.js isn't trusted on this device yet, and orgstar can't ask here."])
        let modules = config.url.appendingPathComponent("commands")
        trust.trust(path: modules.appendingPathComponent("check.js").path, content: try #require(UserCommandFile.trustedText("check.js", modules: modules)))
        #expect(await runner.run(allowed("capture?template=t&text=Read")) == .reply(.success(["template": "t", "file": "todo.org"])))
        #expect(await runner.run(allowed("capture?template=t&text=cancel")) == .reply(.failure(.captureFailed, "check in commands/check.js: not with t")))
        #expect(todo.hasPrefix("* Inbox\n** TODO Skipped\n** NEXT Read\n* Project\n"))
    }

    @Test func capturesALinkAsOrgProtocolDoes() async {
        let step = await runner.run(allowed("capture?template=t&text=Read&url=https%3A%2F%2Fexample.com&title=Example"))
        #expect(step == .reply(.success(["template": "t", "file": "todo.org"])))
        #expect(todo.hasPrefix("* Inbox\n** TODO Read\n[[https://example.com][Example]]\n* Project\n"))
    }

    @Test func showsTheSheetWhenSomethingIsMissing() async {
        let link = ["annotation": "[[https://example.com][Example]]", "description": "Example", "initial": "x", "link": "https://example.com", "type": "https"]
        // An unanswered prompt, no text, no template, an unknown template.
        #expect(await runner.run(request("capture?template=e&text=x&url=https%3A%2F%2Fexample.com&title=Example")) == .capture(template: "e", properties: link))
        #expect(await runner.run(request("capture?template=t")) == .capture(template: "t", properties: ["annotation": "", "description": "", "initial": ""]))
        #expect(await runner.run(request("capture?text=x")) == .capture(template: nil, properties: ["annotation": "", "description": "", "initial": "x"]))
        #expect(await runner.run(request("capture?template=zz&text=x")) == .capture(template: "zz", properties: ["annotation": "", "description": "", "initial": "x"]))
        #expect(todo.hasPrefix("* Inbox\n* Project\n"))
    }

    @Test func capturedRepliesNameTheTemplateAndFile() {
        let template = runner.templates()[0]
        let path = (workspace.rootPaths[0] as NSString).appendingPathComponent("todo.org")
        #expect(runner.captured(template, path: path) == .success(["template": "t", "file": "todo.org"]))
    }

    @Test func opensAFileAHeadingOrAnID() async throws {
        let root = workspace.rootPaths[0]
        let path = (root as NSString).appendingPathComponent("todo.org")
        #expect(await runner.run(request("open?file=todo.org")) == .open(path: path, offset: 0, reply: .success(["file": "todo.org"])))
        #expect(await runner.run(request("open?file=todo.org&heading=Project")) == .open(path: path, offset: 8, reply: .success(["file": "todo.org"])))
        #expect(await runner.run(request("open?file=\(path)&heading=Call%20Sam")) == .open(path: path, offset: 107, reply: .success(["file": "todo.org"])))
        #expect(await runner.run(request("open?id=project-1")) == .open(path: path, offset: 8, reply: .success(["file": "todo.org"])))
        #expect(await runner.run(request("open?file=todo.org&heading=Nope")) == .reply(.failure(.notFound, "No heading \"Nope\" in todo.org")))
        #expect(await runner.run(request("open?file=missing.org")) == .reply(.failure(.notFound, "No file \"missing.org\" in orgstar's folders")))
        #expect(await runner.run(request("open?file=../outside.org")) == .reply(.failure(.notFound, "No file \"../outside.org\" in orgstar's folders")))
        #expect(await runner.run(request("open?file=/etc/hosts")) == .reply(.failure(.notFound, "No file \"/etc/hosts\" in orgstar's folders")))
        #expect(await runner.run(request("open?id=nope")) == .reply(.failure(.notFound, "No heading with ID \"nope\"")))
        #expect(await runner.run(request("open")) == .reply(.failure(.missingParameter, "Give file or id")))
    }

    @Test func runsAViewAndReturnsItsEntries() async throws {
        let step = await runner.run(allowed("agenda?view=todo%20list"))
        guard case .reply(.success(let result)) = step else { Issue.record("\(step)"); return }
        #expect(result["view"] == "TODO List")
        #expect(result["count"] == "2" && result["total"] == "2")
        #expect(result["result"] == """
            [{"category":"todo","file":"todo.org","status":"normal","title":"Write report","todo":"TODO"},\
            {"category":"todo","file":"todo.org","status":"normal","tags":["phone"],"title":"Call Sam","todo":"TODO"}]
            """)
        let limited = await runner.run(allowed("agenda?view=TODO%20List&limit=1"))
        guard case .reply(.success(let one)) = limited else { Issue.record("\(limited)"); return }
        #expect(one["count"] == "1" && one["total"] == "2")
        #expect(await runner.run(allowed("agenda?view=Nope")) == .reply(.failure(.notFound, "No agenda view \"Nope\"")))
        #expect(await runner.run(allowed("agenda?limit=none")) == .reply(.failure(.invalidParameter, "limit must be a number above 0")))
    }

    @Test func agendaDaysCarryTheirDateAndTime() async throws {
        let step = await runner.run(allowed("agenda"))
        guard case .reply(.success(let result)) = step, let json = result["result"] else { Issue.record("\(step)"); return }
        let entries = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] ?? []
        let report = try #require(entries.first { $0["title"] as? String == "Write report" })
        #expect(report["date"] as? String == "2026-11-26")
        #expect(report["time"] as? String == "10:00")
        #expect(report["kind"] as? String == "scheduled")
    }

    @Test func clocksInReportsAndClocksOut() async throws {
        #expect(await runner.run(allowed("clock-out")) == .reply(.failure(.noClock, "No active clock")))
        let step = await runner.run(allowed("clock-in?file=todo.org&heading=Call%20Sam"))
        guard case .reply(.success(let started)) = step else { Issue.record("\(step)"); return }
        #expect(started["running"] == "true")
        #expect(started["heading"] == "Call Sam")
        #expect(started["file"] == "todo.org")
        #expect(started["started"] == "2026-11-26T09:00:00Z")
        #expect(started["minutes"] == "0")
        #expect(todo.contains("* TODO Call Sam :phone:\n:LOGBOOK:\nCLOCK: [2026-11-26"))
        #expect(await runner.run(allowed("clock-status")) == .reply(.success(started)))
        guard case .reply(.success(let stopped)) = await runner.run(allowed("clock-out")) else { Issue.record("not stopped"); return }
        #expect(stopped == ["heading": "Call Sam", "file": "todo.org", "minutes": "0"])
        #expect(clock.running == nil)
        // Without an entry, the entry clocked last.
        guard case .reply(.success(let again)) = await runner.run(allowed("clock-in")) else { Issue.record("not clocked in again"); return }
        #expect(again["heading"] == "Call Sam")
        #expect(await runner.run(allowed("clock-in?file=todo.org&heading=Nope")) == .reply(.failure(.notFound, "No heading \"Nope\" in todo.org")))
    }
}
