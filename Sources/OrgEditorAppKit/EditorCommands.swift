#if os(macOS)
import AppKit
import OrgCore

/// Every command a key, menu or the palette can run, by id.
public struct EditorCommand: Sendable {
    /// The title as the string catalog translates it.
    public var localizedTitle: String { CommandTitle.localized(title) }

    public enum Action: Sendable {
        /// An `OrgCore` command, run through `OrgEditor.perform`.
        case text(any OrgCommand)
        /// Folding and other view changes the editor makes itself.
        case view
        /// A text-system action; `extending` is its variant that extends the selection, used
        /// while a mark is active.
        case edit(selector: String, extending: String? = nil)
        /// Mark handling in the editor.
        case mark
        /// The find bar.
        case find(NSTextFinder.Action)
        /// Handled by the app (save, quick open, palette).
        case app
    }

    public let id: String
    public let title: String
    public let action: Action

    /// Shown in the palette; text-system movement and editing are left to keys.
    public var inPalette: Bool {
        switch action {
        case .edit, .mark: false
        default: true
        }
    }
}

public enum EditorCommands {
    /// Every command, with the named keyboard macros.
    public static var all: [EditorCommand] { builtIn + namedMacros(NamedMacros.shared) }

    public static let builtIn: [EditorCommand] = Commands.everything.map { EditorCommand(id: $0.id, title: $0.title, action: .text($0)) } + [
        EditorCommand(id: "org.cycle", title: "Cycle Visibility", action: .view),
        EditorCommand(id: "org.cycle-global", title: "Cycle Global Visibility", action: .view),
        EditorCommand(id: "org.fold.toggle", title: "Toggle Fold", action: .view),
        EditorCommand(id: "org.fold.open", title: "Open Fold", action: .view),
        EditorCommand(id: "org.fold.close", title: "Close Fold", action: .view),
        EditorCommand(id: "org.fold.open-subtree", title: "Open Subtree Folds", action: .view),
        EditorCommand(id: "org.fold.open-all", title: "Open All Folds", action: .view),
        EditorCommand(id: "org.fold.close-all", title: "Close All Folds", action: .view),
        EditorCommand(id: "org.fold.more", title: "Show Next Fold Level", action: .view),
        EditorCommand(id: "org.fold.less", title: "Hide Next Fold Level", action: .view),
        EditorCommand(id: "org.narrow.subtree", title: "Narrow to Subtree", action: .view),
        EditorCommand(id: "org.narrow.block", title: "Narrow to Block", action: .view),
        EditorCommand(id: "org.widen", title: "Widen", action: .view),
        EditorCommand(id: "org.narrow.toggle", title: "Narrow to Subtree or Widen", action: .view),
        EditorCommand(id: "org.toggle-inline-images", title: "Show or Hide Inline Images", action: .view),
        EditorCommand(id: "org.toggle-inline-images-linked", title: "Show or Hide Inline Images, Including Described Links", action: .view),
        EditorCommand(id: "org.latex-preview", title: "Show or Hide LaTeX Previews", action: .view),
        EditorCommand(id: "editor.complete", title: "Complete at Point", action: .view),
        EditorCommand(id: "editor.dabbrev-expand", title: "Expand Word", action: .view),
        EditorCommand(id: "editor.dabbrev-completion", title: "Complete Word", action: .view),
        EditorCommand(id: "editor.dabbrev-completion-previous", title: "Complete Word, Last First", action: .view),
        EditorCommand(id: "org.snippet.next-field", title: "Next Snippet Field", action: .view),
        EditorCommand(id: "org.snippet.previous-field", title: "Previous Snippet Field", action: .view),
        EditorCommand(id: "app.new-file-from-template", title: "New File from Template…", action: .app),
        EditorCommand(id: "app.replace-in-files", title: "Replace in Files…", action: .app),
        EditorCommand(id: "app.rename-tag", title: "Rename Tag…", action: .app),
        EditorCommand(id: "app.rename-todo-keyword", title: "Rename TODO Keyword…", action: .app),
        EditorCommand(id: "editor.toggle-spell-check", title: "Check Spelling While Typing", action: .view),
        EditorCommand(id: "editor.toggle-truncate-lines", title: "Truncate or Wrap Long Lines", action: .view),
        EditorCommand(id: "editor.toggle-auto-fill", title: "Turn Auto Fill On or Off", action: .view),
        EditorCommand(id: "org.table.toggle-column-width", title: "Shrink or Expand Table Column", action: .view),
        EditorCommand(id: "org.table.shrink", title: "Shrink Table Columns with Widths", action: .view),
        EditorCommand(id: "org.table.expand", title: "Expand Table Columns", action: .view),
        EditorCommand(id: "org.link.insert", title: "Insert Link…", action: .app),
        EditorCommand(id: "org.link.store", title: "Store Link", action: .app),
        EditorCommand(id: "org.id.store-link", title: "Store ID Link", action: .app),
        EditorCommand(id: "org.subtree.paste", title: "Paste Subtree", action: .app),
        EditorCommand(id: "app.block.save", title: "Save Block", action: .app),
        EditorCommand(id: "app.block.cancel", title: "Leave Block", action: .app),

        EditorCommand(id: "app.save", title: "Save", action: .app),
        EditorCommand(id: "app.quit", title: "Quit orgstar", action: .app),
        EditorCommand(id: "app.save-all", title: "Save All Buffers", action: .app),
        EditorCommand(id: "app.buffer.switch", title: "Switch to Buffer…", action: .app),
        EditorCommand(id: "app.buffer.kill", title: "Close Buffer", action: .app),
        EditorCommand(id: "app.buffer.kill-others", title: "Close Other Buffers", action: .app),
        EditorCommand(id: "app.buffer.kill-all", title: "Close All Buffers", action: .app),
        EditorCommand(id: "app.buffer.next", title: "Next Buffer", action: .app),
        EditorCommand(id: "app.buffer.previous", title: "Previous Buffer", action: .app),
        EditorCommand(id: "app.buffer.last", title: "Last Buffer", action: .app),
        EditorCommand(id: "app.split-below", title: "Split Pane Below", action: .app),
        EditorCommand(id: "app.split-right", title: "Split Pane Right", action: .app),
        EditorCommand(id: "app.pane-close", title: "Close Pane", action: .app),
        EditorCommand(id: "app.pane-only", title: "Close Other Panes", action: .app),
        EditorCommand(id: "app.pane-next", title: "Next Pane", action: .app),
        EditorCommand(id: "app.window-new", title: "New Window", action: .app),
        EditorCommand(id: "app.babel.cancel", title: "Cancel Running Task", action: .app),
        EditorCommand(id: "app.toggle-tab-bar", title: "Show or Hide Tab Bar", action: .app),
        EditorCommand(id: "app.toggle-outline", title: "Show or Hide Outline", action: .app),
        EditorCommand(id: "app.toggle-backlinks", title: "Show or Hide Backlinks", action: .app),
        EditorCommand(id: "app.toggle-inspector", title: "Show or Hide Inspector", action: .app),
        EditorCommand(id: "app.toggle-markup", title: "Show or Hide Markup", action: .app),
        EditorCommand(id: "app.edit-config", title: "Edit Config File", action: .app),
        EditorCommand(id: "app.import-emacs", title: "Import from Emacs…", action: .app),
        EditorCommand(id: "app.toggle-line-numbers", title: "Show or Hide Line Numbers", action: .app),
        EditorCommand(id: "app.quick-open", title: "Quick Open…", action: .app),
        EditorCommand(id: "app.palette", title: "Command Palette…", action: .app),
        EditorCommand(id: "app.search", title: "Search Notes", action: .app),
        EditorCommand(id: "app.reload-keymap", title: "Reload Keymap", action: .app),
        EditorCommand(id: "app.messages", title: "Messages", action: .app),
        EditorCommand(id: "app.refile", title: "Refile…", action: .app),
        EditorCommand(id: "app.refile.copy", title: "Copy to Refile Target…", action: .app),
        EditorCommand(id: "app.refile.goto", title: "Go to Refile Target…", action: .app),
        EditorCommand(id: "app.archive", title: "Archive Subtree", action: .app),
        EditorCommand(id: "app.agenda", title: "Agenda", action: .app),
        EditorCommand(id: "app.capture", title: "Capture…", action: .app),
        EditorCommand(id: "app.board", title: "Board", action: .app),
        EditorCommand(id: "app.clock.in", title: "Clock In", action: .app),
        EditorCommand(id: "app.clock.in-recent", title: "Clock In to Recent Entry…", action: .app),
        EditorCommand(id: "app.clock.in-last", title: "Clock In to Last Entry", action: .app),
        EditorCommand(id: "app.clock.out", title: "Clock Out", action: .app),
        EditorCommand(id: "app.clock.cancel", title: "Cancel Clock", action: .app),
        EditorCommand(id: "app.clock.goto", title: "Go to Clocked Entry", action: .app),
        EditorCommand(id: "app.clock.goto-recent", title: "Go to Recent Clocked Entry…", action: .app),
        EditorCommand(id: "app.clock.default", title: "Mark as Default Clock Task", action: .app),
        EditorCommand(id: "app.clock.resolve", title: "Resolve Open Clocks…", action: .app),
        EditorCommand(id: "app.clock.report", title: "Clock Report", action: .app),
        EditorCommand(id: "app.table-import", title: "Import Table from File…", action: .app),
        EditorCommand(id: "app.table-export", title: "Export Table to File…", action: .app),
        EditorCommand(id: "app.plot", title: "Plot Table", action: .app),
        EditorCommand(id: "app.dailies.today", title: "Go to Today's Daily Note", action: .app),
        EditorCommand(id: "app.dailies.yesterday", title: "Go to Yesterday's Daily Note", action: .app),
        EditorCommand(id: "app.dailies.tomorrow", title: "Go to Tomorrow's Daily Note", action: .app),
        EditorCommand(id: "app.dailies.date", title: "Go to Daily Note for Date…", action: .app),
        EditorCommand(id: "app.dailies.capture-today", title: "Capture to Today's Daily Note", action: .app),
        EditorCommand(id: "app.dailies.capture-yesterday", title: "Capture to Yesterday's Daily Note", action: .app),
        EditorCommand(id: "app.dailies.capture-tomorrow", title: "Capture to Tomorrow's Daily Note", action: .app),
        EditorCommand(id: "app.dailies.capture-date", title: "Capture to Daily Note for Date…", action: .app),
        EditorCommand(id: "app.dailies.next", title: "Next Daily Note", action: .app),
        EditorCommand(id: "app.dailies.previous", title: "Previous Daily Note", action: .app),
        EditorCommand(id: "app.node.find", title: "Find Node…", action: .app),
        EditorCommand(id: "app.node.find-ref", title: "Find Ref…", action: .app),
        EditorCommand(id: "app.node.insert", title: "Insert Node Link…", action: .app),
        EditorCommand(id: "app.node.graph", title: "Show Node Graph", action: .app),
        EditorCommand(id: "app.sidebar-agenda", title: "Show Agenda or Files in Sidebar", action: .app),
        EditorCommand(id: "app.node.rename-from-front-matter", title: "Rename Note from Front Matter", action: .app),
        EditorCommand(id: "app.node.rename", title: "Rename Note…", action: .app),
        EditorCommand(id: "app.node.rename-folder-from-front-matter", title: "Rename Notes in Folder from Front Matter…", action: .app),
        EditorCommand(id: "app.node.silo-find", title: "Find Note in Silo…", action: .app),
        EditorCommand(id: "app.node.silo-create", title: "New Note in Silo…", action: .app),
        EditorCommand(id: "app.node.sequence-new-parent", title: "New Sequence Note…", action: .app),
        EditorCommand(id: "app.node.sequence-new-child", title: "New Child Sequence Note…", action: .app),
        EditorCommand(id: "app.node.sequence-new-sibling", title: "New Sibling Sequence Note…", action: .app),
        EditorCommand(id: "app.node.sequence-new-child-of-current", title: "New Child of This Note…", action: .app),
        EditorCommand(id: "app.node.sequence-new-sibling-of-current", title: "New Sibling of This Note…", action: .app),
        EditorCommand(id: "app.node.sequence-find", title: "Find Sequence Relatives…", action: .app),
        EditorCommand(id: "app.node.sequence-next-sibling", title: "Next Sibling Note", action: .app),
        EditorCommand(id: "app.node.sequence-previous-sibling", title: "Previous Sibling Note", action: .app),
        EditorCommand(id: "app.node.sequence-reparent", title: "Reparent Note…", action: .app),
        EditorCommand(id: "app.node.sequence-reparent-recursive", title: "Reparent Note with Descendants…", action: .app),
        EditorCommand(id: "app.node.sequence-rename-as-parent", title: "Rename Note as Sequence Parent", action: .app),
        EditorCommand(id: "app.node.sequence-convert", title: "Convert Note Sequence Scheme", action: .app),
        EditorCommand(id: "app.node.sequence-link", title: "Insert Sequence Link…", action: .app),
        EditorCommand(id: "app.node.sequence-hierarchy", title: "Sequence Hierarchy…", action: .app),
        EditorCommand(id: "app.attach.attach", title: "Attach File…", action: .app),
        EditorCommand(id: "app.attach.move", title: "Attach File by Moving…", action: .app),
        EditorCommand(id: "app.attach.link", title: "Attach File as Hard Link…", action: .app),
        EditorCommand(id: "app.attach.symlink", title: "Attach File as Symbolic Link…", action: .app),
        EditorCommand(id: "app.attach.url", title: "Attach File from URL…", action: .app),
        EditorCommand(id: "app.attach.new", title: "New Attachment…", action: .app),
        EditorCommand(id: "app.attach.open", title: "Open Attachment…", action: .app),
        EditorCommand(id: "app.attach.reveal", title: "Show Attachment Folder", action: .app),
        EditorCommand(id: "app.attach.delete", title: "Delete Attachment…", action: .app),
        EditorCommand(id: "app.attach.delete-all", title: "Delete All Attachments…", action: .app),
        EditorCommand(id: "app.attach.sync", title: "Sync Attachments", action: .app),
        EditorCommand(id: "app.attach.set-directory", title: "Set Attachment Folder…", action: .app),
        EditorCommand(id: "app.attach.unset-directory", title: "Unset Attachment Folder", action: .app),
        EditorCommand(id: "app.crypt.encrypt-entry", title: "Encrypt Entry…", action: .app),
        EditorCommand(id: "app.crypt.open-entry", title: "Decrypt Entry…", action: .app),
        EditorCommand(id: "app.crypt.decrypt-entry", title: "Decrypt Entry in File…", action: .app),
        EditorCommand(id: "app.crypt.encrypt-entries", title: "Encrypt Tagged Entries…", action: .app),
        EditorCommand(id: "app.crypt.forget-passphrase", title: "Forget Encryption Passphrase", action: .app),
        EditorCommand(id: "app.export-dialog", title: "Export…", action: .app),
        EditorCommand(id: "app.export-subtree", title: "Turn Subtree Export On or Off", action: .app),
        EditorCommand(id: "app.export-body-only", title: "Turn Body-Only Export On or Off", action: .app),
        EditorCommand(id: "app.share-subtree", title: "Share Subtree…", action: .app),
        EditorCommand(id: "app.sync-conflicts", title: "Resolve Sync Conflicts…", action: .app),
        EditorCommand(id: "app.revert", title: "Revert to File on Disk", action: .app),
        EditorCommand(id: "app.recovery", title: "History…", action: .app),
        EditorCommand(id: "app.lint", title: "Lint File", action: .app),
        EditorCommand(id: "app.lint-folders", title: "Lint All Folders", action: .app),
        EditorCommand(id: "app.export.html", title: "Export to HTML", action: .app),
        EditorCommand(id: "app.export.html-open", title: "Export to HTML and Open", action: .app),
        EditorCommand(id: "app.export.markdown", title: "Export to Markdown", action: .app),
        EditorCommand(id: "app.export.print-pdf", title: "Export to PDF", action: .app),
        EditorCommand(id: "app.export.docx", title: "Export to Word", action: .app),
        EditorCommand(id: "app.export.rtf", title: "Export to RTF", action: .app),
        EditorCommand(id: "app.export.plain-text", title: "Export to Plain Text", action: .app),
        EditorCommand(id: "app.copy-rich-text", title: "Copy as Rich Text", action: .app),
        EditorCommand(id: "app.export.pdf", title: "Export to PDF with Emacs", action: .app),
        EditorCommand(id: "app.export.odt", title: "Export to ODT", action: .app),
        EditorCommand(id: "app.export.latex", title: "Export to LaTeX", action: .app),
        EditorCommand(id: "app.export.text", title: "Export to Plain Text (ASCII)", action: .app),
        EditorCommand(id: "app.export.icalendar", title: "Export to iCalendar", action: .app),
        EditorCommand(id: "app.export.icalendar-agenda", title: "Export Agenda Files to iCalendar", action: .app),
        EditorCommand(id: "app.export.icalendar-combined", title: "Combine Agenda Files into iCalendar", action: .app),
        EditorCommand(id: "app.publish", title: "Publish Project…", action: .app),
        EditorCommand(id: "app.publish.all", title: "Publish All Projects", action: .app),
        EditorCommand(id: "app.publish.current-file", title: "Publish Current File", action: .app),
        EditorCommand(id: "app.publish.current-project", title: "Publish Current Project", action: .app),

        movement("forward-char", "Forward Character", "moveForward:"),
        movement("backward-char", "Backward Character", "moveBackward:"),
        movement("next-line", "Next Line", "moveDown:"),
        movement("previous-line", "Previous Line", "moveUp:"),
        movement("beginning-of-line", "Beginning of Line", "moveToBeginningOfParagraph:"),
        movement("end-of-line", "End of Line", "moveToEndOfParagraph:"),
        movement("forward-word", "Forward Word", "moveWordForward:"),
        movement("backward-word", "Backward Word", "moveWordBackward:"),
        movement("beginning-of-buffer", "Beginning of Buffer", "moveToBeginningOfDocument:"),
        movement("end-of-buffer", "End of Buffer", "moveToEndOfDocument:"),
        movement("scroll-up", "Scroll Up", "pageDown:"),
        movement("scroll-down", "Scroll Down", "pageUp:"),
        edit("recenter", "Recenter", "centerSelectionInVisibleArea:"),
        edit("delete-char", "Delete Character", "deleteForward:"),
        edit("kill-word", "Kill Word", "deleteWordForward:"),
        edit("backward-kill-word", "Kill Word Backward", "deleteWordBackward:"),
        edit("kill-line", "Kill Line", "deleteToEndOfParagraph:"),
        edit("yank", "Yank", "yank:"),
        edit("yank-media", "Yank Media", "paste:"),
        edit("select-all", "Select All", "selectAll:"),
        edit("kill-region", "Kill Region", "cut:"),
        edit("copy-region", "Copy Region", "copy:"),
        edit("undo", "Undo", "undo:"),
        edit("transpose-chars", "Transpose Characters", "transpose:"),
        EditorCommand(id: "edit.find", title: "Find", action: .find(.showFindInterface)),
        EditorCommand(id: "edit.isearch-forward", title: "Incremental Search", action: .view),
        EditorCommand(id: "edit.isearch-backward", title: "Incremental Search Backward", action: .view),
        EditorCommand(id: "edit.isearch-forward-regexp", title: "Incremental Regexp Search", action: .view),
        EditorCommand(id: "edit.isearch-backward-regexp", title: "Incremental Regexp Search Backward", action: .view),
        EditorCommand(id: "edit.replace", title: "Find and Replace", action: .find(.showReplaceInterface)),
        EditorCommand(id: "edit.find-next", title: "Find Next", action: .find(.nextMatch)),
        EditorCommand(id: "edit.find-previous", title: "Find Previous", action: .find(.previousMatch)),
        EditorCommand(id: "edit.use-selection-for-find", title: "Use Selection for Find", action: .find(.setSearchString)),
        EditorCommand(id: "edit.set-mark", title: "Set Mark", action: .mark),
        EditorCommand(id: "edit.keyboard-quit", title: "Quit", action: .mark),

        EditorCommand(id: "macro.start", title: "Start Recording Macro", action: .view),
        EditorCommand(id: "macro.end", title: "Stop Recording Macro", action: .view),
        EditorCommand(id: "macro.call", title: "Run Last Macro", action: .view),
        EditorCommand(id: "macro.start-or-insert-counter", title: "Start Macro or Insert Counter", action: .view),
        EditorCommand(id: "macro.end-or-call", title: "Stop Macro or Run Last Macro", action: .view),
        EditorCommand(id: "macro.name", title: "Name Last Macro…", action: .view),
        EditorCommand(id: "macro.run", title: "Run Macro…", action: .view),
    ]

    /// A command for each named macro, titled with its name.
    public static func namedMacros(_ store: NamedMacros) -> [EditorCommand] {
        store.names.map { EditorCommand(id: NamedMacros.commandPrefix + $0, title: $0, action: .view) }
    }

    private static func movement(_ name: String, _ title: String, _ selector: String) -> EditorCommand {
        let extending = String(selector.dropLast()) + "AndModifySelection:"
        return EditorCommand(id: "edit.\(name)", title: title, action: .edit(selector: selector, extending: extending))
    }

    private static func edit(_ name: String, _ title: String, _ selector: String) -> EditorCommand {
        EditorCommand(id: "edit.\(name)", title: title, action: .edit(selector: selector))
    }

    private static let byID = Dictionary(uniqueKeysWithValues: builtIn.map { ($0.id, $0) })

    /// A command by id; any `macro.named.` id is one, which says so when no macro has its name.
    public static func command(_ id: String) -> EditorCommand? {
        if let command = byID[id] { return command }
        guard id.hasPrefix(NamedMacros.commandPrefix) else { return nil }
        return EditorCommand(id: id, title: String(id.dropFirst(NamedMacros.commandPrefix.count)), action: .view)
    }
}
#endif
