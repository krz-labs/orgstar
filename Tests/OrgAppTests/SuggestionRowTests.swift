import Foundation
import Testing
import OrgCore
@testable import OrgApp

/// The iOS suggestion row (#145).
struct SuggestionRowTests {
    func context(_ text: String, options: EditingOptions = .org) -> EditContext {
        let caret = text.utf16.count
        return EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], options: options)
    }

    @Test func rowOnlyWithTheOnScreenKeyboard() {
        #expect(SuggestionRow.usesRow(hardwareKeyboard: false))
        #expect(!SuggestionRow.usesRow(hardwareKeyboard: true))
    }

    @Test func showsWhileThereAreCandidates() {
        let completion = OrgCompletion.at(context("#+TIT"))
        #expect(SuggestionRow.shows(completion, dismissed: false))
        #expect(!SuggestionRow.shows(completion, dismissed: true))
        #expect(!SuggestionRow.shows(nil, dismissed: false))
        // Nothing matches: the key bar stays.
        #expect(!SuggestionRow.shows(OrgCompletion.at(context("#+XYZQ")), dismissed: false))
    }

    @Test func showsWhenTheListWouldOpenByItself() {
        let options = CompletionOptions(auto: true, prefix: 3)
        for text in ["#+TI", "#+TIT"] {
            let completion = OrgCompletion.at(context(text))
            let opened = CompletionAuto.opens(completion, options) ? completion : nil
            #expect(SuggestionRow.shows(opened, dismissed: false) == (text == "#+TIT"))
        }
    }

    @Test func itemsFollowTheListsOrder() throws {
        let completion = try #require(OrgCompletion.at(context("#+TIT")))
        let items = SuggestionRow.items(completion)
        #expect(items.map(\.candidate) == completion.candidates)
        #expect(items.allSatisfy { !$0.snippet && $0.detail == nil })
        #expect(SuggestionRow.items(completion, limit: 1).count == min(1, completion.candidates.count))
    }

    @Test func snippetsWithTheirNames() throws {
        var options = EditingOptions.org
        options.snippets = [Snippet(trigger: "meeting", name: "Meeting notes", body: "x"), Snippet(trigger: "mail", body: "y")]
        let completion = try #require(OrgCompletion.at(context("m", options: options)))
        #expect(completion.kind == .snippet)
        let items = SuggestionRow.items(completion)
        #expect(Set(items.map(\.candidate)) == ["meeting", "mail"])
        #expect(items.allSatisfy { $0.snippet })
        #expect(items.first { $0.candidate == "meeting" }?.detail == "Meeting notes")
        #expect(items.first { $0.candidate == "mail" }?.detail == nil)
    }

    @Test func templatesWithTheirBlocks() throws {
        let completion = try #require(OrgCompletion.at(context("<s")))
        #expect(completion.kind == .template)
        let item = try #require(SuggestionRow.items(completion).first { $0.candidate == "<s" })
        #expect(item.detail == "src")
    }
}
