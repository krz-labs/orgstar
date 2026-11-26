import Foundation
import OrgCore
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

    /// A finding's trust as the panels show it: org-lint's high trust as an error, low as a warning.
    public static func severity(_ finding: LintFinding) -> String {
        finding.trust == .high ? String(localized: "Error", comment: "Lint File: a problem org-lint trusts highly") : String(localized: "Warning", comment: "Lint File: a problem that may be intended")
    }

    /// The panels' summary line.
    public static func summary(_ findings: [LintFinding]) -> String {
        findings.isEmpty ? String(localized: "No problems found", comment: "Lint File") : String(localized: "\(findings.count) problems", comment: "Lint File: the number of problems found")
    }
}
