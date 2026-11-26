import Foundation
import OrgCore
import Testing
@testable import OrgApp

@MainActor
struct SnippetLibraryTests {
    @Test func aBrokenFileKeepsTheSnippetsReadBefore() {
        let library = SnippetLibrary()
        var text: String? = "[[snippet]]\ntrigger = \"a\"\nbody = \"one\"\n[[snippet]]\ntrigger = \"b\"\n"
        let file = URL(fileURLWithPath: "/nowhere/snippets.toml")
        library.reload(from: file) { _ in text }
        #expect(library.snippets.map(\.trigger) == ["a"])
        #expect(library.problems == ["snippets.toml line 4: a snippet needs trigger and body"])
        text = "[[snippet]]\ntrigger = \"c\nbody = \"two\"\n"
        library.reload(from: file) { _ in text }
        #expect(library.snippets.map(\.trigger) == ["a"])
        #expect(library.problems == ["snippets.toml line 2: unclosed string"])
        text = nil
        library.reload(from: file) { _ in text }
        #expect(library.snippets.isEmpty && library.problems.isEmpty)
    }

    @Test func templatesWaitForTheirFile() {
        let library = SnippetLibrary()
        let template = Snippet(trigger: "week", body: "#+title: %t\n", file: true)
        library.expand(template, intoNewFile: "/tmp/notes/../notes/week.org")
        #expect(library.takeTemplate(for: "/tmp/other.org") == nil)
        #expect(library.takeTemplate(for: "/tmp/notes/week.org") == template)
        #expect(library.takeTemplate(for: "/tmp/notes/week.org") == nil)
    }

    // MARK: - yasnippet

    @Test func readsYasnippetFiles() {
        let meeting = EmacsImport.yasnippet("# -*- mode: snippet -*-\n# name: Meeting\n# key: meet\n# --\n* Meeting ${1:x}\n$0\n", fileName: "meeting")
        #expect(meeting == EmacsImport.Yasnippet(key: "meet", name: "Meeting", body: "* Meeting ${1:x}\n$0\n", lisp: nil))
        // No header: the file name is the key, as yasnippet has it.
        #expect(EmacsImport.yasnippet("plain $0", fileName: "pl").key == "pl")
        #expect(EmacsImport.yasnippet("# key: d\n# --\n`(format-time-string \"%F\")`", fileName: "d").lisp != nil)
        #expect(EmacsImport.yasnippet("# key: d\n# --\n\\`quoted\\`", fileName: "d").lisp == nil)
        #expect(EmacsImport.yasnippet("# key: u\n# --\n${1:x} ${1:$(upcase yas-text)}", fileName: "u").lisp != nil)
        #expect(EmacsImport.yasnippet("# key: c\n# type: command\n# --\n(insert \"x\")", fileName: "c").lisp != nil)
        // The table reads back as the same snippet.
        let parsed = try? Snippets.parse(EmacsImport.snippetTable(meeting))
        #expect(parsed?.snippets == [Snippet(trigger: "meet", name: "Meeting", body: "* Meeting ${1:x}\n$0\n")])
        let quotes = EmacsImport.Yasnippet(key: "q", name: "q", body: "a ''' b\n", lisp: nil)
        #expect((try? Snippets.parse(EmacsImport.snippetTable(quotes)))?.snippets.first?.body == "a ''' b\n")
    }

    @Test func importsSnippetsBesideTheConfiguration() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-snippets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let snippets = folder.appendingPathComponent("snippets/org-mode")
        try FileManager.default.createDirectory(at: snippets, withIntermediateDirectories: true)
        try "(setq org-tags-column 0)".write(to: folder.appendingPathComponent("config.el"), atomically: true, encoding: .utf8)
        try "# name: Meeting\n# key: meet\n# --\n* Meeting ${1:x}\n".write(to: snippets.appendingPathComponent("meeting"), atomically: true, encoding: .utf8)
        try "# key: now\n# --\n`(current-time-string)`".write(to: snippets.appendingPathComponent("now"), atomically: true, encoding: .utf8)
        try "org-mode".write(to: snippets.appendingPathComponent(".yas-parents"), atomically: true, encoding: .utf8)
        let result = EmacsImport.scan(EmacsImport.files(in: folder), doomDefaults: [])
        let found = result.items.filter { if case .snippet = $0.change { true } else { false } }
        #expect(found.map(\.name) == ["meet"] && found.first?.source == "snippets/org-mode/meeting")
        #expect(result.snippetsSkipped == 1 && result.unsupported.contains { $0.name == "snippet now" })
        #expect(Set(result.items.map(\.id) + result.unsupported.map(\.id)).count == result.items.count + result.unsupported.count)

        let out = folder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try "[[snippet]]\ntrigger = \"meet\"\nbody = \"mine\"\n".write(to: out.appendingPathComponent("snippets.toml"), atomically: true, encoding: .utf8)
        let first = await EmacsImport.apply(found, defaults: TestDefaults("orgstar-snippets"), workspace: nil, directory: out)
        #expect(first == "Nothing new to import.")
        try FileManager.default.removeItem(at: out.appendingPathComponent("snippets.toml"))
        let summary = await EmacsImport.apply(found, defaults: TestDefaults("orgstar-snippets"), workspace: nil, directory: out)
        #expect(summary == "Imported 1 snippet.")
        let written = try String(contentsOf: out.appendingPathComponent("snippets.toml"), encoding: .utf8)
        #expect(try Snippets.parse(written).snippets == [Snippet(trigger: "meet", name: "Meeting", body: "* Meeting ${1:x}\n")])
    }
}
