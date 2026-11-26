import AppKit
import OrgApp
import OrgCore
import OrgEditorAppKit
import OrgIndex
import OrgMathJax
import OrgPresentation
#if !APPSTORE
import OrgPrograms
#endif
import SwiftUI
import UserNotifications

/// Window-level requests the menu bar makes.
@MainActor
@Observable
final class AppCommands {
    var showingQuickOpen = false
    var showingFolderPicker = false
    /// The first-launch sheet, while no folder has been added.
    var showingWelcome = false
    /// The notes the main window shows as a sheet.
    var whatsNew: ReleaseNotes?
    var focusSearch = false
    var showingConflict = false
    var showingPalette = false
    var showingMessages = false
    /// The main window's outline pane is shown, for View ▸ Show Outline.
    var outlineShown = false
    /// Lint All Folders' last run, which its window shows.
    let folderLint = FolderLint()
    /// A location another window asked the main window to show.
    private(set) var jumpRequest: (path: String, offset: Int, id: Int)?
    private var jumpID = 0
    /// Days the agenda window should show, from a followed timestamp.
    var agendaRequest: (start: Int, days: Int)?
    /// The editor with focus, for menus and the palette.
    var editor: OrgEditor?
    /// The editors and text views of every pane in every window.
    let store = EditorStore()
    /// The main window is on screen. App commands run there, so an editor window reopens it
    /// before asking for one.
    var mainWindowOpen = false
    /// What every editor is set up with, from the settings; the main window keeps it current.
    var editorSettings = EditorSettings()
    /// Runs work outside the text (a table recalculation in Emacs); the main window sets it.
    var externalHandler: ((ExternalRequest) -> Void)?
    /// Files and images pasted or dropped on an editor; the main window sets them.
    var filesHandler: (([URL]) -> Void)?
    var imageHandler: ((Data, String) -> Void)?
    #if APPSTORE
    /// Asks for the folders outside the sidebar's folders that paths need; the main window sets it.
    var reach: ([String]) -> Bool = { _ in true }
    #endif
    /// Tags used across the workspace, for tag completion; the main window sets it.
    var knownTags: () -> [String] = { [] }
    /// The index completion asks for headings, values and words; the main window sets it.
    var completionIndex: IndexStore?
    /// The pending key prefix, and what can follow it.
    var pendingKeys: String?
    /// The editor's evil state in the Doom preset.
    var editorState: String?
    /// The keymap in use, for showing keys in menus and the palette.
    var keymap = KeymapPreset.emacs.keymap
    var modal = false
    /// `org-stored-links`, most recent first; kept for the session, as in Emacs.
    var storedLinks: [StoredLink] = []

    /// Puts `link` first in `storedLinks` and says what happened.
    func storeLink(_ link: StoredLink) {
        show(StoredLink.add(link, to: &storedLinks))
    }

    /// The keys that run `command`, as menus and the palette show them.
    func keyLabel(for command: String) -> String? {
        let labels = keymap.keyLabels(for: command, modes: modal ? ["normal", "insert"] : [nil])
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    /// The editor's selection, for the modeline.
    var selection = NSRange(location: 0, length: 0)
    /// The focused file and caret, advertised for Handoff.
    @ObservationIgnored let handoff = HandoffAdvertiser()
    /// Opens a file continued from another device; the main window sets it.
    @ObservationIgnored var continueHandoff: ((HandoffPlace) -> Void)?
    var keyHints: [KeyHint] = []
    /// A question a command asked, answered in the echo area.
    private(set) var prompt: PromptRequest?
    /// The last message from a command or the keymap, kept until the next key or click, as
    /// Emacs keeps it.
    private(set) var message: String?
    /// Recent messages, oldest first, for Messages.
    private(set) var messages: [String] = []
    @ObservationIgnored private var inputMonitor: Any?

    func ask(_ prompt: Prompt, reply: @escaping (String?) -> Void) {
        self.prompt = PromptRequest(prompt: prompt, reply: reply)
    }

    /// Clock questions in the echo area.
    var askClock: ClockModel.Ask {
        { [self] prompt in
            await withCheckedContinuation { continuation in
                ask(prompt) { continuation.resume(returning: $0) }
            }
        }
    }

    /// Ends the prompt with an answer, or nil to cancel, and gives the editor the keys back.
    func answer(_ text: String?) {
        guard let request = prompt else { return }
        prompt = nil
        if let textView = editor?.textView { textView.window?.makeFirstResponder(textView) }
        request.reply(text)
    }

    /// An export or table recalculation running in Emacs, for Cancel Running Task.
    private(set) var emacsTask: Task<Void, Never>?
    private var emacsSerial = 0

    /// Runs `work` as the Emacs task, cancelling the one before.
    func runInEmacs(_ work: @escaping @MainActor () async -> Void) {
        emacsTask?.cancel()
        emacsSerial += 1
        let serial = emacsSerial
        emacsTask = Task {
            await work()
            if emacsSerial == serial { emacsTask = nil }
        }
    }

    /// An app command from a menu, run by the main window.
    private(set) var runRequest: (id: String, serial: Int)?
    private var runSerial = 0

    func run(_ id: String) {
        runSerial += 1
        runRequest = (id, runSerial)
    }

    /// A capture waiting for the capture window: the template key and the link properties for
    /// its escapes (org-protocol), or the agenda day to schedule the entry on.
    var captureRequest: (template: String?, properties: [String: String], day: Int?, serial: Int)?
    private var captureSerial = 0

    /// An org-roam capture waiting for the capture window, with its templates in place of
    /// capture.toml's.
    var roamCapture: RoamCapture?
    /// An org-roam-protocol link waiting for the main window.
    var roamProtocol: OrgProtocol.Request?

    /// Opens the capture window on an org-roam capture.
    func capture(roam: RoamCapture) {
        captureSerial += 1
        roamCapture = roam
        captureRequest = (nil, [:], nil, captureSerial)
        run("app.capture")
    }

    /// Capture from an agenda day, as `org-agenda-capture`: that day is the capture's date, and
    /// the entry is scheduled on it. The caller opens the capture window.
    func capture(on day: Int) {
        captureSerial += 1
        captureRequest = (nil, [:], day, captureSerial)
    }

    /// `org-protocol://capture` and `store-link`, and the widgets' `orgstar://` links.
    func handle(protocolURL url: String) {
        if let link = URL(string: url).flatMap(AppLink.init(url:)) {
            switch link {
            case .agenda: run("app.agenda")
            case .clock: run("app.clock.goto")
            case .entry(let path, let offset): jump(path: path, offset: offset)
            case .capture(let template):
                captureSerial += 1
                captureRequest = (template, [:], nil, captureSerial)
                run("app.capture")
            }
            return
        }
        switch OrgProtocol.parse(url) {
        case .capture(let template, let properties):
            captureSerial += 1
            captureRequest = (template, properties, nil, captureSerial)
            run("app.capture")
        case .storeLink(let link, let title):
            storeLink(StoredLink(link: link, description: title))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        case .roamRef, .roamNode:
            roamProtocol = OrgProtocol.parse(url)
            run("app.node.protocol")
        case nil:
            show(String(localized: "orgstar handles org-protocol capture and store-link"))
        }
    }

    func jump(path: String, offset: Int) {
        jumpID += 1
        jumpRequest = (path, offset, jumpID)
    }

    func show(_ text: String) {
        message = text
        messages.append(text)
        if messages.count > 100 { messages.removeFirst(messages.count - 100) }
        AccessibilityNotification.Announcement(text).post()
        // A local monitor sees an event before it is handled, so a message the key or click
        // itself shows is set after this clears the last one.
        if inputMonitor == nil {
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    if self?.message != nil { self?.message = nil }
                }
                return event
            }
        }
    }
}

struct PromptRequest: Identifiable {
    let id = UUID()
    let prompt: Prompt
    let reply: (String?) -> Void
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var session: DocumentSession?
    var commands: AppCommands?
    #if APPSTORE
    var workspace: WorkspaceModel?
    #else
    let updates = Updates()
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIcon.start()
        if SystemReminderCenter.isAvailable { UNUserNotificationCenter.current().delegate = self }
        #if !APPSTORE
        updates.start()
        #endif
    }

    #if APPSTORE
    /// A subscription may have lapsed or renewed while the app was in the background.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await ProStore.shared.refresh() }
    }
    #endif

    /// `:session` interpreters end with the app.
    func applicationWillTerminate(_ notification: Notification) {
        #if !APPSTORE
        BabelSessions.shared.stopAll()
        #endif
    }

    /// Reminders show while Orgstar is in front too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Clicking a reminder shows its entry.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let path = info["path"] as? String, let offset = info["offset"] as? Int else { return }
        await MainActor.run {
            NSApp.activate()
            commands?.jump(path: path, offset: offset)
        }
    }

    /// Files opened from Finder, `open`, or a drop on the Dock icon: each opens as a buffer.
    /// Ones that arrive before the window is ready wait for it (`pendingOpens`).
    static var pendingOpens: [String] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        let links = urls.filter { $0.scheme == "org-protocol" || $0.scheme == AppLink.scheme }.map(\.absoluteString)
        guard let commands, let session else {
            Self.pendingOpens += paths
            Self.pendingLinks += links
            return
        }
        NSApp.activate()
        for path in paths { session.open(path) }
        for link in links { commands.handle(protocolURL: link) }
    }

    /// org-protocol and orgstar:// links that arrive before the window is ready.
    static var pendingLinks: [String] = []

    /// Files continued from another device before the window is ready.
    static var pendingHandoffs: [HandoffPlace] = []

    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        userActivityType == HandoffPlace.activityType
    }

    /// Handoff from an iPhone, iPad or another Mac.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == HandoffPlace.activityType, let place = HandoffPlace(userInfo: userActivity.userInfo) else { return false }
        if let handler = commands?.continueHandoff {
            NSApp.activate()
            handler(place)
        } else {
            Self.pendingHandoffs.append(place)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        #if APPSTORE
        BufferRestore.save(session, workspace: workspace)
        #else
        BufferRestore.save(session)
        #endif
        guard UnsavedChanges.resolve(session, paths: session.openPaths) else { return .terminateCancel }
        #if !APPSTORE
        // Files saved since their folder's last automatic commit are committed before quitting.
        if GitAutoCommit.shared.hasPending {
            Task {
                await GitAutoCommit.shared.flush()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        #endif
        return .terminateNow
    }
}

/// Unsaved edits when leaving a file or quitting.
@MainActor
enum UnsavedChanges {
    /// Whether the open file can be left: saved in automatic mode, or as the user chooses in
    /// explicit mode. A save that fails or conflicts keeps the file open.
    static func resolve(_ session: DocumentSession) -> Bool {
        guard session.isDirty, let path = session.path else { return true }
        if session.saveMode == .automatic { return save(session, path) }
        let alert = NSAlert()
        alert.messageText = session.path.map { String(localized: "Save changes to \(($0 as NSString).lastPathComponent)?") }
            ?? String(localized: "Save changes to this file?")
        alert.informativeText = String(localized: "Your changes will be lost if you don't save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(session, path)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    /// Whether the buffers of `paths` can be closed: saved in automatic mode, or as the user
    /// chooses for all of them in explicit mode.
    static func resolve(_ session: DocumentSession, paths: [String]) -> Bool {
        let dirty = paths.filter(session.dirtyPaths.contains)
        guard !dirty.isEmpty else { return true }
        if session.saveMode == .automatic { return dirty.map { save(session, $0) }.allSatisfy { $0 } }
        if dirty == [session.path] { return resolve(session) }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save changes to \(dirty.count) files?")
        alert.informativeText = dirty.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        alert.addButton(withTitle: String(localized: "Save All"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return dirty.map { save(session, $0) }.allSatisfy { $0 }
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    /// Saves `path`. One held for its passphrase asks for it, or whether to leave without saving.
    static func save(_ session: DocumentSession, _ path: String) -> Bool {
        if session.save(path) { return true }
        let name = (path as NSString).lastPathComponent
        guard let hold = session.held[path], hold.takesPassphrase else {
            // A save that failed otherwise (a conflict, an error, an entry the passphrase can't
            // encrypt) still lets the file be left without saving.
            let alert = NSAlert()
            alert.messageText = String(localized: "Changes to \(name) aren't saved")
            alert.informativeText = session.held[path]?.notice(for: path) ?? session.conflict ?? session.lastError ?? ""
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Don't Save"))
            return alert.runModal() == .alertSecondButtonReturn
        }
        // A new passphrase is typed twice; one that must open what's encrypted already, once.
        let twice = hold == .file || OrgCrypt.firstMessage(session.document(of: path)?.text ?? "") == nil
        let fields = (twice ? [String(localized: "Passphrase"), String(localized: "Repeat passphrase")] : [String(localized: "Passphrase")]).map { placeholder in
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
            field.placeholderString = placeholder
            return field
        }
        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(fields.count) * 28)
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = String(localized: "Changes to \(name) aren't saved")
            alert.informativeText = (problem.map { $0 + "\n\n" } ?? "") + hold.notice(for: path) + " "
                + String(localized: "Enter the passphrase to encrypt and save them, or leave without saving.")
            alert.accessoryView = stack
            alert.addButton(withTitle: String(localized: "Encrypt and Save"))
            alert.addButton(withTitle: String(localized: "Don't Save"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.window.initialFirstResponder = fields[0]
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let passphrase = fields[0].stringValue
                if passphrase.isEmpty {
                    problem = String(localized: "Enter a passphrase.")
                } else if twice, fields[1].stringValue != passphrase {
                    problem = String(localized: "The passphrases differ")
                } else if let failure = session.unlock(passphrase, for: path) {
                    problem = failure
                } else {
                    session.passphrases.keep(passphrase, for: path, text: session.document(of: path)?.text ?? "")
                    return !session.dirtyPaths.contains(path)
                }
            case .alertSecondButtonReturn: return true
            default: return false
            }
        }
    }
}

/// The open buffers, their order and carets, kept for the next launch.
@MainActor
enum BufferRestore {
    private static let key = "openBuffers"

    struct State: Codable {
        var paths: [String]
        var current: String?
        var carets: [String: Int]
        /// In the Mac App Store build, bookmarks of the files outside every folder, which the
        /// sandbox would otherwise keep orgstar out of after relaunch.
        var bookmarks: [String: Data]?
    }

    /// `bookmarking` says which paths get a bookmark. A path still open keeps the bookmark it
    /// has when no new one is made.
    static func save(_ session: DocumentSession, bookmarking: (String) -> Bool = { _ in false }, defaults: UserDefaults = .standard) {
        var carets: [String: Int] = [:]
        for path in session.openPaths { carets[path] = session.caret(of: path) }
        let previous = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) }?.bookmarks ?? [:]
        var bookmarks: [String: Data] = [:]
        for path in session.openPaths {
            bookmarks[path] = (bookmarking(path) ? SecurityBookmark.make(URL(fileURLWithPath: path)) : nil) ?? previous[path]
        }
        let state = State(paths: session.openPaths, current: session.path, carets: carets, bookmarks: bookmarks.isEmpty ? nil : bookmarks)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }

    #if APPSTORE
    /// Saves with bookmarks for the files outside `workspace`'s folders and grants.
    static func save(_ session: DocumentSession, workspace: WorkspaceModel?) {
        save(session, bookmarking: { workspace?.contains(URL(fileURLWithPath: $0)) != true })
    }
    #endif

    /// Opens the buffers that were open, in order, and returns the carets to show them at.
    static func restore(_ session: DocumentSession, defaults: UserDefaults = .standard) -> [String: Int] {
        guard let data = defaults.data(forKey: key), var state = try? JSONDecoder().decode(State.self, from: data) else { return [:] }
        // A bookmarked file comes back with access, at the path it has now.
        for (path, bookmark) in state.bookmarks ?? [:] {
            guard let moved = SecurityBookmark.resolve(bookmark)?.url.path, moved != path else { continue }
            state.paths = state.paths.map { $0 == path ? moved : $0 }
            if state.current == path { state.current = moved }
            state.carets[moved] = state.carets.removeValue(forKey: path)
        }
        let existing = state.paths.filter { FileManager.default.fileExists(atPath: $0) }
        for path in existing { session.open(path) }
        if let current = state.current, existing.contains(current) { session.open(current) }
        return state.carets
    }
}

@main
struct OrgstarApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var workspace = Result {
        try WorkspaceModel(directory: WorkspaceModel.defaultDirectory, settings: .with(todoKeywords: Preferences.orgSettings))
    }
    @State private var commands = AppCommands()
    @State private var clock = ClockModel()
    @State private var scheduler = SystemReminderCenter.isAvailable ? ReminderScheduler(center: SystemReminderCenter()) : nil
    @State private var session: DocumentSession = {
        ClockTask.titleKey = ClockTitleKey.loadOrCreate()
        let session = DocumentSession()
        session.defaults = Preferences.orgSettings
        // Before any window: capture and agenda edits can save before the main window opens.
        session.encryptsTaggedEntries = OrgPreferences.cryptBeforeSave()
        session.cryptTag = OrgPreferences.cryptTag()
        return session
    }()

    init() {
        PDFExport.mathJaxURL = OrgMathJax.script
        DiagramBlocks.vizURL = OrgMathJax.viz
        DiagramBlocks.mermaidURL = OrgMathJax.mermaid
        #if APPSTORE
        AgendaSnapshot.useGroupContainer = true
        EmacsFallback.offered = false
        _ = FolderGrants.shared
        ProStore.shared.start()
        #else
        DocumentSession.programs = Programs()
        MacPro.resolve()
        MacPro.renewInBackground()
        #endif
        // `org-sbe` in table formulas runs blocks, so it needs Babel as source blocks do.
        TableBlocks.allowed = { ProAccess.isUnlockedNow }
        // Debug builds, and runs with ORGSTAR_PERF set: main-thread stalls in the console.
        #if DEBUG
        Perf.watchMainThread()
        #else
        if ProcessInfo.processInfo.environment["ORGSTAR_PERF"] != nil { Perf.watchMainThread() }
        #endif
    }

    var body: some Scene {
        Window("orgstar", id: "main") {
            switch workspace {
            case .success(let model):
                ContentView(workspace: model, session: session, commands: commands, scheduler: scheduler, clock: clock)
                    .environment(\.orgTheme, ConfigSync.shared.theme)
                    .tint(ConfigSync.shared.theme.color("accent"))
                    .onAppear {
                        delegate.session = session
                        delegate.commands = commands
                        #if APPSTORE
                        delegate.workspace = model
                        #else
                        GitAutoCommit.shared.roots = { model.rootPaths }
                        GitAutoCommit.shared.report = { commands.show($0) }
                        session.fileWritten = { GitAutoCommit.shared.fileWritten($0) }
                        #endif
                        CaptureIntent.environment = (model, session, clock, commands)
                    }
            case .failure(let error):
                ContentUnavailableView("Can't Open the Index", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
            }
        }
        .defaultSize(width: 1280, height: 860)
        WindowGroup("Editor", id: "editor") {
            if case .success = workspace {
                EditorWindowView(session: session, commands: commands)
                    .environment(\.orgTheme, ConfigSync.shared.theme)
                    .tint(ConfigSync.shared.theme.color("accent"))
            }
        }
        .defaultSize(width: 900, height: 700)
        .commandsRemoved()
        Window("Agenda", id: "agenda") {
            if case .success(let model) = workspace {
                AgendaView(workspace: model, session: session, commands: commands, scheduler: scheduler, clock: clock)
                    .environment(\.orgTheme, ConfigSync.shared.theme)
                    .tint(ConfigSync.shared.theme.color("accent"))
            }
        }
        .defaultSize(width: 760, height: 720)
        Window("Board", id: "board") {
            if case .success(let model) = workspace {
                BoardView(workspace: model, session: session, commands: commands)
                    .environment(\.orgTheme, ConfigSync.shared.theme)
                    .tint(ConfigSync.shared.theme.color("accent"))
            }
        }
        .defaultSize(width: 1100, height: 700)
        Window("Node Graph", id: "graph") {
            if case .success(let model) = workspace {
                RoamGraphWindow(workspace: model, session: session, commands: commands)
                    .tint(ConfigSync.shared.theme.color("accent"))
            }
        }
        .defaultSize(width: 900, height: 700)
        Window("Lint All Folders", id: "lint-folders") {
            if case .success(let model) = workspace {
                FolderLintWindow(workspace: model, session: session, commands: commands)
                    .tint(ConfigSync.shared.theme.color("accent"))
            }
        }
        .defaultSize(width: 760, height: 520)
        Window("Clock Report", id: "clock-report") {
            if case .success(let model) = workspace {
                ClockReportView(workspace: model, session: session)
                    .environment(\.orgTheme, ConfigSync.shared.theme)
                    .tint(ConfigSync.shared.theme.color("accent"))
            }
        }
        .defaultSize(width: 860, height: 560)
        Window("Capture", id: "capture") {
            if case .success(let model) = workspace {
                CaptureView(workspace: model, session: session, commands: commands, clock: clock)
                    .environment(\.orgTheme, ConfigSync.shared.theme)
                    .tint(ConfigSync.shared.theme.color("accent"))
            }
        }
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { commands.showingFolderPicker = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Quick Open…") { commands.showingQuickOpen = true }
                    .keyboardShortcut("p")
                Button("Command Palette…") { commands.showingPalette = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(after: .saveItem) {
                Menu("Export") {
                    ForEach(EditorCommands.all.filter { $0.id.hasPrefix("app.export.") && !hiddenCommandIDs.contains($0.id) }, id: \.id) { command in
                        Button(command.localizedTitle) { commands.run(command.id) }
                    }
                }
                .disabled(session.path == nil)
                Button("Share Subtree…") { commands.run("app.share-subtree") }
                    .disabled(!session.isOrg)
                Menu("Publish") {
                    ForEach(EditorCommands.all.filter { $0.id.hasPrefix("app.publish") }, id: \.id) { command in
                        Button(command.localizedTitle) { commands.run(command.id) }
                    }
                }
                Divider()
                Button("Revert to File on Disk") { commands.run("app.revert") }
                    .disabled(session.path == nil)
                Button("Resolve Sync Conflicts…") { commands.run("app.sync-conflicts") }
                    .disabled(session.path == nil)
                Button("History…") { commands.run("app.recovery") }
                    .disabled(session.path == nil)
                Button("Lint File") { commands.run("app.lint") }
                    .disabled(!FileLint.applies(to: session.path))
                Button("Lint All Folders") { commands.run("app.lint-folders") }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Buffer") {
                    // ⌘W closes the buffer in the main window, and other windows themselves.
                    if let key = NSApp.keyWindow, key.identifier?.rawValue.contains("main") != true {
                        key.performClose(nil)
                    } else {
                        commands.run("app.buffer.kill")
                    }
                }
                .keyboardShortcut("w")
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("Save") {
                    if !session.save(), session.conflict != nil { commands.showingConflict = true }
                }
                .keyboardShortcut("s")
                .disabled(session.path == nil || session.isReadOnly)
                Button("Save All") { commands.run("app.save-all") }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(session.dirtyPaths.isEmpty)
            }
            CommandGroup(after: .sidebar) {
                Button("Split Pane Below") { commands.run("app.split-below") }
                    .keyboardShortcut("2", modifiers: [.command, .control])
                Button("Split Pane Right") { commands.run("app.split-right") }
                    .keyboardShortcut("3", modifiers: [.command, .control])
                Button("Close Pane") { commands.run("app.pane-close") }
                    .keyboardShortcut("0", modifiers: [.command, .control])
                Button("Close Other Panes") { commands.run("app.pane-only") }
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Button("Next Pane") { commands.run("app.pane-next") }
                    .keyboardShortcut("`", modifiers: [.command, .option])
                Divider()
                ViewMenuToggles(commands: commands)
                Divider()
                Button("Messages") { commands.run("app.messages") }
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                FindMenu(commands: commands)
                MacroMenu(commands: commands)
            }
            CommandGroup(after: .textEditing) {
                Button("Cancel Running Task") { commands.run("app.babel.cancel") }
                    .keyboardShortcut(".")
                    .disabled(!session.isRunningBabel && commands.emacsTask == nil)
                Button("Search Notes") { commands.focusSearch = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandGroup(before: .windowList) {
                AgendaMenuItem()
                Divider()
                Button("Switch to Buffer…") { commands.run("app.buffer.switch") }
                Button("Next Buffer") { commands.run("app.buffer.next") }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Buffer") { commands.run("app.buffer.previous") }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
            }
            CommandGroup(after: .newItem) {
                Button("Capture…") { commands.run("app.capture") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New File from Template…") { commands.run("app.new-file-from-template") }
                Button("New Window") { commands.run("app.window-new") }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
        }
        .commands {
            CommandMenu("Org") {
                ClockMenu(commands: commands, clock: clock)
                Divider()
                OrgMenuItems(commands: commands)
            }
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Edit Config File") { commands.jump(path: UserConfig.configFile.path, offset: 0) }
                    .keyboardShortcut(",", modifiers: [.command, .option])
            }
            #if !APPSTORE
            CommandGroup(after: .appInfo) {
                CheckForUpdatesItem(updates: delegate.updates)
            }
            #endif
            CommandGroup(replacing: .help) {
                Button("orgstar Manual") { NSWorkspace.shared.open(Manual.home) }
                Button("Keys") { NSWorkspace.shared.open(Manual.keys) }
                Divider()
                Button("What's New in orgstar") { commands.whatsNew = WhatsNew.releases.first }
                    .disabled(!commands.mainWindowOpen)
            }
        }
        Settings {
            #if APPSTORE
            SettingsView(commands: commands, workspace: try? workspace.get())
            #else
            SettingsView(commands: commands, workspace: try? workspace.get(), updates: delegate.updates)
            #endif
        }
    }
}

/// The Org menu: every org command and the app's commands for entries and notes, in submenus by
/// subject, with the keys that run them in the current keymap.
struct OrgMenuItems: View {
    let commands: AppCommands

    /// Submenus and the command id prefixes they hold, in menu order. A command goes in the
    /// first submenu with a prefix it starts with.
    static let groups: [(title: LocalizedStringKey, prefixes: [String])] = [
        ("Visibility", ["org.cycle", "org.fold.", "org.narrow.", "org.widen", "org.sparse-tree", "org.toggle-inline-images", "org.latex-preview"]),
        ("Headings", ["org.heading.", "org.subtree.", "org.element.", "org.goto", "org.sort", "org.archive.", "app.refile", "app.archive"]),
        ("TODO and Tags", ["org.todo.", "org.priority.", "org.tags.", "org.effort.", "app.rename-"]),
        ("Properties and Columns", ["org.property.", "org.columns", "org.drawer."]),
        ("Dates and Timers", ["org.schedule", "org.deadline", "org.timestamp.", "org.timer."]),
        ("Lists", ["org.item.", "org.checkbox."]),
        ("Tables", ["org.table", "app.table-", "app.plot"]),
        ("Links and Footnotes", ["org.link.", "org.id.", "org.footnote.", "app.cite."]),
        ("Blocks", ["org.babel.", "org.structure-template", "org.edit-special", "org.dblock.", "org.clock.report", "org.denote."]),
        ("Text", ["org.emphasize", "org.fill-"]),
        ("Attachments", ["app.attach."]),
        ("Notes", ["app.dailies.", "app.node."]),
        ("Encryption", ["app.crypt."]),
    ]

    private static func group(of id: String) -> Int? {
        groups.firstIndex { $0.prefixes.contains { id.hasPrefix($0) } }
    }

    private static let shown = EditorCommands.all.filter { ($0.id.hasPrefix("org.") || group(of: $0.id) != nil) && !hiddenCommandIDs.contains($0.id) }

    var body: some View {
        // Commands that fit no subject, such as Act at Point, come first.
        ForEach(Self.shown.filter { Self.group(of: $0.id) == nil }, id: \.id) { item($0) }
        Divider()
        ForEach(Self.groups.indices, id: \.self) { index in
            Menu(Self.groups[index].title) {
                ForEach(Self.shown.filter { Self.group(of: $0.id) == index }, id: \.id) { item($0) }
            }
        }
    }

    private func item(_ command: EditorCommand) -> some View {
        Button {
            if command.id.hasPrefix("org.") { commands.editor?.run(command.id) } else { commands.run(command.id) }
        } label: {
            Text(command.localizedTitle)
            if let keys = commands.keyLabel(for: command.id) { Text(keys) }
        }
        .disabled(command.id.hasPrefix("org.") && commands.editor == nil)
    }
}

/// The user manual, as `scripts/publish-docs.sh` publishes it.
enum Manual {
    static let home = URL(string: "https://files.krz.sh/orgstar/")!
    /// The key reference, with every preset's keys.
    static let keys = URL(string: "https://files.krz.sh/orgstar/guide/03-keys.html#key-reference")!
}

/// View ▸ the panes and the focused editor's modes, checked while on.
struct ViewMenuToggles: View {
    let commands: AppCommands
    @AppStorage("backlinksShown") private var backlinksShown = true
    @AppStorage("inspectorShown") private var inspectorShown = false

    var body: some View {
        let outline = commands.outlineShown
        let editor = commands.editor
        // A key that switches an editor mode shows a message, so the checks follow it.
        let _ = commands.message
        Toggle("Show Outline", isOn: Binding(get: { outline }, set: { _ in commands.run("app.toggle-outline") }))
            .keyboardShortcut("o", modifiers: [.command, .option])
        Toggle("Show Backlinks", isOn: $backlinksShown)
        Toggle("Show Inspector", isOn: $inspectorShown)
            .keyboardShortcut("i", modifiers: [.command, .option])
        MarkupToggle()
        editorToggle("Truncate Long Lines", "editor.toggle-truncate-lines", editor?.truncatesLines)
        editorToggle("Auto Fill", "editor.toggle-auto-fill", editor?.autoFills)
        editorToggle("Check Spelling While Typing", "editor.toggle-spell-check", editor?.spellChecking)
    }

    private func editorToggle(_ title: LocalizedStringKey, _ id: String, _ on: Bool?) -> some View {
        Toggle(title, isOn: Binding(get: { on ?? false }, set: { _ in commands.editor?.run(id) }))
            .disabled(on == nil)
    }
}

/// View ▸ Show Markup (link brackets and targets, emphasis markers) and Show Line Numbers.
struct MarkupToggle: View {
    @AppStorage("showTabBar") private var showTabBar = false
    @AppStorage("showMarkup") private var showMarkup = false
    @AppStorage("showLineNumbers") private var showLineNumbers = false
    @AppStorage("lineNumbersType") private var lineNumbersType = "t"

    var body: some View {
        Toggle("Show Markup", isOn: $showMarkup)
            .keyboardShortcut("m", modifiers: [.command, .shift])
        Toggle("Show Line Numbers", isOn: $showLineNumbers)
            .keyboardShortcut("l", modifiers: [.command, .shift])
        Picker("Line Numbers", selection: $lineNumbersType) {
            Text("Absolute").tag("t")
            Text("Relative").tag("relative")
            Text("Visual").tag("visual")
        }
        Toggle("Show Tab Bar", isOn: $showTabBar)
    }
}

/// Edit ▸ Find: the editor's find bar.
struct FindMenu: View {
    let commands: AppCommands

    var body: some View {
        Menu("Find") {
            item("Find…", "edit.find", "f")
            item("Find and Replace…", "edit.replace", "f", [.command, .option])
            item("Find Next", "edit.find-next", "g")
            item("Find Previous", "edit.find-previous", "g", [.command, .shift])
            item("Use Selection for Find", "edit.use-selection-for-find", "e")
            Divider()
            Button("Replace in Files…") { commands.run("app.replace-in-files") }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
        }
    }

    private func item(_ title: String, _ id: String, _ key: KeyEquivalent, _ modifiers: EventModifiers = .command) -> some View {
        Button(title) { commands.editor?.run(id) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(commands.editor == nil)
    }
}

/// Edit ▸ Macros: keyboard macros, with the keys that run them in the current keymap.
struct MacroMenu: View {
    let commands: AppCommands

    var body: some View {
        Menu("Macros") {
            item("Start Recording", "macro.start")
            item("Stop Recording", "macro.end")
            item("Run Last Macro", "macro.call")
            Divider()
            item("Name Last Macro…", "macro.name")
            item("Run Macro…", "macro.run")
        }
    }

    private func item(_ title: LocalizedStringKey, _ id: String) -> some View {
        Button {
            commands.editor?.run(id)
        } label: {
            Text(title)
            if let keys = commands.keyLabel(for: id) { Text(keys) }
        }
        .disabled(commands.editor == nil)
    }
}

/// Window ▸ Agenda.
struct AgendaMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Agenda") { openWindow(id: "agenda") }
            .keyboardShortcut("a", modifiers: [.command, .shift])
        Button("Board") { openWindow(id: "board") }
            .keyboardShortcut("b", modifiers: [.command, .shift])
        Button("Graph") { if ProAccess.shared.allows(.roam) { openWindow(id: "graph") } }
    }
}

struct SettingsView: View {
    let commands: AppCommands
    let workspace: WorkspaceModel?
    #if !APPSTORE
    let updates: Updates
    #endif
    @State private var importing = false
    #if APPSTORE
    @State private var configFolder = UserConfig.directoryOverride
    #endif
    @Environment(\.openWindow) private var openWindow
    @AppStorage("saveMode") private var saveMode = SaveMode.automatic
    @AppStorage("keymap") private var preset = KeymapPreset.emacs
    @AppStorage("optionAsMeta") private var optionAsMeta = OptionAsMeta.left.rawValue
    @AppStorage("tagsColumn") private var tagsColumn = -77
    @AppStorage("headingAfterSubtree") private var headingAfterSubtree = false
    @AppStorage("splitLine") private var splitLine = false
    @AppStorage("alphabeticalLists") private var alphabeticalLists = true
    @AppStorage("fillColumn") private var fillColumn = 80
    @AppStorage("hiddenMarkers") private var hiddenMarkers = true
    @AppStorage("prettyEntities") private var prettyEntities = true
    @AppStorage("startupTruncated") private var startupTruncated = false
    @AppStorage("todoKeywords") private var todoKeywords = Preferences.defaultTodoKeywords
    @AppStorage("logDone") private var logDone = "nil"
    @AppStorage("logIntoDrawer") private var logIntoDrawer = ""
    @AppStorage("useSpeedCommands") private var useSpeedCommands = false
    @AppStorage("spellCheck") private var spellCheck = false
    @AppStorage("completionAuto") private var completionAuto = "preset"
    @AppStorage("completionAutoDelay") private var completionAutoDelay = 400
    @AppStorage("completionAutoPrefix") private var completionAutoPrefix = 2
    @AppStorage("completionStyle") private var completionStyle = "preset"
    @AppStorage("completionWords") private var completionWords = false
    @AppStorage("enforceTodoDependencies") private var enforceTodoDependencies = false
    @AppStorage("enforceTodoCheckboxDependencies") private var enforceTodoCheckboxDependencies = false
    @AppStorage("agendaSpan") private var agendaSpan = 10
    @AppStorage("agendaStartOffset") private var agendaStartOffset = 0
    @AppStorage("agendaSubfolders") private var agendaSubfolders = false
    @AppStorage("agendaShowAllDates") private var agendaShowAllDates = false
    @AppStorage("habitsOnlyForToday") private var habitsOnlyForToday = true
    @AppStorage("agendaDimBlockedTasks") private var agendaDimBlockedTasks = "t"
    @AppStorage("calendarEvents") private var calendarEvents = false
    @AppStorage("calendarEventCalendars") private var calendarEventCalendars = ""
    @State private var calendars: [(id: String, title: String, color: RGBA?)] = []
    @AppStorage("agendaReminders") private var agendaReminders = false
    @AppStorage("agendaReminderLists") private var agendaReminderLists = ""
    @State private var reminderLists: [(id: String, title: String, color: RGBA?)] = []
    @AppStorage("reminders") private var reminders = true
    @AppStorage("reminderLead") private var reminderLead = 12
    @AppStorage("clockIdleTime") private var clockIdleTime = 0
    @AppStorage("clockHistoryLength") private var clockHistoryLength = 5
    @AppStorage("globalCapture") private var globalCapture = true
    @AppStorage("menuBarItem") private var menuBarItem = false
    @AppStorage("settingsTab") private var tab = "general"
    @AppStorage("showHiddenFiles") private var showHiddenFiles = true
    @AppStorage("themeFont") private var themeFont = ""
    @AppStorage("themeBodyFont") private var themeBodyFont = ""
    @AppStorage("themeFontSize") private var themeFontSize = 13
    @AppStorage("themeLineSpacing") private var themeLineSpacing = 2
    @AppStorage("themeTextWidth") private var themeTextWidth = 0
    @AppStorage("themeHeadingStep") private var themeHeadingStep = 1

    /// Installed font families that aren't monospaced, for body text.
    private static let proportionalFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { family in
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?.isFixedPitch == false
    }

    /// Installed monospaced font families.
    private static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { family in
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?.isFixedPitch == true
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { general }
            Tab("Editing", systemImage: "text.alignleft", value: "editing") { editing }
            Tab("Appearance", systemImage: "paintpalette", value: "appearance") { appearance }
            Tab("Agenda", systemImage: "calendar", value: "agenda") { agenda }
            Tab("Capture", systemImage: "tray.and.arrow.down", value: "capture") { capture }
            Tab("Encryption", systemImage: "lock", value: "encryption") {
                Form { DecryptSettings() }.formStyle(.grouped).frame(height: 330)
            }
            #if !APPSTORE
            Tab(value: "git") { GitSettingsForm(workspace: workspace) } label: {
                Label { Text("Git", tableName: "DeveloperID") } icon: { Image(systemName: "arrow.triangle.branch") }
            }
            #endif
            #if APPSTORE
            Tab("orgstar+", systemImage: "star", value: "pro") { StoreForm() }
            #else
            Tab("orgstar+", systemImage: "star", value: "pro") { LicenseForm() }
            #endif
        }
        .frame(width: 600)
    }

    private func editConfig() {
        ConfigSync.shared.start()
        openWindow(id: "main")
        commands.jump(path: UserConfig.configFile.path, offset: 0)
    }

    #if APPSTORE
    /// A folder outside the app's container, such as `~/.config/orgstar` kept with dotfiles.
    private func chooseConfigFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = configFolder ?? ConfigFolder.suggested
        panel.message = String(localized: "Choose the folder for config.toml and orgstar's other configuration files.", comment: "Choose Configuration Folder panel")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !ConfigFolder.set(url) {
            GrantAccess.tell(String(localized: "orgstar can't keep \(OrgPaths.abbreviatingWithTilde(url.path)) as the configuration folder.", comment: "Alert when the chosen configuration folder can't be saved"),
                             String(localized: "Access lasts until orgstar quits.", comment: "Alert when a folder grant or the configuration folder can't be saved"))
        }
        useConfigFolder(url)
    }

    /// Reads and writes the configuration in `url`, or with nil in the default folder.
    private func useConfigFolder(_ url: URL?) {
        if url == nil { ConfigFolder.clear() }
        UserConfig.directoryOverride = url
        configFolder = url
        ConfigSync.shared.move(to: UserConfig.configFile)
    }
    #endif

    private var general: some View {
        Form {
            Section {
                LabeledContent("config.toml") {
                    HStack {
                        Button("Edit in orgstar") { editConfig() }
                        Button("Open with Default App") { NSWorkspace.shared.open(UserConfig.configFile) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([UserConfig.configFile]) }
                    }
                }
                #if APPSTORE
                LabeledContent("Folder") {
                    HStack {
                        Button("Choose Configuration Folder…") { chooseConfigFolder() }
                        if configFolder != nil { Button("Use Default Folder") { useConfigFolder(nil) } }
                    }
                }
                #endif
                LabeledContent("Emacs") {
                    Button("Import from Emacs…") { importing = true }
                }
            } footer: {
                Text("Every setting here is also in \(UserConfig.configFile.path), which you can edit, share or keep with your dotfiles. Changes in either place show up in the other.")
                    .settingsFooter()
            }
            #if !APPSTORE
            if updates.canCheck {
                Section {
                    Toggle(isOn: Binding(get: { updates.automatically }, set: { updates.automatically = $0 })) { Text("Check for updates automatically", tableName: "DeveloperID") }
                } footer: {
                    Text("Once a day, from the app's own feed. orgstar ▸ Check for Updates… checks now.", tableName: "DeveloperID")
                        .settingsFooter()
                }
            }
            #endif
            Section {
                Picker("Save files", selection: $saveMode) {
                    Text("Automatically, when typing stops").tag(SaveMode.automatic)
                    Text("Only with File ▸ Save (⌘S)").tag(SaveMode.explicit)
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                Picker("Keys", selection: $preset) {
                    ForEach(KeymapPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show hidden files and folders", isOn: $showHiddenFiles)
                Toggle("Keep orgstar in the menu bar", isOn: $menuBarItem)
                    .help("Capture, the agenda, today's entries and the clock, from any app. When off, the menu bar shows orgstar only while a clock runs.")
                Picker("Option as Meta", selection: $optionAsMeta) {
                    Text("Left Option").tag(OptionAsMeta.left.rawValue)
                    Text("Right Option").tag(OptionAsMeta.right.rawValue)
                    Text("Both").tag(OptionAsMeta([.left, .right]).rawValue)
                    Text("Neither").tag(0)
                }
            } footer: {
                Text("Your own bindings go in \(KeymapLoader.userFile.path), on top of the preset.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(height: 330)
        .sheet(isPresented: $importing) { EmacsImportView(workspace: workspace) }
    }

    private var editing: some View {
        Form {
            Section {
                Picker("Tags", selection: $tagsColumn) {
                    Text("Aligned to end at column 77").tag(-77)
                    Text("One space after the title").tag(0)
                }
                .help(Text(verbatim: "org-tags-column"))
                Toggle(isOn: $headingAfterSubtree) { keyed("New headings go after the subtree", "org.heading.insert") }
                    .help(Text(verbatim: "org-insert-heading-respect-content"))
                Toggle(isOn: $splitLine) { keyed("New headings and items split the line at the caret", "org.heading.insert") }
                    .help(Text(verbatim: "org-M-RET-may-split-line"))
                Toggle("Lists can use letters (a. b. c.)", isOn: $alphabeticalLists)
                    .help(Text(verbatim: "org-list-allow-alphabetical"))
                Stepper(value: $fillColumn, in: 40...200) { keyed("Fill Paragraph wraps lines at column \(fillColumn)", "org.fill-paragraph") }
                    .help(Text(verbatim: "fill-column"))
            }
            Section {
                Toggle("Long lines run off the edge instead of wrapping", isOn: $startupTruncated)
                    .help(Text(verbatim: "org-startup-truncated"))
            } footer: {
                Text("Applies to files as they open. View ▸ Truncate Long Lines switches the current file.")
                    .settingsFooter()
            }
            Section {
                Toggle("Emacs hides emphasis markers", isOn: $hiddenMarkers)
                    .help(Text(verbatim: "org-hide-emphasis-markers"))
                Toggle("Emacs shows entities as characters", isOn: $prettyEntities)
                    .help(Text(verbatim: "org-pretty-entities"))
            } footer: {
                Text("Tags, tables and Fill Paragraph measure text as your Emacs displays it, so both write the same file.")
                    .settingsFooter()
            }
            Section {
                TextField("Default TODO keywords", text: $todoKeywords, axis: .vertical)
            } footer: {
                Text("For files without #+TODO, in #+TODO syntax, one sequence per line. Takes effect when orgstar restarts.")
                    .settingsFooter()
            }
            Section {
                Toggle("Entries can't be done before their TODO children", isOn: $enforceTodoDependencies)
                    .help(Text(verbatim: "org-enforce-todo-dependencies"))
                Toggle("Entries can't be done with unchecked boxes", isOn: $enforceTodoCheckboxDependencies)
                    .help(Text(verbatim: "org-enforce-todo-checkbox-dependencies"))
            } footer: {
                Text("Under a parent with the ORDERED property (Org ▸ Properties and Columns ▸ Toggle ORDERED Property), TODO children are also done in order.")
                    .settingsFooter()
            }
            Section {
                Picker("When an entry is done", selection: $logDone) {
                    Text("Record nothing").tag("nil")
                    Text("Record the time, as CLOSED").tag("time")
                    Text("Record the time and ask for a note").tag("note")
                }
                .help(Text(verbatim: "org-log-done"))
                Toggle("State notes go in a LOGBOOK drawer", isOn: logIntoDrawerOn)
                    .help(Text(verbatim: "org-log-into-drawer"))
            } footer: {
                Text("Keyword flags such as DONE(d!) and #+STARTUP words in a file override these. org-log-reschedule and org-log-redeadline are in config.toml.")
                    .settingsFooter()
            }
            Section {
                Toggle("Speed keys: single letters at the start of a heading line run commands", isOn: $useSpeedCommands)
                    .help(Text(verbatim: "org-use-speed-commands"))
                Toggle("Check spelling while typing", isOn: $spellCheck)
                    .help(Text(verbatim: "spell-check"))
            } footer: {
                Text("Spell checking applies to files as they open; Check Spelling While Typing switches the current file. Code, links, dates, tags and keywords aren't checked.")
                    .settingsFooter()
            }
            Section {
                Picker("Completion list opens", selection: $completionAuto) {
                    Text("As the keys do (by itself with Doom)").tag("preset")
                    Text("By itself as you type").tag("on")
                    Text("Only with a key").tag("off")
                }
                .help(Text(verbatim: "completion-auto"))
                Stepper("After a pause of \(completionAutoDelay) ms", value: $completionAutoDelay, in: 0...2000, step: 50)
                    .help(Text(verbatim: "completion-auto-delay"))
                Stepper("Once \(completionAutoPrefix) characters are typed", value: $completionAutoPrefix, in: 1...10)
                    .help(Text(verbatim: "completion-auto-prefix"))
                Picker("Candidates", selection: $completionStyle) {
                    Text("As the keys do (letters in order with Doom)").tag("preset")
                    Text("Start with what's typed").tag("prefix")
                    Text("Have its letters in order, best first").tag("fuzzy")
                }
                .help(Text(verbatim: "completion-style"))
                Toggle("The list offers words from open files and folders", isOn: $completionWords)
                    .help(Text(verbatim: "completion-words"))
            } header: {
                Text("Completion")
            } footer: {
                Text("Doom's keys open the list by itself and match letters in order, as Doom's corfu does; the Emacs and Mac keys do neither unless set here. Expand Word completes the word before the caret from your files whatever is set.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(height: 860)
    }

    /// `label`, then the keys that run `command` in the current preset, if any.
    private func keyed(_ label: LocalizedStringKey, _ command: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
            if let keys = commands.keyLabel(for: command) {
                Text(verbatim: keys).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    /// `org-log-into-drawer` as a switch: on is "LOGBOOK" (Emacs's t); a drawer name of its own counts as on.
    private var logIntoDrawerOn: Binding<Bool> {
        Binding(get: { !logIntoDrawer.isEmpty }, set: { logIntoDrawer = $0 ? "LOGBOOK" : "" })
    }

    private var appearance: some View {
        Form {
            ThemePickerSection()
            AppIconSection()
            Section {
                Picker("Font", selection: $themeFont) {
                    Text("System monospaced").tag("")
                    Divider()
                    ForEach(Self.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                    if !themeFont.isEmpty, !Self.monospacedFamilies.contains(themeFont) { Text(themeFont).tag(themeFont) }
                }
                Picker("Body font", selection: $themeBodyFont) {
                    Text("Same as Font").tag("")
                    Text("System").tag("system")
                    Divider()
                    ForEach(Self.proportionalFamilies, id: \.self) { Text($0).tag($0) }
                    if !["", "system"].contains(themeBodyFont), !Self.proportionalFamilies.contains(themeBodyFont) { Text(themeBodyFont).tag(themeBodyFont) }
                }
                Stepper("Size: \(themeFontSize) pt", value: $themeFontSize, in: 8...36)
                Stepper("Line spacing: \(themeLineSpacing) pt", value: $themeLineSpacing, in: 0...16)
                Picker("Text width", selection: $themeTextWidth) {
                    Text("Whole editor").tag(0)
                    ForEach([60, 70, 80, 90, 100, 120], id: \.self) { Text("\($0) columns").tag($0) }
                    if ![0, 60, 70, 80, 90, 100, 120].contains(themeTextWidth) { Text("\(themeTextWidth) columns").tag(themeTextWidth) }
                }
                Stepper("Headings grow by \(themeHeadingStep) pt a level", value: $themeHeadingStep, in: 0...8)
            } footer: {
                Text("Tags and tables line up in columns, so Font should be monospaced. With a body font, prose uses it while tables, code, dates, tags and drawers keep Font.")
                    .settingsFooter()
            }
            Section {
                LabeledContent("Colors") {
                    HStack {
                        Button("Edit in config.toml") { editConfig() }
                        Button("Show Default Theme") {
                            openWindow(id: "main")
                            commands.jump(path: UserConfig.directory.appendingPathComponent("default-theme.toml").path, offset: 0)
                        }
                    }
                }
            } footer: {
                Text("Set colors under [theme] (both appearances), [theme.light] or [theme.dark] in config.toml, and TODO keyword colors under [theme.todo]. default-theme.toml lists every color with the default theme's values.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(height: 620)
    }

    private var agenda: some View {
        Form {
            Section {
                Stepper("Agenda shows \(agendaSpan) days", value: $agendaSpan, in: 1...366)
                Stepper(agendaStartOffset == 0 ? "Agenda starts today" : "Agenda starts \(-agendaStartOffset) days before today", value: $agendaStartOffset, in: -14...0)
                Toggle("Include files in subfolders", isOn: $agendaSubfolders)
                Toggle("Show days without entries", isOn: $agendaShowAllDates)
                Toggle("Habits only today", isOn: $habitsOnlyForToday)
                Picker("Blocked entries", selection: $agendaDimBlockedTasks) {
                    Text("Dimmed").tag("t")
                    Text("Hidden").tag("invisible")
                    Text("Shown as usual").tag("nil")
                }
            }
            Section {
                Toggle("Show events from Calendar", isOn: $calendarEvents)
                    .disabled(!ProAccess.shared.isUnlocked && !calendarEvents)
                    .help(ProAccess.shared.isUnlocked ? "" : "Needs orgstar+")
                if calendarEvents {
                    choices(calendars, empty: CalendarEvents.isAuthorized ? "No calendars." : "Allow orgstar to read your calendars in System Settings ▸ Privacy & Security ▸ Calendars.", setting: $calendarEventCalendars)
                }
            } footer: {
                Text("Events show in the agenda; double-click one to open it in Calendar, or choose Edit Event… in its context menu. New calendars show while every calendar is checked.")
                    .settingsFooter()
            }
            .task(id: calendarEvents) {
                let allowed = calendarEvents ? await CalendarAccess.events.requestAccess() : false
                calendars = allowed ? CalendarAccess.events.calendars() : []
            }
            Section {
                Toggle("Show reminders from Reminders", isOn: $agendaReminders)
                    .disabled(!ProAccess.shared.isUnlocked && !agendaReminders)
                    .help(ProAccess.shared.isUnlocked ? "" : "Needs orgstar+")
                if agendaReminders {
                    choices(reminderLists, empty: ReminderLists.isAuthorized ? "No lists." : "Allow orgstar to read your reminders in System Settings ▸ Privacy & Security ▸ Reminders.", setting: $agendaReminderLists)
                }
            } footer: {
                Text("Incomplete reminders with a due date show in the agenda read-only, overdue ones under today; double-click one to open it in Reminders.")
                    .settingsFooter()
            }
            .task(id: agendaReminders) {
                let allowed = agendaReminders ? await CalendarAccess.reminders.requestAccess() : false
                reminderLists = allowed ? CalendarAccess.reminders.lists() : []
            }
            Section {
                Toggle("Notify before timed agenda entries", isOn: $reminders)
                Stepper("\(reminderLead) minutes before", value: $reminderLead, in: 0...120)
                    .disabled(!reminders)
            } footer: {
                Text("An entry's APPT_WARNTIME property overrides the lead time.")
                    .settingsFooter()
            }
            Section {
                Toggle("Ask what to do with idle time while clocked in", isOn: Binding {
                    clockIdleTime > 0
                } set: { on in
                    clockIdleTime = on ? 15 : 0
                })
                Stepper("After \(max(clockIdleTime, 1)) minutes without keyboard or mouse input", value: $clockIdleTime, in: 1...240)
                    .disabled(clockIdleTime == 0)
                Stepper("Remember \(clockHistoryLength) recently clocked entries", value: $clockHistoryLength, in: 1...35)
            } footer: {
                Text("org-clock-idle-time and org-clock-history-length. Org ▸ Clock lists the recent entries.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }

    /// A toggle per calendar or reminder list, with its color; `empty` when there are none.
    @ViewBuilder
    private func choices(_ calendars: [(id: String, title: String, color: RGBA?)], empty: LocalizedStringKey, setting: Binding<String>) -> some View {
        if calendars.isEmpty {
            Text(empty)
                .foregroundStyle(.secondary)
        }
        ForEach(calendars, id: \.id) { calendar in
            Toggle(isOn: chosen(calendar, among: calendars, setting: setting)) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(calendar.color.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha) } ?? .secondary)
                        .frame(width: 8, height: 8)
                    Text(calendar.title)
                }
            }
        }
    }

    /// `calendar-event-calendars` and `agenda-reminder-lists`: empty for every calendar or
    /// list, else the titles checked.
    private func chosen(
        _ calendar: (id: String, title: String, color: RGBA?), among calendars: [(id: String, title: String, color: RGBA?)], setting: Binding<String>
    ) -> Binding<Bool> {
        let chosen = setting.wrappedValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Binding {
            CalendarEvents.chooses(id: calendar.id, title: calendar.title, chosen: chosen)
        } set: { on in
            var titles = calendars.map(\.title).filter { title in
                chosen.isEmpty || chosen.contains(title) || chosen.contains(calendars.first { $0.title == title }?.id ?? "")
            }
            titles.removeAll { $0 == calendar.title }
            if on { titles.append(calendar.title) }
            // An empty list means every calendar; turning events off hides them all.
            guard !titles.isEmpty else { return }
            setting.wrappedValue = Set(titles) == Set(calendars.map(\.title)) ? "" : titles.joined(separator: ", ")
        }
    }

    private var capture: some View {
        Form {
            Section {
                Toggle("⌃⌥Space opens Capture from any app", isOn: $globalCapture)
            } footer: {
                Text("Templates go in \(CaptureTemplates.userFile.path).")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(height: 160)
    }
}

extension Text {
    func settingsFooter() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
