import AppKit
import CoreGraphics
import OrgApp
import OrgCore
import OrgEditorAppKit
import SwiftUI

/// Elapsed time of the running clock, `H:MM`.
func clockElapsed(_ running: ClockModel.Running, now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(running.startedAt) / 60))
    return String(format: "%d:%02d", minutes / 60, minutes % 60)
}

/// What the menu bar item shows.
struct ClockMenuState: Equatable {
    let running: ClockModel.Running?
    let history: [ClockTask]
    /// `menu-bar-item`: the item stays when no clock runs.
    var always = false
    /// Today's entries not done, overdue ones first.
    var today: [MenuBarAgenda.Entry] = []
    /// `menu-bar-clock`.
    var clockTitle = MenuBarAgenda.ClockTitle.heading
}

/// The menu bar's capture field. Its menu has no Edit menu to send the editing keys, so the
/// field handles them.
private final class CaptureField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        let actions: [String: Selector] = [
            "x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
            "a": #selector(NSText.selectAll(_:)), "z": Selector(("undo:")),
        ]
        guard let action = actions[key] else { return super.performKeyEquivalent(with: event) }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

/// `org-user-idle-seconds` on macOS: time since the last keyboard or mouse input anywhere.
enum ClockIdle {
    static func seconds() -> Double {
        // `kCGAnyInputEventType`.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

/// The clock history in a menu: clocking in to an entry runs `app.clock.history.N`.
struct RecentClocks: View {
    let clock: ClockModel
    let run: (String) -> Void

    var body: some View {
        if !clock.history.isEmpty {
            Section("Recent Entries") {
                ForEach(Array(clock.history.enumerated()), id: \.offset) { index, task in
                    Button(task.title) { run("app.clock.history.\(index)") }
                        .help("Clock in to \(task.title) in \((task.path as NSString).lastPathComponent)")
                }
            }
        }
    }
}

/// Org ▸ Clock: the clock commands, with their keys, and the recent entries.
struct ClockMenu: View {
    let commands: AppCommands
    let clock: ClockModel

    var body: some View {
        Menu("Clock") {
            ForEach(EditorCommands.all.filter { $0.id.hasPrefix("app.clock.") }, id: \.id) { command in
                Button {
                    commands.run(command.id)
                } label: {
                    Text(command.localizedTitle)
                    if let keys = commands.keyLabel(for: command.id) { Text(keys) }
                }
            }
            RecentClocks(clock: clock) { commands.run($0) }
        }
    }
}

/// The menu bar item: while a clock runs, the clock in its title and the clock commands; with
/// `always`, there all the time, with a capture field, the agenda and today's entries too.
@MainActor
final class ClockStatusItem: NSObject, NSMenuDelegate {
    /// Today's entries the menu lists before "more".
    static let rowLimit = 12

    private var item: NSStatusItem?
    private var timer: Timer?
    private var running: ClockModel.Running?
    private var effort: (effort: Int, clocked: Int)?
    private var clockTitle = MenuBarAgenda.ClockTitle.heading
    private var field: NSTextField?
    private let commands: AppCommands
    private let actions: MenuBarActions
    /// After an action changed a file: today's entries are read again.
    private let changed: () -> Void

    init(commands: AppCommands, actions: MenuBarActions, changed: @escaping () -> Void) {
        self.commands = commands
        self.actions = actions
        self.changed = changed
    }

    /// `effort`: the running clock's Effort and the time clocked on its entry before, from
    /// `ClockModel.effort`.
    func update(_ state: ClockMenuState, effort: (effort: Int, clocked: Int)?) {
        running = state.running
        self.effort = effort
        clockTitle = state.clockTitle
        guard state.running != nil || state.always else {
            timer?.invalidate()
            timer = nil
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        field = nil
        if state.always {
            addCapture(to: menu)
            add(String(localized: "Agenda"), "app.agenda", to: menu)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: String(localized: "Today")))
            if state.today.isEmpty { menu.addItem(withTitle: String(localized: "Nothing scheduled"), action: nil, keyEquivalent: "") }
            let clocked = state.running == nil ? nil : actions.clock.entry(actions.session)
            for entry in state.today.prefix(Self.rowLimit) { menu.addItem(item(for: entry, clocked: entry.isClocked(clocked))) }
            if state.today.count > Self.rowLimit { add(String(localized: "\(state.today.count - Self.rowLimit) more…"), "app.agenda", to: menu) }
            menu.addItem(.separator())
        }
        var commands = [("Clock In to Recent Entry…", "app.clock.in-recent"), ("Clock Report", "app.clock.report")]
        if let running = state.running {
            menu.addItem(withTitle: running.heading, action: nil, keyEquivalent: "")
            menu.addItem(.separator())
            commands.insert(contentsOf: [("Clock Out", "app.clock.out"), ("Cancel Clock", "app.clock.cancel"), ("Go to Clocked Entry", "app.clock.goto")], at: 0)
        }
        for (title, id) in commands { add(title, id, to: menu) }
        let recent = state.history.map(\.title)
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Recent Entries"))
            for (index, title) in recent.enumerated() { add(title, "app.clock.history.\(index)", to: menu) }
        }
        if state.always {
            menu.addItem(.separator())
            let show = NSMenuItem(title: String(localized: "Open orgstar"), action: #selector(activate), keyEquivalent: "")
            show.target = self
            menu.addItem(show)
        }
        item?.menu = menu
        refresh()
    }

    /// The capture field, which files with `menu-bar-capture-template` on Return; Capture With
    /// to file with another template; Capture… for the window.
    private func addCapture(to menu: NSMenu) {
        let field = CaptureField(frame: NSRect(x: 20, y: 3, width: 260, height: 22))
        field.placeholderString = String(localized: "Capture")
        field.setAccessibilityLabel(String(localized: "Capture"))
        field.target = self
        field.action = #selector(captureDefault(_:))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 296, height: 28))
        view.addSubview(field)
        let row = NSMenuItem()
        row.view = view
        menu.addItem(row)
        self.field = field
        let templates = actions.templates()
        if !templates.isEmpty {
            let with = NSMenuItem(title: String(localized: "Capture With"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for template in templates {
                let choice = NSMenuItem(title: "\(template.key)  \(template.name)", action: #selector(captureWith(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = template.key
                submenu.addItem(choice)
            }
            with.submenu = submenu
            menu.addItem(with)
        }
        add(String(localized: "Capture…"), "app.capture", to: menu)
    }

    /// An entry of today's agenda, with Open, Mark Done and Clock In or Out.
    private func item(for entry: MenuBarAgenda.Entry, clocked: Bool) -> NSMenuItem {
        let row = NSMenuItem(title: entry.label, action: nil, keyEquivalent: "")
        if clocked {
            row.state = .on
            row.onStateImage = NSImage(systemSymbolName: "clock", accessibilityDescription: String(localized: "Clocked in"))
        }
        guard entry.link != nil else { return row }
        let submenu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let choice = NSMenuItem(title: title, action: action, keyEquivalent: "")
            choice.target = self
            choice.representedObject = Box(entry)
            submenu.addItem(choice)
        }
        add(String(localized: "Open"), #selector(open(_:)))
        if entry.canBeDone { add(String(localized: "Mark Done"), #selector(markDone(_:))) }
        if clocked {
            add(String(localized: "Clock Out"), #selector(clockOut(_:)))
        } else if entry.canClockIn {
            add(String(localized: "Clock In"), #selector(clockIn(_:)))
        }
        row.submenu = submenu
        return row
    }

    private final class Box: NSObject {
        let entry: MenuBarAgenda.Entry
        init(_ entry: MenuBarAgenda.Entry) { self.entry = entry }
    }

    private func add(_ title: String, _ id: String, to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = id
        menu.addItem(entry)
    }

    private func refresh() {
        guard let button = item?.button else { return }
        if let running {
            button.image = NSImage(systemSymbolName: "clock", accessibilityDescription: String(localized: "Clocked in"))
            button.imagePosition = .imageLeading
            button.title = MenuBarAgenda.clockTitle(running, effort: effort, style: clockTitle, now: Date())
        } else {
            button.image = NSImage(systemSymbolName: "star", accessibilityDescription: "orgstar")
            button.title = ""
        }
    }

    /// The capture field takes the keys as the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        guard let field else { return }
        RunLoop.main.perform(inModes: [.eventTracking, .default]) {
            MainActor.assumeIsolated { _ = field.window?.makeFirstResponder(field) }
        }
    }

    @objc private func captureDefault(_ sender: NSTextField) {
        capture(template: nil)
    }

    @objc private func captureWith(_ sender: NSMenuItem) {
        capture(template: sender.representedObject as? String)
    }

    private func capture(template: String?) {
        let text = field?.stringValue ?? ""
        item?.menu?.cancelTracking()
        Task {
            switch await actions.capture(text, template: template) {
            case .filed(let key, _):
                field?.stringValue = ""
                let chosen = actions.templates().first { $0.key == key }
                commands.show("Captured to \(chosen.map(CaptureView.target) ?? key)")
                changed()
            case .window(let key):
                field?.stringValue = ""
                NSApp.activate()
                commands.capture(template: key, initial: text)
            case .failed(let message):
                NSApp.activate()
                commands.show(message)
            }
        }
    }

    @objc private func markDone(_ sender: NSMenuItem) {
        guard let entry = (sender.representedObject as? Box)?.entry else { return }
        report(actions.markDone(entry), entry)
    }

    @objc private func clockIn(_ sender: NSMenuItem) {
        guard let entry = (sender.representedObject as? Box)?.entry else { return }
        Task { report(await actions.clockIn(entry), entry) }
    }

    @objc private func clockOut(_ sender: NSMenuItem) {
        commands.show(actions.clockOut())
        changed()
    }

    /// An action that couldn't be done brings orgstar forward: at the entry's file when the
    /// entry moved, else with the reason in the echo area.
    private func report(_ outcome: ReminderActionOutcome, _ entry: MenuBarAgenda.Entry) {
        switch outcome {
        case .changed, .snoozed:
            changed()
        case .notFound:
            NSApp.activate()
            if let path = entry.path { commands.jump(path: path, offset: 0) }
        case .failed(let message):
            NSApp.activate()
            commands.show(message)
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            NSApp.activate()
            commands.run(id)
        }
    }

    @objc private func open(_ sender: NSMenuItem) {
        if case .entry(let path, let offset)? = (sender.representedObject as? Box)?.entry.link {
            NSApp.activate()
            commands.jump(path: path, offset: offset)
        }
    }

    @objc private func activate() {
        NSApp.activate()
    }
}

/// Clocked time per day and heading (`ClockReport.timeReport`) for chosen files and dates.
struct ClockReportView: View {
    let workspace: WorkspaceModel
    /// Open buffers are read as they are, unsaved edits included, as the agenda reads them.
    let session: DocumentSession
    @State private var start = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var limit = false
    @State private var selected: Set<String> = []
    @State private var report = ""

    private var candidates: [FileEntry] { workspace.files.filter { $0.kind == .org } }

    var body: some View {
        HSplitView {
            List(candidates, selection: $selected) { file in
                Text(file.relativePath).tag(file.path)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("From", isOn: $limit)
                    DatePicker("", selection: $start, displayedComponents: .date).labelsHidden().disabled(!limit)
                    Text("to")
                    DatePicker("", selection: $end, displayedComponents: .date).labelsHidden().disabled(!limit)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                    Button("Save…", action: saveReport)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(report.isEmpty ? "Choose files with clocked time." : report)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(4)
                }
                .defaultScrollAnchor(.topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(12)
        }
        .navigationTitle("Clock Report")
        .onAppear {
            if selected.isEmpty {
                selected = Set(candidates.filter { text(of: $0.path)?.contains("CLOCK: [") ?? false }.map(\.path))
            }
            compute()
        }
        .onChange(of: selected) { compute() }
        .onChange(of: session.editVersion) { compute() }
        .onChange(of: session.dirtyPaths) { compute() }
        .onChange(of: start) { compute() }
        .onChange(of: end) { compute() }
        .onChange(of: limit) { compute() }
    }

    private func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// The file's text: its open buffer, else the file on disk.
    private func text(of path: String) -> String? {
        session.openTexts[path] ?? (try? String(contentsOfFile: path, encoding: .utf8))
    }

    private func compute() {
        var entries: [ClockReport.Entry] = []
        for path in selected.sorted() {
            guard let text = text(of: path) else { continue }
            entries += ClockReport.entries(text, settings: workspace.settings.org)
        }
        report = selected.isEmpty ? "" : ClockReport.timeReport(entries, start: limit ? day(start) : nil, end: limit ? day(end) : nil)
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "time-report.org"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
