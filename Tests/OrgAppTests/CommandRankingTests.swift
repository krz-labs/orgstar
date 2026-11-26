import Foundation
import OrgCore
import Testing
@testable import OrgApp

struct CommandRankingTests {
    private func rank(_ titles: [String], _ query: String, _ usage: CommandUsage) -> (recent: [String], rest: [String]) {
        CommandRanking.rank(titles, query: query, usage: usage, id: { $0 }, titles: { [$0] })
    }

    @Test func recentsAreTheLastTenMostRecentFirst() {
        let usage = CommandUsage(defaults: TestDefaults("orgstar-command-usage"))
        for n in 1...12 { usage.record("c\(n)") }
        usage.record("c5")
        #expect(usage.recent == ["c5", "c12", "c11", "c10", "c9", "c8", "c7", "c6", "c4", "c3"])
        #expect(usage.uses(of: "c5") == 2 && usage.uses(of: "c1") == 1 && usage.uses(of: "other") == 0)
    }

    @Test func emptyQueryListsRecentsThenTheRestByTitle() {
        let usage = CommandUsage(defaults: TestDefaults("orgstar-command-usage"))
        usage.record("Tags")
        usage.record("Gone")
        usage.record("Schedule")
        let ranked = rank(["Tags", "Archive", "Schedule", "Deadline"], " ", usage)
        // A recent command no longer offered is left out.
        #expect(ranked.recent == ["Schedule", "Tags"])
        #expect(ranked.rest == ["Archive", "Deadline"])
    }

    @Test func frequentUseBreaksTies() {
        let usage = CommandUsage(defaults: TestDefaults("orgstar-command-usage"))
        #expect(FuzzyMatch.score("ac", "Alpha Copy") == FuzzyMatch.score("ac", "Alpha Cuts"))
        #expect(rank(["Alpha Cuts", "Alpha Copy"], "ac", usage).rest == ["Alpha Copy", "Alpha Cuts"])
        usage.record("Alpha Cuts")
        let ranked = rank(["Alpha Cuts", "Alpha Copy"], "ac", usage)
        #expect(ranked.recent.isEmpty && ranked.rest == ["Alpha Cuts", "Alpha Copy"])
    }

    @Test func frequentUseNeverBeatsAClearlyBetterMatch() throws {
        let usage = CommandUsage(defaults: TestDefaults("orgstar-command-usage"))
        for _ in 0..<100 { usage.record("Make Fun") }
        #expect(usage.bonus(for: "Make Fun") == FuzzyMatch.wordStartBonus * 100)
        // One word start apart, less one character of length.
        let better = try #require(FuzzyMatch.score("mu", "Move Up")), worse = try #require(FuzzyMatch.score("mu", "Make Fun"))
        #expect(better - worse == FuzzyMatch.wordStartBonus * 100 + 1)
        #expect(rank(["Make Fun", "Move Up"], "mu", usage).rest == ["Move Up", "Make Fun"])
    }

    @Test func groupsByFirstMatchingPrefix() {
        #expect(CommandGroups.group(of: "org.table.align").map { CommandGroups.orgMenu[$0].prefixes.first } == "org.table")
        #expect(CommandGroups.group(of: "org.ctrl-c-ctrl-c") == nil)
        #expect(CommandGroups.group(of: "app.clock.in") == nil)
        #expect(CommandGroups.group(of: "app.clock.in", in: CommandGroups.commandList) == CommandGroups.orgMenu.count)
    }

    private func context(_ text: String, caret: Int) -> EditContext {
        EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
    }

    @Test func reasonNamesWhatTheCaretIsNotIn() {
        let text = "Before\n* One\nBody\n| a | b |\n- item\n"
        #expect(CommandReason.reason(for: "org.table.align", in: context(text, caret: 0)) == "No table at point")
        #expect(CommandReason.reason(for: "org.item.indent", in: context(text, caret: 0)) == "Not in a list")
        #expect(CommandReason.reason(for: "org.subtree.move-up", in: context(text, caret: 0)) == "Not in a subtree")
        #expect(CommandReason.reason(for: "org.link.open", in: context(text, caret: 0)) == "Not on a link")
        #expect(CommandReason.reason(for: "org.babel.execute", in: context(text, caret: 0)) == "Not in a code block")
        // In the entry, a subtree command that still doesn't apply has nothing to do.
        #expect(CommandReason.reason(for: "org.subtree.move-up", in: context(text, caret: 15)) == "Nothing to do here")
        #expect(CommandReason.reason(for: "org.table.align", in: context(text, caret: 20)) == "Nothing to do here")
    }
}
