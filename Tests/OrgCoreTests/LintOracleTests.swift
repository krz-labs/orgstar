import Foundation
import Testing
@testable import OrgCore

/// orgstar's checkers against `org-lint` in Emacs, on the same files: the same lines for every
/// checker both have.
struct LintOracleTests {
    static let enabled = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil && EmacsOracle.isAvailable

    static let script = #"""
    ;;; -*- lexical-binding: t -*-
    (require 'org)
    (require 'org-lint)
    (require 'json)
    (setq org-todo-keywords '((sequence "TODO" "DONE"))
          org-id-locations-file (make-temp-file "orgstar-id-locations"))
    (let ((results nil))
      (dolist (file (split-string (getenv "ORACLE_FILES") "\n" t))
        (with-current-buffer (find-file-noselect file)
          (org-mode)
          (let ((lines nil))
            (dolist (r (org-lint))
              (let ((v (cadr r)))
                (push (format "%s %s" (aref v 0) (org-lint-checker-name (aref v 3))) lines)))
            (push (vconcat (nreverse lines)) results))
          (kill-buffer)))
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-file (getenv "ORACLE_OUTPUT")
          (insert (json-encode (vconcat (nreverse results)))))))
    """#

    /// `org-lint`'s reports for each file, as "LINE CHECKER".
    static func orgLint(_ files: [URL]) throws -> [[String]] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scriptURL = folder.appendingPathComponent("lint.el"), output = folder.appendingPathComponent("out.json")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let log = try EmacsOracle.run(["-Q", "--batch", "-l", scriptURL.path],
                                      environment: ["ORACLE_FILES": files.map(\.path).joined(separator: "\n"), "ORACLE_OUTPUT": output.path, "TZ": "UTC"])
        guard let data = try? Data(contentsOf: output) else { throw EmacsOracle.EvaluateError(log: log) }
        return try JSONDecoder().decode([[String]].self, from: data)
    }

    /// The checkers both have. Not invalid-id-link: `org-id-find-id-file` falls back to the
    /// file being linted for an ID it doesn't know, so what org-lint reports depends on org-id's
    /// saved locations; `idLinksResolveThroughTheIndex` covers orgstar's.
    static let shared: Set<String> = Set(LintChecker.allCases.filter { $0.isOrgLint && $0 != .invalidIDLink }.map(\.rawValue))

    static func ours(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return OrgLint.lint(text, tree: OrgParser.parse(text), path: url.path).map { "\($0.line) \($0.checker.rawValue)" }
    }

    /// Both sides' reports for the checkers both have, sorted.
    static func compare(_ files: [URL]) throws {
        let theirs = try orgLint(files)
        for (file, reports) in zip(files, theirs) {
            let expected = reports.filter { shared.contains(String($0.split(separator: " ")[1])) }.sorted()
            let actual = try ours(file).filter { shared.contains(String($0.split(separator: " ")[1])) }.sorted()
            #expect(actual == expected, "\(file.lastPathComponent)")
        }
    }

    static func folder(_ files: [String: String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-lint-\(UUID().uuidString)").resolvingSymlinksInPath()
        for (name, text) in files {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return folder
    }

    @Test(.enabled(if: enabled)) func corpusMatchesOrgLint() throws {
        let folder = try Self.folder(LintTests.corpus.merging(["exists.org": "* Here\n", "data/ab/cdef/photo.png": ""]) { $1 })
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.compare(LintTests.corpus.keys.sorted().map { folder.appendingPathComponent($0) })
    }

    @Test(.enabled(if: enabled)) func conformanceFilesMatchOrgLint() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Conformance")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".org") }.sorted()
        try Self.compare(files.map { folder.appendingPathComponent($0) })
    }
}
