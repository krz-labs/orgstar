import Foundation
import OrgCore
import Testing
@testable import OrgApp
@testable import OrgConfig

@MainActor
struct SettingOptionsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func defaults() -> UserDefaults { TestDefaults("orgstar-options") }

    func setting(_ path: String) throws -> UserConfig.Setting {
        try #require(UserConfig.settings.first { $0.path == path })
    }

    static let file = """
        # My settings, kept with my dotfiles.
        fill-column=80     # wide enough
        org-log-done = "time"	# tab before this comment
        my-own-key = "kept"
        \torg-agenda-span = 7

        [theme]
        font = "JetBrains Mono"   # the comment stays
        link = "#0a7ea4"

        [[publish]]
        name = "site"
        font-size = 9

        [orgstar]
        keymap = 'doom'
        unknown-thing = [1, 2,
          3]

        """

    @Test func changedValueKeepsEveryOtherByte() throws {
        let changed = UserConfig.setting(Self.file, section: "", key: "fill-column", to: .integer(72))
        let before = Self.file.components(separatedBy: "\n")
        let after = changed.components(separatedBy: "\n")
        #expect(after.count == before.count)
        for (old, new) in zip(before, after) where !old.hasPrefix("fill-column") { #expect(old == new) }
        #expect(after[1] == "fill-column=72     # wide enough")

        let tabbed = UserConfig.setting(Self.file, section: "", key: "org-log-done", to: .string("note"))
        #expect(tabbed.contains("\norg-log-done = \"note\"\t# tab before this comment\n"))
        #expect(tabbed.replacingOccurrences(of: "\"note\"", with: "\"time\"") == Self.file)

        let indented = UserConfig.setting(Self.file, section: "", key: "org-agenda-span", to: .integer(14))
        #expect(indented == Self.file.replacingOccurrences(of: "\torg-agenda-span = 7", with: "\torg-agenda-span = 14"))

        // A key of the same name in [[publish]] is left alone.
        let size = UserConfig.setting(Self.file, section: "theme", key: "font-size", to: .integer(15))
        #expect(size.contains("[[publish]]\nname = \"site\"\nfont-size = 9\n"))
        #expect(size.contains("font = \"JetBrains Mono\"   # the comment stays\nlink = \"#0a7ea4\"\nfont-size = 15\n"))

        let keymap = UserConfig.setting(Self.file, section: "orgstar", key: "keymap", to: .string("mac"))
        #expect(keymap == Self.file.replacingOccurrences(of: "keymap = 'doom'", with: "keymap = \"mac\""))
    }

    @Test func missingKeysAreAdded() {
        let top = UserConfig.setting(Self.file, section: "", key: "org-startup-truncated", to: .bool(true))
        #expect(top == Self.file.replacingOccurrences(of: "\torg-agenda-span = 7\n", with: "\torg-agenda-span = 7\norg-startup-truncated = true\n"))
        let orgstar = UserConfig.setting(Self.file, section: "orgstar", key: "tab-bar", to: .bool(true))
        #expect(orgstar == Self.file.replacingOccurrences(of: "  3]\n", with: "  3]\ntab-bar = true\n"))
        let section = UserConfig.setting(Self.file, section: "org-stuck-projects", key: "tags", to: .string("project"))
        #expect(section == Self.file + "\n[org-stuck-projects]\ntags = \"project\"\n")
    }

    @Test func resetWritesTheDefaultInPlace() throws {
        let fill = try setting("fill-column")
        let reset = UserConfig.resetting(Self.file, fill)
        #expect(reset == Self.file)
        let changed = UserConfig.setting(Self.file, section: "", key: "fill-column", to: .integer(60))
        #expect(UserConfig.resetting(changed, fill) == Self.file)
        let keymap = try setting("orgstar.keymap")
        let target = defaults()
        #expect(UserConfig.apply(Self.file, to: target).count == 2)
        #expect(UserConfig.value(keymap, in: target) == .string("doom"))
        #expect(UserConfig.apply(UserConfig.resetting(Self.file, keymap), to: target).count == 2)
        #expect(UserConfig.value(keymap, in: target) == keymap.fallback)
        #expect(UserConfig.value(keymap, in: target) == .string("emacs"))
    }

    @Test func searchMatchesKeyEmacsNameAndDescription() throws {
        let found = { (query: String) in Set(UserConfig.settings.filter { $0.matches(query) }.map(\.path)) }
        #expect(found("fill-col") == ["fill-column", "auto-fill-mode"])
        #expect(found("FILL-COLUMN").contains("fill-column"))
        // The Emacs variable an [orgstar] key mirrors, and the table an entry belongs to.
        #expect(found("corfu-auto-delay") == ["orgstar.completion-auto-delay"])
        #expect(found("org-agenda-sorting-strategy") == ["org-agenda-sorting-strategy.agenda", "org-agenda-sorting-strategy.todo",
                                                         "org-agenda-sorting-strategy.tags", "org-agenda-sorting-strategy.search"])
        // The comment and the help.
        #expect(found("bibliography").contains("org-cite-global-bibliography"))
        #expect(found("Dynamic Type") == ["theme.font-size"])
        #expect(found("tags inherit") == ["org-use-tag-inheritance", "org-tags-exclude-from-inheritance"])
        // Every word must match, in any order.
        #expect(found("drawer clock") == ["org-clock-into-drawer"])
        #expect(found("nothing matches this") == [])
        #expect(found("") == Set(UserConfig.settings.map(\.path)))
        // Text as shown, such as a translation.
        let fill = try setting("fill-column")
        #expect(fill.matches("Spalte", texts: ["M-q füllt bis zu dieser Spalte"]))
        #expect(fill.matches("fullt", texts: ["M-q füllt bis zu dieser Spalte"]))
        #expect(!fill.matches("Spalte"))
    }

    @Test func emacsVariables() throws {
        #expect(try setting("fill-column").emacsVariable == "fill-column")
        #expect(try setting("spell-check").emacsVariable == nil)
        #expect(try setting("org-roam-dailies-file").emacsVariable == nil)
        #expect(try setting("org-stuck-projects.match").emacsVariable == "org-stuck-projects")
        #expect(try setting("theme.font").emacsVariable == nil)
        #expect(try setting("orgstar.keymap").emacsVariable == nil)
        #expect(try setting("orgstar.completion-auto-prefix").emacsVariable == "corfu-auto-prefix")
    }

    @Test func controlsWriteTheirFileValues() throws {
        let truncated = try setting("org-startup-truncated")
        #expect(truncated.control == .toggle)
        let fill = try setting("fill-column")
        #expect(fill.control == .integer)
        #expect(fill.value(text: " 72 ") == .integer(72))
        #expect(fill.value(text: "-3") == .integer(-3))
        #expect(fill.value(text: "wide") == nil)
        let start = try setting("org-agenda-start-day")
        #expect(start.control == .days)
        #expect(UserConfig.Setting.value(days: -3) == .string("-3d"))
        #expect(UserConfig.Setting.value(days: 0) == .string("+0d"))
        #expect(UserConfig.Setting.value(days: 2) == .string("+2d"))
        #expect(UserConfig.Setting.days(.string("-3d")) == -3)
        #expect(UserConfig.Setting.days(.string("+2d")) == 2)
        let log = try setting("org-log-done")
        #expect(log.control == .choice(["nil", "time", "note"]))
        #expect(log.value(choice: "time") == .string("time"))
        let meta = try setting("orgstar.option-as-meta")
        #expect(meta.control == .choice(["left", "right", "both", "none"]))
        #expect(meta.value(choice: "both") == .string("both"))
        let weekday = try setting("org-agenda-start-on-weekday")
        #expect(weekday.control == .choice(["nil", "0", "1", "2", "3", "4", "5", "6"]))
        #expect(weekday.choice(weekday.fallback) == "1")
        let numbers = try setting("display-line-numbers-type")
        #expect(numbers.control == .choice(["false", "true", "relative", "visual"]))
        #expect(numbers.value(choice: "true") == .bool(true))
        #expect(numbers.value(choice: "false") == .bool(false))
        #expect(numbers.value(choice: "relative") == .string("relative"))
        #expect(numbers.choice(.bool(false)) == "false")
        let keywords = try setting("org-todo-keywords")
        #expect(keywords.control == .text)
        #expect(keywords.value(text: "TODO | DONE\nWAIT | GONE") == .string("TODO | DONE\nWAIT | GONE"))
        #expect(UserConfig.setting("fill-column = 80\n", section: "", key: "org-todo-keywords", to: .string("A | B\nC | D"))
            == "fill-column = 80\norg-todo-keywords = \"A | B\\nC | D\"\n")
    }

    /// Every setting, changed through its control, written into the default file and applied,
    /// reads back as written; reset reads back as the default.
    @Test func everyControlRoundTripsThroughApply() throws {
        let target = defaults()
        for setting in UserConfig.settings {
            let changed: TOML.Value = switch setting.control {
            case .toggle: .bool(!(setting.fallback.bool ?? false))
            case .integer: try #require(setting.value(text: String((setting.fallback.integer ?? 0) + 3)))
            case .days: UserConfig.Setting.value(days: UserConfig.Setting.days(setting.fallback) - 3)
            case .choice(let names): setting.value(choice: try #require(names.first { $0 != setting.choice(setting.fallback) }))
            case .text: try #require(setting.value(text: "a \"quoted\" value\nover two lines"))
            }
            #expect(changed != setting.fallback, "\(setting.path)")
            let text = UserConfig.setting(UserConfig.defaultTemplate, section: setting.section, key: setting.key, to: changed)
            #expect(UserConfig.apply(text, to: target).isEmpty, "\(setting.path)")
            #expect(UserConfig.value(setting, in: target) == changed, "\(setting.path)")
            #expect(UserConfig.resetting(text, setting) == UserConfig.defaultTemplate, "\(setting.path)")
            #expect(UserConfig.apply(UserConfig.resetting(text, setting), to: target).isEmpty)
            #expect(UserConfig.value(setting, in: target) == setting.fallback, "\(setting.path)")
        }
    }

    @Test func manualChaptersDescribeTheirSettings() throws {
        let guide = Self.root.appendingPathComponent("docs/manual/guide")
        let reference = try String(contentsOf: guide.appendingPathComponent("13-configuration.org"), encoding: .utf8)
        for setting in UserConfig.settings {
            #expect(reference.contains("=\(setting.key)="), "\(setting.path) isn't in the config.toml reference")
            guard let chapter = setting.manualChapter else { continue }
            #expect(UserConfig.manualChapters[chapter] != nil, "\(chapter)")
            let text = try String(contentsOf: guide.appendingPathComponent(chapter + ".org"), encoding: .utf8)
            #expect(text.contains(setting.section == "" || setting.section == "orgstar" ? setting.key : setting.section), "\(setting.path) in \(chapter)")
        }
        for (chapter, title) in UserConfig.manualChapters {
            let text = try String(contentsOf: guide.appendingPathComponent(chapter + ".org"), encoding: .utf8)
            #expect(text.hasPrefix("#+TITLE: \(title)\n"), "\(chapter)")
        }
        #expect(UserConfig.help.keys.allSatisfy { key in UserConfig.settings.contains { $0.path == key } })
    }
}
