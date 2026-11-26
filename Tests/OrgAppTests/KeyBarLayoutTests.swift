import Foundation
import Testing
@testable import OrgApp

@MainActor
struct KeyBarLayoutTests {
    func defaults() -> UserDefaults { TestDefaults("orgstar-keybar") }

    @Test func defaultsWithoutTheTable() {
        let d = defaults()
        #expect(UserConfig.apply("fill-column = 70\n", to: d).isEmpty)
        #expect(KeyBarLayout.stored(.iphone, in: d) == nil)
        #expect(KeyBarLayout.stored(.ipad, in: d) == nil)
        #expect(KeyBarLayout.Width.iphone.defaultIDs.contains("plan"))
        #expect(!KeyBarLayout.Width.ipad.defaultIDs.contains("plan"))
        #expect(KeyBarLayout.Width.ipad.defaultIDs.suffix(4) == ["schedule", "deadline", "tags", "hide-keyboard"])
    }

    @Test func readsIPhoneAndIPadLists() {
        let d = defaults()
        let problems = UserConfig.apply("""
            [key-bar]
            iphone = ["commands", "org.snippet:td", "macro.named.tidy", "commands"]
            ipad = [
              "fold",  # TAB
              "hide-keyboard",
            ]
            """, to: d)
        #expect(problems.isEmpty)
        #expect(KeyBarLayout.stored(.iphone, in: d) == ["commands", "org.snippet:td", "macro.named.tidy"])
        #expect(KeyBarLayout.stored(.ipad, in: d) == ["fold", "hide-keyboard"])
        // A list taken out of the file goes back to the default.
        UserConfig.apply("[key-bar]\nipad = []\n", to: d)
        #expect(KeyBarLayout.stored(.iphone, in: d) == nil)
        #expect(KeyBarLayout.stored(.ipad, in: d) == [])
    }

    @Test func reportsBadValuesAndUnknownIDs() {
        let d = defaults()
        let problems = UserConfig.apply("""
            [key-bar]
            iphone = "fold"
            ipad = ["fold", 3]
            watch = []
            """, to: d)
        #expect(problems.count == 3)
        #expect(problems.contains { $0.contains("key-bar.iphone must be a list") })
        #expect(problems.contains { $0.contains("unknown setting key-bar.watch") })
        #expect(KeyBarLayout.stored(.iphone, in: d) == nil)
        let known: Set = ["fold", "commands"]
        #expect(KeyBarLayout.problems(["fold", "nonsense", "commands"], .ipad, known: known.contains)
            == ["config.toml: key-bar.ipad has no command nonsense"])
    }

    @Test func writesAndRemovesLists() throws {
        let start = """
            fill-column = 80

            [key-bar]
            iphone = [
              "fold",
              "todo",
            ]  # mine
            ipad = ["fold"]
            """
        let written = UserConfig.setting(start, section: KeyBarLayout.table, key: "iphone", to: .array([.string("act"), .string("org.snippet:td")]))
        #expect(written.contains("iphone = [\"act\", \"org.snippet:td\"]\nipad = [\"fold\"]"))
        let d = defaults()
        #expect(UserConfig.apply(written, to: d).isEmpty)
        #expect(KeyBarLayout.stored(.iphone, in: d) == ["act", "org.snippet:td"])
        let removed = UserConfig.removingSetting(start, section: KeyBarLayout.table, key: "iphone")
        #expect(removed == "fill-column = 80\n\n[key-bar]\nipad = [\"fold\"]")
        let added = UserConfig.setting("fill-column = 80\n", section: KeyBarLayout.table, key: "ipad", to: .array([.string("fold")]))
        #expect(added.hasSuffix("[key-bar]\nipad = [\"fold\"]\n"))
    }

    @Test func fitsOrOverflows() {
        let ids = ["a", "b", "wide", "c", "d"]
        let slots: (String) -> Int = { $0 == "wide" ? 2 : 1 }
        #expect(KeyBarLayout.fit(ids, available: 6, slots: slots) == (ids, []))
        #expect(KeyBarLayout.fit(ids, available: 20, slots: slots) == (ids, []))
        // One slot goes to More.
        #expect(KeyBarLayout.fit(ids, available: 5, slots: slots) == (["a", "b", "wide"], ["c", "d"]))
        // A wide button that doesn't fit ends the row, though a narrow one after it would fit.
        #expect(KeyBarLayout.fit(ids, available: 4, slots: slots) == (["a", "b"], ["wide", "c", "d"]))
        #expect(KeyBarLayout.fit(ids, available: 2, slots: slots) == (["a"], ["b", "wide", "c", "d"]))
        #expect(KeyBarLayout.fit(ids, available: 0, slots: slots) == ([], ids))
        #expect(KeyBarLayout.fit([], available: 0, slots: slots) == ([], []))
    }

    @Test func slotsWidenWithTheSymbols() {
        // iPhone 17: 402 points less the bar's margins.
        let width: CGFloat = 390
        let ids = KeyBarLayout.Width.iphone.defaultIDs
        #expect(KeyBarLayout.availableSlots(width: width, scale: 1) == 12)
        #expect(KeyBarLayout.availableSlots(width: width, scale: 0.8) == 12)
        #expect(KeyBarLayout.fit(ids, available: KeyBarLayout.availableSlots(width: width, scale: 1)) { _ in 1 } == (ids, []))
        // At the largest symbol size (23 against 17 points of body text), slots are a third wider.
        let large = KeyBarLayout.availableSlots(width: width, scale: 23.0 / 17)
        #expect(large == 9)
        let (shown, more) = KeyBarLayout.fit(ids, available: large) { _ in 1 }
        #expect(shown == Array(ids.prefix(8)) && more == Array(ids.dropFirst(8)))
        #expect(CGFloat(large) * KeyBarLayout.slotWidth * 23 / 17 <= width)
        #expect(KeyBarLayout.availableSlots(width: 0, scale: 2) == 0)
    }

    @Test func snippetFieldsTakePromoteAndDemote() {
        let next = KeyBarLayout.nextField, previous = KeyBarLayout.previousField
        #expect(KeyBarLayout.withSnippetFields(KeyBarLayout.Width.iphone.defaultIDs).prefix(4)
            == ["commands", "fold", previous, next])
        #expect(KeyBarLayout.withSnippetFields(KeyBarLayout.Width.iphone.defaultIDs).count == KeyBarLayout.Width.iphone.defaultIDs.count)
        #expect(KeyBarLayout.withSnippetFields(["fold", "todo"]) == [previous, next, "fold", "todo"])
        #expect(KeyBarLayout.withSnippetFields(["demote", "fold"]) == [previous, next, "fold"])
        #expect(KeyBarLayout.withSnippetFields([next, "promote", "demote"]) == [next, previous, "demote"])
        #expect(KeyBarLayout.withSnippetFields([previous, next]) == [previous, next])
    }

    @Test func faces() {
        #expect(KeyBarLayout.face(title: "Insert Link…") == "Insert Link")
        #expect(KeyBarLayout.slots(symbol: true, face: "Insert Link") == 1)
        #expect(KeyBarLayout.slots(symbol: false, face: "TODO") == 1)
        #expect(KeyBarLayout.slots(symbol: false, face: "Insert Link") == 2)
    }
}
