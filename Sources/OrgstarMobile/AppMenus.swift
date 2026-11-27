#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// What the menu bar does in the focused window.
struct WindowActions {
    var show: (AppTab) -> Void
    var capture: () -> Void
    var addFolder: () -> Void
    var board: () -> Void
    var flashcards: () -> Void
    var clock: (String) -> Void
}

/// The editor of the focused pane in the focused window.
struct EditorActions {
    let editor: MobileEditor
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
    @Entry var editorActions: EditorActions?
}

/// The iPad menu bar, after the Mac's File, Edit, View and Org menus, with their keys, and Go
/// in place of the Mac's windows.
struct AppMenus: SwiftUI.Commands {
    let model: MobileModel
    @FocusedValue(\.windowActions) private var window
    @FocusedValue(\.editorActions) private var editor

    var body: some SwiftUI.Commands {
        CommandGroup(after: .newItem) {
            Button("Capture…") { window?.capture() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(window == nil)
            Button("Add Folder…") { window?.addFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(window == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { editor?.editor.run("app.save") }
                .keyboardShortcut("s")
                .disabled(editor == nil)
            Button("Save All") { for path in model.session.dirtyPaths { _ = model.session.save(path) } }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.session.dirtyPaths.isEmpty)
        }
        CommandGroup(after: .textEditing) {
            Button("Search Notes") { window?.show(.search) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(window == nil)
        }
        CommandGroup(after: .sidebar) {
            editorItem("Split Pane Below", "app.split-below", "2", [.command, .control])
            editorItem("Split Pane Right", "app.split-right", "3", [.command, .control])
            editorItem("Close Pane", "app.pane-close", "0", [.command, .control])
            editorItem("Close Other Panes", "app.pane-only", "1", [.command, .control])
            editorItem("Next Pane", "app.pane-next", "`", [.command, .option])
            Divider()
            Toggle("Show Markup", isOn: Bindable(model).showMarkup)
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Toggle("Truncate Long Lines", isOn: Binding(get: { editor?.editor.truncatesLines ?? false }, set: { _ in editor?.editor.run("editor.toggle-truncate-lines") }))
                .disabled(editor == nil)
            Toggle("Auto Fill", isOn: Binding(get: { editor?.editor.autoFills ?? false }, set: { _ in editor?.editor.run("editor.toggle-auto-fill") }))
                .disabled(editor == nil)
        }
        CommandMenu("Org") {
            Menu("Clock") {
                ForEach(Self.clockCommands, id: \.id) { command in
                    Button(CommandTitle.localized(command.title)) { window?.clock(command.id) }
                }
            }
            .disabled(window == nil)
            Divider()
            OrgMenuItems(editor: editor?.editor)
        }
        CommandMenu("Go") {
            Button("Agenda") { window?.show(.agenda) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Board") { window?.board() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Review Flashcards") { window?.flashcards() }
            Button("Folders") { window?.show(.folders) }
            Button("Settings") { window?.show(.settings) }
                .keyboardShortcut(",")
            Divider()
            Button(CommandTitle.localized("Go to Clocked Entry")) { window?.clock("app.clock.goto") }
                .disabled(model.clock.running == nil)
        }
    }

    /// Clock commands that run without an editor, as the clock accessory runs them.
    static let clockCommands = CommandPalette.viewCommands.filter { $0.id.hasPrefix("app.clock.") } + [("app.clock.report", "Clock Report")]

    private func editorItem(_ title: LocalizedStringKey, _ id: String, _ key: KeyEquivalent, _ modifiers: EventModifiers) -> some View {
        Button(title) { editor?.editor.run(id) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(editor == nil)
    }
}

/// Org: the org commands and the app's commands for entries and notes, in the Org menu's
/// submenus (`CommandGroups.orgMenu`), with the keys that run them in the current keymap.
private struct OrgMenuItems: View {
    let editor: MobileEditor?

    private static func group(of id: String) -> Int? { CommandGroups.group(of: id) }

    /// The commands the iOS editor knows, less the ones the App Store build hides, once each.
    private static let shown: [(id: String, title: String)] = {
        var seen = Set<String>()
        return (CommandPalette.viewCommands + OrgCore.Commands.everything.map { ($0.id, $0.title) })
            .filter { ($0.id.hasPrefix("org.") || group(of: $0.id) != nil) && !AppStoreCommands.hidden.contains($0.id) && seen.insert($0.id).inserted }
    }()

    var body: some View {
        // Commands that fit no subject, such as Act at Point, come first.
        ForEach(Self.shown.filter { Self.group(of: $0.id) == nil }, id: \.id) { item($0) }
        Divider()
        ForEach(CommandGroups.orgMenu.indices, id: \.self) { index in
            Menu(CommandGroups.orgMenu[index].title) {
                ForEach(Self.shown.filter { Self.group(of: $0.id) == index }, id: \.id) { item($0) }
            }
        }
    }

    private func item(_ command: (id: String, title: String)) -> some View {
        Button {
            editor?.run(command.id)
        } label: {
            Text(CommandTitle.localized(command.title))
            if let keys = editor?.keymap.keyLabels(for: command.id).first { Text(keys) }
        }
        .disabled(editor == nil)
    }
}
#endif
