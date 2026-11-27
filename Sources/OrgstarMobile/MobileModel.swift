#if os(iOS)
import Foundation
import Observation
import OrgApp
import OrgCore
import OrgIndex
import OrgPresentation
import OrgWatchData
import OrgWorkspace
import UIKit
import UserNotifications
import WidgetKit

/// The app's models, and the settings from the configuration folder: a folder you choose
/// (a synced copy of the Mac's `~/.config/orgstar`) with `config.toml` and `capture.toml`.
@MainActor
@Observable
final class MobileModel {
    /// One per process: Shortcuts runs the capture action without a window.
    static let shared = MobileModel()

    let workspace: WorkspaceModel?
    let failure: String?
    let session = DocumentSession()
    /// The open files' editors, shared by every scene's panes.
    let editors = MobileEditorStore()
    let agenda: AgendaModel?
    let scheduler = ReminderScheduler(center: SystemReminderCenter())
    let clock = ClockModel()
    let clockPrompts = ClockPrompter()
    let spotlight = SpotlightIndexer()
    /// Captures from the share extension; nil without the app group.
    let inbox = CaptureInbox()
    private(set) var configFolder: URL?
    private(set) var configProblems: [String] = []
    /// An entry to show, from a tapped reminder.
    var openRequest: ReaderRoute?
    /// Agenda days to show, from a followed timestamp: the first (a `Days` number) and how many.
    var agendaRequest: AgendaDays?
    /// A capture to show, from the agenda or the capture control.
    var captureRequest: CaptureRequest?
    /// Folders shows its folder picker, from File ▸ Add Folder… in the menu bar.
    var addingFolder = false
    /// The flashcard review shows, from the agenda, the menu bar, a command or the widget.
    var reviewRequested = false
    /// Calendar's events for the agenda, with `calendar-events`.
    let calendarEvents = CalendarEvents()
    /// Captures the watch sent, for the root view to pick up from the inbox.
    var watchCaptures = 0
    /// Reminders for the agenda, with `agenda-reminders`.
    let reminderLists = ReminderLists()
    /// The file and caret of the editor on screen, advertised for Handoff.
    @ObservationIgnored let handoff = HandoffAdvertiser()
    /// Folders synced through Working Copy.
    let workingCopy = WorkingCopySync()
    /// The file of the editor on screen; nil when none is.
    @ObservationIgnored var handoffPath: String? {
        didSet { if handoffPath != oldValue { handoff.changed() } }
    }

    struct AgendaDays: Equatable {
        let start: Int
        let count: Int
    }
    /// Bumped when settings apply, so views that read them update.
    private(set) var settingsVersion = 0
    /// The `keymap` preset with the folder's `keymap.toml` on it, for a hardware keyboard, and
    /// whether it is Doom's modal one.
    private(set) var keymap = KeymapPreset.emacs.keymap
    private(set) var modalKeys = false
    /// The theme from `config.toml` and its theme file, with the type settings.
    private(set) var theme = ThemeSpec.default
    /// `show-markup`, toggled in the editor; the folder's value applies when it changes.
    var showMarkup = false
    /// `org-stored-links`, most recent first; kept while the app runs, as in Emacs.
    var storedLinks: [StoredLink] = []
    @ObservationIgnored private var configShowMarkup: Bool?
    /// Whether orgstar+ was locked at the last widget update; nil before the first.
    @ObservationIgnored private var widgetsLocked: Bool?
    @ObservationIgnored private var presenter: FolderPresenter?
    @ObservationIgnored private var sizeObserver: NSObjectProtocol?

    private init() {
        // Development: `ORGSTAR_CONFIG_DIR` stands in for a chosen folder.
        let folder = ConfigFolder.resolve() ?? ProcessInfo.processInfo.environment["ORGSTAR_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        UserConfig.directoryOverride = folder
        let (problems, colors) = Self.readConfig(folder)
        let settings = OrgPreferences.orgSettings()
        // `org-sbe` in table formulas runs blocks, so it needs Babel as source blocks do.
        TableBlocks.allowed = { ProAccess.isUnlockedNow }
        do {
            let workspace = try WorkspaceModel(directory: WorkspaceModel.defaultDirectory, settings: .with(todoKeywords: settings))
            // Recently Deleted where the folder's provider keeps one (iCloud Drive); otherwise gone.
            workspace.trasher = { url in
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { try FileManager.default.removeItem(at: url) }
            }
            self.workspace = workspace
            agenda = AgendaModel(workspace: workspace)
            failure = nil
        } catch {
            workspace = nil
            agenda = nil
            failure = error.localizedDescription
        }
        configFolder = folder
        configProblems = problems
        applySettings(colors)
        shareTemplates()
        watchConfig()
        // `org-clock-out-when-done`, and the reminder when the Effort runs out.
        clock.notifications = SystemReminderCenter()
        handoff.place = { [weak self] in
            guard let self, let path = self.handoffPath, let workspace = self.workspace else { return nil }
            return self.session.handoffPlace(path, roots: workspace.rootPaths)
        }
        session.textChanged = { [weak self] path in
            guard let self else { return }
            _ = self.clock.textChanged(path, self.session)
        }
        // Shortcuts' capture can run without a window; the window's view asks and shows messages.
        session.hooks = UserHookHost(trust: TrustStore(), ask: nil, report: { _ in },
                                     workspace: workspace.map { UserCommandWorkspace(workspace: $0, clock: clock) })
        // A new Dynamic Type size restyles editors and the reader.
        sizeObserver = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsVersion += 1 }
        }
    }

    /// Chooses the configuration folder, or with nil stops using one; its settings apply now.
    func setConfigFolder(_ url: URL?) {
        var problem: String?
        if let url {
            ConfigFolder.set(url)
            problem = Self.createConfig(in: url)
        } else {
            ConfigFolder.clear()
            // What the folder set no longer applies.
            for setting in UserConfig.settings { UserDefaults.standard.removeObject(forKey: setting.defaultsKey) }
            for width in KeyBarLayout.Width.allCases { KeyBarLayout.store(nil, width, in: .standard) }
        }
        configFolder = url
        _ = reloadConfig(after: problem)
        watchConfig()
    }

    func reloadConfig() {
        let interval = Perf.begin("config.reload")
        defer { interval.end() }
        UserConfig.directoryOverride = configFolder
        let (problems, colors) = Self.readConfig(configFolder)
        configProblems = problems
        applySettings(colors)
        shareTemplates()
    }

    private func applySettings(_ colors: ThemeSpec) {
        theme = OrgPreferences.theme(colors)
        let markup = OrgPreferences.showMarkup()
        if markup != configShowMarkup {
            configShowMarkup = markup
            showMarkup = markup
        }
        let preset = KeymapPreset(rawValue: UserDefaults.standard.string(forKey: "keymap") ?? "") ?? .emacs
        let loaded = KeymapLoader.load(preset, userFile: UserConfig.file("keymap.toml"))
        keymap = loaded.keymap
        modalKeys = preset.isModal
        configProblems += loaded.problems.map { "keymap.toml: " + $0 }
        configProblems += MacroFile.load().map { "\(NamedMacros.fileName): " + $0 }
        configProblems += configFolder.map { UserCommandFile.load(folder: $0, read: Self.read) } ?? UserCommandFile.load(folder: UserConfig.directory)
        SnippetLibrary.shared.reload(from: UserConfig.file(Snippets.fileName), read: configFolder == nil ? { try? String(contentsOf: $0, encoding: .utf8) } : Self.read)
        configProblems += SnippetLibrary.shared.problems
        configProblems += KeyBar.problems()
        let settings = OrgPreferences.orgSettings()
        session.defaults = settings
        session.options = OrgPreferences.options()
        session.encryptsTaggedEntries = OrgPreferences.cryptBeforeSave()
        session.cryptTag = OrgPreferences.cryptTag()
        session.options.snippets = SnippetLibrary.shared.snippets
        workspace?.settings = .with(todoKeywords: settings)
        if let agenda {
            agenda.span = OrgPreferences.agendaSpan()
            agenda.startOffset = OrgPreferences.agendaStartOffset()
            agenda.startOnWeekday = OrgPreferences.agendaStartOnWeekday()
            agenda.includeSubfolders = OrgPreferences.agendaSubfolders()
            agenda.excludeArchives = OrgPreferences.agendaExcludeArchives()
            agenda.agendaFiles = OrgPreferences.agendaFiles()
            agenda.options = OrgPreferences.agendaOptions(agenda.options)
            agenda.calendarEvents = ProAccess.shared.isUnlocked && OrgPreferences.calendarEvents() ? calendarEvents : nil
            agenda.calendarNames = OrgPreferences.calendarEventCalendars()
            agenda.reminderLists = ProAccess.shared.isUnlocked && OrgPreferences.agendaReminders() ? reminderLists : nil
            agenda.reminderListNames = OrgPreferences.agendaReminderLists()
        }
        settingsVersion += 1
    }

    /// The folder's `config.toml`, read in coordination with the app that syncs it.
    func configText() -> String? {
        configFolder.flatMap { Self.read($0.appendingPathComponent("config.toml")) }
    }

    /// Writes the folder's `config.toml` and applies it. False, with the reason first in
    /// `configProblems`, when the file can't be written or what it holds can't be read.
    @discardableResult
    func saveConfig(_ text: String) -> Bool {
        guard let configFolder else { return false }
        return reloadConfig(after: Self.updateConfig(in: configFolder) { _ in text })
    }

    /// Changes the folder's `config.toml`; returns the problem when it can't be read or written.
    private static func updateConfig(in folder: URL, _ change: (String) -> String) -> String? {
        do {
            try UserFile.update(folder.appendingPathComponent("config.toml"), coordinated: true, change)
            return nil
        } catch {
            return "config.toml wasn't changed: \(error.localizedDescription)"
        }
    }

    /// Applies the folder's settings, with the `problem` of the write before it first.
    private func reloadConfig(after problem: String?) -> Bool {
        reloadConfig()
        if let problem { configProblems.insert(problem, at: 0) }
        return problem == nil
    }

    /// Changes a setting from the app: in the folder's config.toml when there is a folder, as
    /// the Mac's Settings write it, else in this device's settings.
    func set(_ defaultsKey: String, to value: TOML.Value) {
        guard let setting = UserConfig.settings.first(where: { $0.defaultsKey == defaultsKey }) else { return }
        var problem: String?
        if let configFolder {
            problem = Self.updateConfig(in: configFolder) { UserConfig.setting($0, section: setting.section, key: setting.key, to: value) }
        } else {
            switch value {
            case .bool(let b): UserDefaults.standard.set(b, forKey: defaultsKey)
            case .string(let s): UserDefaults.standard.set(s, forKey: defaultsKey)
            case .integer(let i): UserDefaults.standard.set(i, forKey: defaultsKey)
            case .array: break
            }
        }
        _ = reloadConfig(after: problem)
    }

    /// Sets the key bar's buttons for `width`, or with nil its default, as `set` does.
    func setKeyBar(_ ids: [String]?, _ width: KeyBarLayout.Width) {
        var problem: String?
        if let configFolder {
            problem = Self.updateConfig(in: configFolder) { text in
                guard let ids else { return UserConfig.removingSetting(text, section: KeyBarLayout.table, key: width.rawValue) }
                return UserConfig.setting(text, section: KeyBarLayout.table, key: width.rawValue, to: .array(ids.map(TOML.Value.string)))
            }
        } else {
            KeyBarLayout.store(ids, width, in: .standard)
        }
        _ = reloadConfig(after: problem)
    }

    /// The capture templates, for the share extension to offer.
    private func shareTemplates() {
        try? inbox?.setTemplates(CaptureTemplates.load().templates.map { CaptureInbox.Template(key: $0.key, name: $0.name) })
    }

    /// Edits to the folder's files, synced from the Mac, apply as they arrive.
    private func watchConfig() {
        presenter?.stop()
        presenter = nil
        guard let configFolder else { return }
        let presenter = FolderPresenter(root: configFolder) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadConfig() }
        }
        presenter.start()
        self.presenter = presenter
    }

    /// Applies the folder's `config.toml` to the settings; returns its problems and the theme's
    /// colors.
    /// Writes `config.toml` with every setting at its default when the folder has none; returns
    /// the problem when it can't be written.
    private static func createConfig(in folder: URL) -> String? {
        let file = folder.appendingPathComponent("config.toml")
        var error: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: [], error: &error) { url in
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            do { try UserConfig.defaultTemplate.write(to: url, atomically: true, encoding: .utf8) } catch { failure = error }
        }
        return (error ?? failure).map { "config.toml wasn't created: \($0.localizedDescription)" }
    }

    private static func readConfig(_ folder: URL?) -> ([String], ThemeSpec) {
        let defaults = UserDefaults.standard
        guard let folder else {
            let (base, problems) = ThemeSpec.base(light: defaults.string(forKey: "themeLight"), dark: defaults.string(forKey: "themeDark"))
            return (problems, base)
        }
        guard let text = read(folder.appendingPathComponent("config.toml")) else {
            return (["No config.toml in \(folder.lastPathComponent); the defaults apply."], .default)
        }
        let problems = UserConfig.apply(text, to: defaults)
        guard let theme = UserConfig.theme(
            config: text, themeFile: defaults.string(forKey: "themeFile"),
            lightTheme: defaults.string(forKey: "themeLight"), darkTheme: defaults.string(forKey: "themeDark"), in: folder, read: read
        ) else {
            return (problems, .default)
        }
        return (problems + theme.problems, theme.theme)
    }

    /// A file of the folder, read in coordination with the app that syncs it.
    private static func read(_ file: URL) -> String? {
        var text: String?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: [], error: &error) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        return text
    }

    /// Notifications for the next week's timed entries, at most 64, as iOS allows.
    func updateReminders() async {
        let interval = Perf.begin("reminders.update")
        defer { interval.end() }
        guard let workspace else { return }
        guard OrgPreferences.reminders() else {
            await scheduler.clear()
            return
        }
        guard !workspace.files.isEmpty else { return }
        // The agenda's cache and options, so files it has read aren't read again.
        let agenda = AgendaModel(workspace: workspace, cache: self.agenda?.cache ?? AgendaSourceCache())
        agenda.includeSubfolders = OrgPreferences.agendaSubfolders()
        if let options = self.agenda?.options { agenda.options = options }
        let reminders = await agenda.reminders(open: session.openTexts, lead: OrgPreferences.reminderLead())
        await scheduler.reconcile(reminders)
    }

    /// The widgets' agenda: today and the next days in the app group's container, with the
    /// widgets reloaded when it changed; their habits and capture templates; and the icon's
    /// overdue badge.
    func updateWidgets() async {
        let interval = Perf.begin("widgets.update")
        defer { interval.end() }
        guard let workspace else { return }
        let days = AgendaModel(workspace: workspace, cache: agenda?.cache ?? AgendaSourceCache())
        days.mode = .agenda(span: AgendaSnapshot.dayCount, startOffset: 0)
        days.startOnWeekday = nil
        days.hiddenFolders = HiddenFolders.shared.all
        if let agenda {
            days.includeSubfolders = agenda.includeSubfolders
            days.excludeArchives = agenda.excludeArchives
            days.options = agenda.options
            days.options.logMode = false
            days.calendarEvents = agenda.calendarEvents
            days.calendarNames = agenda.calendarNames
            days.reminderLists = agenda.reminderLists
            days.reminderListNames = agenda.reminderListNames
        }
        await days.refresh(open: session.openTexts)
        let groups = days.groups()
        let locked = !ProAccess.shared.isUnlocked
        let wasLocked = widgetsLocked
        widgetsLocked = locked
        guard !locked else {
            // Widgets read the flag and show that they need Pro.
            WatchLink.shared.send(.locked(generated: Date()))
            await updateBadge(OverdueBadge.counts(groups, today: days.today, days: AgendaSnapshot.dayCount))
            if AgendaSnapshot.reloadsWidgets(locked: true, wasLocked: wasLocked, snapshotChanged: false) { WidgetCenter.shared.reloadAllTimelines() }
            return
        }
        let cards = await FlashcardReview.cards(workspace: workspace, session: session)
        var watch = WatchAgenda(groups: groups, today: days.today, clock: clock.running, lastClocked: clock.history.first?.title, generated: Date())
        watch.cards = WatchAgenda.Card.review(Flashcards.due(cards, at: Date()))
        WatchLink.shared.send(watch)
        if (try? FlashcardSnapshot(cards: cards.map(\.card)).write()) == true { WidgetCenter.shared.reloadTimelines(ofKind: "sh.krz.orgstar.flashcards") }
        await updateBadge(OverdueBadge.counts(groups, today: days.today, days: AgendaSnapshot.dayCount))
        if (try? HabitSnapshot(habits: await days.habits(open: session.openTexts), theme: theme).write()) == true { WidgetCenter.shared.reloadTimelines(ofKind: "sh.krz.orgstar.habits") }
        _ = try? TemplateList(templates: CaptureTemplates.load().templates.map { .init(key: $0.key, name: $0.name) }).write()
        guard let file = AgendaSnapshot.file() else { return }
        let snapshot = AgendaSnapshot(groups: groups, today: days.today, theme: theme, generated: Date())
        let changed = (try? snapshot.write(to: file)) == true
        if AgendaSnapshot.reloadsWidgets(locked: false, wasLocked: wasLocked, snapshotChanged: changed) { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Today's count on the icon, and each later day's set for its midnight by a notification
    /// that only changes the badge.
    private func updateBadge(_ counts: [Int]) async {
        let center = UNUserNotificationCenter.current()
        // Onboarding asks first.
        guard await badgesEnabled(asking: UserDefaults.standard.bool(forKey: OnboardingScreen.doneKey)) else { return }
        try? await center.setBadgeCount(counts.first ?? 0)
        center.removePendingNotificationRequests(withIdentifiers: (1..<AgendaSnapshot.dayCount).map(Self.badgeID))
        let today = Calendar.current.startOfDay(for: Date())
        for (offset, count) in counts.enumerated().dropFirst() {
            guard let midnight = Calendar.current.date(byAdding: .day, value: offset, to: today) else { continue }
            let content = UNMutableNotificationContent()
            content.badge = NSNumber(value: count)
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: midnight)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.badgeID(offset), content: content, trigger: trigger))
        }
    }

    static func badgeID(_ offset: Int) -> String { "badge.\(offset)" }

    /// Whether iOS shows the icon's badge. Asking adds badges to the app's notification
    /// settings, which an earlier grant without them leaves out; iOS prompts only the first time.
    func badgesEnabled(asking: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.badgeSetting == .enabled { return true }
        guard asking, settings.authorizationStatus != .denied else { return false }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return await center.notificationSettings().badgeSetting == .enabled
    }
}
#endif
