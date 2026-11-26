import Foundation
import OrgCore
import OrgDocument
import OrgIndex
import Testing
@testable import OrgApp

/// org-roam itself, run in Emacs, when it's installed: the load-path directories in
/// `ORGSTAR_ROAM` (colon-separated), else a Doom (straight) install.
enum RoamOracle {
    static let packages = ["org-roam", "emacsql", "magit-section", "dash", "compat", "llama", "cond-let"]

    static let loadPath: [String]? = {
        if let paths = ProcessInfo.processInfo.environment["ORGSTAR_ROAM"] { return paths.split(separator: ":").map(String.init) }
        let fm = FileManager.default, home = NSHomeDirectory()
        let roots = ["\(home)/.config/emacs/.local/straight", "\(home)/.emacs.d/.local/straight"].flatMap { root in
            ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasPrefix("build-") && !$0.hasSuffix(".el") }.sorted().reversed().map { "\(root)/\($0)" }
        }
        for root in roots {
            let dirs = packages.map { "\(root)/\($0)" }.filter { fm.fileExists(atPath: $0) }
            if dirs.first == "\(root)/org-roam", dirs.count >= 5 { return dirs }
        }
        return nil
    }()

    static var enabled: Bool { loadPath != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil }

    /// Runs `body` with org-roam loaded, `org-roam-directory` at `folder`, its database and
    /// `org-id-locations-file` in a folder beside it, and the database synced.
    static func run(_ folder: URL, _ body: String) throws -> String {
        let paths = loadPath!.map(\.debugDescription).joined(separator: " ")
        let state = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "-state").path
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        return try DailiesTests.emacs("""
            (progn (setq load-path (append (list \(paths)) load-path) make-backup-files nil auto-save-default nil create-lockfiles nil
                         coding-system-for-read 'utf-8 coding-system-for-write 'utf-8 org-id-locations-file \((state + "/ids").debugDescription))
              (require 'org-roam) (require 'org-roam-dailies)
              (setq org-roam-directory \((folder.path + "/").debugDescription) org-roam-db-location \((state + "/db.sqlite").debugDescription))
              (org-roam-db-sync)
              \(body))
            """)
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-roam-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "-state"))
    }

    /// IDs as one placeholder, since each side makes its own.
    static func withoutIDs(_ text: String) -> String {
        text.replacing(/(?m)^:ID:[ \t]+\S+$/, with: ":ID: x")
    }
}

struct RoamOracleTests {
    static let files: [(name: String, text: String)] = [
        ("a.org", """
            :PROPERTIES:
            :ID: f1
            :ROAM_ALIASES: "Alias One" two "say \\"hi\\""
            :ROAM_REFS: https://example.com @key2020 [cite:@other2021;@third] [[https://x.org/page][Page]] junk
            :END:
            #+title: File One
            #+filetags: :alpha:beta:
            * Head :gamma:
            :PROPERTIES:
            :ID: h1
            :ROAM_REFS: @headkey
            :END:
            ** Deeper :delta:
            :PROPERTIES:
            :ID: h1b
            :ROAM_ALIASES: Deep
            :END:
            * Excl
            :PROPERTIES:
            :ID: h2
            :ROAM_EXCLUDE: t
            :END:
            ** Child
            :PROPERTIES:
            :ID: h3
            :END:
            * ExNil
            :PROPERTIES:
            :ID: h4
            :ROAM_EXCLUDE: nil
            :END:
            * No ID :epsilon:

            """),
        ("b.org", """
            :PROPERTIES:
            :ID: f2
            :ROAM_EXCLUDE: t
            :END:
            #+title: Excluded file
            * Inside
            :PROPERTIES:
            :ID: h5
            :ROAM_ALIASES: x
            :END:

            """),
        ("c.org", """
            :PROPERTIES:
            :ID: f3
            :END:
            #+title: Third
            * Untitled file's heading
            :PROPERTIES:
            :ID: h6
            :END:

            """),
    ]

    /// Nodes, aliases, refs and tags as org-roam's database has them after `org-roam-db-sync`.
    @Test(.enabled(if: RoamOracle.enabled)) func nodesMatchOrgRoam() throws {
        let folder = try RoamOracle.folder()
        defer { RoamOracle.remove(folder) }
        let store = try IndexStore()
        for file in Self.files {
            let path = folder.appendingPathComponent(file.name).path
            try file.text.write(toFile: path, atomically: true, encoding: .utf8)
            try store.write(FileRecord(path: path, root: folder.path, kind: .org, bytes: Array(file.text.utf8), mtime: 1, settings: IndexSettings()))
        }
        let output = try RoamOracle.run(folder, """
            (dolist (row (org-roam-db-query [:select [id title] :from nodes]))
              (let ((id (car row)))
                (princ (format "%s\\t%s\\t%s\\t%s\\t%s\\n" id (cadr row)
                  (string-join (sort (mapcar #'car (org-roam-db-query [:select alias :from aliases :where (= node-id $s1)] id)) #'string<) "|")
                  (string-join (sort (mapcar (lambda (r) (concat (cadr r) ":" (car r))) (org-roam-db-query [:select [ref type] :from refs :where (= node-id $s1)] id)) #'string<) "|")
                  (string-join (sort (mapcar #'car (org-roam-db-query [:select tag :from tags :where (= node-id $s1)] id)) #'string<) "|")))))
            """)
        let theirs = output.split(separator: "\n").map(String.init).filter { $0.contains("\t") }.sorted()
        let ours = try store.nodes().map { node in
            [node.id, node.title, node.aliases.sorted().joined(separator: "|"), node.refs.sorted().joined(separator: "|"), node.tags.sorted().joined(separator: "|")].joined(separator: "\t")
        }.sorted()
        #expect(!theirs.isEmpty)
        #expect(ours == theirs)
    }

    /// New nodes from `org-roam-capture-` with `:immediate-finish`: a `file+head` template
    /// and a `file+head+olp` one, twice, whose headings are made the first time.
    @MainActor
    @Test(.enabled(if: RoamOracle.enabled)) func captureMatchesOrgRoam() throws {
        let theirs = try RoamOracle.folder(), ours = try RoamOracle.folder()
        defer {
            RoamOracle.remove(theirs)
            RoamOracle.remove(ours)
        }
        _ = try RoamOracle.run(theirs, """
            (setq org-roam-capture-templates
                  '(("d" "default" plain "%?" :target (file+head "${slug}.org" "#+title: ${title}\\n") :unnarrowed t :immediate-finish t)
                    ("p" "project" entry "* ${title} %?\\nbody" :target (file+head+olp "proj.org" "#+title: Projects" ("Work" "Active")) :immediate-finish t)
                    ("e" "plain end" plain "Some ${slug} text" :target (file+head "end-${slug}.org" "#+title: ${title}") :immediate-finish t)))
            (org-roam-capture- :node (org-roam-node-create :title "Field Notes") :keys "d" :props '(:finalize find-file))
            (org-roam-capture- :node (org-roam-node-create :title "Big Thing") :keys "p" :props '(:finalize find-file))
            (org-roam-capture- :node (org-roam-node-create :title "Other Thing") :keys "p" :props '(:finalize find-file))
            (org-roam-capture- :node (org-roam-node-create :title "Café Time") :keys "e" :props '(:finalize find-file))
            """)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: ours.appendingPathComponent(".r")))
        let templates = [
            RoamTemplate(key: "d", name: "default", kind: .plain, template: "%?", file: "${slug}.org", head: "#+title: ${title}\n"),
            RoamTemplate(key: "p", name: "project", kind: .entry, template: "* ${title} %?\nbody", file: "proj.org", head: "#+title: Projects", olp: ["Work", "Active"]),
            RoamTemplate(key: "e", name: "plain end", kind: .plain, template: "Some ${slug} text", file: "end-${slug}.org", head: "#+title: ${title}"),
        ]
        for (key, title) in [("d", "Field Notes"), ("p", "Big Thing"), ("p", "Other Thing"), ("e", "Café Time")] {
            let capture = RoamCapture(templates.filter { $0.key == key }, title: title, directory: ours.path, session: session, refresh: {}) { _, _, _ in }
            if case .failure(let error) = capture.fileFirst() { Issue.record("\(error.message)") }
        }
        for name in ["field_notes.org", "proj.org", "end-cafe_time.org"] {
            var expected = try String(contentsOf: theirs.appendingPathComponent(name), encoding: .utf8)
            let actual = try String(contentsOf: ours.appendingPathComponent(name), encoding: .utf8)
            // A plain template of only `%?` leaves an empty line in Emacs, which orgstar's
            // capture doesn't add, for org-roam or org-capture.
            if name == "field_notes.org", expected.hasSuffix("\n\n") { expected.removeLast() }
            #expect(RoamOracle.withoutIDs(actual) == RoamOracle.withoutIDs(expected), "\(name)")
        }
    }

    /// `org-roam-dailies-capture-date` with two templates into the same day's file, the second
    /// under an outline path.
    @MainActor
    @Test(.enabled(if: RoamOracle.enabled)) func dailiesCaptureMatchesOrgRoam() throws {
        let theirs = try RoamOracle.folder(), ours = try RoamOracle.folder()
        defer {
            RoamOracle.remove(theirs)
            RoamOracle.remove(ours)
        }
        let seconds = Int(DailiesTests.day.timeIntervalSince1970)
        try FileManager.default.createDirectory(at: theirs.appendingPathComponent("daily"), withIntermediateDirectories: true)
        _ = try RoamOracle.run(theirs, """
            (setq org-roam-dailies-capture-templates
                  '(("d" "default" entry "* Note %?" :target (file+head "%<%Y-%m-%d>.org" "#+title: %<%Y-%m-%d>\\n") :immediate-finish t)
                    ("j" "journal" entry "* Entry %?" :target (file+head+olp "%<%Y-%m-%d>.org" "#+title: %<%Y-%m-%d>\\n" ("Journal")) :immediate-finish t)))
            (org-roam-dailies--capture (seconds-to-time \(seconds)) nil "d")
            (org-roam-dailies--capture (seconds-to-time \(seconds)) nil "j")
            (org-roam-dailies--capture (seconds-to-time \(seconds)) nil "d")
            """)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: ours.appendingPathComponent(".r")))
        let directory = ours.appendingPathComponent("daily").path
        let templates = [
            RoamTemplate(key: "d", name: "default", kind: .entry, template: "* Note %?", file: "%<%Y-%m-%d>.org", head: "#+title: %<%Y-%m-%d>\n"),
            RoamTemplate(key: "j", name: "journal", kind: .entry, template: "* Entry %?", file: "%<%Y-%m-%d>.org", head: "#+title: %<%Y-%m-%d>\n", olp: ["Journal"]),
        ]
        for key in ["d", "j", "d"] {
            let capture = RoamCapture(templates.filter { $0.key == key }, title: "", directory: directory, now: DailiesTests.day, session: session, refresh: {}) { _, _, _ in }
            if case .failure(let error) = capture.fileFirst() { Issue.record("\(error.message)") }
        }
        let expected = try String(contentsOf: theirs.appendingPathComponent("daily/2026-10-11.org"), encoding: .utf8)
        let actual = try String(contentsOf: ours.appendingPathComponent("daily/2026-10-11.org"), encoding: .utf8)
        #expect(RoamOracle.withoutIDs(actual) == RoamOracle.withoutIDs(expected))
    }
}
