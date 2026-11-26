import OrgCore
import Testing
@testable import OrgIndex

struct CompletionQueriesTests {
    func store() throws -> IndexStore {
        let store = try IndexStore()
        try store.write(record("/notes/a.org", """
            :PROPERTIES:
            :ID: file-a
            :END:
            #+TITLE: Project notes
            * Alpha
            :PROPERTIES:
            :ID: alpha
            :Status: waiting
            :Status_ALL: todo "in progress" done :ETC
            :END:
            Helmet and helium.
            * Beta
            :PROPERTIES:
            :Status: waiting
            :END:
            """))
        try store.write(record("/notes/b.org", "* Gamma\n:PROPERTIES:\n:Status: blocked\n:END:\nHelpful words.\n"))
        return store
    }

    @Test func linkTargetsAreEveryHeadingWithItsID() throws {
        let targets = try store().linkTargets()
        #expect(targets.map(\.title) == ["Project notes", "Alpha", "Beta", "Gamma"])
        #expect(targets[0] == CompletionItem(title: "Project notes", id: "file-a", path: "/notes/a.org", start: 0, heading: false))
        #expect(targets[1].id == "alpha" && targets[2].id == nil && targets[2].heading)
        #expect(try store().linkTargets(excluding: "/notes/a.org").map(\.title) == ["Gamma"])
    }

    @Test func propertyValuesMostUsedFirstAndAllowed() throws {
        let values = try store().propertyValues("status")
        #expect(values.used == ["waiting", "blocked"])
        #expect(values.allowed == ["todo", "in progress", "done"])
        #expect(try store().propertyValues("Status", excluding: "/notes/a.org").used == ["blocked"])
    }

    @Test func wordsFromTheFullTextIndex() throws {
        #expect(try store().words("hel") == ["Helmet", "helium", "Helpful"])
        #expect(try store().words("Hel", excluding: "/notes/b.org") == ["Helmet", "helium"])
        #expect(try store().words("--").isEmpty)
    }
}
