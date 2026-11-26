import Foundation
import OrgCore
import OrgDocument
import OrgIndex

/// Lint File in the apps: the checkers run over an open file's text off the main actor, with
/// the file system and the workspace index for IDs in other files.
public enum FileLint {
    /// The checkers' environment: the file system, IDs through `index` (unsaved buffers'
    /// from `overlay`), and the attachment and crypt settings.
    public static func environment(index: IndexStore?, overlay: [String: FileRecord] = [:], defaults: UserDefaults = .standard) -> LintEnvironment {
        var environment = LintEnvironment.fileSystem
        environment.attachIDDir = OrgPreferences.attachIDDir(defaults)
        environment.attachInherit = OrgPreferences.attachUseInheritance(defaults)
        environment.cryptTag = OrgPreferences.cryptTag(defaults)
        if let index {
            environment.idFiles = { id in ((try? index.headings(withID: id, overlay: overlay)) ?? []).map(\.path) }
        }
        return environment
    }

    /// Whether Lint File applies to the file at `path`: Org files, and encrypted ones once
    /// decrypted in memory.
    public static func applies(to path: String?) -> Bool {
        guard let path else { return false }
        return path.hasSuffix(".org") || path.hasSuffix(".org_archive") || path.hasSuffix(".org.gpg")
    }

    /// The findings in `text`, off the main actor.
    @concurrent
    public static func lint(_ text: String, tree: OrgTree, path: String?, environment: LintEnvironment) async -> [LintFinding] {
        OrgLint.lint(text, tree: tree, path: path, environment: environment)
    }

    /// One file's findings in Lint All Folders.
    public struct FileFindings: Sendable, Identifiable {
        public let path: String
        public let findings: [LintFinding]
        public var id: String { path }
    }

    /// The files Lint All Folders checks: the indexed Org files and archives. Encrypted files
    /// (`.org.gpg`) are left out.
    public static func folderPaths(_ files: [FileEntry]) -> [String] {
        files.filter { ($0.kind == .org || $0.kind == .archive) && applies(to: $0.path) && !CryptVault.isEncryptedFile($0.path) }.map(\.path).sorted()
    }

    /// How Lint All Folders names each file: its path below its folder, after the folder's name
    /// when there are several folders.
    public static func names(_ files: [FileEntry]) -> [String: String] {
        let several = Set(files.map(\.root)).count > 1
        return Dictionary(files.map { ($0.path, several ? "\(($0.root as NSString).lastPathComponent)/\($0.relativePath)" : $0.relativePath) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Lint All Folders: the findings in each of `paths`, read from disk or, for an open file,
    /// from `texts`, off the main actor and several files at a time. Files with none are left
    /// out. An orphaned attachment folder is reported once, by the first file that finds it.
    /// `progress` is told the number of files checked so far. Throws `CancellationError` when
    /// the task is cancelled.
    @concurrent
    public static func lint(
        paths: [String], texts: [String: String], defaults: OrgSettings = .default, environment: LintEnvironment,
        progress: @escaping @Sendable (Int) async -> Void = { _ in }
    ) async throws -> [FileFindings] {
        let chunk = 32
        let chunks = stride(from: 0, to: paths.count, by: chunk).map { Array(paths[$0..<min($0 + chunk, paths.count)]) }
        var results = [[FileFindings]](repeating: [], count: chunks.count)
        try await withThrowingTaskGroup(of: (Int, [FileFindings]).self) { group in
            var next = 0
            func add() {
                guard next < chunks.count else { return }
                let index = next, paths = chunks[index]
                next += 1
                group.addTask {
                    var found: [FileFindings] = []
                    for path in paths {
                        try Task.checkCancellation()
                        guard let text = texts[path] ?? (try? String(contentsOfFile: path, encoding: .utf8)) else { continue }
                        let findings = OrgLint.lint(text, tree: OrgParser.parse(text, defaults: defaults), path: path, environment: environment)
                        if !findings.isEmpty { found.append(FileFindings(path: path, findings: findings)) }
                    }
                    return (index, found)
                }
            }
            for _ in 0..<max(1, ProcessInfo.processInfo.activeProcessorCount) { add() }
            var done = 0
            while let (index, found) = try await group.next() {
                results[index] = found
                done += chunks[index].count
                await progress(done)
                try Task.checkCancellation()
                add()
            }
        }
        var folders: Set<String> = []
        return results.joined().compactMap { file in
            let findings = file.findings.filter { $0.folder.map { folders.insert($0).inserted } ?? true }
            return findings.isEmpty ? nil : FileFindings(path: file.path, findings: findings)
        }
    }

    /// A finding's trust as the panels show it: org-lint's high trust as an error, low as a warning.
    public static func severity(_ finding: LintFinding) -> String {
        finding.trust == .high ? String(localized: "Error", comment: "Lint File: a problem org-lint trusts highly") : String(localized: "Warning", comment: "Lint File: a problem that may be intended")
    }

    /// The panels' summary line.
    public static func summary(_ findings: [LintFinding]) -> String {
        findings.isEmpty ? String(localized: "No problems found", comment: "Lint File") : String(localized: "\(findings.count) problems", comment: "Lint File: the number of problems found")
    }
}

/// Lint All Folders as the panels run it: every indexed Org file checked off the main actor,
/// with progress, until it finishes or is stopped.
@MainActor
@Observable
public final class FolderLint {
    /// The files with findings, by path; nil until a run finishes.
    public private(set) var files: [FileLint.FileFindings]?
    public private(set) var checked = 0
    public private(set) var total = 0
    public private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Counts runs, so a stopped run's last progress doesn't show in the next.
    @ObservationIgnored private var run = 0

    public init() {}

    /// Checks every indexed file again; open files as their buffers have them.
    public func run(workspace: WorkspaceModel, session: DocumentSession) {
        task?.cancel()
        let paths = FileLint.folderPaths(workspace.files)
        let open = session.openDocuments
        let texts = Dictionary(open.map { ($0.path, $0.document.text) }, uniquingKeysWith: { first, _ in first })
        let environment = FileLint.environment(index: workspace.index, overlay: workspace.overlay(open))
        let defaults = session.defaults
        files = nil
        checked = 0
        total = paths.count
        isRunning = true
        run += 1
        let run = run
        task = Task { [weak self] in
            let found = try? await FileLint.lint(paths: paths, texts: texts, defaults: defaults, environment: environment) { [weak self] checked in
                await self?.progressed(checked, run: run)
            }
            guard let self, let found, !Task.isCancelled else { return }
            files = found
            isRunning = false
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func progressed(_ count: Int, run: Int) {
        if run == self.run { checked = count }
    }

    /// The panels' summary line.
    public var summary: String {
        guard let files else {
            return isRunning
                ? String(localized: "Checked \(checked) of \(total) files", comment: "Lint All Folders: progress")
                : String(localized: "Stopped after \(checked) of \(total) files", comment: "Lint All Folders: stopped before the end")
        }
        let findings = files.flatMap(\.findings)
        if findings.isEmpty { return String(localized: "No problems found in \(total) files", comment: "Lint All Folders") }
        return String(localized: "\(FileLint.summary(findings)) in \(files.count) of \(total) files", comment: "Lint All Folders: the number of problems, files with problems, files checked")
    }
}
