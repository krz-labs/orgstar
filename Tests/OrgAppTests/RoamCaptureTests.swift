import Foundation
import OrgCore
import OrgDocument
@testable import OrgIndex
import Testing
@testable import OrgApp

struct RoamPropertiesTests {
    @Test func splitsAsSplitStringAndUnquote() {
        #expect(RoamProperties.split(#""Alias One" two  three"#) == ["Alias One", "two", "three"])
        #expect(RoamProperties.split(#"a"b c"d"#) == ["a", "b c", "d"])
        #expect(RoamProperties.split(#""say \"hi\"" "back\\slash""#) == [#"say "hi""#, #"back\slash"#])
        #expect(RoamProperties.split("  ") == [])
    }

    @Test func readsRefsAsOrgRoamDoes() {
        let refs = RoamProperties(refs: #"https://example.com @key2020 [cite:@a;@b] [[https://x.org/p][Page]] junk "file:/tmp/a b.pdf""#).refList
        #expect(refs == ["https://example.com", "cite:key2020", "cite:a", "cite:b", "https://x.org/p", "file:/tmp/a"])
    }

    @Test func excludeIsAnyValueButNil() {
        #expect(RoamProperties(exclude: "t").excluded)
        #expect(RoamProperties(exclude: "").excluded)
        #expect(!RoamProperties(exclude: "nil").excluded)
        #expect(!RoamProperties().excluded)
    }

    @Test func indexedNodesHaveAliasesRefsAndTagsAndLeaveExcludedOut() throws {
        let store = try IndexStore()
        let text = """
            :PROPERTIES:
            :ID: f1
            :ROAM_ALIASES: "Alias One" two
            :ROAM_REFS: @key
            :END:
            #+title: File One
            #+filetags: :alpha:
            * Head :beta:
            :PROPERTIES:
            :ID: h1
            :ROAM_EXCLUDE: t
            :END:
            ** Child
            :PROPERTIES:
            :ID: h2
            :END:

            """
        let record = FileRecord(path: "/n/a.org", root: "/n", kind: .org, bytes: Array(text.utf8), mtime: 1, settings: IndexSettings())
        try store.write(record)
        for nodes in [try store.nodes(), try store.nodes(overlay: ["/n/a.org": record])] {
            #expect(nodes.map(\.id) == ["f1", "h2"])
            #expect(nodes.first?.aliases == ["Alias One", "two"])
            #expect(nodes.first?.refs == ["cite:key"])
            #expect(nodes.first?.tags == ["alpha"])
            #expect(nodes.last?.tags == ["alpha", "beta"])
        }
        #expect(try store.nodeSections()["/n/a.org"]?.map(\.id) == ["h2"])
    }
}

@MainActor
struct RoamCaptureTests {
    static var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9, minute: 5, second: 7))! }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-roam-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func node(_ id: String, _ title: String, aliases: [String] = [], refs: [String] = [], tags: [String] = [], path: String? = nil) -> IndexStore.Node {
        IndexStore.Node(id: id, title: title, location: .file(path ?? "/n/\(id).org", contentHash: ""), aliases: aliases, refs: refs, tags: tags)
    }

    /// Actions answering each question with the next of `answers`, keeping what they did.
    final class Recorder {
        var answers: [String?] = []
        var asked: [Prompt] = []
        var shown: [String] = []
        var opened: [(String, Int)] = []
        var links: [(String, String)] = []
        var captures: [RoamCapture] = []
    }

    static func actions(_ folder: URL, nodes: [IndexStore.Node] = [], templates: [RoamTemplate.Set: [RoamTemplate]] = [:], _ recorder: Recorder) -> RoamActions {
        let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.appendingPathComponent(".r")))
        var actions = RoamActions(session: session, roots: { [folder.path] }, nodes: { nodes }, show: { recorder.shown.append($0) },
                                  ask: { prompt, reply in
                                      recorder.asked.append(prompt)
                                      reply(recorder.answers.isEmpty ? nil : recorder.answers.removeFirst())
                                  },
                                  open: { recorder.opened.append(($0, $1)) }, insertLink: { recorder.links.append(($0, $1)) }, refresh: {})
        actions.capture = { recorder.captures.append($0) }
        actions.templates = { set in (templates[set] ?? RoamTemplate.defaults(set), []) }
        return actions
    }

    @Test func newNodeFileFromTheDefaultTemplate() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.appendingPathComponent(".r")))
        var filed: (String, Int, String)?
        let capture = RoamCapture(RoamTemplate.defaults(.node), title: "Field Notes", directory: folder.path, now: Self.now, session: session, refresh: {},
                                  newID: "abc-123") { filed = ($0, $1, $2) }
        #expect(capture.templates.map(\.target) == [.file(folder.appendingPathComponent("20261013090507-field_notes.org").path)])
        #expect(capture.isNew(capture.templates[0]))
        guard case .success(let entry) = capture.file("First line", with: capture.templates[0]) else { Issue.record("not filed"); return }
        let text = try String(contentsOfFile: entry.path, encoding: .utf8)
        #expect(text == ":PROPERTIES:\n:ID:       abc-123\n:END:\n#+title: Field Notes\nFirst line\n")
        #expect(filed?.0 == entry.path && filed?.2 == "abc-123")
    }

    /// Find Node… with a new title shows the capture window; nothing is written until it files,
    /// and then the node opens. Insert Node Link… links to it only once it's filed.
    @Test func newNodesWaitForTheCaptureWindow() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        recorder.answers = ["Fresh Idea", "Fresh Idea"]
        let actions = Self.actions(folder, recorder)
        actions.run("app.node.find")
        #expect(recorder.captures.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".org") }.isEmpty)
        let capture = recorder.captures[0]
        guard case .success(let entry) = capture.file("", with: capture.templates[0]) else { Issue.record("not filed"); return }
        #expect(recorder.opened.map(\.0) == [entry.path])

        actions.run("app.node.insert")
        #expect(recorder.links.isEmpty)
        let second = recorder.captures[1]
        guard case .success = second.file("", with: second.templates[0]) else { Issue.record("not filed"); return }
        #expect(recorder.links.first?.1 == "Fresh Idea")
        #expect(recorder.links.first?.0.hasPrefix("id:") == true)
    }

    @Test func severalTemplatesAreAllOffered() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        recorder.answers = ["Topic"]
        let templates = [RoamTemplate(key: "d", name: "default", kind: .plain, template: "%?", file: "${slug}.org", head: "#+title: ${title}\n"),
                         RoamTemplate(key: "p", name: "person", kind: .plain, template: "* About ${title}", file: "people/${slug}.org", head: "#+title: ${title}\n")]
        Self.actions(folder, templates: [.node: templates], recorder).run("app.node.find")
        #expect(recorder.captures.first?.templates.map(\.key) == ["d", "p"])
        #expect(recorder.captures.first?.templates.map(\.target.file) == [folder.path + "/topic.org", folder.path + "/people/topic.org"])
        #expect(recorder.captures.first?.templates.last?.template == "* About Topic")
    }

    @Test func candidatesShowAliasesAndTags() {
        let nodes = [Self.node("1", "Apple", aliases: ["Malus"], tags: ["fruit", "tree"]), Self.node("2", "Pear"), Self.node("3", "Pear")]
        #expect(RoamActions.candidates(nodes).map(\.label) == ["Apple  #fruit #tree", "Malus  #fruit #tree", "Pear (2.org)", "Pear (3.org)"])
    }

    /// An alias finds its node, and the link it inserts is described by the alias, as
    /// `org-roam-node-insert` does; a title typed without the tags shown still matches.
    @Test func aliasesFindTheirNode() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        recorder.answers = ["Malus  #fruit", "Apple"]
        let actions = Self.actions(folder, nodes: [Self.node("1", "Apple", aliases: ["Malus"], tags: ["fruit"])], recorder)
        actions.run("app.node.insert")
        actions.run("app.node.find")
        #expect(recorder.links.map(\.1) == ["Malus"] && recorder.links.map(\.0) == ["id:1"])
        #expect(recorder.opened.map(\.0) == ["/n/1.org"])
        #expect(recorder.captures.isEmpty)
    }

    @Test func refsFindTheirNode() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        recorder.answers = ["cite:key2020  Paper"]
        Self.actions(folder, nodes: [Self.node("1", "Paper", refs: ["https://example.com", "cite:key2020"]), Self.node("2", "Other")], recorder).run("app.node.find-ref")
        #expect(recorder.asked.first?.choices == ["https://example.com  Paper", "cite:key2020  Paper"])
        #expect(recorder.opened.map(\.0) == ["/n/1.org"])
    }

    /// org-protocol's `roam-ref`: the node with the ref opens; another ref makes a node with
    /// it in `ROAM_REFS` through the capture window. `roam-node` opens the node with the ID.
    @Test func protocolRefsOpenOrMakeNodes() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        let actions = Self.actions(folder, nodes: [Self.node("1", "Paper", refs: ["https://example.com"])], recorder)
        actions.follow(.roamRef(ref: "https://example.com", title: "Example", body: nil, template: nil))
        actions.follow(.roamNode(id: "1"))
        #expect(recorder.opened.map(\.0) == ["/n/1.org", "/n/1.org"])
        actions.follow(.roamRef(ref: "https://new.example/a b", title: "New Page", body: "quoted", template: nil))
        let capture = try #require(recorder.captures.first)
        guard case .success(let entry) = capture.file("", with: capture.templates[0]) else { Issue.record("not filed"); return }
        let text = try String(contentsOfFile: entry.path, encoding: .utf8)
        #expect((entry.path as NSString).lastPathComponent == "new_page.org")
        #expect(text.contains(":ROAM_REFS: \"https://new.example/a b\"\n:END:\n#+title: New Page\n"))
    }

    @Test func dailyGotoAsksOnlyWhenTemplatesNameDifferentFiles() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let same = [RoamTemplate(key: "d", name: "default", kind: .entry, template: "* %?", file: "%<%Y-%m-%d>.org", head: "#+title: %<%Y-%m-%d>\n"),
                    RoamTemplate(key: "t", name: "task", kind: .entry, template: "* TODO %?", file: "%<%Y-%m-%d>.org", head: "#+title: %<%Y-%m-%d>\n")]
        let recorder = Recorder()
        Self.actions(folder, templates: [.dailies: same], recorder).goto(DailiesTests.day)
        #expect(recorder.asked.isEmpty && recorder.opened.map(\.0) == [folder.path + "/daily/2026-10-11.org"])

        let different = [same[0], RoamTemplate(key: "w", name: "work", kind: .entry, template: "* %?", file: "work-%<%Y-%m-%d>.org", head: "#+title: Work\n")]
        let asking = Recorder()
        asking.answers = ["[w] work"]
        let actions = Self.actions(folder, templates: [.dailies: different], asking)
        actions.goto(DailiesTests.day)
        #expect(asking.asked.first?.choices == ["[d] default", "[w] work"])
        #expect(asking.opened.map(\.0) == [folder.path + "/daily/work-2026-10-11.org"])
        #expect(try String(contentsOfFile: folder.path + "/daily/work-2026-10-11.org", encoding: .utf8).hasSuffix(":END:\n#+title: Work\n"))

        actions.capture(DailiesTests.day)
        #expect(asking.captures.first?.templates.map(\.key) == ["d", "w"])
        #expect(asking.captures.first?.now == DailiesTests.day)
    }

    @Test func templatesLoadFromCaptureToml() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("capture.toml")
        try #"""
            [[template]]
            key = "t"
            name = "Todo"
            file = "todo.org"
            template = "* TODO %?"

            [[roam-template]]
            key = "p"
            name = "person"
            template = "* Notes"
            file = "people/${slug}.org"
            head = "#+title: ${title}\n#+filetags: :person:\n"
            type = "entry"

            [[roam-template]]
            key = "x"

            [[roam-dailies-template]]
            key = "j"
            name = "journal"
            template = "* %<%H:%M> %?"
            olp = "Journal/Log"
            """#.write(to: file, atomically: true, encoding: .utf8)
        let nodes = RoamTemplate.load(.node, userFile: file)
        #expect(nodes.templates == [RoamTemplate(key: "p", name: "person", kind: .entry, template: "* Notes", file: "people/${slug}.org", head: "#+title: ${title}\n#+filetags: :person:\n")])
        #expect(nodes.problems.count == 1)
        let defaults = TestDefaults("orgstar-roam-templates")
        let dailies = RoamTemplate.load(.dailies, userFile: file, defaults: defaults).templates
        #expect(dailies.map(\.olp) == [["Journal", "Log"]] && dailies.map(\.kind) == [.entry] && dailies.map(\.file) == ["%<%Y-%m-%d>.org"])
        #expect(RoamTemplate.load(.ref, userFile: file).templates == RoamTemplate.defaults(.ref))
        let capture = CaptureTemplates.load(userFile: file)
        #expect(capture.templates.map(\.key) == ["t"] && capture.problems.isEmpty)
    }
}

@MainActor
struct RoamLinkTests {
    @Test func roamLinksFollowTitlesAndAliases() async throws {
        let notes = try Folder()
        let a = try notes.write("a.org", ":PROPERTIES:\n:ID: a1\n:ROAM_ALIASES: \"Second Name\"\n:END:\n#+title: First\n")
        _ = try notes.write("b.org", ":PROPERTIES:\n:ID: b1\n:END:\n#+title: Twice\n")
        _ = try notes.write("c.org", ":PROPERTIES:\n:ID: c1\n:END:\n#+title: Twice\n")
        let workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        func follow(_ raw: String) -> LinkFollow { session.follow(Links.parse(bracket: raw), workspace: workspace, isText: { $0.hasSuffix(".org") }) }
        #expect(follow("roam:Second Name") == .shown && session.path == a.path)
        #expect(follow("roam:First") == .shown)
        #expect(follow("roam:Nobody") == .message("No node has the title or alias Nobody"))
        #expect(follow("roam:Twice") == .message("Multiple nodes exist with title or alias \"Twice\""))
    }
}
