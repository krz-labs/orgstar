import Foundation
import Observation
import OrgCore
import OrgDocument

/// Replace in Files, Rename Tag and Rename TODO Keyword: a search of the files of one folder or
/// all folders, off the main actor and cancellable, whose changes are listed by file and line
/// to untick, then applied as one change per file through `DocumentSession.applyChanges`.
/// Open buffers are searched as they are, unsaved edits included. Encrypted files (`.gpg`) and
/// org-crypt's encrypted entries are left out.
@MainActor
@Observable
public final class ReplaceInFiles {
    public enum Mode: Sendable, Equatable {
        case replace(TextReplace)
        case renameTag(from: String, to: String)
        case renameKeyword(from: String, to: String)
    }

    /// `org-todo-keywords` and `org-tag-alist` in config.toml, and how to change one by its
    /// user-defaults key.
    public struct Config {
        public var todoKeywords: String
        public var tagAlist: String
        public var set: @MainActor (_ defaultsKey: String, _ value: String) -> Void

        public init(todoKeywords: String, tagAlist: String, set: @escaping @MainActor (String, String) -> Void) {
            self.todoKeywords = todoKeywords
            self.tagAlist = tagAlist
            self.set = set
        }

        /// From user defaults; on the Mac, a change there is written into config.toml.
        public static var standard: Config {
            let defaults = UserDefaults.standard
            return Config(todoKeywords: defaults.string(forKey: "todoKeywords") ?? OrgPreferences.defaultTodoKeywords,
                          tagAlist: defaults.string(forKey: "tagAlist") ?? "") { key, value in defaults.set(value, forKey: key) }
        }
    }

    /// The changes found in one file.
    public struct FileChanges: Identifiable, Sendable {
        public let path: String
        /// The path below its folder.
        public let relativePath: String
        public let changes: [ProposedChange]
        /// The text the changes were found in.
        let text: String
        /// Changes left out, by id.
        public var unticked: Set<Int> = []
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
        public var isIncluded: Bool { unticked.count < changes.count }
    }

    /// A setting of config.toml the rename changes too, if the user agrees.
    public struct ConfigChange: Equatable, Sendable {
        /// Its name in config.toml.
        public let key: String
        let defaultsKey: String
        public let old: String
        public let new: String
    }

    public private(set) var mode: Mode?
    public private(set) var files: [FileChanges] = []
    public private(set) var configChange: ConfigChange?
    /// Apply also changes config.toml.
    public var changesConfig = true
    /// Files searched so far, of how many.
    public private(set) var progress: (done: Int, total: Int) = (0, 0)
    public private(set) var isSearching = false
    public private(set) var wasCancelled = false
    /// Why there is nothing to apply: a pattern that doesn't compile, a refused rename.
    public private(set) var problem: String?

    private let session: DocumentSession
    private let workspace: WorkspaceModel
    @ObservationIgnored private var config: Config
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(session: DocumentSession, workspace: WorkspaceModel, config: Config = .standard) {
        self.session = session
        self.workspace = workspace
        self.config = config
    }

    public var changeCount: Int { files.reduce(0) { $0 + $1.changes.count } }
    public var tickedCount: Int { files.reduce(0) { $0 + $1.changes.count - $1.unticked.count } }

    /// Extensions searched besides org files, by Replace in Files.
    static let textExtensions: Set<String> = ["txt", "md", "markdown"]

    /// Searches the files of the folder `scope` (a root's path), or of every folder. A rename
    /// with `includeConfig` also renames in config.toml. Cancels a search that is running.
    public func start(_ mode: Mode, scope: String?, includeConfig: Bool = true, cryptTag: String = OrgPreferences.cryptTag()) {
        task?.cancel()
        generation += 1
        self.mode = mode
        files = []
        configChange = nil
        problem = nil
        wasCancelled = false
        changesConfig = includeConfig
        isSearching = false
        progress = (0, 0)

        var regex: NSRegularExpression?
        switch mode {
        case .replace(let query):
            do {
                regex = try query.regex()
            } catch TextReplace.InvalidPattern.empty {
                return problem = String(localized: "Nothing to search for", comment: "Replace in Files: the search field is empty")
            } catch {
                return problem = String(localized: "Not a regular expression: \(query.pattern)", comment: "Replace in Files")
            }
        case .renameTag(let old, let new):
            if let refusal = Self.refusal(old, new, valid: TagRename.isValidName, kind: .tag) { return problem = refusal }
            if let renamed = TagRename.renamedTagAlist(config.tagAlist, from: old, to: new) {
                configChange = ConfigChange(key: "org-tag-alist", defaultsKey: "tagAlist", old: config.tagAlist, new: renamed)
            }
        case .renameKeyword(let old, let new):
            if let refusal = Self.refusal(old, new, valid: KeywordRename.isValidName, kind: .keyword) { return problem = refusal }
            let settings = OrgSettings.default.withTodoKeywords(config.todoKeywords) ?? .default
            if KeywordRename.crossesStates(settings, from: old, to: new) {
                return problem = Self.crossing(old, new, settings, in: "config.toml")
            }
            if let renamed = KeywordRename.renamedTodoKeywords(config.todoKeywords, from: old, to: new) {
                configChange = ConfigChange(key: "org-todo-keywords", defaultsKey: "todoKeywords", old: config.todoKeywords, new: renamed)
            }
        }

        let entries = workspace.files.filter { entry in
            guard scope == nil || entry.root == scope, !EncryptedText.isEncryptedFile(entry.path) else { return false }
            switch entry.kind {
            case .org, .archive: return true
            case .other:
                if case .replace = mode { return Self.textExtensions.contains((entry.path as NSString).pathExtension.lowercased()) }
                return false
            case .conflict: return false
            }
        }
        // Open buffers as they are; the rest is read from disk off the main actor.
        var open: [String: String?] = [:]
        for entry in entries {
            if let document = session.document(of: entry.path) { open[entry.path] = document.isEditable ? document.text : nil }
        }
        let job = Job(mode: mode, regex: regex, options: session.options, defaults: session.defaults, cryptTag: cryptTag,
                      configRenamed: includeConfig && configChange != nil, scope: Set(entries.map(\.path)))
        let generation = generation
        let list = entries.map { ($0.path, $0.relativePath) }
        progress = (0, list.count)
        isSearching = true
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var found: [FileChanges] = []
            var refusal: String?
            for (index, (path, relative)) in list.enumerated() {
                if Task.isCancelled { break }
                let text: String?
                if let buffered = open[path] {
                    text = buffered
                } else {
                    text = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { data in
                        let source = SourceText(bytes: [UInt8](data))
                        return source.isEditable ? source.text : nil
                    }
                }
                if let text {
                    switch job.changes(in: text, path: path) {
                    case .success(let changes):
                        if !changes.isEmpty { found.append(FileChanges(path: path, relativePath: relative, changes: changes, text: text)) }
                    case .failure(let reason):
                        refusal = reason.message
                    }
                }
                if refusal != nil { break }
                if index % 16 == 15 || index == list.count - 1 {
                    let done = index + 1
                    await MainActor.run { self?.reportProgress(done, generation: generation) }
                }
            }
            let cancelled = Task.isCancelled
            await MainActor.run { [found, refusal] in self?.finish(found, refusal: refusal, cancelled: cancelled, generation: generation) }
        }
    }

    /// Waits for the running search, for tests.
    public func waitForSearch() async {
        await task?.value
    }

    /// Stops the search; what it found so far stays listed.
    public func cancel() {
        guard isSearching else { return }
        task?.cancel()
        wasCancelled = true
    }

    private func reportProgress(_ done: Int, generation: Int) {
        guard generation == self.generation else { return }
        progress.done = done
    }

    private func finish(_ found: [FileChanges], refusal: String?, cancelled: Bool, generation: Int) {
        guard generation == self.generation else { return }
        isSearching = false
        if cancelled { wasCancelled = true }
        if let refusal {
            problem = refusal
            files = []
            configChange = nil
            return
        }
        files = found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Choosing

    public func isTicked(_ change: Int, in path: String) -> Bool {
        files.first { $0.path == path }.map { !$0.unticked.contains(change) } ?? false
    }

    public func setTicked(_ on: Bool, change: Int, in path: String) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        if on { files[index].unticked.remove(change) } else { files[index].unticked.insert(change) }
    }

    /// Ticks or unticks every change in a file.
    public func setTicked(_ on: Bool, file path: String) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        files[index].unticked = on ? [] : Set(files[index].changes.map(\.id))
    }

    // MARK: - Applying

    /// Applies the ticked changes, one change per file, and config.toml's when `changesConfig`.
    /// Returns what happened, for the echo area.
    @discardableResult
    public func apply(now: Date = Date()) -> String {
        var changed = 0
        var problems: [String] = []
        for file in files where file.isIncluded {
            let edits = file.changes.filter { !file.unticked.contains($0.id) }.map(\.edit)
            if let problem = session.applyChanges(edits, to: file.path, expecting: file.text, now: now) {
                problems.append(problem)
            } else {
                changed += 1
            }
        }
        if let configChange, changesConfig {
            config.set(configChange.defaultsKey, configChange.new)
            config = Config(todoKeywords: configChange.defaultsKey == "todoKeywords" ? configChange.new : config.todoKeywords,
                            tagAlist: configChange.defaultsKey == "tagAlist" ? configChange.new : config.tagAlist, set: config.set)
        }
        let appliedConfig = configChange != nil && changesConfig
        files = []
        configChange = nil
        var summary = String(localized: "Files changed: \(changed)", comment: "Replace in Files: after applying")
        if appliedConfig { summary += "; " + String(localized: "config.toml changed", comment: "Replace in Files: after applying") }
        return ([summary] + problems).joined(separator: "; ")
    }

    // MARK: - Refusals

    enum NameKind { case tag, keyword }

    private static func refusal(_ old: String, _ new: String, valid: (String) -> Bool, kind: NameKind) -> String? {
        if old.isEmpty || new.isEmpty { return String(localized: "Give the old and the new name.", comment: "Rename Tag or TODO Keyword") }
        if old == new { return String(localized: "The new name is the old one.", comment: "Rename Tag or TODO Keyword") }
        guard valid(new) else {
            return switch kind {
            case .tag: String(localized: "\(new) can't be a tag: a tag is letters, digits, _, @, # and %.", comment: "Rename Tag")
            case .keyword: String(localized: "\(new) can't be a TODO keyword: it has a space, a bar or a parenthesis.", comment: "Rename TODO Keyword")
            }
        }
        return nil
    }

    nonisolated static func crossing(_ old: String, _ new: String, _ settings: OrgSettings, in place: String) -> String {
        settings.isDone(old)
            ? String(localized: "Can't rename \(old) to \(new): in \(place), \(old) is a done state and \(new) isn't.", comment: "Rename TODO Keyword: refused")
            : String(localized: "Can't rename \(old) to \(new): in \(place), \(new) is a done state and \(old) isn't.", comment: "Rename TODO Keyword: refused")
    }

    // MARK: - The search

    struct Refusal: Error {
        let message: String
    }

    /// What a search looks for, with what it needs to look off the main actor.
    struct Job: Sendable {
        let mode: Mode
        let regex: NSRegularExpression?
        let options: EditingOptions
        let defaults: OrgSettings
        let cryptTag: String
        /// config.toml's `org-todo-keywords` is renamed too.
        let configRenamed: Bool
        /// Every file searched.
        let scope: Set<String>

        func changes(in text: String, path: String) -> Result<[ProposedChange], Refusal> {
            let skipping = EncryptedText.ranges(in: text, tag: cryptTag)
            switch mode {
            case .replace(let query):
                return .success((try? query.changes(in: text, skipping: skipping, regex: regex)) ?? [])
            case .renameTag(let old, let new):
                guard Self.isOrg(path), text.contains(old) else { return .success([]) }
                let tree = OrgParser.parse(text, defaults: defaults.resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile))
                return .success(TagRename.changes(in: text, tree: tree, from: old, to: new, options: options, skipping: skipping))
            case .renameKeyword(let old, let new):
                guard Self.isOrg(path), text.contains(old) else { return .success([]) }
                var setupFiles: [String] = []
                let settings = defaults.resolvingSetupFiles(in: text, path: path) { file in
                    setupFiles.append(file)
                    return OrgSettings.readFile(file)
                }
                let tree = OrgParser.parse(text, defaults: settings)
                if KeywordRename.crossesStates(tree.settings, from: old, to: new) {
                    return .failure(Refusal(message: ReplaceInFiles.crossing(old, new, tree.settings, in: (path as NSString).lastPathComponent)))
                }
                // Headings change where the keyword they get will be one: where the file's own
                // lines name it, or setup files also searched, or config.toml when it changes.
                let headings = switch KeywordRename.source(of: old, in: tree) {
                case .file: true
                case .setupFile: setupFiles.allSatisfy { scope.contains(($0 as NSString).standardizingPath) || scope.contains($0) }
                case .defaults: configRenamed
                case .none: false
                }
                return .success(KeywordRename.changes(in: text, tree: tree, from: old, to: new, headings: headings, options: options, skipping: skipping))
            }
        }

        static func isOrg(_ path: String) -> Bool {
            path.hasSuffix(".org") || path.hasSuffix(".org_archive")
        }
    }
}
