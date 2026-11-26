#if os(iOS)
import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI
import UIKit

/// Where settings come from: a folder with the Mac's `config.toml` and `capture.toml`, kept in
/// sync by iCloud Drive or another app.
struct SettingsScreen: View {
    let model: MobileModel
    @State private var choosing = false
    @State private var calendars: [CalendarChoice] = []
    @State private var reminderLists: [CalendarChoice] = []
    @State private var badges: Bool?
    @State private var appIcon = AppIcons.id(alternateName: UIApplication.shared.alternateIconName)
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private struct CalendarChoice {
        let id: String
        let title: String
        let color: RGBA?
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ProScreen()
                } label: {
                    ProBanner()
                }
            }
            .listRowBackground(ProBanner.rowBackground)
            Section {
                let _ = model.settingsVersion
                NavigationLink {
                    ThemePickerScreen(model: model, appearance: .light)
                } label: {
                    LabeledContent("Light theme", value: ThemePickerScreen.current(.light).displayName)
                }
                NavigationLink {
                    ThemePickerScreen(model: model, appearance: .dark)
                } label: {
                    LabeledContent("Dark theme", value: ThemePickerScreen.current(.dark).displayName)
                }
                NavigationLink {
                    AppIconScreen(current: $appIcon)
                } label: {
                    LabeledContent("App icon", value: AppIcons.name(appIcon))
                }
                Picker("Body font", selection: Binding {
                    UserDefaults.standard.string(forKey: "themeBodyFont") ?? ""
                } set: { model.set("themeBodyFont", to: .string($0)) }) {
                    let body = UserDefaults.standard.string(forKey: "themeBodyFont") ?? ""
                    Text("Same as Font").tag("")
                    Text("System").tag("system")
                    ForEach(Self.proportionalFamilies, id: \.self) { Text($0).tag($0) }
                    if !["", "system"].contains(body), !Self.proportionalFamilies.contains(body) { Text(body).tag(body) }
                }
                .pickerStyle(.navigationLink)
                Picker("Text width", selection: Binding {
                    UserDefaults.standard.integer(forKey: "themeTextWidth")
                } set: { model.set("themeTextWidth", to: .integer($0)) }) {
                    let width = UserDefaults.standard.integer(forKey: "themeTextWidth")
                    Text("Whole screen").tag(0)
                    ForEach([60, 70, 80, 90, 100, 120], id: \.self) { Text("\($0) columns").tag($0) }
                    if ![0, 60, 70, 80, 90, 100, 120].contains(width) { Text("\(width) columns").tag(width) }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("With a body font, prose uses it while tables, code, dates, tags and drawers keep the monospaced font. Text width keeps lines to that many columns, centred, on a screen wider than that.")
            }
            Section {
                NavigationLink("Key Bar") { KeyBarSettings(model: model) }
            } footer: {
                Text("The buttons above the on-screen keyboard.")
            }
            Section {
                let _ = model.settingsVersion
                Toggle("Show days without entries", isOn: Binding {
                    OrgPreferences.agendaShowAllDates()
                } set: { model.set("agendaShowAllDates", to: .bool($0)) })
                .help(Text(verbatim: "org-agenda-show-all-dates"))
                Toggle("Habits only today", isOn: Binding {
                    OrgPreferences.habitsOnlyForToday()
                } set: { model.set("habitsOnlyForToday", to: .bool($0)) })
                .help(Text(verbatim: "org-habit-show-habits-only-for-today"))
                Toggle("Exclude archived tasks", isOn: Binding {
                    OrgPreferences.agendaExcludeArchives()
                } set: { model.set("agendaExcludeArchives", to: .bool($0)) })
                .help(Text(verbatim: "agenda-exclude-archives"))
                Picker("Blocked entries", selection: Binding {
                    UserDefaults.standard.string(forKey: "agendaDimBlockedTasks") ?? "t"
                } set: { model.set("agendaDimBlockedTasks", to: .string($0)) }) {
                    Text("Dimmed").tag("t")
                    Text("Hidden").tag("invisible")
                    Text("Shown as usual").tag("nil")
                }
                .help(Text(verbatim: "org-agenda-dim-blocked-tasks"))
            } header: {
                Text("Agenda")
            } footer: {
                Text("Archive files are the ones your agenda files archive to, named by #+ARCHIVE:, an :ARCHIVE: property or org-archive-location.")
            }
            Section {
                let _ = model.settingsVersion
                Toggle("Entries can't be done before their TODO children", isOn: Binding {
                    UserDefaults.standard.bool(forKey: "enforceTodoDependencies")
                } set: { model.set("enforceTodoDependencies", to: .bool($0)) })
                .help(Text(verbatim: "org-enforce-todo-dependencies"))
                Toggle("Entries can't be done with unchecked boxes", isOn: Binding {
                    UserDefaults.standard.bool(forKey: "enforceTodoCheckboxDependencies")
                } set: { model.set("enforceTodoCheckboxDependencies", to: .bool($0)) })
                .help(Text(verbatim: "org-enforce-todo-checkbox-dependencies"))
            } header: {
                Text("TODO Dependencies")
            } footer: {
                Text("org-enforce-todo-dependencies and org-enforce-todo-checkbox-dependencies.")
            }
            Section {
                let _ = model.settingsVersion
                Picker("Completion list opens", selection: Binding {
                    UserDefaults.standard.string(forKey: "completionAuto") ?? "preset"
                } set: { model.set("completionAuto", to: .string($0)) }) {
                    Text("As the keys do (by itself with Doom)").tag("preset")
                    Text("By itself as you type").tag("on")
                    Text("Only with a key").tag("off")
                }
                .help(Text(verbatim: "completion-auto"))
                let delay = OrgPreferences.completion().delay
                Stepper("After a pause of \(Int(delay * 1000)) ms", value: Binding {
                    Int(delay * 1000)
                } set: { model.set("completionAutoDelay", to: .integer($0)) }, in: 0...2000, step: 50)
                .help(Text(verbatim: "completion-auto-delay"))
                let prefix = OrgPreferences.completion().prefix
                Stepper("Once \(prefix) characters are typed", value: Binding {
                    prefix
                } set: { model.set("completionAutoPrefix", to: .integer($0)) }, in: 1...10)
                .help(Text(verbatim: "completion-auto-prefix"))
                Picker("Candidates", selection: Binding {
                    UserDefaults.standard.string(forKey: "completionStyle") ?? "preset"
                } set: { model.set("completionStyle", to: .string($0)) }) {
                    Text("As the keys do (letters in order with Doom)").tag("preset")
                    Text("Start with what's typed").tag("prefix")
                    Text("Have its letters in order, best first").tag("fuzzy")
                }
                .help(Text(verbatim: "completion-style"))
                Toggle("The list offers words from open files and folders", isOn: Binding {
                    OrgPreferences.completion().words
                } set: { model.set("completionWords", to: .bool($0)) })
                .help(Text(verbatim: "completion-words"))
            } header: {
                Text("Completion")
            } footer: {
                Text("With a hardware keyboard. Doom's keys open the list by itself and match letters in order, as Doom's corfu does; the Emacs and Mac keys do neither unless set here.")
            }
            calendarSection
            reminderSection
            Section {
                if badges == true {
                    LabeledContent("Overdue count on icon", value: String(localized: "On"))
                } else if badges == false {
                    Button("Show Overdue Count on Icon…") {
                        Task {
                            if await model.badgesEnabled(asking: true) {
                                badges = true
                                await model.updateWidgets()
                            } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                openURL(url)
                            }
                        }
                    }
                }
            } header: {
                Text("Badge")
            } footer: {
                if badges == false { Text("Turn on Badges in orgstar's notification settings.") }
            }
            Section {
                LabeledContent("Folder", value: model.configFolder?.lastPathComponent ?? String(localized: "none.folder", defaultValue: "None", comment: "No configuration folder chosen"))
                Button(model.configFolder == nil ? "Choose Folder…" : "Choose Another Folder…") { choosing = true }
                if model.configFolder != nil {
                    NavigationLink("Edit config.toml") { ConfigFileEditor(model: model) }
                }
                NavigationLink("Import from Emacs") { EmacsImportScreen(model: model) }
                if model.configFolder != nil {
                    Button("Stop Using This Folder", role: .destructive) { model.setConfigFolder(nil) }
                }
                ForEach(model.configProblems, id: \.self) { Text($0).foregroundStyle(.red) }
            } header: {
                Text("Configuration")
            } footer: {
                Text("A folder with config.toml and capture.toml, such as a synced copy of ~/.config/orgstar from your Mac. Changes to them apply as they sync.")
            }
            Section("In Use") {
                let _ = model.settingsVersion
                LabeledContent("TODO keywords", value: todoKeywords)
                LabeledContent("Agenda", value: agenda)
                LabeledContent("Notifications", value: OrgPreferences.reminders() ? String(localized: "\(OrgPreferences.reminderLead()) min before") : String(localized: "Off"))
                LabeledContent("Capture templates", value: CaptureTemplates.load().templates.map(\.key).joined(separator: " "))
                LabeledContent("Theme", value: themeInUse)
                LabeledContent("Font", value: font)
            }
            Section {
                NavigationLink {
                    AboutScreen(appIcon: appIcon)
                } label: {
                    Label("About orgstar", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("Settings")
        // Read again on return from the Settings app.
        .task(id: scenePhase) { badges = await model.badgesEnabled(asking: false) }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.setConfigFolder(url) }
        }
    }

    /// The two palettes' names, and the theme file's when there is one.
    private var themeInUse: String {
        let names = "\(ThemePickerScreen.current(.light).displayName) / \(ThemePickerScreen.current(.dark).displayName)"
        guard let file = UserDefaults.standard.string(forKey: "themeFile"), !file.isEmpty else { return names }
        return "\(names), \(file)"
    }

    /// `calendar-events` and `calendar-event-calendars`, written to config.toml.
    private var calendarSection: some View {
        let _ = model.settingsVersion
        let on = OrgPreferences.calendarEvents()
        let chosen = OrgPreferences.calendarEventCalendars()
        return Section {
            Toggle("Show events from Calendar", isOn: Binding {
                on
            } set: { value in
                guard !value || ProAccess.shared.allows(.calendar) else { return }
                model.set("calendarEvents", to: .bool(value))
                if value { Task { await requestCalendars() } }
            })
            if on {
                if !CalendarEvents.isAuthorized {
                    Button("Allow Access to Calendars…") { Task { await requestCalendars() } }
                }
                ForEach(calendars, id: \.id) { calendar in
                    let shown = CalendarEvents.chooses(id: calendar.id, title: calendar.title, chosen: chosen)
                    Button {
                        toggle(calendar.title, shown: shown, chosen: chosen)
                    } label: {
                        HStack {
                            Circle().fill(calendar.color?.swiftUI ?? .secondary).frame(width: 10, height: 10)
                            Text(calendar.title).foregroundStyle(.primary)
                            Spacer()
                            if shown { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .tint(.primary)
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text(on ? "Events from the checked calendars show in the agenda. Tap one to edit it." : "Show events from Calendar in the agenda.")
        }
        .task(id: on) { loadCalendars() }
    }

    /// `agenda-reminders` and `agenda-reminder-lists`, written to config.toml.
    private var reminderSection: some View {
        let _ = model.settingsVersion
        let on = OrgPreferences.agendaReminders()
        let chosen = OrgPreferences.agendaReminderLists()
        return Section {
            Toggle("Show reminders from Reminders", isOn: Binding {
                on
            } set: { value in
                guard !value || ProAccess.shared.allows(.calendar) else { return }
                model.set("agendaReminders", to: .bool(value))
                if value { Task { await requestReminders() } }
            })
            if on {
                if !ReminderLists.isAuthorized {
                    Button("Allow Access to Reminders…") { Task { await requestReminders() } }
                }
                ForEach(reminderLists, id: \.id) { list in
                    let shown = CalendarEvents.chooses(id: list.id, title: list.title, chosen: chosen)
                    Button {
                        toggle(list.title, shown: shown, chosen: chosen, among: reminderLists, key: "agendaReminderLists")
                    } label: {
                        HStack {
                            Circle().fill(list.color?.swiftUI ?? .secondary).frame(width: 10, height: 10)
                            Text(list.title).foregroundStyle(.primary)
                            Spacer()
                            if shown { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .tint(.primary)
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text(on ? "Incomplete reminders with a due date from the checked lists show in the agenda, read-only; overdue ones under today."
                 : "Show reminders from Reminders in the agenda, read-only.")
        }
        .task(id: on) { loadReminderLists() }
    }

    private func requestReminders() async {
        _ = await model.reminderLists.requestAccess()
        loadReminderLists()
        model.reloadConfig()
    }

    private func loadReminderLists() {
        reminderLists = model.reminderLists.lists()
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { CalendarChoice(id: $0.id, title: $0.title, color: $0.color) }
    }

    private func requestCalendars() async {
        _ = await model.calendarEvents.requestAccess()
        loadCalendars()
        model.reloadConfig()
    }

    private func loadCalendars() {
        calendars = model.calendarEvents.calendars()
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { CalendarChoice(id: $0.id, title: $0.title, color: $0.color) }
    }

    /// Shows or hides a calendar's events or a list's reminders; with every one checked the
    /// setting is empty. The last checked one stays checked, as an empty list means every one.
    private func toggle(_ title: String, shown: Bool, chosen: [String], among choices: [CalendarChoice]? = nil, key: String = "calendarEventCalendars") {
        let choices = choices ?? calendars
        var titles = choices.filter { CalendarEvents.chooses(id: $0.id, title: $0.title, chosen: chosen) }.map(\.title)
        titles.removeAll { $0 == title }
        if !shown { titles.append(title) }
        guard !titles.isEmpty else { return }
        let value = Set(titles) == Set(choices.map(\.title)) ? "" : titles.joined(separator: ", ")
        model.set(key, to: .string(value))
    }

    /// Installed proportional font families, for prose.
    private static let proportionalFamilies: [String] = UIFont.familyNames.sorted().filter { family in
        guard let name = UIFont.fontNames(forFamilyName: family).first, let font = UIFont(name: name, size: 13) else { return false }
        return !font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
    }

    /// The span and start day, worded as the Mac's Settings word the start.
    private var agenda: String {
        let offset = OrgPreferences.agendaStartOffset()
        let span = String(localized: "\(OrgPreferences.agendaSpan()) days", comment: "Agenda span in Settings ▸ In Use")
        let start = offset == 0 ? String(localized: "starting today", comment: "Agenda start in Settings ▸ In Use")
            : offset < 0 ? String(localized: "starting \(-offset) days before today", comment: "Agenda start in Settings ▸ In Use")
            : String(localized: "starting \(offset) days after today", comment: "Agenda start in Settings ▸ In Use")
        return String(localized: "\(span), \(start)", comment: "Agenda span and start in Settings ▸ In Use")
    }

    /// The theme's family, or the system's monospaced font when it's unset or not on the device.
    private var font: String {
        let spec = model.theme
        let family = spec.font.isEmpty || UIFont.fontNames(forFamilyName: spec.font).isEmpty ? String(localized: "System monospaced") : spec.font
        return !spec.font.isEmpty && family != spec.font ? String(localized: "\(family), \(spec.fontSize) pt (\(spec.font) isn't installed)")
            : String(localized: "\(family), \(spec.fontSize) pt")
    }

    private var todoKeywords: String {
        OrgPreferences.orgSettings().todoSequences.map { ($0.active.map(\.name) + ["|"] + $0.done.map(\.name)).joined(separator: " ") }
            .joined(separator: "; ")
    }
}
/// The orgstar+ row at the top of Settings.
private struct ProBanner: View {
    private var access: ProAccess { .shared }

    static var rowBackground: some View {
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            LinearGradient.plusGold.opacity(0.22)
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            PlusBadge()
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "orgstar+").font(.headline)
                Group {
                    if access.isUnlocked {
                        Text("Unlocked. Thanks for supporting orgstar.")
                    } else {
                        Text("Export, encryption, widgets, the Watch app and more")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

/// The configuration folder's `config.toml` as plain text, saved when you tap Save or leave.
struct ConfigFileEditor: View {
    let model: MobileModel
    @State private var text = ""
    @State private var saved: String?

    var body: some View {
        PlainTextView(text: $text)
            .navigationTitle("config.toml")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Save") { save() }.disabled(text == saved)
            }
            .safeAreaInset(edge: .bottom) {
                let _ = model.settingsVersion
                if !model.configProblems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.configProblems, id: \.self) { Text($0) }
                    }
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                }
            }
            .onAppear {
                guard saved == nil else { return }
                text = model.configText() ?? UserConfig.defaultTemplate
                saved = text
            }
            .onDisappear { save() }
    }

    private func save() {
        guard text != saved else { return }
        if model.saveConfig(text) { saved = text }
    }
}

/// A monospaced text view without smart quotes, dashes or autocorrection, which would break TOML.
private struct PlainTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardDismissMode = .interactive
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ view: UITextView) { text.wrappedValue = view.text }
    }
}
#endif
