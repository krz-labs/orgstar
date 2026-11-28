import Foundation
import OrgCore

/// What the All Settings screens need of a setting: the control that edits it, the file value
/// each control value writes, the Emacs variable it mirrors, longer help, and the manual
/// chapter that describes it.
extension UserConfig.Setting {
    /// The control that edits a setting.
    public enum Control: Equatable, Sendable {
        case toggle
        case integer
        /// A day offset, `org-agenda-start-day`.
        case days
        /// One of these names.
        case choice([String])
        case text
    }

    public var control: Control {
        switch kind {
        case .bool: .toggle
        case .integer: .integer
        case .string: .text
        case .dayOffset: .days
        case .choice(let choices): .choice(choices.map(\.name))
        case .integerChoice(let choices): .choice(choices.map(\.name))
        case .lineNumbers: .choice(["false", "true", "relative", "visual"])
        }
    }

    /// The file value for a choice's name.
    public func value(choice name: String) -> TOML.Value {
        if case .lineNumbers = kind, let on = Bool(name) { return .bool(on) }
        return .string(name)
    }

    /// The choice's name for a file value.
    public func choice(_ value: TOML.Value) -> String {
        switch value {
        case .bool(let b): String(b)
        case .integer(let i): String(i)
        case .string(let s): s
        case .array: ""
        }
    }

    /// The file value for a day offset: `"+3d"`, `"-3d"`.
    public static func value(days: Int) -> TOML.Value { .string((days < 0 ? "" : "+") + "\(days)d") }

    /// The day offset of a file value, 0 for one that isn't.
    public static func days(_ value: TOML.Value) -> Int { value.string.flatMap(UserConfig.dayOffset) ?? 0 }

    /// The file value for typed text: a whole number for an integer setting (nil when it isn't
    /// one), the text itself for the rest.
    public func value(text: String) -> TOML.Value? {
        if case .integer = kind { return Int(text.trimmingCharacters(in: .whitespaces)).map(TOML.Value.integer) }
        return .string(text)
    }

    /// The Emacs variable the setting mirrors: its key at the top of the file, its table's name
    /// for an entry of an Emacs list; nil for orgstar's own.
    public var emacsVariable: String? {
        switch section {
        case "": UserConfig.notEmacsVariables.contains(key) ? nil : key
        case "theme": nil
        case "orgstar": UserConfig.emacsCounterparts[key]
        default: section
        }
    }

    /// Help longer than the comment, in English; nil where the comment says it all.
    public var help: String? { UserConfig.help[path] }

    /// The manual chapter that describes the setting, as its file name without `.org`, besides
    /// the config.toml reference in Configuration.
    public var manualChapter: String? {
        let rules: [(String, String)]
        let name: String
        switch section {
        case "": (rules, name) = (UserConfig.chapterRules, key)
        case "orgstar": (rules, name) = (UserConfig.orgstarChapterRules, key)
        case "theme": return nil
        default: (rules, name) = ([("", "07-agenda")], section)
        }
        return rules.first { name.hasPrefix($0.0) }?.1
    }

    /// Whether the setting has `value` in every word of `query`: in its key, table, Emacs
    /// variable, comment or help, or in `texts` (the comment and help as shown). Case and
    /// diacritics don't count.
    public func matches(_ query: String, texts: [String] = []) -> Bool {
        let haystack = ([path, emacsVariable ?? "", comment, help ?? ""] + texts).joined(separator: "\n")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

extension UserConfig {
    /// `text` with `setting` set to its default, as Reset to Default writes it: the line stays,
    /// with its comment, at the default value.
    public static func resetting(_ text: String, _ setting: Setting) -> String {
        self.setting(text, section: setting.section, key: setting.key, to: setting.fallback)
    }

    /// Keys at the top of the file that are no Emacs variable.
    static let notEmacsVariables: Set<String> = [
        "spell-check", "notes-package", "org-roam-dailies-file", "org-roam-dailies-head", "org-roam-dailies-entry",
    ]

    /// `[orgstar]` keys that mirror an Emacs package's variable.
    static let emacsCounterparts = [
        "completion-auto": "corfu-auto", "completion-auto-delay": "corfu-auto-delay", "completion-auto-prefix": "corfu-auto-prefix",
    ]

    /// The manual's chapters, by file name without `.org`, with their titles.
    public static let manualChapters: [String: String] = [
        "01-files-and-folders": "Files, folders and buffers",
        "02-the-editor": "The editor",
        "03-keys": "Keys and commands",
        "04-outlines": "Outlines and structure",
        "05-todos-and-tags": "TODOs and tags",
        "06-dates-and-clocking": "Dates, scheduling and clocking",
        "07-agenda": "The agenda",
        "08-capture": "Capture",
        "09-links": "Links",
        "12-export": "Export",
        "13-configuration": "Configuration",
        "16-flashcards": "Flashcards",
    ]

    /// The chapter of a top-level key, by the first prefix it has.
    static let chapterRules: [(String, String)] = [
        ("org-agenda-", "07-agenda"), ("org-habit-", "07-agenda"), ("org-deadline-", "07-agenda"),
        ("appt-", "06-dates-and-clocking"), ("org-clock-", "06-dates-and-clocking"), ("org-timer-", "06-dates-and-clocking"),
        ("org-log-", "05-todos-and-tags"), ("org-todo-", "05-todos-and-tags"), ("org-tag", "05-todos-and-tags"),
        ("org-use-tag", "05-todos-and-tags"), ("org-enforce-", "05-todos-and-tags"), ("org-track-", "05-todos-and-tags"),
        ("org-roam-", "09-links"), ("denote-", "09-links"), ("notes-", "09-links"), ("org-cite-", "09-links"),
        ("org-yank-", "09-links"), ("org-display-", "09-links"),
        ("org-refile-", "04-outlines"), ("org-archive-", "04-outlines"), ("org-attach-", "04-outlines"), ("org-crypt-", "04-outlines"),
        ("org-list-", "04-outlines"), ("org-M-RET", "04-outlines"), ("org-insert-", "04-outlines"), ("org-use-property", "04-outlines"),
        ("org-icalendar-", "12-export"), ("org-export-", "12-export"), ("org-fc-", "16-flashcards"), ("org-use-speed", "03-keys"),
        ("", "02-the-editor"),
    ]

    /// The chapter of an `[orgstar]` key, by the first prefix it has.
    static let orgstarChapterRules: [(String, String)] = [
        ("keymap", "03-keys"), ("option-as-meta", "03-keys"), ("completion-", "02-the-editor"), ("pdf-", "12-export"),
        ("agenda-", "07-agenda"), ("calendar-", "07-agenda"), ("triage-", "07-agenda"), ("weekly-review-", "07-agenda"),
        ("reminders", "06-dates-and-clocking"), ("global-capture", "08-capture"),
        ("show-hidden", "01-files-and-folders"), ("ignored-", "01-files-and-folders"), ("tab-bar", "01-files-and-folders"),
        ("show-markup", "02-the-editor"), ("save", "01-files-and-folders"), ("menu-bar", "06-dates-and-clocking"),
    ]

    /// Help for settings whose comment is short of what they do, by `section.key`.
    static let help: [String: String] = [
        "fill-column": "The column Fill Paragraph (M-q) breaks lines at, and the column past which typing a space breaks the line when auto-fill-mode is on.",
        "org-use-property-inheritance": "Which properties a heading takes from its ancestors: nil for none, t for all, or the names of the properties that inherit, separated by spaces, such as \"STYLE\". ID and CUSTOM_ID never inherit.",
        "org-hide-emphasis-markers": "While markup is hidden, the markers around *bold*, /italic/, =code= and the other emphasis are hidden, and tags, tables and filling measure the text without them. View ▸ Show Markup shows them.",
        "org-pretty-entities": "While markup is hidden, entities such as \\alpha show as the character they name (α), and subscripts and superscripts such as x_{1} are drawn lowered or raised.",
        "org-todo-keywords": "The TODO keywords of files without a #+TODO line, in #+TODO syntax: active keywords, then |, then done keywords, such as \"TODO NEXT | DONE\". Separate several sequences with \\n. A letter in parentheses after a keyword, as in TODO(t), turns on fast selection with that key. Read at launch.",
        "org-log-done": "What marking an entry done records: nil records nothing, time adds a CLOSED timestamp, note adds the timestamp and asks for a note.",
        "org-log-into-drawer": "Where state change notes go: a drawer's name, such as \"LOGBOOK\" (Emacs's t), or \"\" to put them under the heading.",
        "org-enforce-todo-dependencies": "An entry can't become done while a descendant has an active TODO keyword, or, under a parent with the ORDERED property, while an earlier sibling has one.",
        "org-enforce-todo-checkbox-dependencies": "An entry can't become done while its text has an unchecked checkbox.",
        "org-archive-location": "Where Archive Subtree moves an entry that has no ARCHIVE property and whose file has no #+ARCHIVE: line, as file::heading. %s is the file's name, so \"%s_archive::\" moves entries of notes.org to the top level of notes.org_archive.",
        "org-use-tag-inheritance": "Which tags a heading takes from its ancestors: \"t\" all, \"nil\" none, tag names separated by spaces, or a regular expression in braces, such as \"{^@}\" for the tags that start with @. Read at launch.",
        "org-tags-exclude-from-inheritance": "Tags that never inherit, separated by spaces, such as crypt. As in Org, it applies when org-use-tag-inheritance is t or a regular expression, not a list of names. Read at launch.",
        "org-tag-alist": "The tags Set Tags (C-c C-q) offers in files without #+TAGS, in #+TAGS syntax: a letter in parentheses is the tag's key, and tags in braces exclude each other, as in \"work(w) home(h) { @office(o) @home(H) }\". Separate rows with \\n.",
        "org-track-ordered-property-with-tag": "A tag that Toggle ORDERED Property adds and removes along with the property: \"t\" for the tag ORDERED, a tag's name, or \"nil\" for none.",
        "org-startup-truncated": "Long lines run off the right edge instead of wrapping. Emacs's default is t; Doom Emacs wraps.",
        "electric-pair-mode": "Typing an opening bracket, < or a quote also types its closing one, as electric-pair-mode does. Off in plain Emacs; Doom Emacs pairs with smartparens.",
        "org-roam-dailies-file": "A daily note's file name, in org-roam-dailies-directory. %<…> formats the date as format-time-string does, so \"%<%Y-%m-%d>.org\" names the note for 1 March 2026 2026-03-01.org.",
        "org-roam-dailies-entry": "The capture template Capture to Daily Note files under, in capture template syntax: %? is where the caret goes.",
        "denote-sequence-scheme": "How denote-sequence numbers notes: numeric (1=1=2), alphanumeric (1a2) or alphanumeric-delimited (1=a2).",
        "org-attach-use-inheritance": "Whether an entry's attachment folder can come from an ancestor's DIR or ID property: selective follows org-use-property-inheritance, t always, nil never.",
        "org-cite-global-bibliography": "Bibliography files, .bib or CSL-JSON .json, that every file's citations use after its own #+bibliography: files, separated by :. ~ is your home folder. Insert Citation, key completion, following citations and export read them.",
        "org-fc-review-history-file": "The file flashcard ratings are added to, in org-fc's format: relative to the configuration folder unless absolute, ~ for your home folder; empty for org-fc-reviews.tsv in the configuration folder.",
        "org-crypt-use-before-save-magic": "Encrypt the entries with org-crypt-tag-matcher's tag on every save. Without their passphrase the file isn't saved until it's given.",
        "org-display-remote-inline-images": "Images at http(s) links: skip doesn't show them, download fetches them and keeps them until orgstar quits, cache keeps them on disk.",
        "display-line-numbers-type": "Line numbers in the editor's gutter: false for none, true for each line's number, \"relative\" for how many lines of the file away from the caret's line, \"visual\" for how many lines on the screen away, counting each wrapped line. View ▸ Line Numbers changes it. The iOS editor has no line numbers.",
        "org-agenda-start-day": "The agenda's first day relative to today, as \"-3d\" or \"+0d\". Only day offsets are accepted.",
        "org-deadline-warning-days": "Days ahead the agenda and the deadline sparse tree warn about a deadline. A -Nd cookie in the timestamp, as in <2026-03-01 Sun -5d>, overrides it.",
        "org-agenda-start-on-weekday": "The day weeks start on, 0 (Sunday) to 6 (Saturday), for the week view and spans of 7 or 14 days. nil starts them on the day the view starts from.",
        "org-habit-show-habits-only-for-today": "Show habits only on today's agenda. Off, a habit also shows on the later days it is scheduled for.",
        "org-agenda-todo-ignore-scheduled": "The TODO list leaves out scheduled entries: \"all\" (or \"t\") all of them, \"future\" those scheduled after today, \"past\" today or before, \"N\" N or more days ahead, \"-N\" N or more days ago; \"nil\" none.",
        "org-agenda-todo-ignore-deadlines": "The TODO list leaves out entries with deadlines: \"near\" (or \"t\") those within their warning period, \"far\" those beyond it, \"all\", \"future\", \"past\", \"N\" or \"-N\" as for scheduled entries; \"nil\" none.",
        "org-agenda-todo-ignore-timestamp": "The TODO list leaves out entries with other active timestamps: \"all\" (or \"t\"), \"future\", \"past\", \"N\" or \"-N\" as for scheduled entries; \"nil\" none.",
        "org-agenda-tags-todo-honor-ignore-options": "The org-agenda-todo-ignore settings apply to TODO-only tag matches (M) too, not only to the TODO list.",
        "org-agenda-search-view-force-full-words": "Text search snippets match whole words only, as a leading : does.",
        "org-agenda-dim-blocked-tasks": "t dims entries that org-enforce-todo-dependencies or org-enforce-todo-checkbox-dependencies blocks, invisible hides them (entries blocked only by checkboxes are still dimmed), nil shows them as usual.",
        "appt-message-warning-time": "Minutes of warning before timed entries. An entry's APPT_WARNTIME property overrides it.",
        "org-clock-idle-time": "Minutes without keyboard or mouse input, with a clock running, before orgstar asks what to do with the idle time. 0 never asks (Emacs's nil). Mac only.",
        "org-clock-into-drawer": "Where clock lines go: \"t\" the log drawer (LOGBOOK), \"nil\" no drawer, \"N\" a drawer once there are N clock lines, or a drawer's name. An entry's CLOCK_INTO_DRAWER property overrides it.",
        "org-refile-allow-creating-parent-nodes": "t or confirm: a refile target typed as an existing target, /, and a new heading's title adds that heading under the target; confirm asks first. nil doesn't.",
        "org-icalendar-use-scheduled": "What a SCHEDULED date makes in iCalendar export, separated by spaces: event-if-not-todo, event-if-todo, event-if-todo-not-done and todo-start.",
        "org-agenda-use-time-grid": "Grid lines at the times in [org-agenda-time-grid], on the days it names.",
        "org-agenda-prefix-format.agenda": "The prefix of lines in the day view: %c the category, %t the time, %s the scheduled or deadline leader, %e the effort, %l the level, %b the outline path; a width after %, as in %-12:c, pads the item. A view in views.toml can set its own with prefix-format.",
        "org-agenda-prefix-format.todo": "The prefix of lines in the TODO list, with the codes of the day view's.",
        "org-agenda-prefix-format.tags": "The prefix of tag and property match lines, with the codes of the day view's.",
        "org-agenda-sorting-strategy.agenda": "How lines within a day are ordered: sort keys separated by spaces, each used when the ones before it tie, such as time-up, priority-down, category-keep, alpha-up, effort-up, tag-up and todo-state-up. Unknown keys are ignored. A view in views.toml can set its own with sorting-strategy.",
        "org-agenda-sorting-strategy.todo": "How the TODO list is ordered, with the sort keys of the day view's order.",
        "org-agenda-sorting-strategy.tags": "How tag and property matches are ordered, with the sort keys of the day view's order.",
        "org-agenda-sorting-strategy.search": "How text search results are ordered, with the sort keys of the day view's order.",
        "org-stuck-projects.match": "The entries that are projects, as a tag and property match: \"+LEVEL=2/-DONE\" is every level-2 heading that isn't DONE. A project is stuck when nothing in it matches the other three.",
        "org-agenda-time-grid.when": "Which days get a grid, separated by spaces: daily (views of one day), today, weekly (every day), require-timed (only days with a timed entry) and remove-match (no line at a time an entry has).",
        "theme.font-size": "The text size, in points. Headings are larger by heading-size-step per level. On iOS it is the size at the default text size and grows and shrinks with Dynamic Type.",
        "theme.theme-file": "A theme in its own file, relative to the configuration folder. Its colors apply under the ones set in config.toml. default-theme.toml in the folder lists every color key.",
        "orgstar.keymap": "The key preset: emacs, mac or doom. Bindings of your own in keymap.toml go over it.",
        "orgstar.option-as-meta": "Which Option key is Meta in the editor: left, right, both or none.",
        "orgstar.completion-auto-delay": "Milliseconds after typing stops before the completion list opens by itself. Emacs's corfu-auto-delay is in seconds.",
        "orgstar.ignored-folders": "Folder names never listed or searched, separated by spaces. The default leaves out version control, build and cache folders such as .git, node_modules and .venv.",
        "orgstar.triage-view": "The name of a view, from views.toml or built in, whose entries Triage goes through in its order. \"\" goes through the entries in the default capture template's target: the children of its headline or outline path, the top-level entries of its file, or the entries in its date tree.",
        "orgstar.weekly-review-waiting": "The TODO keyword the built-in Weekly Review lists as waiting for someone, such as WAIT. A Weekly Review defined in views.toml replaces the built-in one and its blocks.",
        "orgstar.global-capture-hotkey": "⌃⌥Space opens Capture from any app on the Mac. Templates go in capture.toml.",
        "orgstar.menu-bar-clock": "What the Mac menu bar item shows beside the clock symbol while a clock runs. heading: the time and the heading, as Org's mode line shows them, such as [0:25] (Write the report), with the entry's clocked total and its Effort when it has one; time: the time since clocking in, such as 0:25; none: the symbol only.",
        "orgstar.menu-bar-capture-template": "The key, in capture.toml, of the template the menu bar's capture field files with when Return is pressed. A template with prompts opens the capture window instead. \"\" uses the first template.",
    ]
}
