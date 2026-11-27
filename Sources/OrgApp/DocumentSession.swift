import Foundation
import Observation
import OrgCore
import OrgDocument
import OrgIndex
import OrgPresentation

/// A heading, or a whole file, a subtree can be refiled to.
public struct RefileTarget: Sendable, Hashable {
    /// `file.org/Parent/Heading`, as the prompt lists it.
    public let label: String
    public let path: String
    /// Start of the heading when the file had `contentHash`; nil refiles to the end of the file.
    public let start: Int?
    public let title: String
    public let level: Int
    public let contentHash: String

    public init(label: String, path: String, start: Int?, title: String, level: Int, contentHash: String) {
        self.label = label
        self.path = path
        self.start = start
        self.title = title
        self.level = level
        self.contentHash = contentHash
    }

    /// The heading's start in `state`: its indexed offset if the text is what was indexed,
    /// else the first heading with the same title and level. Nil for the end of the file.
    func locate(in state: DocumentState) -> Int?? {
        guard let start else { return .some(nil) }
        if !state.isDirty, FileRecord.hash(state.mergeBase) == contentHash { return .some(start) }
        let entry = Presentation.outline(state.tree).first { $0.title == title && $0.level == level }
        return entry.map { .some($0.start) }
    }
}

public enum SaveMode: String, Sendable, CaseIterable {
    /// Save shortly after typing stops.
    case automatic
    /// Save only on ⌘S.
    case explicit
}

/// The files open in the app, as Emacs's buffers: each keeps its text, caret, undo and
/// unsaved edits while another is shown. Buffers show in panes (`EditorPane`), one or more
/// per window; `focused` is the pane commands and menus act on, and the properties below
/// that describe one buffer (`path`, `outline`, `isDirty`, `conflict`, `revealRequest`) are
/// its. The view layer attaches an editor to each buffer and, per pane, follows the pane's
/// `path` and `revealRequest`.
@MainActor
@Observable
public final class DocumentSession {
    /// Where buffers show. There is always at least one.
    public private(set) var panes: [EditorPane]
    /// The pane with focus: what `open`, `reveal`, saving and the forwarders below act on.
    public var focused: EditorPane
    /// The focused pane's file.
    public var path: String? { focused.path }
    /// The focused pane's buffer state. Not observed: it changes on every keystroke; views
    /// follow `path`, `isDirty` and `outline`.
    public var document: DocumentState? { current?.buffer.document }
    public var outline: [OutlineEntry] { focused.outline }
    /// Bumped when the focused buffer settles after edits, and when a file opens: views that
    /// read `document` follow this.
    public var editVersion: Int { focused.editVersion }
    public var isDirty: Bool { focused.isDirty }
    /// The file isn't UTF-8, so it can't be edited or saved.
    public var isReadOnly: Bool { focused.isReadOnly }
    /// Set while the focused buffer and the file on disk conflict; says how to resolve it.
    public var conflict: String? { focused.conflict }
    /// Bumped to ask the focused pane's editor to reveal an offset.
    public var revealRequest: (offset: Int, id: Int)? { focused.revealRequest }
    /// Open files, in the order buffers were opened (each after the one focused then).
    public private(set) var openPaths: [String] = []
    /// Open files with unsaved edits.
    public private(set) var dirtyPaths: Set<String> = []
    public var lastError: String? { didSet { lastErrorTitle = nil } }
    /// What failed, as the title of the alert that shows `lastError`; nil when `lastError` was
    /// set without one.
    public private(set) var lastErrorTitle: String?

    /// Sets `lastError` to `message` under `title`, which says what failed ("Couldn't Save File").
    public func showError(_ title: String, _ message: String) {
        lastError = message
        lastErrorTitle = title
    }

    public var saveMode: SaveMode = .automatic
    public var autosaveDelay: Duration = .seconds(1)
    /// Org options for commands the session runs (refile, archive).
    public var options: EditingOptions = .org
    /// Called with a file's path after its text changed through the session, typed or not.
    @ObservationIgnored public var textChanged: ((String) -> Void)?
    /// Called with a file's path each time a save wrote it to disk.
    @ObservationIgnored public var fileWritten: ((String) -> Void)?
    /// TODO keywords and priorities for files without their own settings.
    public var defaults: OrgSettings = .default

    /// A buffer for `bytes` read from `path`, with the keywords of the setup files it names.
    func loaded(_ bytes: [UInt8], path: String) -> DocumentState {
        DocumentState(bytes: bytes, defaults: defaults.resolvingSetupFiles(in: SourceText(bytes: bytes).text, path: path, read: readText))
    }

    /// A file's text, for setup files.
    func readText(_ file: String) -> String? {
        (try? fileSystem.read(URL(fileURLWithPath: file))).flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// C-c C-c on a keyword line: the open file's setup files read again (`org-mode-restart`).
    public func refreshSetup() {
        guard let entry = current else { return }
        resolveSetup(entry)
        for pane in panes(showing: entry.path) {
            refresh(pane)
            pane.editVersion += 1
        }
    }

    /// The entry's setup files read again, as its text names them now.
    private func resolveSetup(_ entry: Entry) {
        let settings = defaults.resolvingSetupFiles(in: entry.buffer.document.text, path: entry.path, read: readText)
        if settings != entry.buffer.document.defaults { entry.buffer.update { $0.setDefaults(settings) } }
    }

    /// One open file.
    @MainActor
    final class Entry {
        let path: String
        var buffer: DocumentBuffer
        var conflict: String?
        var autosave: Task<Void, Never>?

        init(path: String, buffer: DocumentBuffer) {
            self.path = path
            self.buffer = buffer
        }
    }

    /// Files and recovery through `crypt`, and as they are on disk.
    private let fileSystem: FileSystem
    private let recovery: RecoveryStore
    private let diskFileSystem: FileSystem
    private let diskRecovery: RecoveryStore
    /// Passphrases and encrypted entries of the open files.
    @ObservationIgnored public let crypt = CryptVault()
    @ObservationIgnored private var entries: [Entry] = []
    /// The focused pane's buffer.
    private var current: Entry? { focused.path.flatMap(entry) }
    /// Paths, most recently shown first, across every pane.
    @ObservationIgnored private var history: [String] = []
    @ObservationIgnored private var outlineUpdates: [String: Task<Void, Never>] = [:]
    private var requestID = 0

    public init(
        fileSystem: FileSystem = CoordinatedFileSystem(),
        recovery: RecoveryStore = FileRecoveryStore(directory: WorkspaceModel.defaultDirectory.appendingPathComponent("Recovery"))
    ) {
        diskFileSystem = fileSystem
        diskRecovery = recovery
        self.fileSystem = CryptFileSystem(base: fileSystem, vault: crypt)
        self.recovery = CryptRecoveryStore(base: recovery, vault: crypt)
        let pane = EditorPane()
        panes = [pane]
        focused = pane
    }

    // MARK: - Encryption

    /// `org-crypt-use-before-save-magic`: entries with `cryptTag` are encrypted on every save.
    public var encryptsTaggedEntries: Bool {
        get { crypt.encryptsTaggedEntries }
        set { crypt.encryptsTaggedEntries = newValue }
    }

    /// `org-crypt-tag-matcher`.
    public var cryptTag: String {
        get { crypt.tag }
        set { crypt.tag = newValue }
    }

    /// Open files that aren't saved until a passphrase is given: tagged entries that would be
    /// written unencrypted, or an encrypted file without one. Other edits to them wait too.
    public private(set) var held: [String: CryptHold] = [:]
    /// Holds from saves that failed: a version on disk with tagged entries that can't be kept
    /// encrypted, or an entry the passphrase can't encrypt. Kept until a save succeeds.
    @ObservationIgnored private var failedHolds: [String: CryptHold] = [:]

    /// An encrypted file waiting for its passphrase to open, and the pane to show it in.
    public private(set) var unlockRequest: String?
    @ObservationIgnored private var unlockPane: EditorPane?

    /// Passphrases saved in the Keychain, used after Touch ID, Face ID or the device's password
    /// while the setting is on.
    @ObservationIgnored public var passphrases = CryptPassphrases.shared
    /// Files whose remembered passphrase is being asked for, and those where it was refused:
    /// the Keychain is asked once per file until the file closes or Encrypt is chosen.
    @ObservationIgnored private var askingKeychain: Set<String> = []
    @ObservationIgnored private var refusedKeychain: Set<String> = []

    public static func isEncryptedFile(_ path: String) -> Bool { CryptVault.isEncryptedFile(path) }

    /// An encrypted org file, which lists with the org files.
    public static func isEncryptedOrgFile(_ path: String) -> Bool { path.hasSuffix(".org.gpg") }

    /// Gives `passphrase` for `path`: an encrypted file opens with it, and a held file is saved.
    /// It must open the file, or the file's encrypted entries if it has any. A message when it
    /// doesn't.
    public func unlock(_ passphrase: String, for path: String) -> String? {
        if let entry = entry(path) {
            if let message = OrgCrypt.firstMessage(entry.buffer.document.text), !OrgCrypt.opens(message, passphrase: passphrase) {
                return String(localized: "Wrong passphrase")
            }
            // An encrypted file on disk keeps its passphrase: a passphrase given after Forget
            // must open it.
            if Self.isEncryptedFile(entry.path), let disk = try? diskFileSystem.read(URL(fileURLWithPath: entry.path)),
               !CryptVault.opens(disk, passphrase: passphrase) {
                return String(localized: "Wrong passphrase")
            }
            crypt.unlock(passphrase, for: entry.path)
            refusedKeychain.remove(entry.path)
            save(entry)
            return nil
        }
        guard Self.isEncryptedFile(path) else { return nil }
        let bytes: [UInt8]
        do {
            guard let read = try diskFileSystem.read(URL(fileURLWithPath: path)) else { return "\((path as NSString).lastPathComponent) no longer exists." }
            bytes = read
        } catch {
            return error.localizedDescription
        }
        guard CryptVault.opens(bytes, passphrase: passphrase) else { return String(localized: "Wrong passphrase") }
        crypt.unlock(passphrase, for: path)
        let pane = unlockPane.flatMap { pane in panes.contains { $0 === pane } ? pane : nil } ?? focused
        unlockRequest = nil
        unlockPane = nil
        open(path, in: pane)
        return nil
    }

    /// The encrypted file waiting for its passphrase stays closed.
    public func cancelUnlock() {
        if let unlockRequest { passphrases.endSession(for: unlockRequest) }
        unlockRequest = nil
        unlockPane = nil
    }

    /// A crypt command used `passphrase` for `path`: saves use it from now on, without asking.
    public func cryptUsed(_ passphrase: String, for path: String) {
        crypt.unlock(passphrase, for: path)
        refusedKeychain.remove(path)
    }

    /// The entry holding `plaintext` in `path`'s buffer was decrypted from `message`.
    public func cryptDecrypted(message: String, plaintext: String, for path: String) {
        crypt.remember(message: message, plaintext: plaintext, for: path)
    }

    /// Forget Encryption Passphrase: the passphrase leaves the Keychain and the session.
    public func forgetPassphrase(for path: String) {
        passphrases.forget(path)
        crypt.forgetPassphrase(for: path)
    }

    /// `title`, of the heading at `heading` in `path`, as it may be shown and kept outside
    /// the editor (the clock's file, widgets, the Live Activity, the menu bar): a placeholder
    /// for a heading of an encrypted file or one inside an entry that's encrypted on disk.
    public func shareableTitle(_ title: String, path: String, heading: Int) -> String {
        let hidden = Self.isEncryptedFile(path)
            || (crypt.sealsEntries(for: path) && document(of: path).map { OrgCrypt.isInTaggedText($0.text, at: heading, tag: cryptTag) } == true)
        return hidden ? String(localized: "Encrypted entry") : title
    }

    /// Why a copy of the buffer can't be kept, with what to do; the buffer's notice shows.
    private func keepFailure(_ hold: CryptHold) -> String {
        if let current { _ = updateHold(current) }
        return hold.localizedDescription + ". " + String(localized: "Give the passphrase with Encrypt… first, so that a copy of your edits can be kept encrypted.")
    }

    /// Whether `path`'s buffer is held back from disk now.
    private func updateHold(_ entry: Entry) -> CryptHold? {
        let dirty = entry.buffer.document.isDirty
        let hold = dirty ? crypt.hold(entry.buffer.document.text, for: entry.path) ?? failedHolds[entry.path] : nil
        if held[entry.path] != hold { held[entry.path] = hold }
        return hold
    }

    /// Asks the Keychain for `entry`'s passphrase, once, and saves with it.
    private func askKeychain(_ entry: Entry) {
        let path = entry.path
        guard !askingKeychain.contains(path), !refusedKeychain.contains(path), passphrases.hasStored(path) else { return }
        askingKeychain.insert(path)
        Task { [weak self, weak entry] in
            guard let self else { return }
            let passphrase = await self.passphrases.stored(for: path)
            self.askingKeychain.remove(path)
            guard let entry, self.entries.contains(where: { $0 === entry }) else { return }
            if let passphrase, self.unlock(passphrase, for: path) == nil { return }
            self.refusedKeychain.insert(path)
        }
    }

    // MARK: - Panes

    /// A new, empty pane.
    public func makePane() -> EditorPane {
        let pane = EditorPane()
        panes.append(pane)
        return pane
    }

    /// Removes `pane`; its buffers stay open. The last pane stays.
    public func closePane(_ pane: EditorPane) {
        guard panes.count > 1, let index = panes.firstIndex(where: { $0 === pane }) else { return }
        panes.remove(at: index)
        if focused === pane { focused = panes[0] }
    }

    /// The panes showing `path`.
    private func panes(showing path: String) -> [EditorPane] {
        panes.filter { $0.path == path }
    }

    private var buffer: DocumentBuffer? { current?.buffer }
    /// The focused buffer's pending autosave, for tests to wait on.
    var autosave: Task<Void, Never>? { current?.autosave }
    private var url: URL? { path.map { URL(fileURLWithPath: $0) } }
    /// Whether the open file is an org file (`.org`, `.org_archive`), not plain text.
    public var isOrg: Bool { path.map(Self.isOrgPath) ?? false }

    public static func isOrgPath(_ path: String) -> Bool {
        path.hasSuffix(".org") || path.hasSuffix(".org_archive") || path.hasSuffix(".org.gpg")
    }

    /// Whether the open file is Markdown, which has highlighting, heading folds and an outline.
    public var isMarkdown: Bool { path.map(Markdown.isPath) ?? false }

    /// The outline of `path`'s text: org headings, or Markdown's; none for other files.
    static func outline(_ path: String, _ state: DocumentState) -> [OutlineEntry] {
        if isOrgPath(path) { return Presentation.outline(state.tree) }
        return Markdown.isPath(path) ? MarkdownDocument(state.text).outline : []
    }

    /// The caret in the open file.
    public var caret: Int { buffer?.selection.first?.lowerBound ?? 0 }
    private var name: String { path.map { ($0 as NSString).lastPathComponent } ?? "" }

    /// The open buffer of `path`, or of the same file by another path (`find-buffer-visiting`
    /// by truename).
    private func entry(_ path: String) -> Entry? {
        if let exact = entries.first(where: { $0.path == path }) { return exact }
        let truename = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return entries.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == truename }
    }

    /// The text of `path`: its buffer's when it's open, else what's on disk.
    public func text(of path: String) -> String? {
        if let entry = entry(path) { return entry.buffer.document.text }
        guard let bytes = try? fileSystem.read(URL(fileURLWithPath: path)) else { return nil }
        let state = loaded(bytes, path: path)
        return state.isEditable ? state.text : nil
    }

    /// A copy of `path`'s text and tree, its buffer's when it's open, for changes made apart
    /// and written back with `ReplaceChangedText`.
    public func copy(of path: String) -> DocumentState? {
        if let entry = entry(path) { return entry.buffer.document }
        guard let bytes = try? fileSystem.read(URL(fileURLWithPath: path)) else { return nil }
        let state = loaded(bytes, path: path)
        return state.isEditable ? state : nil
    }

    /// The buffer's name as uniquify writes it (`post-forward-angle-brackets`): the file name,
    /// with as many of its folders as tell it apart from other open files of the same name.
    public func bufferName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let others = openPaths.filter { $0 != path && ($0 as NSString).lastPathComponent == name }
        guard !others.isEmpty else { return name }
        func folders(_ p: String) -> [String] { (p as NSString).deletingLastPathComponent.split(separator: "/").map(String.init).reversed() }
        let mine = folders(path)
        var count = 1
        while count < mine.count, others.contains(where: { folders($0).prefix(count) == mine.prefix(count) }) { count += 1 }
        return name + "<" + mine.prefix(count).reversed().joined(separator: "/") + ">"
    }

    public func isOpen(_ path: String) -> Bool { entry(path) != nil }

    /// The document of an open file, whichever pane shows it.
    public func document(of path: String) -> DocumentState? { entry(path)?.buffer.document }

    /// Whether `buffer` is the live state of `path`, as `attach` made it.
    public func isAttached(_ buffer: DocumentBuffer, for path: String) -> Bool { entry(path)?.buffer === buffer }

    /// The caret of an open file.
    public func caret(of path: String) -> Int? { entry(path)?.buffer.selection.first?.lowerBound }

    /// The text of every open file, for views that read files (the agenda, search).
    public var openDocuments: [(path: String, document: DocumentState)] {
        entries.map { ($0.path, $0.buffer.document) }
    }

    /// The text of every open file by path, for the agenda and what it writes (widgets, the
    /// watch, reminders). Encrypted files, and files with entries decrypted that saving
    /// encrypts, are left out: those views read them from disk.
    public var openTexts: [String: String] {
        let shown = entries.filter { !crypt.isPrivate($0.buffer.document.text, for: $0.path) }
        return Dictionary(shown.map { ($0.path, $0.buffer.document.text) }, uniquingKeysWith: { a, _ in a })
    }

    /// The text of `path` for an export that writes files (iCalendar, publishing): an open
    /// buffer's, unless it holds what's encrypted on disk, then what's on disk; nil for an
    /// encrypted file.
    public func exportText(of path: String) -> String? {
        if Self.isEncryptedFile(path) { return nil }
        if let entry = entry(path), !crypt.isPrivate(entry.buffer.document.text, for: entry.path) { return entry.buffer.document.text }
        return (try? diskFileSystem.read(URL(fileURLWithPath: path))).flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// Whether `exportText` leaves `path` out or reads it from disk for what's encrypted.
    public func exportLeavesOut(_ path: String) -> Bool {
        Self.isEncryptedFile(path) || entry(path).map { crypt.isPrivate($0.buffer.document.text, for: $0.path) } == true
    }

    /// Why the buffer of `path` isn't copied to a temporary file for Emacs (recalculating,
    /// exporting, `elisp:` links): it's an encrypted file, or holds entries encrypted on disk.
    public func refusesEmacsCopy(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if Self.isEncryptedFile(path) { return String(localized: "\(name) is encrypted, so Emacs isn't given a copy of it.") }
        guard let entry = entry(path), crypt.isPrivate(entry.buffer.document.text, for: entry.path) else { return nil }
        return String(localized: "\(name) has decrypted entries that are encrypted on disk, so Emacs isn't given a copy of it.")
    }

    /// Said after an export that left out encrypted files or read decrypted entries from disk.
    public static var exportNote: String {
        String(localized: "Encrypted files were left out, and encrypted entries were exported as they are on disk.")
    }

    /// Open buffers, most recently shown first.
    public var recentPaths: [String] { history.filter(isOpen) }

    /// Shows the buffer of `path` in the focused pane, opening the file if it isn't open.
    public func open(_ path: String) {
        open(path, in: focused)
    }

    /// Shows the buffer of `path` in `pane`, opening the file if it isn't open.
    public func open(_ path: String, in pane: EditorPane) {
        let interval = Perf.begin("session.open")
        defer { interval.end((path as NSString).lastPathComponent) }
        if let existing = entry(path) {
            show(existing, in: pane)
            return
        }
        if Self.isEncryptedFile(path), crypt.passphrase(for: path) == nil,
           (try? diskFileSystem.read(URL(fileURLWithPath: path)))??.isEmpty == false {
            unlockRequest = path
            unlockPane = pane
            return
        }
        do {
            guard let bytes = try fileSystem.read(URL(fileURLWithPath: path)) else {
                showError(String(localized: "Couldn't Open File", comment: "Error alert title"), "\((path as NSString).lastPathComponent) no longer exists.")
                return
            }
            let entry = Entry(path: path, buffer: StateBuffer(loaded(bytes, path: path)))
            crypt.opened(path)
            let index = pane.path.flatMap(self.entry).flatMap { c in entries.firstIndex { $0 === c } }.map { $0 + 1 } ?? entries.count
            entries.insert(entry, at: index)
            show(entry, in: pane)
        } catch {
            showError(String(localized: "Couldn't Open File", comment: "Error alert title"), "Can't open \(path): \(error.localizedDescription)")
        }
    }

    private func show(_ entry: Entry, in pane: EditorPane) {
        pane.path = entry.path
        if !pane.shown.contains(entry.path) { pane.shown.append(entry.path) }
        pane.history.removeAll { $0 == entry.path }
        pane.history.insert(entry.path, at: 0)
        pane.revealRequest = nil
        history.removeAll { $0 == entry.path }
        history.insert(entry.path, at: 0)
        refresh(pane)
        // A worker ready ahead of the first user command run in this buffer.
        #if canImport(WebKit)
        if !userCommands.all.isEmpty { userCommandHost()?.prepare() }
        #endif
    }

    /// The buffer before or after the focused one, wrapping, in the focused pane.
    public func cycle(_ step: Int) {
        guard let current, let index = entries.firstIndex(where: { $0 === current }), entries.count > 1 else { return }
        show(entries[((index + step) % entries.count + entries.count) % entries.count], in: focused)
    }

    /// The buffer shown before the focused one.
    public func showPrevious() {
        guard let previous = recentPaths.dropFirst().first else { return }
        open(previous)
    }

    /// Closes the buffer of `path` without saving it. A pane showing it shows the buffer it
    /// showed before, else the most recent other buffer, else nothing.
    public func kill(_ path: String) {
        guard let entry = entry(path) else { return }
        entry.autosave?.cancel()
        entries.removeAll { $0 === entry }
        crypt.close(entry.path)
        passphrases.endSession(for: entry.path)
        held[entry.path] = nil
        failedHolds[entry.path] = nil
        refusedKeychain.remove(entry.path)
        history.removeAll { $0 == path }
        outlineUpdates[path]?.cancel()
        outlineUpdates[path] = nil
        for pane in panes {
            pane.shown.removeAll { $0 == path }
            pane.history.removeAll { $0 == path }
            guard pane.path == path else { continue }
            if let next = pane.history.first.flatMap(self.entry) ?? recentPaths.first.flatMap(self.entry) ?? entries.last {
                show(next, in: pane)
            } else {
                pane.path = nil
                pane.outline = []
                pane.isDirty = false
                pane.isReadOnly = false
                pane.conflict = nil
                pane.revealRequest = nil
            }
        }
        refreshLists()
    }

    /// Closes the focused buffer without saving, as when its file was deleted.
    public func close() {
        if let path { kill(path) }
    }

    /// Makes `buffer`, built from `document`, the live state of the focused file.
    public func attach(_ buffer: DocumentBuffer) {
        if let path { attach(buffer, for: path) }
    }

    /// Makes `buffer`, built from the file's `document`, the live state of `path`.
    public func attach(_ buffer: DocumentBuffer, for path: String) {
        guard let entry = entry(path) else { return }
        entry.buffer = buffer
        for pane in panes(showing: path) { refresh(pane) }
    }

    /// The buffer of `path` changed in its editor: the panes showing it update their views
    /// once typing pauses, and it saves on its own.
    public func bufferChanged(_ path: String) {
        guard let entry = entry(path) else { return }
        changed(entry)
    }

    /// The focused buffer changed through typing.
    public func bufferChanged() {
        if let current { changed(current) }
    }

    /// A buffer changed, typed or not: the panes showing it update their views, the outline
    /// once typing pauses, and it saves on its own.
    private func changed(_ entry: Entry) {
        let showing = panes(showing: entry.path)
        for pane in showing { refresh(pane, outline: false) }
        outlineUpdates[entry.path]?.cancel()
        if !showing.isEmpty {
            let path = entry.path
            outlineUpdates[path] = Task { [weak self, weak entry] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, let entry else { return }
                let outline = Self.outline(path, entry.buffer.document)
                for pane in self.panes(showing: path) {
                    pane.outline = outline
                    pane.editVersion += 1
                }
            }
        }
        scheduleAutosave(entry)
        refreshLists()
        textChanged?(entry.path)
    }

    /// `pane`'s view of its buffer, from the buffer's state.
    private func refresh(_ pane: EditorPane, outline updateOutline: Bool = true) {
        let interval = Perf.begin("session.refresh")
        defer { interval.end() }
        refreshLists()
        guard let entry = pane.path.flatMap(entry) else { return }
        let state = entry.buffer.document
        if pane.isDirty != state.isDirty { pane.isDirty = state.isDirty }
        if pane.isReadOnly == state.isEditable { pane.isReadOnly = !state.isEditable }
        if pane.conflict != entry.conflict { pane.conflict = entry.conflict }
        if updateOutline {
            pane.outline = Self.outline(entry.path, state)
            pane.editVersion += 1
        }
    }

    /// Every pane showing `entry`, from the buffer's state.
    private func refresh(_ entry: Entry) {
        for pane in panes(showing: entry.path) { refresh(pane) }
    }

    /// The focused pane, from its buffer's state.
    private func refresh() {
        refresh(focused)
    }

    private func refreshLists() {
        let paths = entries.map(\.path)
        if paths != openPaths { openPaths = paths }
        let dirty = Set(entries.filter { $0.buffer.document.isDirty }.map(\.path))
        if dirty != dirtyPaths { dirtyPaths = dirty }
    }

    // MARK: - Saving

    private var saver: Saver {
        Saver(fileSystem: WriteReporting(base: fileSystem) { [weak self] url in MainActor.assumeIsolated { self?.fileWritten?(url.path) } }, recovery: recovery)
    }

    /// The saver for a file that isn't open, whose state is thrown away after the save: a
    /// version another writer put on disk just before ours, which recovery can't keep, is put
    /// back as it was, and the change fails. A version written after ours is left in place.
    private var closedFileSaver: Saver {
        var saver = saver
        let crypt = crypt, disk = diskFileSystem
        saver.restoreOverwritten = { url in
            guard let last = crypt.takeReplaced(for: url.path), try disk.read(url) == last.written else { return }
            _ = try disk.replace(url, with: last.replaced)
        }
        return saver
    }

    private func scheduleAutosave(_ entry: Entry) {
        entry.autosave?.cancel()
        // A held file whose edits were undone, or whose tagged entries went, isn't held.
        if held[entry.path] != nil, updateHold(entry) == nil { refresh(entry) }
        guard saveMode == .automatic, entry.buffer.document.isDirty, entry.conflict == nil else { return }
        entry.autosave = Task { [weak self, weak entry, autosaveDelay] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled, let self, let entry else { return }
            self.save(entry)
        }
    }

    /// Saves the current buffer now. True when nothing is left unsaved.
    @discardableResult
    public func save() -> Bool {
        guard let current else { return true }
        return save(current)
    }

    /// Saves the buffer of `path`. True when nothing is left unsaved.
    @discardableResult
    public func save(_ path: String) -> Bool {
        guard let entry = entry(path) else { return true }
        return save(entry)
    }

    /// Saves every open buffer. True when nothing is left unsaved.
    @discardableResult
    public func saveAll() -> Bool {
        entries.map { save($0) }.allSatisfy { $0 }
    }

    @discardableResult
    private func save(_ entry: Entry) -> Bool {
        let interval = Perf.begin("session.save")
        defer { interval.end((entry.path as NSString).lastPathComponent) }
        entry.autosave?.cancel()
        let name = (entry.path as NSString).lastPathComponent
        // A failed save is tried again: what failed may be fixed by now.
        guard updateHold(entry) == nil || held[entry.path] == failedHolds[entry.path] else {
            askKeychain(entry)
            refresh(entry)
            return false
        }
        guard entry.buffer.document.isDirty else { return true }
        guard entry.conflict == nil else { return false }
        defer { _ = updateHold(entry) }
        do {
            let outcome = try entry.buffer.update { try saver.save(&$0, to: URL(fileURLWithPath: entry.path)) }
            failedHolds[entry.path] = nil
            switch outcome {
            case .saved, .mergedAndSaved:
                break
            case .conflict:
                entry.conflict = "\(name) changed on disk, and the changes conflict with yours."
            case .overwroteExternalChange(let change), .changedAfterWrite(let change):
                if case .conflict(let conflicts) = change {
                    // No conflicts listed: both versions went into the buffer between markers.
                    entry.conflict = conflicts.isEmpty
                        ? String(localized: "\(name) changed on disk while saving, and the changes conflict with yours; both are in the editor between conflict markers.")
                        : "\(name) changed on disk while saving, and the changes conflict with yours."
                }
            }
        } catch let hold as CryptHold {
            // A version on disk with tagged entries in plaintext can be kept only encrypted.
            failedHolds[entry.path] = hold
            askKeychain(entry)
        } catch let failure as OrgCrypt.Failure {
            failedHolds[entry.path] = .blocked(failure.description)
        } catch {
            showError(String(localized: "Couldn't Save File", comment: "Error alert title"), "Can't save \(name): \(error.localizedDescription)")
        }
        refresh(entry)
        return !entry.buffer.document.isDirty
    }

    /// Resolves a conflict by writing the buffer over the disk version, which goes to recovery.
    public func keepMine() {
        guard let buffer, let url else { return }
        if let current, updateHold(current) != nil { return refresh() }
        do {
            try buffer.update { try saver.overwrite(&$0, to: url) }
            current?.conflict = nil
        } catch let hold as CryptHold {
            // The version on disk can be kept only encrypted: the passphrase first.
            if let current {
                failedHolds[current.path] = hold
                _ = updateHold(current)
                askKeychain(current)
            }
        } catch {
            showError(String(localized: "Couldn't Save File", comment: "Error alert title"), "Can't save \(name): \(error.localizedDescription)")
        }
        refresh()
    }

    /// Resolves a conflict by loading the disk version; the buffer goes to recovery.
    public func useDiskVersion() {
        guard let buffer, let url else { return }
        do {
            guard let bytes = try fileSystem.read(url) else { return }
            if isDirty { try recovery.keep(try buffer.document.encodedText(), for: url, label: "local") }
            let path = url.path
            buffer.update { $0 = loaded(bytes, path: path) }
            current?.conflict = nil
        } catch let hold as CryptHold {
            showError(String(localized: "Couldn't Keep a Copy", comment: "Error alert title"), keepFailure(hold))
        } catch {
            showError(String(localized: "Couldn't Read File", comment: "Error alert title"), "Can't read \(name): \(error.localizedDescription)")
        }
        refresh()
    }

    // MARK: - Comparing versions

    /// The buffer, the file on disk and the version both started from, while they conflict.
    public func conflictVersions() -> (mine: String, disk: String, base: String)? {
        guard current?.conflict != nil, let buffer, let url, let disk = try? fileSystem.read(url) else { return nil }
        return (buffer.document.text, SourceText(bytes: disk).text, SourceText(bytes: buffer.document.mergeBase).text)
    }

    /// Resolves a conflict as `git merge` leaves one: the buffer holds both sides' changes, those
    /// that conflict between markers, to fix and save. The disk version becomes the base, and
    /// the buffer as it was goes to recovery.
    public func mergeConflictWithMarkers() {
        guard let versions = conflictVersions(), let buffer, let url, let disk = try? fileSystem.read(url) else { return }
        do {
            try recovery.keep(try buffer.document.encodedText(), for: url, label: "local")
            let merged = mergeWithMarkers(base: versions.base, ours: versions.mine, theirs: versions.disk, oursLabel: "yours", theirsLabel: "disk")
            try buffer.update { state in
                state = loaded(disk, path: url.path)
                try state.apply(lineEdits(from: versions.disk, to: merged), baseRevision: state.revision)
            }
            current?.conflict = nil
        } catch let hold as CryptHold {
            showError(String(localized: "Couldn't Keep a Copy", comment: "Error alert title"), keepFailure(hold))
        } catch {
            showError(String(localized: "Couldn't Merge", comment: "Error alert title"), "Can't merge \(name): \(error.localizedDescription)")
        }
        refresh()
    }

    /// Syncthing's conflict copies of the open file beside it: `name.sync-conflict-DATE-TIME-ID.ext`.
    public func syncConflictCopies() -> [URL] {
        guard let url else { return [] }
        let folder = url.deletingLastPathComponent()
        let stem = NSRegularExpression.escapedPattern(for: url.deletingPathExtension().lastPathComponent)
        let ext = url.pathExtension.isEmpty ? "" : "\\." + NSRegularExpression.escapedPattern(for: url.pathExtension)
        let pattern = "^" + stem + "\\.sync-conflict-[0-9]{8}-[0-9]{6}-[A-Z0-9]+" + ext + "$"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.range(of: pattern, options: .regularExpression) != nil }.sorted().map { folder.appendingPathComponent($0) }
    }

    /// What to do with a conflict copy: keep the file as it is, take the copy's text, or merge
    /// the two with markers. The copy goes to recovery and is removed.
    public enum CopyResolution { case keepFile, useCopy, merge }

    public func resolve(copy: URL, _ resolution: CopyResolution) -> String? {
        guard let buffer, let url else { return "No file is open" }
        do {
            guard let bytes = try diskFileSystem.read(copy).map({ try crypt.plain($0, for: url.path) }) else { return "\(copy.lastPathComponent) is gone" }
            let copyText = SourceText(bytes: bytes).text
            let mine = buffer.document.text
            let new: String? = switch resolution {
            case .keepFile: nil
            case .useCopy: copyText
            case .merge: mergeWithMarkers(base: nil, ours: mine, theirs: copyText, oursLabel: url.lastPathComponent, theirsLabel: copy.lastPathComponent)
            }
            if let new, new != mine {
                let result = EditResult(baseRevision: buffer.document.revision, edits: lineEdits(from: mine, to: new))
                if case .failed(let message) = buffer.perform(PrecomputedEdit(result), now: Date(), answers: [:]) { return message }
            }
            try recovery.keep(bytes, for: url, label: "sync-conflict")
            try FileManager.default.removeItem(at: copy)
        } catch {
            return "Can't resolve \(copy.lastPathComponent): \(error.localizedDescription)"
        }
        if let current { changed(current) }
        return nil
    }

    /// Versions of the open file kept in recovery, newest first, with when and why each was
    /// kept.
    public func recoveryVersions() -> [(url: URL, date: Date, label: String)] {
        guard let url, let store = diskRecovery as? FileRecoveryStore, let versions = try? store.versions(for: url) else { return [] }
        // `STAMP-LABEL-UUID8-NAME`, as `FileRecoveryStore.keep` names them.
        return versions.reversed().map { version in
            let m = version.lastPathComponent.firstMatch(of: /^([0-9]+)-(.+?)-([0-9A-Fa-f]{8})-/)
            let nanos = m.flatMap { UInt64($0.1) } ?? 0
            return (version, Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000), m.map { String($0.2) } ?? "")
        }
    }

    /// The text of a kept version.
    public func recoveryText(_ version: URL) -> String? {
        guard let bytes = (try? diskFileSystem.read(version)).flatMap({ $0 }) else { return nil }
        // Kept as the open file is: encrypted with its passphrase, its entries' messages known.
        return (try? path.map { try crypt.plain(bytes, for: $0) } ?? bytes).map { SourceText(bytes: $0).text }
    }

    /// Puts a kept version's text in the buffer, as an edit that can be undone; the buffer as it
    /// was goes to recovery.
    public func restore(_ version: URL) -> String? {
        guard let text = recoveryText(version) else { return "Can't read that version" }
        return restore(text: text)
    }

    /// Puts `text`, an earlier version of the file, in the buffer as an edit that can be undone;
    /// the buffer as it was goes to recovery.
    public func restore(text: String) -> String? {
        guard let buffer, let url else { return "Can't read that version" }
        do {
            try recovery.keep(try buffer.document.encodedText(), for: url, label: "local")
        } catch let hold as CryptHold {
            return keepFailure(hold)
        } catch {
            return "Can't keep the current version: \(error.localizedDescription)"
        }
        let mine = buffer.document.text
        let result = EditResult(baseRevision: buffer.document.revision, edits: lineEdits(from: mine, to: text))
        if case .failed(let message) = buffer.perform(PrecomputedEdit(result), now: Date(), answers: [:]) { return message }
        if let current { changed(current) }
        return nil
    }

    // MARK: - Moving subtrees

    /// The current context of the buffer, as commands see it.
    private func editContext(now: Date) -> EditContext? {
        guard let buffer else { return nil }
        let document = buffer.document
        return EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: buffer.selection, now: now, options: options)
    }

    /// The file and context a subtree command works on: `from` (a file and a heading in it,
    /// as the agenda gives them), or the current buffer at its caret.
    private func source(_ from: (path: String, offset: Int)?, now: Date) -> (path: String, context: EditContext)? {
        guard let from else {
            guard let path, let context = editContext(now: now) else { return nil }
            return (path, context)
        }
        let state: DocumentState
        if let open = entry(from.path) {
            state = open.buffer.document
        } else {
            guard let bytes = try? fileSystem.read(URL(fileURLWithPath: from.path)) else { return nil }
            state = loaded(bytes, path: from.path)
        }
        guard state.isEditable else { return nil }
        let context = EditContext(revision: state.revision, text: state.text, tree: state.tree, selection: [from.offset..<from.offset], now: now, options: options)
        return (from.path, context)
    }

    /// Applies an edit computed from `source(_:now:)` to that file, open or not.
    private func applySource(_ edit: EditResult, path: String, now: Date) -> String? {
        if case .failed(let message) = perform(PrecomputedEdit(edit), path: path, at: 0, expect: nil, now: now) { return message }
        return nil
    }

    /// Moves the subtree at the caret, or at `from`, under `target`, or with `keep` copies it
    /// there (`org-copy`). For another file, that file is written first, through the save
    /// path; the subtree leaves its file only once it has. Returns a message for the echo area.
    @discardableResult
    public func refile(to target: RefileTarget, from: (path: String, offset: Int)? = nil, keep: Bool = false, now: Date = Date()) -> String? {
        guard case (let path, var context)? = source(from, now: now) else { return from == nil ? nil : "Can't read the entry's file." }
        do {
            switch prepareMove(path, context: context, to: target.path) {
            case .refused(let message): return message
            case .sealed(let heading):
                guard let again = source((path, heading), now: now) else { return "Can't read the entry's file." }
                context = again.context
            case .ready: break
            }
        }
        let done = (keep ? "Copied to " : "Refiled to ") + target.label
        if target.path == path {
            let answers = ["refile": target.start.map(String.init) ?? ""]
            let command = RefileWithinFile(keep: keep)
            let step = from == nil ? buffer?.perform(command, now: now, answers: answers)
                : perform(command, path: path, at: from!.offset, expect: nil, answers: answers, now: now)
            if case .failed(let message)? = step { return message }
            if from == nil { bufferChanged() }
            return done
        }
        let url = URL(fileURLWithPath: target.path)
        let targetName = (target.path as NSString).lastPathComponent
        // A target open in a buffer takes the subtree there, with its unsaved edits.
        if let open = entry(target.path) {
            let state = open.buffer.document
            guard state.isEditable else { return "\(targetName) isn't UTF-8, so it can't be changed." }
            guard let start = target.locate(in: state) else { return "Can't find \(target.label) any more." }
            guard let result = Refile.toOtherFile(source: context, target: state.text, under: start, keep: keep) else { return "Can't refile from here." }
            let edit = EditResult(baseRevision: state.revision, edits: [result.target])
            if case .failed(let message) = open.buffer.perform(PrecomputedEdit(edit), now: now, answers: [:]) { return message }
            changed(open)
            if !keep, let message = applySource(result.source, path: path, now: now) { return message }
            return done
        }
        do {
            guard let bytes = try fileSystem.read(url) else { return "\(targetName) no longer exists." }
            var state = loaded(bytes, path: url.path)
            guard state.isEditable else { return "\(targetName) isn't UTF-8, so it can't be changed." }
            guard let start = target.locate(in: state) else { return "Can't find \(target.label) any more." }
            guard let result = Refile.toOtherFile(source: context, target: state.text, under: start, keep: keep) else { return "Can't refile from here." }
            try state.apply([result.target], baseRevision: state.revision)
            if case .conflict = try closedFileSaver.save(&state, to: url) { return "\(targetName) changed on disk; nothing was refiled." }
            if !keep, let message = applySource(result.source, path: path, now: now) { return message }
            return done
        } catch {
            return "Can't refile: \(error.localizedDescription)"
        }
    }

    /// `org-refile-new-child`: a heading `title` at the end of `parent`'s subtree, one level
    /// below it, or at the end of the file for a file target. Returns the new heading as a
    /// target, or a message.
    public func createRefileChild(under parent: RefileTarget, title: String, now: Date = Date()) -> Result<RefileTarget, RefileFailure> {
        let name = (parent.path as NSString).lastPathComponent
        func insert(into state: DocumentState) -> (edit: TextEdit, start: Int, level: Int)? {
            guard let start = parent.locate(in: state) else { return nil }
            return Self.newChild(state.text, under: start, title: title)
        }
        func target(_ start: Int, _ level: Int, _ hash: String) -> RefileTarget {
            RefileTarget(label: parent.label + "/" + title, path: parent.path, start: start, title: title, level: level, contentHash: hash)
        }
        if let open = entry(parent.path) {
            let state = open.buffer.document
            guard state.isEditable else { return .failure(.message("\(name) isn't UTF-8, so it can't be changed.")) }
            guard let (edit, start, level) = insert(into: state) else { return .failure(.message("Can't find \(parent.label) any more.")) }
            if case .failed(let message) = open.buffer.perform(PrecomputedEdit(EditResult(baseRevision: state.revision, edits: [edit])), now: now, answers: [:]) {
                return .failure(.message(message))
            }
            changed(open)
            return .success(target(start, level, ""))
        }
        do {
            let url = URL(fileURLWithPath: parent.path)
            guard let bytes = try fileSystem.read(url) else { return .failure(.message("\(name) no longer exists.")) }
            var state = loaded(bytes, path: url.path)
            guard state.isEditable else { return .failure(.message("\(name) isn't UTF-8, so it can't be changed.")) }
            guard let (edit, start, level) = insert(into: state) else { return .failure(.message("Can't find \(parent.label) any more.")) }
            try state.apply([edit], baseRevision: state.revision)
            if case .conflict = try closedFileSaver.save(&state, to: url) { return .failure(.message("\(name) changed on disk; nothing was added.")) }
            return .success(target(start, level, FileRecord.hash(state.mergeBase)))
        } catch {
            return .failure(.message("Can't add \(title): \(error.localizedDescription)"))
        }
    }

    public enum RefileFailure: Error, Equatable {
        case message(String)
    }

    /// The edit `org-refile-new-child` makes in `text` under the heading at `start` (nil for
    /// the file), and where the new heading starts and its level.
    static func newChild(_ text: String, under start: Int??, title: String) -> (edit: TextEdit, start: Int, level: Int) {
        let ns = text as NSString
        var prefix = ""
        var pos = ns.length
        var level = 1
        if case .some(.some(let heading)) = start {
            var stars = 0
            while heading + stars < ns.length, ns.character(at: heading + stars) == 42 { stars += 1 }
            level = stars + 1
            // `org-end-of-subtree t t`: the next heading at this level or above.
            var at = NSMaxRange(ns.lineRange(for: NSRange(location: heading, length: 0)))
            pos = ns.length
            while at < ns.length {
                let line = ns.lineRange(for: NSRange(location: at, length: 0))
                var n = 0
                while at + n < NSMaxRange(line), ns.character(at: at + n) == 42 { n += 1 }
                if n > 0, n <= stars, at + n < ns.length, [32, 9].contains(ns.character(at: at + n)) {
                    pos = at
                    break
                }
                at = NSMaxRange(line)
            }
        } else if ns.length > 0, ns.character(at: ns.length - 1) != 10 {
            prefix = "\n"
        }
        // `org-back-over-empty-lines`.
        var back = pos
        while back > 0, [32, 9, 10, 13].contains(ns.character(at: back - 1)) { back -= 1 }
        var lineAfter = back
        while lineAfter < ns.length, ns.character(at: lineAfter) != 10 { lineAfter += 1 }
        if lineAfter < ns.length { lineAfter += 1 }
        if !prefix.isEmpty { lineAfter = ns.length }
        let at = min(lineAfter, pos)
        let insertion = prefix + "\n" + String(repeating: "*", count: level) + " " + title + "\n"
        let newStart = at + (prefix as NSString).length + 1
        return (TextEdit(range: at..<at, replacement: insertion), newStart, level)
    }

    private enum MovePreparation {
        case ready
        /// Tagged entries in the subtree were encrypted in its file; its heading starts here.
        case sealed(Int)
        case refused(String)
    }

    /// Before the subtree at the caret of `context`, in `path`, moves to the file `target`: an
    /// encrypted file's entries go only to another encrypted file, which takes the same
    /// passphrase; tagged entries with text in the subtree are encrypted where they are first,
    /// since the tag they inherit doesn't go with them.
    private func prepareMove(_ path: String, context: EditContext, to target: String) -> MovePreparation {
        // Within the file, an entry keeps its own tag; one inside an encrypted entry would leave it.
        if target == path {
            guard crypt.sealsEntries(for: path), let heading = OrgCrypt.heading(context.text, at: context.selection.first?.lowerBound ?? 0),
                  OrgCrypt.isInTaggedText(context.text, at: heading, tag: cryptTag) else { return .ready }
            return .refused(String(localized: "This heading is inside an encrypted entry, so it isn't moved on its own; move the encrypted entry."))
        }
        // The target's passphrase, lent by the source for the move, isn't kept after it.
        if Self.isEncryptedFile(target), !isOpen(target) {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isOpen(target) else { return }
                self.crypt.close(target)
            }
        }
        let from = (path as NSString).lastPathComponent, to = (target as NSString).lastPathComponent
        if Self.isEncryptedFile(path) {
            guard Self.isEncryptedFile(target) else {
                return .refused(String(localized: "\(from) is encrypted, and \(to) isn't; the entry wasn't moved."))
            }
            if crypt.passphrase(for: target) == nil, let passphrase = crypt.passphrase(for: path) {
                let disk = (try? diskFileSystem.read(URL(fileURLWithPath: target))).flatMap { $0 } ?? []
                guard CryptVault.opens(disk, passphrase: passphrase) else {
                    return .refused(String(localized: "\(to) has another passphrase; open it first."))
                }
                crypt.unlock(passphrase, for: target)
            }
        }
        guard crypt.sealsEntries(for: path), let heading = OrgCrypt.heading(context.text, at: context.selection.first?.lowerBound ?? 0) else { return .ready }
        // A heading inside an encrypted entry is in that entry's message on disk; moved on its
        // own, its title would be in plaintext.
        if OrgCrypt.isInTaggedText(context.text, at: heading, tag: cryptTag) {
            return .refused(String(localized: "This heading is inside an encrypted entry, so it isn't moved on its own; move the encrypted entry."))
        }
        let end = OrgCrypt.bodyRange(context.text, at: heading)?.upperBound ?? heading
        let subtree = heading..<max(heading + 1, end)
        guard !OrgCrypt.unencrypted(context.text, tag: cryptTag, within: subtree).isEmpty else { return .ready }
        guard let passphrase = crypt.passphrase(for: path) else {
            return .refused(String(localized: "Tagged entries in the subtree aren't encrypted; give the passphrase with Encrypt… first."))
        }
        let sealed: String
        do {
            sealed = try OrgCrypt.seal(context.text, passphrase: passphrase, tag: cryptTag, within: subtree).text
        } catch {
            return .refused("\(error)")
        }
        let edit = EditResult(baseRevision: context.revision, edits: lineEdits(from: context.text, to: sealed))
        if let open = entry(path) {
            if case .failed(let message) = open.buffer.perform(PrecomputedEdit(edit), now: Date(), answers: [:]) { return .refused(message) }
            changed(open)
        } else {
            do {
                guard let bytes = try fileSystem.read(URL(fileURLWithPath: path)) else { return .refused("\(from) no longer exists.") }
                var state = loaded(bytes, path: path)
                try state.apply(edit.edits, baseRevision: state.revision)
                if case .conflict = try closedFileSaver.save(&state, to: URL(fileURLWithPath: path)) { return .refused("\(from) changed on disk; nothing was moved.") }
            } catch {
                return .refused("Can't encrypt the entry: \(error.localizedDescription)")
            }
        }
        return .sealed(heading)
    }

    /// The file `archive(from:now:)` moves the entry to, or nil when it can't tell.
    public func archiveFile(from: (path: String, offset: Int)? = nil, now: Date = Date()) -> String? {
        guard let (path, context) = source(from, now: now), case .success(let destination) = Archive.destination(context, sourcePath: path) else { return nil }
        return destination.path
    }

    /// Archives the subtree at the caret, or at `from`, where `org-archive-subtree` would.
    /// Returns a message.
    @discardableResult
    public func archive(from: (path: String, offset: Int)? = nil, now: Date = Date()) -> String? {
        guard case (let path, var context)? = source(from, now: now) else { return from == nil ? nil : "Can't read the entry's file." }
        let destination: Archive.Destination
        switch Archive.destination(context, sourcePath: path) {
        case .success(let value): destination = value
        case .failure(.message(let message)): return message
        }
        do {
            switch prepareMove(path, context: context, to: destination.isSameFile ? path : destination.path) {
            case .refused(let message): return message
            case .sealed(let heading):
                guard let again = source((path, heading), now: now) else { return "Can't read the entry's file." }
                context = again.context
            case .ready: break
            }
        }
        // An archive file open in a buffer takes the subtree there.
        if !destination.isSameFile, let open = entry(destination.path) {
            let state = open.buffer.document
            let name = (destination.path as NSString).lastPathComponent
            guard state.isEditable else { return "\(name) isn't UTF-8, so it can't be changed." }
            let edits: Archive.Edits
            switch Archive.run(context, sourcePath: path, destination: destination, archiveText: state.text) {
            case .success(let value): edits = value
            case .failure(.message(let message)): return message
            }
            if let archiveEdit = edits.archive {
                let edit = EditResult(baseRevision: state.revision, edits: [archiveEdit])
                if case .failed(let message) = open.buffer.perform(PrecomputedEdit(edit), now: now, answers: [:]) { return message }
                changed(open)
            }
            if let message = applySource(edits.source, path: path, now: now) { return message }
            return "Archived to \(name)"
        }
        do {
            let url = URL(fileURLWithPath: destination.path)
            let existing = destination.isSameFile ? nil : try fileSystem.read(url)
            var state = loaded(existing ?? [], path: url.path)
            if !destination.isSameFile, !state.isEditable { return "\(url.lastPathComponent) isn't UTF-8, so it can't be changed." }
            let edits: Archive.Edits
            switch Archive.run(context, sourcePath: path, destination: destination, archiveText: existing.map { _ in state.text }) {
            case .success(let value): edits = value
            case .failure(.message(let message)): return message
            }
            if let archiveEdit = edits.archive {
                try state.apply([archiveEdit], baseRevision: state.revision)
                if case .conflict = try closedFileSaver.save(&state, to: url) { return "\(url.lastPathComponent) changed on disk; nothing was archived." }
            }
            if let message = applySource(edits.source, path: path, now: now) { return message }
            return destination.isSameFile ? "Archived under \(destination.heading ?? "the end of the file")" : "Archived to \(url.lastPathComponent)"
        } catch {
            return "Can't archive: \(error.localizedDescription)"
        }
    }

    // MARK: - Commands from other views

    /// Where the heading line `line` is now in `path`: at `offset` if it still reads so, else
    /// the copy of the line nearest `offset`. For acting on agenda entries after other edits
    /// moved them.
    public func locateHeading(path: String, line: String, near offset: Int) -> Int? {
        guard let text = entry(path)?.buffer.document.text ?? (try? fileSystem.read(URL(fileURLWithPath: path))).flatMap({ $0.map { SourceText(bytes: $0).text } }) else { return nil }
        let ns = text as NSString
        let length = (line as NSString).length
        if offset + length <= ns.length, ns.substring(with: NSRange(location: offset, length: length)) == line,
           offset == 0 || ns.character(at: offset - 1) == 10 {
            return offset
        }
        var best: Int?
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let found = ns.range(of: line, options: [], range: search)
            guard found.location != NSNotFound else { break }
            let atLineStart = found.location == 0 || ns.character(at: found.location - 1) == 10
            let lineEnd = NSMaxRange(found) == ns.length || ns.character(at: NSMaxRange(found)) == 10
            if atLineStart, lineEnd, best.map({ abs($0 - offset) > abs(found.location - offset) }) ?? true { best = found.location }
            search = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
        }
        return best
    }

    /// Runs `command` with the caret at `offset` in the file at `path`, as the agenda does:
    /// through the buffer when the file is open, leaving its caret alone; otherwise on the
    /// file, written back at once through the save path. `expect` is the heading line the
    /// caller saw at a position; if the text there changed, nothing runs.
    public func perform(
        _ command: any OrgCommand, path: String, at offset: Int, expect: (start: Int, line: String)?,
        answers: [String: String] = [:], now: Date = Date()
    ) -> CommandStep {
        let stale = CommandStep.failed("The entry changed; the agenda has been refreshed.")
        func matches(_ text: String) -> Bool {
            guard let expect else { return true }
            let ns = text as NSString
            guard expect.start + (expect.line as NSString).length <= ns.length else { return false }
            return ns.substring(with: NSRange(location: expect.start, length: (expect.line as NSString).length)) == expect.line
        }
        if let entry = entry(path) {
            let buffer = entry.buffer
            guard matches(buffer.document.text) else { return stale }
            do {
                let options = self.options
                let step = try buffer.update { try $0.run(command, selection: [offset..<offset], now: now, answers: answers, options: options) }
                if case .commit = step { changed(entry) }
                return step
            } catch {
                return .failed("\(error)")
            }
        }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        do {
            guard let bytes = try fileSystem.read(url) else { return .failed("\(name) no longer exists.") }
            var state = loaded(bytes, path: path)
            guard state.isEditable else { return .failed("\(name) isn't UTF-8, so it can't be changed.") }
            guard matches(state.text) else { return stale }
            let step = try state.run(command, selection: [offset..<offset], now: now, answers: answers, options: options)
            if case .commit = step, state.isDirty, case .conflict = try closedFileSaver.save(&state, to: url) {
                return .failed("\(name) changed on disk; nothing was changed.")
            }
            if case .commit = step { textChanged?(path) }
            return step
        } catch {
            return .failed("Can't change \(name): \(error.localizedDescription)")
        }
    }

    /// Applies `edits`, computed against `expected`, to `path` as one change, as Replace in
    /// Files and the renames do. An open buffer takes them as an edit its editor can undo; a
    /// buffer with no editor yet, and a file that isn't open, first has its text kept in
    /// recovery (labelled `replace`), and the file is written through the save path. Nil when
    /// done, else why not; nothing changes when the text is no longer `expected`.
    public func applyChanges(_ edits: [TextEdit], to path: String, expecting expected: String, now: Date = Date()) -> String? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let stale = "\(name) changed after the search; nothing was changed in it."
        if let entry = entry(path) {
            let state = entry.buffer.document
            guard state.isEditable else { return "\(name) isn't UTF-8, so it can't be changed." }
            guard state.text == expected else { return stale }
            if entry.buffer is StateBuffer {
                // A buffer held for its passphrase keeps no copy: it can't be kept encrypted,
                // and the replacement can be undone in the buffer.
                do { try recovery.keep(try state.encodedText(), for: url, label: "replace") } catch is CryptHold {} catch {
                    return "Can't keep a copy of \(name): \(error.localizedDescription)"
                }
            }
            if case .failed(let message) = entry.buffer.perform(PrecomputedEdit(EditResult(baseRevision: state.revision, edits: edits)), now: now, answers: [:]) {
                return message
            }
            changed(entry)
            return nil
        }
        do {
            guard let bytes = try fileSystem.read(url) else { return "\(name) no longer exists." }
            var state = loaded(bytes, path: path)
            guard state.isEditable else { return "\(name) isn't UTF-8, so it can't be changed." }
            guard state.text == expected else { return stale }
            try recovery.keep(bytes, for: url, label: "replace")
            try state.apply(edits, baseRevision: state.revision)
            if case .conflict = try closedFileSaver.save(&state, to: url) { return "\(name) changed on disk; nothing was changed." }
            textChanged?(path)
            return nil
        } catch {
            return "Can't change \(name): \(error.localizedDescription)"
        }
    }

    // MARK: - External work

    /// Recalculates a table in Emacs from a snapshot of the buffer, then replaces the table
    /// with Emacs's text if it hasn't changed meanwhile. Returns a message for the echo area.
    public func recalculateInEmacs(table: Range<Int>, point: Int, form: String) async -> String {
        guard let programs = Self.runner else {
            #if os(macOS)
            return "Tables that need Emacs aren't recalculated in this version of orgstar."
            #else
            return "Tables that need Emacs aren't recalculated on iOS."
            #endif
        }
        guard let entry = current else { return "No file is open." }
        let path = entry.path
        if let refusal = refusesEmacsCopy(path) { return refusal }
        let snapshot = entry.buffer.document.text as NSString
        guard table.upperBound <= snapshot.length else { return "The table moved; try again." }
        let old = snapshot.substring(with: NSRange(table))
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            let new = try await programs.recalculateTable(text: snapshot as String, directory: directory, table: table, point: point, form: form)
            guard entries.contains(where: { $0 === entry }) else { return "The file was closed before Emacs finished." }
            let current = entry.buffer
            let text = current.document.text as NSString
            guard table.upperBound <= text.length, text.substring(with: NSRange(table)) == old else {
                return "The table changed while Emacs recalculated it; nothing was changed."
            }
            guard new != old else { return "Recalculated in Emacs" }
            let result = EditResult(baseRevision: current.document.revision, edits: [TextEdit(range: table, replacement: new)])
            if case .failed(let message) = current.perform(PrecomputedEdit(result), now: Date(), answers: [:]) { return message }
            changed(entry)
            return "Recalculated in Emacs"
        } catch is CancellationError {
            return "Recalculation canceled"
        } catch {
            return "\(error)"
        }
    }

    /// Runs a src block and writes its result under it, unless the block changed while it
    /// ran. Returns a message for the echo area.
    public func runBabel(_ job: BabelJob) async -> String {
        guard let entry = current else { return "No file is open." }
        let directory = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
        let programs = Self.runner
        /// A program through `programs`; without it, Emacs Lisp in `Elisp`, js in
        /// JavaScriptCore, python in Pyodide when the app has it, and nothing else.
        func run(_ job: BabelJob) async throws -> BabelOutput {
            if let output = job.known { return output }
            if let programs { return try await programs.runBabel(job, fileDirectory: directory) }
            #if canImport(JavaScriptCore)
            if let output = try await JavaScriptBlocks.run(job, directory: directory) { return output }
            #endif
            #if canImport(WebKit)
            if let output = try await PythonBlocks.run(job, directory: directory) { return output }
            #endif
            if job.calc != nil { return try TableReason.calcBlock(job) }
            #if canImport(SQLite3)
            if let output = try SQLiteBlocks.run(job, directory: directory) { return output }
            #endif
            #if canImport(WebKit)
            if let output = try await DiagramBlocks.run(job, directory: directory) { return output }
            #endif
            guard let output = try Babel.evaluateNatively(job) else {
                #if os(macOS)
                throw Babel.Failure.message(job.lispForm == nil
                    ? "\(job.language) blocks don't run in this version of orgstar."
                    : "This block uses Emacs Lisp that runs only in Emacs.")
                #else
                throw Babel.Failure.message(job.lispForm == nil
                    ? "\(job.language) blocks need the Mac to run."
                    : "This block uses Emacs Lisp that runs only in Emacs, on the Mac.")
                #endif
            }
            return output
        }
        /// Writes the result to `:file`, when the block asks for that; a message when it can't.
        func write(_ job: BabelJob, _ output: BabelOutput) -> String? {
            guard let file = Babel.fileResult(job, output: output) else { return nil }
            do {
                try file.contents.write(to: Self.resultFile(file.path, job: job, directory: directory), atomically: true, encoding: .utf8)
                return nil
            } catch {
                return "Can't write \(file.path): \(error.localizedDescription)"
            }
        }
        // Without programs, a block that refers to one that can't run here runs nothing.
        if programs == nil, !job.needs.isEmpty, let language = ([job.language] + job.referenced).first(where: { !Self.inProcess.contains($0) }) {
            #if os(macOS)
            return "This block needs a \(language) block, and \(language) blocks don't run in this version of orgstar; nothing was run."
            #else
            return "This block needs a \(language) block, and \(language) blocks need the Mac to run; nothing was run."
            #endif
        }
        do {
            // Blocks the `:var`s, `:post` and noweb references refer to run first, one at a time.
            // Each is one of the blocks agreed to, or the run stops: the text may have changed
            // while a block ran.
            var job = job
            let approved = job.approved
            func agreed(_ block: BabelJob) -> Bool { approved.isEmpty || approved.contains(block.blockText) }
            if job.needsFile {
                let document = entry.buffer.document
                switch Babel.replan(job, file: entry.path, text: document.text, tree: document.tree) {
                case .failure(.message(let message)): return message
                case .success(let next): job = next
                }
            }
            while let need = job.needs.first {
                guard agreed(need.job) else { return "The blocks changed while running; nothing more was run." }
                let output = try await run(need.job)
                guard entries.contains(where: { $0 === entry }) else { return "The file was closed before the block finished." }
                if let message = write(need.job, output) { return message }
                let document = entry.buffer.document
                switch Babel.resume(job, need: need, output: output, text: document.text, tree: document.tree) {
                case .failure(.message(let message)): return message
                case .success(let next): job = next
                }
            }
            guard agreed(job) else { return "The blocks changed while running; nothing more was run." }
            let output = try await run(job)
            guard entries.contains(where: { $0 === entry }) else { return "The file was closed before the block finished." }
            if let message = write(job, output) { return message }
            let current = entry.buffer
            let document = current.document
            let done = output.problem ?? "Code block evaluation complete."
            switch Babel.finish(job, output: output, text: document.text, settings: document.tree.settings) {
            case .failure(.message(let message)):
                return message
            case .success(let edits):
                guard !edits.isEmpty else { return job.finish.params.contains("silent") ? output.problem ?? output.stdout : done }
                let result = EditResult(baseRevision: document.revision, edits: edits)
                if case .failed(let message) = current.perform(PrecomputedEdit(result), now: Date(), answers: [:]) { return message }
                changed(entry)
                return done
            }
        } catch is CancellationError {
            return "Code block canceled."
        } catch Babel.Failure.message(let message) {
            return message
        } catch {
            return "\(error)"
        }
    }

    /// The languages that run without programs.
    static var inProcess: Set<String> {
        var languages: Set<String> = ["emacs-lisp", "elisp", "js", "javascript", "calc", "sqlite", "dot", "mermaid"]
        #if canImport(WebKit)
        if PythonBlocks.folder != nil { languages.insert("python") }
        #endif
        return languages
    }

    /// Where a block's `:file` result goes: relative to `:dir`, itself relative to `directory`.
    static func resultFile(_ name: String, job: BabelJob, directory: URL) -> URL {
        let runDirectory = job.directory.map { URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL } ?? directory
        return name.hasPrefix("/") ? URL(fileURLWithPath: name) : runDirectory.appendingPathComponent(name)
    }

    /// The `:file` the block writes its result to, for the open file; nil without one.
    public func resultFile(of job: BabelJob) -> String? {
        guard let path, let name = job.finish.file else { return nil }
        return Self.resultFile(name, job: job, directory: URL(fileURLWithPath: path).deletingLastPathComponent()).path
    }

    /// The block running now, to cancel.
    @ObservationIgnored private var babelTask: Task<String, Never>?
    public private(set) var isRunningBabel = false

    /// Runs a src block in the background; its message comes back through `report`.
    public func startBabel(_ job: BabelJob, report: @escaping @MainActor (String) -> Void) {
        babelTask?.cancel()
        isRunningBabel = true
        let task = Task { await runBabel(job) }
        babelTask = task
        Task {
            let message = await task.value
            if babelTask == task {
                babelTask = nil
                isRunningBabel = false
            }
            report(message)
        }
    }

    /// Stops the running block; its results aren't inserted.
    public func cancelBabel() {
        babelTask?.cancel()
    }

    // MARK: - User commands

    /// The commands of `commands.toml`; their folder is where the host loads modules from.
    @ObservationIgnored public var userCommands = UserCommands.shared
    #if canImport(WebKit)
    @ObservationIgnored private var commandHost: CommandHost?

    /// The host for the commands' folder, made again when the folder changed.
    func userCommandHost() -> CommandHost? {
        guard let folder = userCommands.folder else { return nil }
        if commandHost?.folder != folder {
            commandHost?.unload()
            commandHost = CommandHost(folder: folder)
        }
        return commandHost
    }
    #endif
    @ObservationIgnored private var userCommandTask: Task<String?, Never>?
    public private(set) var isRunningUserCommand = false

    /// Runs a user command on the focused buffer in the background, with `context` the editor's
    /// context at the request's revision; the message comes back through `report`. `file` is
    /// the file's path relative to its folder, for `org.file()`. Prompts go to `ask`. `finished`
    /// gets the message once the command has ended, nil when its result was applied.
    /// `workspace` answers the calls of commands with `workspace = true`.
    public func startUserCommand(_ request: UserCommandRequest, context: EditContext, file: String?, workspace: UserCommandWorkspace? = nil,
                                 ask: @escaping @MainActor (Prompt, @escaping (String?) -> Void) -> Void,
                                 report: @escaping @MainActor (String) -> Void,
                                 finished: @escaping @MainActor (String?) -> Void = { _ in }) {
        userCommandTask?.cancel()
        isRunningUserCommand = true
        let task = Task { await runUserCommand(request, context: context, file: file, workspace: workspace, ask: ask, report: report) }
        userCommandTask = task
        Task {
            let message = await task.value
            if userCommandTask == task {
                userCommandTask = nil
                isRunningUserCommand = false
            }
            if let message { report(message) }
            finished(message)
        }
    }

    /// Stops the running user command; nothing it returns is applied.
    public func cancelUserCommand() {
        userCommandTask?.cancel()
    }

    /// Why a user command doesn't run in `path`'s buffer: it's an encrypted file or holds
    /// decrypted entries, which a command could copy elsewhere in the file. Nil when it runs.
    public func refusesUserCommand(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard Self.isEncryptedFile(path) || entry(path).map({ crypt.isPrivate($0.buffer.document.text, for: $0.path) }) == true else { return nil }
        return String(localized: "\(name) has decrypted entries, so user commands don't run in it.", comment: "A user command refused in a buffer holding decrypted text")
    }

    /// Runs `request` in the focused buffer and applies what it returns as one change at the
    /// request's revision. The message to show; nil when the command's own messages were shown.
    func runUserCommand(_ request: UserCommandRequest, context: EditContext, file: String?, workspace: UserCommandWorkspace? = nil,
                        ask: @escaping @MainActor (Prompt, @escaping (String?) -> Void) -> Void,
                        report: @escaping @MainActor (String) -> Void) async -> String? {
        let command = request.command
        guard let path, let entry = entry(path) else { return "No file is open." }
        if let refusal = refusesUserCommand(path) { return refusal }
        guard entry.buffer.document.revision == request.revision, context.revision == request.revision else { return "The file changed; try again." }
        #if canImport(WebKit)
        guard let host = userCommandHost() else { return "No \(UserCommands.fileName)." }
        final class State {
            var failure: String?
            var quit = false
            /// `org.run("app.save")` ran.
            var save = false
            var buffer: UserCommandState
            init(_ buffer: UserCommandState) { self.buffer = buffer }
        }
        let state = State(UserCommandState(
            EditContext(revision: context.revision, text: context.text, tree: context.tree, selection: request.selection,
                        now: context.now, calendar: context.calendar, options: context.options, knownTags: context.knownTags),
            defaults: entry.buffer.document.defaults))
        /// The answer to `prompt`; a canceled prompt throws.
        func reply(to prompt: Prompt) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                ask(prompt) { answer in
                    guard let answer else {
                        state.quit = true
                        return continuation.resume(throwing: CommandHost.Failure.script("Quit"))
                    }
                    continuation.resume(returning: answer)
                }
            }
        }
        host.calls = { name, value in
            if let answer = UserCommandAPI.answer(name, value, context: state.buffer.context, file: file) { return answer }
            switch name {
            case "prompt":
                let prompt = UserCommandAPI.prompt(value)
                return UserCommandAPI.answer(try await reply(to: prompt), to: prompt, now: Date(), calendar: state.buffer.context.calendar)
            case "run":
                let id = value as? String ?? ""
                if UserCommandAPI.safeAppCommands.contains(id) {
                    state.save = true
                    return state.buffer.reply
                }
                let command: any OrgCommand
                switch UserCommandAPI.builtIn(id) {
                case .success(let found): command = found
                case .failure(let problem): throw CommandHost.Failure.script(problem.message)
                }
                // A built-in command's prompts go through the same prompt as the command's own.
                var answers: [String: String] = [:]
                while true {
                    switch state.buffer.run(command, answers: answers) {
                    case .commit: return state.buffer.reply
                    case .failed(let message): throw CommandHost.Failure.script(message)
                    case .external: throw CommandHost.Failure.script(UserCommandAPI.external(id).message)
                    case .prompt(let prompt): answers[prompt.key] = try await reply(to: prompt)
                    }
                }
            case "message":
                report(value as? String ?? "")
                return NSNull()
            case "fail":
                state.failure = value as? String ?? ""
                return NSNull()
            case _ where UserCommandWorkspace.calls.contains(name):
                guard command.workspace else {
                    throw CommandHost.Failure.script("org.\(name) needs workspace = true on the command in \(UserCommands.fileName).")
                }
                guard let workspace else { throw CommandHost.Failure.script("org.\(name) isn't available here.") }
                do throws(UserCommandWorkspace.Failure) {
                    return try await workspace.answer(name, value, session: self, path: path)
                } catch {
                    throw CommandHost.Failure.script(error.message)
                }
            default:
                throw CommandHost.Failure.script("org.\(name) isn't in API version \(UserCommands.apiVersion).")
            }
        }
        let json: String
        do {
            json = try await host.run(module: command.file, function: command.function, context: "null",
                                      timeout: .seconds(command.timeout), api: UserCommands.apiVersion)
        } catch let CommandHost.Failure.timedOut(limit) {
            let seconds = Int(limit.components.seconds)
            return String(localized: "\(command.title) didn't finish within \(seconds) s and was stopped.", comment: "A user command passed its time limit")
        } catch CommandHost.Failure.script(let message) {
            if let failure = state.failure { return failure }
            return state.quit ? "Quit" : "\(command.title): \(message)"
        } catch CommandHost.Failure.stopped {
            return String(localized: "\(command.title) was stopped: its web view ended, as when a command runs out of memory.", comment: "A user command whose web view ended")
        } catch {
            return String(localized: "\(command.title) canceled.", comment: "A user command canceled with Cancel Running Task")
        }
        if let failure = state.failure { return failure }
        guard !Task.isCancelled else { return String(localized: "\(command.title) canceled.", comment: "A user command canceled with Cancel Running Task") }
        switch state.buffer.result(json) {
        case .failure(let problem):
            return "\(command.title): \(problem.message)"
        case .success(let result):
            guard entries.contains(where: { $0 === entry }) else { return "The file was closed before the command finished." }
            if case .failed(let message) = entry.buffer.perform(PrecomputedEdit(result), now: Date(), answers: [:]) { return message }
            if !result.edits.isEmpty { changed(entry) }
            // A save that fails shows why, as Save does.
            if state.save { save(entry) }
            return nil
        }
        #else
        return "User commands aren't available here."
        #endif
    }

    // MARK: - Locations

    /// Opens the file of `location` if needed and asks the editor to show the heading. Offsets
    /// are used only if the buffer matches what was indexed; otherwise the heading is found
    /// again by position and title.
    public func show(_ location: HeadingLocation) {
        if path != location.path { open(location.path) }
        guard let document else { return }
        let hash = FileRecord.hash(document.mergeBase)
        let offset: Int
        if !isDirty, hash == location.contentHash {
            offset = location.start
        } else if location.ordinal == HeadingLocation.fileOrdinal {
            offset = 0
        } else if location.ordinal < outline.count, outline[location.ordinal].title == location.title {
            offset = outline[location.ordinal].start
        } else if let entry = outline.first(where: { $0.title == location.title }) {
            offset = entry.start
        } else {
            return
        }
        reveal(offset)
    }

    /// Asks the focused pane's editor to show `offset`.
    public func reveal(_ offset: Int) {
        reveal(offset, in: focused)
    }

    /// Asks `pane`'s editor to show `offset`.
    public func reveal(_ offset: Int, in pane: EditorPane) {
        requestID += 1
        pane.revealRequest = (offset, requestID)
    }

    /// Called when the workspace sees a file change on disk: an open buffer of it takes the
    /// change in.
    public func fileChanged(_ path: String) {
        let interval = Perf.begin("session.fileChanged")
        defer { interval.end((path as NSString).lastPathComponent) }
        guard let entry = entry(path) else { return }
        let name = (path as NSString).lastPathComponent
        let read: [UInt8]?
        do {
            read = try fileSystem.read(URL(fileURLWithPath: path))
        } catch {
            showError(String(localized: "Couldn't Read File", comment: "Error alert title"), "Can't read \(name): \(error.localizedDescription)")
            return
        }
        guard let bytes = read else { return }
        let buffer = entry.buffer
        guard bytes != buffer.document.mergeBase else { return }
        switch buffer.update({ $0.diskChanged(to: bytes) }) {
        case .conflict:
            entry.autosave?.cancel()
            entry.conflict = "\(name) changed on disk, and the changes conflict with yours."
        case .merged, .reloaded:
            entry.conflict = nil
            resolveSetup(entry)
            // Edits merged with the disk's still need saving.
            scheduleAutosave(entry)
        case .unchanged:
            break
        }
        refresh(entry)
    }
}

/// `base`, telling `written` about each file it replaced.
private struct WriteReporting: FileSystem {
    let base: FileSystem
    let written: @Sendable (URL) -> Void

    func read(_ url: URL) throws -> [UInt8]? { try base.read(url) }

    func replace(_ url: URL, with bytes: [UInt8]) throws -> [UInt8]? {
        let replaced = try base.replace(url, with: bytes)
        written(url)
        return replaced
    }
}
