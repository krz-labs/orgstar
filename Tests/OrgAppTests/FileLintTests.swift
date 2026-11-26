import Foundation
import OrgCore
@testable import OrgIndex
import Testing
@testable import OrgApp

struct FileLintTests {
    @Test func idsResolveThroughTheIndexAndItsOverlay() async throws {
        let store = try IndexStore()
        try store.write(FileRecord(path: "/notes/a.org", root: "/notes", kind: .org, bytes: Array("* A\n:PROPERTIES:\n:ID: in-a\n:END:\n".utf8), mtime: 1, settings: IndexSettings()))
        // An unsaved buffer of b.org, in place of what the index has.
        let overlay = ["/notes/b.org": FileRecord(path: "/notes/b.org", root: "/notes", kind: .org, bytes: Array("* B\n:PROPERTIES:\n:ID: in-b\n:END:\n".utf8),
                                                  mtime: 2, settings: IndexSettings())]
        let text = "* Here\n:PROPERTIES:\n:ID: in-a\n:END:\n[[id:in-a]] [[id:in-b]]\n[[id:nowhere]]\n"
        let environment = FileLint.environment(index: store, overlay: overlay)
        let findings = await FileLint.lint(text, tree: OrgParser.parse(text), path: "/notes/here.org", environment: environment)
        #expect(findings.map(\.checker) == [.duplicateID, .invalidIDLink])
        #expect(findings.map(\.line) == [3, 6])
        #expect(findings.first?.message == "Duplicate ID \"in-a\", also in a.org")
    }

    @Test func settingsComeFromThePreferences() {
        let defaults = TestDefaults("FileLintTests")
        defaults.set("attach/", forKey: "attachIDDir")
        defaults.set("t", forKey: "attachUseInheritance")
        defaults.set("secret", forKey: "cryptTagMatcher")
        let environment = FileLint.environment(index: nil, defaults: defaults)
        #expect(environment.attachIDDir == "attach/")
        #expect(environment.attachInherit == true)
        #expect(environment.cryptTag == "secret")
        #expect(environment.idFiles == nil)
    }

    @Test func appliesToOrgFiles() {
        #expect(FileLint.applies(to: "/n/a.org"))
        #expect(FileLint.applies(to: "/n/a.org_archive"))
        #expect(FileLint.applies(to: "/n/a.org.gpg"))
        #expect(!FileLint.applies(to: "/n/a.md"))
        #expect(!FileLint.applies(to: nil))
    }

    @Test func summaries() {
        #expect(FileLint.summary([]) == "No problems found")
        let finding = LintFinding(offset: 0, line: 1, checker: .priority, message: "x")
        #expect(FileLint.summary([finding, finding]) == "2 problems")
        #expect(FileLint.severity(finding) == "Error")
        #expect(FileLint.severity(LintFinding(offset: 0, line: 1, checker: .timestampSyntax, message: "x")) == "Warning")
    }
}
