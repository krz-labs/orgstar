import Foundation
import OrgCore
import OrgDocument
import OrgIndex
import Testing
@testable import OrgApp

@MainActor
struct CompletionSourcesTests {
    @Test func presetDecidesUntilSet() {
        let defaults = TestDefaults("orgstar-completion")
        #expect(OrgPreferences.completion(defaults) == CompletionOptions(auto: false, delay: 0.4, prefix: 2, fuzzy: false, words: false))
        defaults.set("doom", forKey: "keymap")
        #expect(OrgPreferences.completion(defaults) == CompletionOptions(auto: true, delay: 0.4, prefix: 2, fuzzy: true, words: false))
        defaults.set("off", forKey: "completionAuto")
        defaults.set("prefix", forKey: "completionStyle")
        #expect(OrgPreferences.completion(defaults) == CompletionOptions(auto: false, fuzzy: false))
        defaults.set("mac", forKey: "keymap")
        defaults.set("on", forKey: "completionAuto")
        defaults.set(250, forKey: "completionAutoDelay")
        defaults.set(3, forKey: "completionAutoPrefix")
        defaults.set(true, forKey: "completionWords")
        #expect(OrgPreferences.completion(defaults) == CompletionOptions(auto: true, delay: 0.25, prefix: 3, fuzzy: false, words: true))
        #expect(UserConfig.apply("[orgstar]\ncompletion-auto = \"sometimes\"\n", to: defaults) == ["config.toml: completion-auto must be one of preset, on, off"])
    }

    @Test func answersFromTheIndexLeavingOutThisFile() async throws {
        let index = try IndexStore()
        try index.write(FileRecord(path: "/n/a.org", root: "/n", kind: .org, bytes: Array("* Here\n".utf8), mtime: 1, settings: IndexSettings()))
        try index.write(FileRecord(path: "/n/b.org", root: "/n", kind: .org, bytes: Array("* There\nThermal.\n".utf8), mtime: 1, settings: IndexSettings()))
        let targets = await CompletionSources.answer(.linkTargets, index: index, excluding: "/n/a.org")
        #expect(targets.items.map(\.title) == ["There"])
        #expect(await CompletionSources.answer(.words("the"), index: index, excluding: nil).strings == ["There", "Thermal"])
    }

    /// Completing `[[id:` to a heading in another file without an ID gives it one there.
    @Test func linkingAHeadingElsewhereGivesItAnID() throws {
        let notes = try Folder()
        let target = try notes.write("target.org", "* Intro\n* Plan\nBody\n")
        let here = try notes.write("here.org", "See ")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(here.path)
        let item = CompletionItem(title: "Plan", id: nil, path: target.path, start: 8, heading: true)
        #expect(CompletionSources.createID(item, session: session, newID: "plan-id") == "plan-id")
        #expect(try String(contentsOf: target, encoding: .utf8) == "* Intro\n* Plan\n:PROPERTIES:\n:ID:       plan-id\n:END:\nBody\n")
        // A heading that moved is left alone.
        let moved = CompletionItem(title: "Plan", id: nil, path: target.path, start: 0, heading: true)
        #expect(CompletionSources.createID(moved, session: session, newID: "other") == nil)
        // The link the completion inserts.
        var completion = OrgCompletion.at(EditContext(revision: 0, text: "See [[id:Pl", tree: OrgParser.parse("See [[id:Pl"), selection: [11..<11]))!
        completion = OrgCompletion.filled(completion, with: CompletionResult(items: [item]), fuzzy: false)
        let edit = CompletionFlow.linkEdit(completion, completion.item("Plan")!, id: "plan-id")
        #expect(edit.apply(to: "See [[id:Pl") == "See [[id:plan-id][Plan]]")
    }
}
