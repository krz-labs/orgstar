#if os(iOS)
import CoreSpotlight
import OrgApp
import OrgCore
import OrgMathJax
import SwiftUI
import UserNotifications

/// Orgstar on iPhone and iPad: the agenda, capture, and the folders they read.
@main
struct OrgstarMobileApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = MobileModel.shared
    /// The app's phase: in the background only when every window is.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PDFExport.mathJaxURL = OrgMathJax.script
        RevealExport.library = OrgMathJax.reveal
        RevealExport.mathJax = OrgMathJax.script
        DiagramBlocks.vizURL = OrgMathJax.viz
        DiagramBlocks.mermaidURL = OrgMathJax.mermaid
        PythonBlocks.folder = OrgMathJax.pyodide
        // Debug builds, and runs from Xcode, whose scheme sets ORGSTAR_PERF.
        #if DEBUG
        Perf.watchMainThread()
        #else
        if ProcessInfo.processInfo.environment["ORGSTAR_PERF"] != nil { Perf.watchMainThread() }
        #endif
        LiveClock.install()
        ProStore.shared.start()
        ClockTask.titleKey = ClockTitleKey.loadOrCreate()
        // Read before the app becomes active and clears it.
        _ = UnsavedHeldFiles.atLaunch
        // Early, so that the watch's actions are taken when iOS wakes the app for them.
        WatchLink.shared.activate(MobileModel.shared)
    }

    var body: some Scene {
        WindowGroup {
            if let workspace = model.workspace, let agenda = model.agenda {
                RootView(model: model, workspace: workspace, agenda: agenda)
                    .environment(model)
                    .environment(model.clock)
                    .onAppear { delegate.model = model }
            } else {
                ContentUnavailableView("Can't Open the Index", systemImage: "exclamationmark.triangle", description: Text(model.failure ?? ""))
            }
        }
        // For the clock's idle time: time working in another window isn't time away.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.clock.wentAway() }
        }
        .commands { AppMenus(model: model) }
    }
}

/// Reminders show while the app is open too, and open their entry when tapped.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var model: MobileModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // A midnight badge update shows nothing else.
        if notification.request.content.badge != nil { return [.badge] }
        // A countdown's end shows in the app's own message.
        if notification.request.identifier == "sh.krz.orgstar.org-timer" { return [] }
        return [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let path = info["path"] as? String, let offset = info["offset"] as? Int else { return }
        await MainActor.run { model?.openRequest = .offset(path, offset) }
    }
}

/// Files continued from another device, and what Working Copy's syncs come to.
private struct HandoffAndSync: ViewModifier {
    let model: MobileModel
    let open: (HandoffPlace) -> Void
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .onContinueUserActivity(HandoffPlace.activityType) { activity in
                if let place = HandoffPlace(userInfo: activity.userInfo) { open(place) }
            }
            .onChange(of: model.workingCopy.message) {
                guard let text = model.workingCopy.message else { return }
                model.workingCopy.message = nil
                message = text
            }
    }
}

/// A tab on iPhone, or a row of the sidebar on a regular-width iPad, which also lists search
/// and each added folder.
enum AppTab: Hashable { case agenda, search, folders, folder(String), settings }

/// The search screen, pushed from the Agenda and Folders tabs.
struct SearchRoute: Hashable {}

extension AppTab {
    /// The tab that shows this on iPhone: search is pushed from Agenda and Folders, and folders
    /// are listed in Folders.
    var inTabBar: AppTab {
        switch self {
        case .search: .agenda
        case .folder: .folders
        default: self
        }
    }
}

extension View {
    /// Readers pushed for `ReaderRoute`s; Markdown and other text files open in the editor.
    func readerDestination(workspace: WorkspaceModel, session: DocumentSession) -> some View {
        navigationDestination(for: ReaderRoute.self) { route in
            switch route {
            case .file(let path) where !DocumentSession.isOrgPath(path):
                EditorSplitScreen(path: path, offset: nil, workspace: workspace, session: session)
            case .offset(let path, let offset) where !DocumentSession.isOrgPath(path):
                EditorSplitScreen(path: path, offset: offset, workspace: workspace, session: session)
            case .heading(let location) where !DocumentSession.isOrgPath(location.path):
                EditorSplitScreen(path: location.path, offset: location.start, workspace: workspace, session: session)
            default:
                ReaderScreen(route: route, workspace: workspace, session: session)
            }
        }
        .navigationDestination(for: EditorRoute.self) { route in
            EditorSplitScreen(path: route.path, offset: route.offset, workspace: workspace, session: session)
        }
        .navigationDestination(for: SearchRoute.self) { _ in
            SearchScreen(workspace: workspace, session: session)
        }
    }
}

/// A share of files from the share extension.
struct SharedFiles: Identifiable {
    let id = UUID()
    let batch: URL
}

/// An org-protocol capture, or a plain one.
struct CaptureRequest: Identifiable {
    let id = UUID()
    var template: String?
    var properties: [String: String] = [:]
    /// An agenda day (a `Days` number) the entry is scheduled on.
    var day: Int?
    /// An org-roam capture, whose templates take the place of capture.toml's.
    var roam: RoamCapture?
}

extension CaptureRequest {
    /// An `org-protocol://capture` link's request.
    init?(link: String) {
        guard case .capture(let template, let properties)? = OrgProtocol.parse(link) else { return nil }
        self.init(template: template, properties: properties)
    }
}

struct RootView: View {
    let model: MobileModel
    let workspace: WorkspaceModel
    let agenda: AgendaModel
    @State private var capture: CaptureRequest?
    /// The share extension's link whose capture sheet is showing, with its request's id. The link
    /// stays in the inbox until the sheet is dismissed.
    @State private var shared: (link: CaptureInbox.Link, request: UUID)?
    /// Files from the share extension, waiting for the entry to attach them to.
    @State private var sharedFiles: SharedFiles?
    @State private var tab = AppTab.agenda
    @State private var agendaPath = NavigationPath()
    @State private var hour = 0
    @State private var showingClockReport = false
    @State private var showingBoard = false
    @State private var message: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(OnboardingScreen.doneKey) private var onboarded = false
    @State private var onboarding = false
    @State private var whatsNew: ReleaseNotes?

    private var session: DocumentSession { model.session }

    /// Reminders, widgets and Spotlight following the files. Its own view, so that edits redraw
    /// only it, not the tabs.
    private struct BackgroundWork: View {
        let model: MobileModel
        let workspace: WorkspaceModel
        let agenda: AgendaModel
        let active: Bool
        /// Notifications and badges ask for permission, which onboarding asks for first.
        let onboarded: Bool
        let hour: Int

        private var session: DocumentSession { model.session }

        var body: some View {
            Color.clear
                // Reminders follow the files, the settings, coming back to the app and the hour.
                .task(id: ReminderKey(hidden: HiddenFolders.shared.all, files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion,
                                      settings: model.settingsVersion, active: active, onboarded: onboarded, hour: hour)) {
                    guard active, onboarded else { return }
                    try? await Task.sleep(for: .seconds(1))
                    // After the agenda's refresh, whose parsed files these share.
                    while agenda.isComputing, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                    guard !Task.isCancelled else { return }
                    await model.updateReminders()
                    await model.updateWidgets()
                }
                // Spotlight follows the files and saved edits.
                .task(id: SpotlightKey(files: workspace.files.count, changed: workspace.changedFile?.version, saved: session.dirtyPaths.count)) {
                    await model.spotlight.update(workspace.files)
                }
        }
    }

    private struct SpotlightKey: Equatable {
        var files: Int
        var changed: Int?
        var saved: Int
    }

    private struct ReminderKey: Equatable {
        /// The widgets leave out hidden folders.
        var hidden: Set<String>
        var files: Int
        var changed: Int?
        var edits: Int
        var settings: Int
        var active: Bool
        var onboarded: Bool
        var hour: Int
    }

    /// Tabs on iPhone and in a narrow window; a sidebar beside the content on a wider iPad.
    private var tabs: some View {
        TabView(selection: Binding { tab.inTabBar } set: { tab = $0 }) {
            Tab("Agenda", systemImage: "calendar", value: .agenda) { agendaStack }
            Tab("Folders", systemImage: "folder", value: .folders) { foldersStack }
            Tab("Settings", systemImage: "gearshape", value: .settings) { settingsStack }
        }
        .clockAccessory(model.clock, perform: clock)
    }

    private var split: some View {
        NavigationSplitView {
            AppSidebar(workspace: workspace, selection: $tab)
        } detail: {
            Group {
                switch tab {
                case .agenda: agendaStack
                case .search:
                    NavigationStack {
                        SearchScreen(workspace: workspace, session: session)
                            .toolbar { captureButton }
                            .readerDestination(workspace: workspace, session: session)
                    }
                case .folders: foldersStack
                case .folder(let root):
                    NavigationStack {
                        FolderPage(workspace: workspace, session: session, route: FolderRoute(root: root, folder: ""))
                            .toolbar { searchButton; captureButton }
                            .readerDestination(workspace: workspace, session: session)
                            .navigationDestination(for: FolderRoute.self) { FolderPage(workspace: workspace, session: session, route: $0) }
                    }
                    .id(root)
                case .settings: settingsStack
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let running = model.clock.running {
                    ClockAccessory(running: running, clock: model.clock, perform: clock).padding(.vertical, 8).background(.bar)
                }
            }
        }
    }

    private var agendaStack: some View {
        NavigationStack(path: $agendaPath) {
            AgendaScreen(workspace: workspace, session: session, agenda: agenda, scheduler: model.scheduler)
                .equatable()
                .toolbar { searchButton; captureButton }
                .readerDestination(workspace: workspace, session: session)
        }
    }

    private var foldersStack: some View {
        NavigationStack {
            FoldersScreen(workspace: workspace, session: session)
                .toolbar { searchButton; captureButton }
                .readerDestination(workspace: workspace, session: session)
        }
    }

    private var settingsStack: some View {
        NavigationStack { SettingsScreen(model: model) }
    }

    var body: some View {
        // One view around both layouts, so that what follows runs once, not again when the
        // window's width class changes.
        ZStack {
            if sizeClass == .regular { split } else { tabs }
        }
        .tint(model.theme.accentColor)
        .focusedSceneValue(\.windowActions, WindowActions(
            show: show, capture: { capture = CaptureRequest() },
            addFolder: {
                tab = .folders
                model.addingFolder = true
            },
            board: { showingBoard = true }, clock: clock))
        .fullScreenCover(isPresented: $showingBoard) {
            BoardScreen(workspace: workspace, session: session) { showingBoard = false }
        }
        // A removed folder's row goes from the sidebar.
        .onChange(of: workspace.rootPaths) {
            if case .folder(let root) = tab, !workspace.rootPaths.contains(root) { tab = .folders }
        }
        // Until a folder is added there is nothing for the agenda to show.
        .onAppear {
            if workspace.rootPaths.isEmpty { tab = .folders }
            whatsNew = WhatsNew.pending(firstLaunch: !onboarded)
            // First launch only; a workspace from before onboarding existed skips it.
            guard !onboarded else { return }
            if workspace.rootPaths.isEmpty, ProcessInfo.processInfo.environment["ORGSTAR_ROOT"] == nil {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { onboarding = true }
            } else {
                onboarded = true
            }
        }
        .fullScreenCover(isPresented: $onboarding) {
            OnboardingScreen(model: model, workspace: workspace) {
                onboarding = false
                onboarded = true
                if !workspace.rootPaths.isEmpty { tab = .agenda }
            }
            .interactiveDismissDisabled()
        }
        .sheet(item: $whatsNew) { WhatsNewView(notes: $0) }
        .modifier(DecryptQuestion())
        .sheet(item: Bindable(ProAccess.shared).paywall) { ProSheet(feature: $0) }
        .onChange(of: ProAccess.shared.isUnlocked) {
            // Calendar and Reminders in the agenda, the widgets and the watch follow Pro.
            model.reloadConfig()
            Task { await model.updateWidgets() }
        }
        .sheet(item: Binding(get: { model.clockPrompts.pending }, set: { if $0 == nil { model.clockPrompts.answer(nil) } })) { pending in
            ClockPromptSheet(prompt: pending.prompt) { model.clockPrompts.answer($0) }
        }
        // At the top, where the keyboard can't hide it.
        .message($message, edge: .top)
        .sheet(isPresented: $showingClockReport) { ClockReportScreen(workspace: workspace) }
        .onChange(of: model.openRequest) {
            guard let route = model.openRequest else { return }
            model.openRequest = nil
            tab = .agenda
            agendaPath.append(route)
        }
        .onChange(of: model.agendaRequest) {
            guard let request = model.agendaRequest else { return }
            model.agendaRequest = nil
            agenda.mode = .agenda(span: request.count, startOffset: nil)
            agenda.start = request.start
            tab = .agenda
            agendaPath = NavigationPath()
        }
        .onChange(of: workspace.changedFile?.version) {
            // An open file takes in what changed on disk.
            if let path = workspace.changedFile?.path {
                session.fileChanged(path)
                // A clock started or stopped in Emacs or on another device.
                if path.hasSuffix(".org"), let text = model.clock.sync(session, paths: [path]) { message = text }
            }
        }
        // At launch and as folders load: open clocks in the agenda files.
        .task(id: workspace.files.count) {
            guard !workspace.files.isEmpty, let text = model.clock.sync(session, paths: workspace.agendaFilePaths()) else { return }
            message = text
        }
        // Initially too: the capture control may have launched the app.
        .onChange(of: model.captureRequest?.id, initial: true) {
            guard let request = model.captureRequest else { return }
            model.captureRequest = nil
            capture = request
        }

        // Another capture took the sheet from a shared one, which stays in the inbox for later.
        .onChange(of: capture?.id) { _, id in
            if let id, id != shared?.request { shared = nil }
        }
        .sheet(item: $capture, onDismiss: captureDismissed) { request in
            CaptureScreen(workspace: workspace, session: session, request: request)
        }
        .sheet(item: $sharedFiles) { shared in
            RefileSheet(targets: workspace.refileTargets(openPath: nil, document: nil, settings: RefileSettings(targets: [.init(files: .workspace, spec: .all)])),
                        title: "Attach to") { target in
                sharedFiles = nil
                if let target {
                    message = session.attach(AttachmentInbox.files(in: shared.batch), to: target.path, at: target.start ?? 0)
                } else {
                    message = "The shared files weren't attached"
                }
                AttachmentInbox()?.remove(shared.batch)
                takeShared()
            }
        }
        // After the first frame: removing a pending notification waits on the notification
        // service, which can take many seconds after the device starts.
        .task {
            await Task.yield()
            model.clock.remindAtEffort(session)
        }
        .task {
            TimerModel.shared.onDone = { message = $0 }
            if let lost = UnsavedHeldFiles.atLaunch { message = lost }
            takeShared()
            // Development: `ORGSTAR_ROOT` adds a folder at launch, as on the Mac.
            if let root = ProcessInfo.processInfo.environment["ORGSTAR_ROOT"] { try? await workspace.addRoot(URL(fileURLWithPath: root)) }
            // `ORGSTAR_PASTE_IMAGE`: paste takes this PNG from a pasteboard of the app's own.
            if let image = ProcessInfo.processInfo.environment["ORGSTAR_PASTE_IMAGE"], let data = try? Data(contentsOf: URL(fileURLWithPath: image)),
               let pasteboard = UIPasteboard(name: UIPasteboard.Name("orgstar-check"), create: true) {
                pasteboard.setData(data, forPasteboardType: "public.png")
                MobileEditor.pasteboard = pasteboard
            }
            workspace.startWatching()
            await workspace.refresh()
            model.workingCopy.appOpened(roots: workspace.rootPaths, session: session)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                hour += 1
            }
        }
        .background { BackgroundWork(model: model, workspace: workspace, agenda: agenda, active: scenePhase == .active, onboarded: onboarded, hour: hour) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let path = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { model.openRequest = .file(path) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Unsaved edits are written before the app may be stopped. A file held for its
            // passphrase stays in memory; its name is kept so that, if iOS ends the app
            // meanwhile, the next launch says its edits were lost.
            if phase == .background {
                for path in session.dirtyPaths { _ = session.save(path) }
                UnsavedHeldFiles.record(session.held.keys.filter(session.dirtyPaths.contains).sorted())
            }
            if phase == .active { UnsavedHeldFiles.record([]) }
            // Files and settings synced while away; not every sync tool tells file presenters.
            guard phase == .active else { return }
            // iOS has no idle time: time away from the app while a clock ran stands in for it.
            if let since = model.clock.cameBack(idleMinutes: OrgPreferences.clockIdleTime()) {
                MobileClock.resolveIdle(since: since, model: model) { message = $0 }
            }
            takeShared()
            model.reloadConfig()
            model.handoff.update()
            model.workingCopy.appOpened(roots: workspace.rootPaths, session: session)
            Task { await workspace.refresh() }
        }
        .onOpenURL(perform: handle)
        .modifier(HandoffAndSync(model: model, open: continueHandoff, message: $message))
        // The Live Activity follows the clock, wherever it starts or stops.
        .task {
            LiveClock.publish(model.clock)
            await LiveClock.sync(model.clock.running)
        }
        .onChange(of: model.clock.running) {
            LiveClock.publish(model.clock)
            Task { await LiveClock.sync(model.clock.running) }
            Task { await model.updateWidgets() }
        }
        // A capture dictated on the watch, while the app is open.
        .onChange(of: model.watchCaptures) { takeShared() }
    }

    /// What the share extension left, one capture sheet at a time.
    private func takeShared() {
        showWaiting()
        if sharedFiles == nil, let batch = AttachmentInbox()?.batches().first { sharedFiles = SharedFiles(batch: batch) }
    }

    /// The inbox's oldest capture, unless a capture sheet is showing or being dismissed.
    private func showWaiting() {
        guard capture == nil, shared == nil, let inbox = model.inbox else { return }
        for link in inbox.links() {
            guard let request = CaptureRequest(link: link.text) else {
                inbox.remove(link)
                continue
            }
            shared = (link, request.id)
            capture = request
            return
        }
    }

    /// The shared capture was saved or discarded, so its link goes; then the next one shows.
    private func captureDismissed() {
        if let shared { model.inbox?.remove(shared.link) }
        shared = nil
        showWaiting()
    }

    /// A widget's or the Live Activity's link, or an org-protocol URL.
    private func handle(_ url: URL) {
        if let callback = WorkingCopy.callback(url) {
            model.workingCopy.finished(callback, workspace: workspace, session: session)
        } else if let link = AppLink(url: url) {
            open(link)
        } else if let request = CaptureRequest(link: url.absoluteString) {
            capture = request
        } else if case .storeLink(let link, let title)? = OrgProtocol.parse(url.absoluteString) {
            message = StoredLink.add(StoredLink(link: link, description: title), to: &model.storedLinks)
            UIPasteboard.general.string = link
        } else if let request = OrgProtocol.parse(url.absoluteString), ProAccess.shared.allows(.roam) {
            // org-roam-protocol's `roam-ref` and `roam-node`.
            var actions = RoamActions(session: session, roots: { workspace.rootPaths }, nodes: { try workspace.nodes(overlay: workspace.overlay(session.openDocuments)) },
                                      show: { message = $0 }, ask: { $1(nil) }, open: { path, offset in model.openRequest = .offset(path, offset) },
                                      insertLink: { _, _ in }, refresh: { Task { await workspace.refresh() } })
            actions.capture = { capture = CaptureRequest(roam: $0) }
            actions.follow(request)
        } else if url.scheme == "org-protocol" {
            message = "orgstar handles org-protocol capture and store-link"
        }
    }

    /// A file continued from another device, in the editor at the caret's heading or line there.
    private func continueHandoff(_ place: HandoffPlace) {
        let match = place.resolve(roots: workspace.rootPaths)
        guard case .file(let path) = match else { return message = place.problem(match) }
        let offset = session.text(of: path).map { place.offset(in: $0, settings: session.defaults) } ?? 0
        tab = .agenda
        agendaPath.append(EditorRoute(path: path, offset: offset))
    }

    /// A tab or sidebar row; on iPhone, search is pushed on the agenda.
    private func show(_ destination: AppTab) {
        if destination == .search, sizeClass != .regular {
            tab = .agenda
            agendaPath.append(SearchRoute())
        } else {
            tab = destination
        }
    }

    /// A widget's or the Live Activity's link.
    private func open(_ link: AppLink) {
        switch link {
        case .agenda:
            tab = .agenda
            agendaPath = NavigationPath()
        case .entry(let path, let offset):
            model.openRequest = .offset(path, offset)
        case .clock:
            clock("app.clock.goto")
        case .capture(let template):
            capture = CaptureRequest(template: template)
        }
    }

    private func clock(_ id: String) {
        if id == "app.clock.report" {
            showingClockReport = true
        } else {
            _ = MobileClock.run(id, model: model, workspace: workspace) { message = $0 }
        }
    }

    private var searchButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            NavigationLink(value: SearchRoute()) { Label("Search", systemImage: "magnifyingglass") }
        }
    }

    private var captureButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Capture", systemImage: "square.and.pencil") { capture = CaptureRequest() }
        }
    }
}
#else
/// The iOS app has nothing to run elsewhere.
@main
enum OrgstarMobileUnavailable {
    static func main() { print("orgstar for iOS runs on iPhone and iPad.") }
}
#endif
