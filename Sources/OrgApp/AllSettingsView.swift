import OrgCore
import SwiftUI

/// Every setting of `config.toml`, one row each with the control for its kind, grouped by table:
/// a search field over keys, Emacs variables and descriptions, a marker on settings that differ
/// from their default, Reset to Default, and an (i) sheet for each. Values are read from user
/// defaults, where the file is applied; `write` puts a changed value in the file.
public struct AllSettingsView: View {
    let write: (UserConfig.Setting, TOML.Value) -> Void
    let problems: [String]
    let editAsText: (() -> Void)?
    @State private var query = ""
    @State private var info: UserConfig.Setting?
    /// Bumped when user defaults change, as when the file is edited elsewhere.
    @State private var version = 0

    /// The manual's chapters online, by file name.
    public static func manual(_ chapter: String) -> URL {
        URL(string: "https://files.krz.sh/orgstar/guide/\(chapter).html")!
    }

    /// `editAsText`, on the Mac, opens the file in the editor; iOS puts its own link in the toolbar.
    public init(problems: [String] = [], editAsText: (() -> Void)? = nil, write: @escaping (UserConfig.Setting, TOML.Value) -> Void) {
        self.write = write
        self.problems = problems
        self.editAsText = editAsText
    }

    private struct Table {
        let name: String
        var settings: [UserConfig.Setting]
    }

    /// The settings that match the search, by table in the file's order.
    private var sections: [Table] {
        var result: [Table] = []
        for setting in UserConfig.settings where setting.matches(query, texts: [setting.shownComment, setting.shownHelp ?? ""]) {
            if result.last?.name == setting.section {
                result[result.count - 1].settings.append(setting)
            } else {
                result.append(Table(name: setting.section, settings: [setting]))
            }
        }
        return result
    }

    public var body: some View {
        let _ = version
        let sections = sections
        VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                TextField("Search", text: $query, prompt: Text("Search settings"))
                    .textFieldStyle(.roundedBorder)
                if let editAsText { Button("Edit as Text", action: editAsText) }
            }
            .padding([.horizontal, .top])
            #endif
            Form {
                if !problems.isEmpty {
                    Section {
                        ForEach(problems, id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                }
                ForEach(sections, id: \.name) { section in
                    Section {
                        ForEach(section.settings, id: \.path) { setting in
                            SettingRow(setting: setting, write: write) { info = setting }
                        }
                    } header: {
                        if section.name.isEmpty { Text("Top Level") } else { Text(verbatim: "[\(section.name)]") }
                    }
                }
                if query.isEmpty {
                    Section {
                    } footer: {
                        Text("Tables of their own, such as [org-structure-template-alist], [denote-templates], [key-bar], [[publish]] and the theme's colors, are edited as text.")
                    }
                }
            }
            .formStyle(.grouped)
            .overlay {
                if sections.isEmpty { ContentUnavailableView.search(text: query) }
            }
        }
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search settings"))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        #endif
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in version += 1 }
        .sheet(isPresented: Binding { info != nil } set: { if !$0 { info = nil } }) {
            if let info { SettingInfo(setting: info, write: write) }
        }
    }
}

extension UserConfig.Setting {
    /// The comment, from the string catalog.
    public var shownComment: String { Bundle.main.localizedString(forKey: comment, value: comment, table: nil) }
    /// The help, from the string catalog.
    public var shownHelp: String? { help.map { Bundle.main.localizedString(forKey: $0, value: $0, table: nil) } }

    /// The setting's value now, as in the file.
    func current(_ defaults: UserDefaults = .standard) -> TOML.Value { UserConfig.value(self, in: defaults) }
}

/// A setting's key and comment, its control and its (i) button.
private struct SettingRow: View {
    let setting: UserConfig.Setting
    let write: (UserConfig.Setting, TOML.Value) -> Void
    let showInfo: () -> Void

    var body: some View {
        let value = setting.current()
        let changed = value != setting.fallback
        Group {
            if setting.control == .text {
                VStack(alignment: .leading, spacing: 6) {
                    label(changed)
                    HStack(alignment: .firstTextBaseline) {
                        TextSettingField(value: value.string ?? "") { write(setting, .string($0)) }
                        infoButton
                    }
                }
            } else {
                HStack {
                    label(changed).frame(maxWidth: .infinity, alignment: .leading)
                    control(value).fixedSize()
                    infoButton
                }
            }
        }
        .contextMenu {
            Button("Reset to Default") { write(setting, setting.fallback) }.disabled(!changed)
            Button("About This Setting", action: showInfo)
        }
        #if os(iOS)
        .swipeActions {
            if changed { Button("Reset") { write(setting, setting.fallback) }.tint(.orange) }
        }
        #endif
    }

    private func label(_ changed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(verbatim: setting.key).font(.callout.monospaced())
                if changed {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text("Changed from the default"))
                        .help(Text("Changed from the default"))
                }
            }
            Text(setting.shownComment)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    private var infoButton: some View {
        Button(action: showInfo) {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("About \(setting.key)"))
    }

    @ViewBuilder
    private func control(_ value: TOML.Value) -> some View {
        switch setting.control {
        case .toggle:
            Toggle("", isOn: Binding { value.bool ?? false } set: { write(setting, .bool($0)) })
                .labelsHidden()
        case .integer:
            let number = value.integer ?? 0
            HStack(spacing: 4) {
                TextField("", value: Binding { number } set: { if $0 != number { write(setting, .integer($0)) } },
                          format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                Stepper("", value: Binding { number } set: { write(setting, .integer($0)) })
                    .labelsHidden()
            }
        case .days:
            let days = UserConfig.Setting.days(value)
            Stepper(value: Binding { days } set: { write(setting, UserConfig.Setting.value(days: $0)) }) {
                Text(verbatim: UserConfig.format(value)).monospaced()
            }
            .fixedSize()
        case .choice(let names):
            let chosen = setting.choice(value)
            Picker("", selection: Binding { chosen } set: { write(setting, setting.value(choice: $0)) }) {
                ForEach(names.contains(chosen) ? names : names + [chosen], id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        case .text:
            EmptyView()
        }
    }
}

/// A text setting's field, written when Return is pressed or the field loses focus.
private struct TextSettingField: View {
    let value: String
    let commit: (String) -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: Binding { draft ?? value } set: { draft = $0 }, prompt: Text(verbatim: "\"\""), axis: .vertical)
            .font(.callout.monospaced())
            .lineLimit(1...6)
            .focused($focused)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .onDisappear(perform: save)
    }

    private func save() {
        if let draft, draft != value { commit(draft) }
        draft = nil
    }
}

/// What a setting does, the values it takes, its default, the Emacs variable it mirrors and where
/// the manual describes it, with Reset to Default.
struct SettingInfo: View {
    let setting: UserConfig.Setting
    let write: (UserConfig.Setting, TOML.Value) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var version = 0

    var body: some View {
        let _ = version
        let value = setting.current()
        NavigationStack {
            Form {
                Section("What It Does") {
                    Text(setting.shownHelp ?? setting.shownComment)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Allowed Values") {
                    allowed.textSelection(.enabled)
                }
                Section("Default") {
                    Text(verbatim: UserConfig.format(setting.fallback)).monospaced().textSelection(.enabled)
                }
                Section {
                    Text(verbatim: line(value)).monospaced().textSelection(.enabled)
                } header: {
                    Text("In config.toml")
                } footer: {
                    if value != setting.fallback { Text("Changed from the default") }
                }
                if let emacs = setting.emacsVariable {
                    Section("Emacs Variable") {
                        Text(verbatim: emacs).monospaced().textSelection(.enabled)
                    }
                }
                Section("In the Manual") {
                    if let chapter = setting.manualChapter, let title = UserConfig.manualChapters[chapter] {
                        Link(destination: AllSettingsView.manual(chapter)) { Text(verbatim: title) }
                    }
                    Link(destination: AllSettingsView.manual("13-configuration")) {
                        Text(verbatim: "Configuration ▸ config.toml reference ▸ " + (setting.section.isEmpty ? "Top level" : "[\(setting.section)]"))
                    }
                }
                Section {
                    Button("Reset to Default") { write(setting, setting.fallback) }
                        .disabled(value == setting.fallback)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: setting.key))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 520)
        #endif
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in version += 1 }
    }

    /// The line the file has for the setting, under its table.
    private func line(_ value: TOML.Value) -> String {
        (setting.section.isEmpty ? "" : "[\(setting.section)]\n") + "\(setting.key) = \(UserConfig.format(value))"
    }

    @ViewBuilder
    private var allowed: some View {
        switch setting.control {
        case .toggle: Text(verbatim: "true, false")
        case .integer: Text("A whole number")
        case .days: Text("Days from today, such as \"-3d\" or \"+0d\"")
        case .choice(let names): Text(verbatim: names.joined(separator: ", "))
        case .text: Text("Text, as described above")
        }
    }
}
