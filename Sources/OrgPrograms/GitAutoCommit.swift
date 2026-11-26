#if os(macOS)
import Foundation
import Observation

/// Whether orgstar commits in each sidebar folder that is a git repository, by root path, in the
/// user defaults under `gitAutoCommit`. Off for a folder that isn't listed.
@MainActor
@Observable
public final class GitFolderSettings {
    public enum Mode: String, CaseIterable, Sendable {
        case off
        /// Commit the files orgstar wrote.
        case commit
        /// Pull with `--ff-only`, commit, then push.
        case sync
    }

    public static let shared = GitFolderSettings()
    static let key = "gitAutoCommit"
    @ObservationIgnored private let defaults: UserDefaults
    public private(set) var modes: [String: Mode]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        modes = saved.compactMapValues(Mode.init(rawValue:)).filter { $0.value != .off }
    }

    public func mode(for root: String) -> Mode { modes[root] ?? .off }

    public func set(_ mode: Mode, for root: String) {
        modes[root] = mode == .off ? nil : mode
        defaults.set(modes.mapValues(\.rawValue), forKey: Self.key)
    }
}

/// Commits the files orgstar writes in folders where `GitFolderSettings` turns it on: a minute
/// after the last write in the folder, and on quit. Only those files are committed, so other
/// work in progress in the repository stays as it is. With pulling on, it pulls with
/// `--ff-only` first and pushes after a commit, and only when the pull succeeded.
@MainActor
public final class GitAutoCommit {
    public static let shared = GitAutoCommit()

    public let settings: GitFolderSettings
    /// How long after the last write in a folder its files are committed.
    public var delay: Duration = .seconds(60)
    /// The sidebar's folders.
    public var roots: () -> [String] = { [] }
    /// Shows a message in the echo area.
    public var report: (String) -> Void = { _ in }
    /// The git to run; looked up once.
    public lazy var git: Git? = Git.find()

    /// Files written since their folder's last commit, by root.
    private var pending: [String: Set<String>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var running: [String: Task<Void, Never>] = [:]

    public init(settings: GitFolderSettings = .shared) {
        self.settings = settings
    }

    /// Whether files are waiting to be committed.
    public var hasPending: Bool { pending.values.contains { !$0.isEmpty } }

    /// The root of the sidebar folder holding `path`, the innermost when folders nest; compared
    /// as written and with symbolic links resolved (`/tmp` and `/private/tmp`).
    func root(containing path: String) -> String? {
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        func inside(_ path: String, _ root: String) -> Bool { path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        let real = resolved(path)
        return roots().filter { inside(path, $0) || inside(real, resolved($0)) }.max { $0.count < $1.count }
    }

    /// Notes that orgstar wrote `path`; its folder commits after `delay` with no further writes.
    public func fileWritten(_ path: String) {
        guard let root = root(containing: path), settings.mode(for: root) != .off else { return }
        pending[root, default: []].insert(path)
        timers[root]?.cancel()
        timers[root] = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.timers[root] = nil
            await self.commit(root)
        }
    }

    /// Commits every folder's waiting files now, as on quit.
    public func flush(networkTimeout: Duration = .seconds(15)) async {
        for timer in timers.values { timer.cancel() }
        timers = [:]
        for root in pending.keys.sorted() { await commit(root, networkTimeout: networkTimeout) }
        for task in running.values { await task.value }
    }

    /// Commits `root`'s waiting files, after a commit already running there.
    func commit(_ root: String, networkTimeout: Duration = .seconds(60)) async {
        while let task = running[root] { await task.value }
        guard let files = pending.removeValue(forKey: root), !files.isEmpty else { return }
        let mode = settings.mode(for: root)
        guard mode != .off else { return }
        guard let git else { return report(String(localized: "Can't commit automatically: git isn't installed.", table: "DeveloperID")) }
        let task = Task { [weak self] in
            let outcome = await Self.run(files: files.sorted(), pullAndPush: mode == .sync, git: git, networkTimeout: networkTimeout)
            guard let self else { return }
            for path in outcome.retry { self.pending[root, default: []].insert(path) }
            for message in outcome.messages { self.report(message) }
            self.running[root] = nil
        }
        running[root] = task
        await task.value
    }

    public struct Outcome: Sendable, Equatable {
        /// Paths committed, relative to their work tree.
        public var committed: [String] = []
        public var pushed = false
        /// What to show, one message per repository.
        public var messages: [String] = []
        /// Files to try again with the next commit.
        public var retry: [String] = []
    }

    /// Pulls (with `pullAndPush`), commits the changes to `files` and nothing else, then pushes
    /// (with `pullAndPush`, after a pull that succeeded and a commit), in each repository the
    /// files are in. Leaves a repository alone while git is in the middle of an operation there.
    public nonisolated static func run(
        files: [String], pullAndPush: Bool, git: Git, localTimeout: Duration = .seconds(30), networkTimeout: Duration = .seconds(60)
    ) async -> Outcome {
        var outcome = Outcome()
        var repositories: [(top: URL, gitDir: URL, files: [String])] = []
        for file in files {
            guard let repository = await git.repository(containing: URL(fileURLWithPath: file).deletingLastPathComponent()) else { continue }
            if let index = repositories.firstIndex(where: { $0.top == repository.top }) {
                repositories[index].files.append(file)
            } else {
                repositories.append((repository.top, repository.gitDir, [file]))
            }
        }
        for repository in repositories {
            let name = repository.top.lastPathComponent
            if let operation = Git.operationInProgress(repository.gitDir) {
                outcome.retry += repository.files
                outcome.messages.append(operation == "index.lock"
                    ? String(localized: "Didn't commit in \(name): another git command is running there. orgstar tries again after the next save.", table: "DeveloperID")
                    : String(localized: "Didn't commit in \(name): a git \(operation) is in progress. Finish or abort it; orgstar commits after the next save.", table: "DeveloperID"))
                continue
            }
            var problems: [String] = []
            var pulled = true
            if pullAndPush {
                do {
                    let pull = try await git.run(["pull", "--no-rebase", "--ff-only"], in: repository.top, timeout: networkTimeout)
                    if !pull.succeeded {
                        pulled = false
                        problems.append(describe(pull, verb: String(localized: "Couldn't pull in \(name)", table: "DeveloperID"))
                            + " " + String(localized: "Nothing was merged; pull and resolve it in a terminal. Not pushed.", table: "DeveloperID"))
                    }
                } catch {
                    pulled = false
                    problems.append(String(localized: "Couldn't pull in \(name): \(String(describing: error)). Not pushed.", table: "DeveloperID"))
                }
            }
            var committed: [String] = []
            do {
                let paths = repository.files.compactMap { Git.relativePath(URL(fileURLWithPath: $0), in: repository.top) }
                let status = try await git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames", "--"] + paths, in: repository.top, timeout: localTimeout)
                guard status.succeeded else { throw Git.Failure(description: status.problem) }
                // `XY path` entries; porcelain paths are relative to the work tree.
                let changed = status.stdout.split(separator: "\0").filter { $0.count > 3 }.map { String($0.dropFirst(3)) }
                if !changed.isEmpty {
                    let add = try await git.run(["add", "--"] + changed, in: repository.top, timeout: localTimeout)
                    guard add.succeeded else { throw Git.Failure(description: add.problem) }
                    let commit = try await git.run(["commit", "--only", "-m", message(changed), "--"] + changed, in: repository.top, timeout: localTimeout)
                    guard commit.succeeded else { throw Git.Failure(description: commit.problem) }
                    committed = changed
                }
            } catch {
                outcome.retry += repository.files
                problems.append(String(localized: "Couldn't commit in \(name): \(String(describing: error))", table: "DeveloperID"))
            }
            var pushed = false
            if pullAndPush, pulled, !committed.isEmpty {
                do {
                    let push = try await git.run(["push"], in: repository.top, timeout: networkTimeout)
                    if push.succeeded { pushed = true } else { problems.append(describe(push, verb: String(localized: "Couldn't push \(name)", table: "DeveloperID"))) }
                } catch {
                    problems.append(String(localized: "Couldn't push \(name): \(String(describing: error))", table: "DeveloperID"))
                }
            }
            outcome.committed += committed
            outcome.pushed = outcome.pushed || pushed
            let names = committed.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            var parts: [String] = []
            if !committed.isEmpty {
                parts.append(pushed
                    ? String(localized: "Committed and pushed \(names) in \(name).", table: "DeveloperID")
                    : String(localized: "Committed \(names) in \(name).", table: "DeveloperID"))
            }
            parts += problems
            if !parts.isEmpty { outcome.messages.append(parts.joined(separator: " ")) }
        }
        return outcome
    }

    /// git's complaint after `verb`, saying so when it is about signing in.
    nonisolated static func describe(_ output: Git.Output, verb: String) -> String {
        guard Git.isAuthenticationFailure(output.stderr) else { return "\(verb): \(output.problem)." }
        return String(localized: "\(verb): git couldn't sign in to the remote (\(output.problem)). orgstar can't answer prompts; use an SSH key in the agent or a credential helper.", table: "DeveloperID")
    }

    /// `Update a.org, b.org`, or `Update N files` with the paths in the body.
    nonisolated static func message(_ paths: [String]) -> String {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        if paths.count <= 3 { return "Update " + names.joined(separator: ", ") }
        return "Update \(paths.count) files\n\n" + paths.joined(separator: "\n")
    }
}
#endif
