import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp
@testable import OrgPrograms

/// Runs each test with `Programs` as the session's runner, scoped to the test's task so
/// suites without one are unaffected.
struct WithPrograms: SuiteTrait, TestTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await DocumentSession.$scopedPrograms.withValue(Programs()) { try await function() }
    }
}

extension Trait where Self == WithPrograms {
    static var programs: Self { WithPrograms() }
}

@MainActor
@Suite(.programs)
struct EmacsFallbackTests {
    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func recalculatesTablesNativeCodeCannot() async throws {
        let notes = try Folder()
        let file = try notes.write("t.org", "* Prices\n| item | n | twice |\n|------+---+-------|\n| x | a | |\n| y | 2 | |\n#+TBLFM: $3=floor($2)\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let step = session.perform(TableRecalculate(all: true), path: file.path, at: 50, expect: nil)
        guard case .external(.emacsTable(let table, let point, let form, let reason, let lisp, _, _)) = step else {
            Issue.record("\(step)")
            return
        }
        #expect(reason == "function floor of a formula")
        #expect(!lisp)
        let message = await session.recalculateInEmacs(table: table, point: point, form: form)
        #expect(message == "Recalculated in Emacs")
        #expect(session.document?.text == "* Prices\n| item | n | twice    |\n|------+---+----------|\n| x    | a | floor(a) |\n| y    | 2 | 2        |\n#+TBLFM: $3=floor($2)\n")
    }

    /// `elisp:` links run in Emacs, in a copy of the file with point at the caret; in
    /// orgstar's interpreter when Emacs is missing.
    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func evaluatesElispLinks() async throws {
        let notes = try Folder()
        let file = try notes.write("l.org", "* Head\nSee [[elisp:(org-get-heading t t)]].\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let heading = await session.evaluateLink("(org-get-heading t t)")
        #expect(heading == "(org-get-heading t t) => Head")
        let list = await session.evaluateLink("(list 1 \"a\")")
        #expect(list == "(list 1 \"a\") => (1 a)")
        let error = await session.evaluateLink("(car 1)")
        #expect(error == "Wrong type argument: listp, 1")
        await DocumentSession.$scopedPrograms.withValue(Programs(emacs: { nil })) {
            #expect(await session.evaluateLink("(+ 1 2)") == "(+ 1 2) => 3")
            #expect(await session.evaluateLink("(org-get-heading t t)") == "This link uses Emacs Lisp that runs only in Emacs.")
        }
    }

    /// Emacs can run each compiled language and interpreter orgstar runs, for `org-sbe`.
    @Test(.enabled(if: EmacsRunner.executable() != nil))
    func loadsEveryLanguageForOrgSbe() throws {
        let languages = ["C", "C++", "D", "fortran", "java", "clojure", "awk", "js", "python", "R", "ruby", "sh", "bash"]
        let process = Process()
        process.executableURL = EmacsRunner.executable()
        process.arguments = ["-Q", "--batch", "--eval", "(progn (require 'org) " + EmacsRunner.sbeLanguages
            + " (princ (mapconcat (lambda (l) (if (fboundp (intern (concat \"org-babel-execute:\" l))) \"\" l)) '(" + languages.map { "\"\($0)\"" }.joined(separator: " ") + ") \"\")))"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "")
    }

    /// `org-sbe` on a block only Emacs runs: Emacs runs it without asking again.
    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func runsOtherLanguagesForOrgSbe() async throws {
        let notes = try Folder()
        let text = "#+NAME: f\n#+begin_src sh :var n=2\necho $((n * 3))\n#+end_src\n\n| n | f |\n|---+---|\n| 3 | |\n#+TBLFM: $2='(org-sbe f (n $1))\n"
        let file = try notes.write("t.org", text)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let step = session.perform(TableRecalculate(all: true), path: file.path, at: (text as NSString).range(of: "#+TBLFM").location + 3, expect: nil)
        guard case .external(.emacsTable(let table, let point, let form, let reason, let lisp, _, _)) = step else {
            Issue.record("\(step)")
            return
        }
        #expect(reason == "Lisp org-sbe with sh blocks")
        #expect(lisp)
        #expect(await session.recalculateInEmacs(table: table, point: point, form: form) == "Recalculated in Emacs")
        #expect(session.document?.text.hasSuffix("| n | f |\n|---+---|\n| 3 | 9 |\n#+TBLFM: $2='(org-sbe f (n $1))\n") == true)
    }

    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func cancelingARecalculationLeavesTheTable() async throws {
        let notes = try Folder()
        let text = "| n | twice |\n|---+-------|\n| a |       |\n#+TBLFM: $2=floor($1)\n"
        let file = try notes.write("t.org", text)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let step = session.perform(TableRecalculate(all: true), path: file.path, at: 2, expect: nil)
        guard case .external(.emacsTable(let table, let point, let form, _, _, _, _)) = step else {
            Issue.record("\(step)")
            return
        }
        let task = Task { await session.recalculateInEmacs(table: table, point: point, form: form) }
        task.cancel()
        #expect(await task.value == "Recalculation canceled")
        #expect(session.document?.text == text)
    }
}

@MainActor
@Suite(.programs)
struct BabelSessionTests {
    @Test func runsBlocksAndWritesResults() async throws {
        let notes = try Folder()
        let file = try notes.write("b.org", "#+begin_src sh\necho answer\necho \"$((6 * 7))\"\n#+end_src\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let step = session.perform(ExecuteSrcBlock(), path: file.path, at: 3, expect: nil)
        guard case .external(.babel(let job)) = step else {
            Issue.record("\(step)")
            return
        }
        #expect(await session.runBabel(job) == "Code block evaluation complete.")
        // A column that is half numbers is right-aligned, as org-table-align does.
        #expect(session.document?.text == "#+begin_src sh\necho answer\necho \"$((6 * 7))\"\n#+end_src\n\n#+RESULTS:\n| answer |\n|     42 |\n")
    }
}

@MainActor
@Suite(.programs)
struct BabelErrorTests {
    func job(_ session: DocumentSession, _ path: String) throws -> BabelJob {
        guard case .external(.babel(let job)) = session.perform(ExecuteSrcBlock(), path: path, at: 3, expect: nil) else {
            throw CancellationError()
        }
        return job
    }

    /// Like `org-babel-eval`: the results go in, and the error output and status are shown.
    @Test func reportsErrorsAndStillInsertsResults() async throws {
        let notes = try Folder()
        let file = try notes.write("e.org", "#+begin_src sh\necho out\necho oops >&2\nexit 3\n#+end_src\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        #expect(await session.runBabel(try job(session, file.path)) == "Exited with status 3: oops")
        #expect(session.document?.text.hasSuffix("#+RESULTS:\n: out\n") == true)
    }

    @Test func cancelsARunningBlock() async throws {
        let notes = try Folder()
        let file = try notes.write("s.org", "#+begin_src sh\nsleep 20\necho late\n#+end_src\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let start = ContinuousClock.now
        var message: String?
        session.startBabel(try job(session, file.path)) { message = $0 }
        #expect(session.isRunningBabel)
        try await Task.sleep(for: .milliseconds(200))
        session.cancelBabel()
        while message == nil, ContinuousClock.now - start < .seconds(5) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(message == "Code block canceled.")
        #expect(!session.isRunningBabel)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(session.document?.text.contains("#+RESULTS:") == false)
    }
}

struct EmacsExportTests {
    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func exportsBesideTheFile() async throws {
        let notes = try Folder()
        let file = try notes.write("doc.org", "#+TITLE: On disk\n")
        // The buffer's text is exported, not the file's.
        let written = try await EmacsRunner.export(text: "#+TITLE: In the buffer\n\n* Heading\nBody.\n", path: file.path, function: "org-ascii-export-to-ascii")
        #expect(URL(fileURLWithPath: written).lastPathComponent == "doc.txt")
        let text = try String(contentsOfFile: written, encoding: .utf8)
        #expect(text.uppercased().contains("IN THE BUFFER") && text.contains("Body."), "\(text)")
        #expect(try String(contentsOf: file, encoding: .utf8) == "#+TITLE: On disk\n")
    }

    /// The dispatcher's `C-s` and `C-b`: the subtree at point alone, its EXPORT_FILE_NAME used.
    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func exportsTheSubtreeBodyOnly() async throws {
        let notes = try Folder()
        let file = try notes.write("doc.org", "")
        let text = "#+TITLE: Doc\n* Ünï\nFirst.\n* Second\n:PROPERTIES:\n:EXPORT_FILE_NAME: second\n:END:\nOnly this.\n"
        let point = (text as NSString).substring(to: (text as NSString).range(of: "Only").location).unicodeScalars.count + 1
        let written = try await EmacsRunner.export(text: text, path: file.path, function: "org-ascii-export-to-ascii", subtree: point, bodyOnly: true)
        #expect(URL(fileURLWithPath: written).lastPathComponent == "second.txt")
        let out = try String(contentsOfFile: written, encoding: .utf8)
        #expect(out.contains("Only this.") && !out.contains("First.") && !out.uppercased().contains("DOC"), "\(out)")
    }

    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func exportUsesBabelPath() async throws {
        let notes = try Folder()
        let file = try notes.write("doc.org", "")
        let function = #"(lambda () (with-temp-file "path.txt" (insert (getenv "PATH"))) "path.txt")"#
        let written = try await EmacsRunner.export(text: "", path: file.path, function: function)
        #expect(try String(contentsOfFile: written, encoding: .utf8) == BabelRunner.environment["PATH"])
    }

    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func cancellingStopsTheExport() async throws {
        let notes = try Folder()
        let file = try notes.write("doc.org", "")
        let pidFile = notes.url.appendingPathComponent("pid")
        let function = #"(lambda () (with-temp-file "pid" (insert (number-to-string (emacs-pid)))) (sleep-for 60) "x")"#
        let export = Task { try await EmacsRunner.export(text: "", path: file.path, function: function) }
        var pid: pid_t?
        for _ in 0..<200 where pid == nil {
            try await Task.sleep(for: .milliseconds(50))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0) }
        }
        let started = try #require(pid)
        export.cancel()
        await #expect(throws: CancellationError.self) { try await export.value }
        var alive = true
        for _ in 0..<100 where alive {
            alive = kill(started, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!alive)
    }
}

/// js runs in JavaScriptCore when its interpreter isn't installed, and in node when it is.
struct JavaScriptFallbackTests {
    func run(_ text: String) async throws -> BabelOutput {
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .success(let job) = Babel.plan(context) else { throw Babel.Failure.message("not planned") }
        return try await Programs().runBabel(job, fileDirectory: FileManager.default.temporaryDirectory)
    }

    @Test func runsWithoutTheInterpreter() async throws {
        #expect(try await run("#+begin_src js :cmd no-such-node\nreturn [1, 2]\n#+end_src\n").stdout == "[ 1, 2 ]")
        #expect(try await run("#+begin_src js :cmd no-such-node :session s\n6 * 7\n#+end_src\n").resultFile == "42")
    }

    /// A `:cmd` with arguments isn't run in JavaScriptCore, which can't take node's options.
    @Test func leavesACommandWithArgumentsToTheRunner() async throws {
        let error = await #expect(throws: BabelRunner.Failure.self) {
            try await run("#+begin_src js :cmd \"no-such-node --no-warnings\" :results output\nconsole.log(1)\n#+end_src\n")
        }
        #expect(error?.description == "no-such-node --no-warnings isn't installed.")
    }

    @Test(.enabled(if: BabelRunner.installed("node")))
    func usesNodeWhenInstalled() async throws {
        #expect(try await run("#+begin_src js :results output\nconsole.log(typeof require('fs').readFileSync)\n#+end_src\n").stdout == "function\n")
    }

    /// A `:cmd` the shell expands, such as `~/../../opt/homebrew/bin/node`, runs node, as in Org.
    @Test(.enabled(if: BabelRunner.installed("node")))
    func expandsTheCommandAsTheShellDoes() async throws {
        let node = try #require(BabelRunner.environment["PATH"]?.split(separator: ":").map { "\($0)/node" }
            .first { FileManager.default.isExecutableFile(atPath: $0) })
        let home = NSHomeDirectory()
        let up = String(repeating: "../", count: home.split(separator: "/").count)
        for cmd in ["~/" + up + node.dropFirst(), "$HOME/" + up + node.dropFirst(), "'\(node)'"] {
            let output = try await run("#+begin_src js :cmd \"\(cmd)\" :results output\nconsole.log(typeof __filename)\n#+end_src\n")
            #expect(output.stdout == "string\n", "\(cmd)")
        }
    }

    /// An expanded `:cmd` that isn't installed runs in JavaScriptCore.
    @Test func expandedCommandFallsBack() async throws {
        #expect(try await run("#+begin_src js :cmd ~/no-such-node\nreturn [1, 2]\n#+end_src\n").stdout == "[ 1, 2 ]")
    }
}

/// Interpreters run through `/bin/sh`, as Org runs them.
struct ShellCommandTests {
    @Test func words() {
        #expect(BabelRunner.words("node --no-warnings") == ["node", "--no-warnings"])
        #expect(BabelRunner.words("~/bin/node") == [NSHomeDirectory() + "/bin/node"])
        #expect(BabelRunner.words("'a b' \"$HOME\"") == ["a b", NSHomeDirectory()])
    }

    /// A command substitution in the command runs once, when the block runs, as in Org.
    @Test(arguments: ["js :cmd", "python :python", "ruby :ruby"])
    func substitutionRunsOnce(header: String) async throws {
        #expect(BabelRunner.words("$(echo node)").isEmpty)
        #expect(BabelRunner.words("`echo node`").isEmpty)
        let folder = try Folder()
        let count = folder.url.appendingPathComponent("count").path
        let text = "#+begin_src \(header) \"$(echo x >> '\(count)'; echo cat)\" :results output\n1\n#+end_src\n"
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .success(let job) = Babel.plan(context) else { throw Babel.Failure.message("not planned") }
        _ = try await Programs().runBabel(job, fileDirectory: folder.url)
        #expect(try String(contentsOfFile: count, encoding: .utf8) == "x\n")
    }

    @Test(.enabled(if: BabelRunner.installed("python3")))
    func pythonWithOptions() async throws {
        let text = "#+begin_src python :python \"python3 -X utf8\" :results output\nimport sys\nprint(sys.flags.utf8_mode)\n#+end_src\n"
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .success(let job) = Babel.plan(context) else { throw Babel.Failure.message("not planned") }
        #expect(try await BabelRunner.run(job, fileDirectory: FileManager.default.temporaryDirectory).stdout == "1\n")
    }

    /// Standard input is a file, as `org-babel-eval` gives it.
    @Test(.enabled(if: BabelRunner.installed("node")))
    func standardInputIsAFile() async throws {
        let text = "#+begin_src js :results output\nconst s = require('fs').fstatSync(0)\nconsole.log(s.isFile(), s.isFIFO(), process.stdin.constructor.name)\n#+end_src\n"
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .success(let job) = Babel.plan(context) else { throw Babel.Failure.message("not planned") }
        #expect(try await BabelRunner.run(job, fileDirectory: FileManager.default.temporaryDirectory).stdout == "true false ReadStream\n")
    }
}

/// js blocks without a session run as `node FILE`, as `org-babel-execute:js` runs them.
@MainActor
@Suite(.programs)
struct NodeFileTests {
    static let cases = [
        "#+begin_src js :results output\nconsole.log(typeof require, typeof module, typeof exports, process.argv.length, require.main === module)\n#+end_src\n",
        "#+begin_src js :results output\nconst path = require('path'), fs = require('fs')\nconsole.log(path.dirname(__filename) === __dirname, __dirname === process.cwd(), "
            + "path.dirname(__dirname) === fs.realpathSync(require('os').tmpdir()), path.basename(process.argv[1]) === path.basename(__filename))\n#+end_src\n",
        "#+begin_src js\nreturn [typeof require, typeof module, process.argv.length, this === module.exports]\n#+end_src\n",
        "#+begin_src js :results output\ntry { require('./helper'); console.log('found') } catch (e) { console.log(e.code) }\nconsole.log(require(process.cwd() + '/helper'))\n#+end_src\n",
        "#+begin_src js :results output\nimport os from 'os'\nconsole.log(typeof require, typeof os.tmpdir)\n#+end_src\n",
        "#+begin_src js :cmd \"node --no-warnings\" :results output\nconsole.log(process.argv.length, process.execArgv.join(' '))\n#+end_src\n",
        "#+begin_src js :results output\nconsole.log(JSON.stringify(require('fs').readFileSync(0, 'utf8')))\n#+end_src\n",
        "#+begin_src js :results output\nconsole.log('top'); return; console.log('not reached')\n#+end_src\n",
        "#+begin_src js :results output\nconst s = require('fs').fstatSync(0)\nconsole.log(s.isFile(), s.isFIFO(), process.stdin.constructor.name)\n#+end_src\n",
    ]

    /// The results Emacs inserts. `org-babel-temporary-directory` is set as interactive Emacs
    /// sets it; `--batch` leaves it nil and writes the file straight into the temporary folder.
    @Test(.enabled(if: EmacsRunner.executable() != nil && BabelRunner.installed("node") && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func resultsMatchEmacs() async throws {
        let folder = try Folder()
        try folder.write("helper.js", "module.exports = 1\n")
        var forms: [String] = []
        var ours: [String] = []
        for text in Self.cases {
            let file = try folder.write("b.org", text)
            let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.url.appendingPathComponent(".r")))
            session.open(file.path)
            guard case .external(.babel(let job)) = session.perform(ExecuteSrcBlock(), path: file.path, at: 2, expect: nil) else {
                Issue.record("not planned: \(text)")
                return
            }
            _ = await session.runBabel(job)
            ours.append(session.document?.text ?? "")
            let quoted = "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            forms.append("(with-temp-buffer (insert \(quoted)) (org-mode) (goto-char 3) (org-babel-execute-src-block) (princ (concat (buffer-string) \"\\f\")))")
        }
        let process = Process()
        process.executableURL = EmacsRunner.executable()
        process.currentDirectoryURL = folder.url
        process.arguments = ["-Q", "--batch", "--eval", """
            (progn (require 'org) (require 'ob-js)
              (setq org-confirm-babel-evaluate nil org-babel-js-cmd "node" org-babel-temporary-directory (make-temp-file "babel-" t))
              \(forms.joined(separator: "\n"))
              (delete-directory org-babel-temporary-directory t))
            """]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let emacs = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\u{0C}", omittingEmptySubsequences: false).map(String.init)
        process.waitUntilExit()
        for (i, text) in Self.cases.enumerated() {
            #expect(ours[i] == emacs[i], "\(text)\nours:\n\(ours[i])\nemacs:\n\(emacs[i])")
        }
    }

    /// The file is gone once the block has run.
    @Test(.enabled(if: BabelRunner.installed("node")))
    func removesTheFile() async throws {
        let text = "#+begin_src js :results output\nconsole.log(__filename)\n#+end_src\n"
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .success(let job) = Babel.plan(context) else { throw Babel.Failure.message("not planned") }
        let output = try await BabelRunner.run(job, fileDirectory: FileManager.default.temporaryDirectory)
        let file = output.stdout.trimmingCharacters(in: .newlines)
        #expect(file.hasPrefix("/") && !FileManager.default.fileExists(atPath: file))
    }
}

/// Emacs Lisp runs in `Elisp` when Emacs isn't installed.
struct EmacsLispFallbackTests {
    func run(_ text: String) async throws -> BabelOutput {
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .success(let job) = Babel.plan(context) else { throw Babel.Failure.message("not planned") }
        return try await Programs(emacs: { nil }).runBabel(job, fileDirectory: FileManager.default.temporaryDirectory)
    }

    @Test func runsWithoutEmacs() async throws {
        #expect(try await run("#+begin_src emacs-lisp\n(cl-loop for i from 1 to 4 sum i)\n#+end_src\n").stdout.contains("\"s\":\"10\""))
    }

    @Test func refusesWhatOnlyEmacsRuns() async throws {
        let error = await #expect(throws: BabelRunner.Failure.self) {
            try await run("#+begin_src emacs-lisp\n(with-temp-buffer (insert \"x\") (buffer-string))\n#+end_src\n")
        }
        #expect(error?.description == "This block uses Emacs Lisp that runs only in Emacs, and Emacs isn't installed.")
    }
}
