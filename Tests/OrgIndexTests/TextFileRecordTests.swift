import Foundation
import OrgCore
import Testing
@testable import OrgIndex

/// Markdown and plain text files in the index: searched, titled, never org.
struct TextFileRecordTests {
    @Test func markdownHeadingsAndTitle() {
        let text = "---\ntitle: Field notes\n---\nThe heron came back.\n# Birds\nherons\n## Waders\n* TODO not org\n```\n# not a heading\n```\n# Fish\n"
        let file = record("/notes/a.md", text, kind: .text)
        #expect(file.title == "Field notes")
        #expect(file.preamble == "---\ntitle: Field notes\n---\nThe heron came back.\n")
        #expect(file.headings.map(\.title) == ["Birds", "Waders", "Fish"])
        #expect(file.headings.map(\.level) == [1, 2, 1])
        #expect(file.headings.map(\.parent) == [nil, 0, nil])
        #expect(file.headings[1].outlinePath == ["Birds", "Waders"])
        #expect(file.headings[0].body == "herons\n")
        #expect(file.headings[1].body == "* TODO not org\n```\n# not a heading\n```\n")
        #expect(file.headings.allSatisfy { $0.todo == nil && $0.tags.isEmpty && $0.timestamps.isEmpty && $0.links.isEmpty })
        #expect(file.fileID == nil && file.links.isEmpty)
        #expect(record("/notes/b.md", "Intro\n## First\n", kind: .text).title == "First")
    }

    @Test func plainTextIsOneBody() {
        let file = record("/notes/a.txt", "* not a heading\n#+title: not a title\n", kind: .text)
        #expect(file.headings.isEmpty && file.title == nil)
        #expect(file.preamble == "* not a heading\n#+title: not a title\n")
    }

    @Test func searchFindsTextFiles() throws {
        let store = try IndexStore()
        try store.write(record("/notes/a.md", "---\ntitle: Pond\n---\nOtters swim.\n# Herons\nThey wade.\n", kind: .text))
        try store.write(record("/notes/b.txt", "A list of kingfishers.\n", kind: .text))
        #expect(try store.search("otters").map(\.title) == ["Pond"])
        let heading = try store.search("wade")
        #expect(heading.map(\.title) == ["Herons"])
        #expect(heading.first?.start == 33)
        #expect(try store.search("kingfish").map(\.title) == ["b.txt"])
        // Not org: no outline, nodes or link targets.
        #expect(try store.outline(maxLevel: 3).isEmpty)
        #expect(try store.linkTargets().isEmpty)
    }
}
