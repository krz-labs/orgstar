import Foundation
import OrgCore
import OrgDocument
import OrgMathJax
import Testing
@testable import OrgApp

/// Serial: the blocks share one Pyodide, which some tests stop.
@MainActor
@Suite(.serialized)
struct PythonBlocksTests {
    init() {
        PythonBlocks.folder = OrgMathJax.pyodide
    }

    func job(_ text: String) throws -> BabelJob {
        let caret = (text as NSString).range(of: "#+begin_src").location + 2
        return try Babel.plan(EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])).get()
    }

    func output(_ text: String, timeout: Duration = .seconds(300)) async throws -> BabelOutput {
        try #require(try await PythonBlocks.run(job(text), directory: FileManager.default.temporaryDirectory, timeout: timeout))
    }

    /// The text the block's result adds to `text`.
    func run(_ text: String) async throws -> String {
        let job = try job(text)
        let output = try #require(try await PythonBlocks.run(job, directory: FileManager.default.temporaryDirectory))
        return added(text, job, output)
    }

    func added(_ text: String, _ job: BabelJob, _ output: BabelOutput) -> String {
        guard case .success(let edits) = Babel.finish(job, output: output, text: text) else { return "" }
        let new = edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
        return String(new.dropFirst(text.count))
    }

    #if os(macOS)
    nonisolated static let python3 = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// `job` in `python3`, as `BabelRunner` runs it: the program on standard input, the value
    /// in a file.
    func installed(_ job: BabelJob) throws -> BabelOutput {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-python-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = folder.appendingPathComponent("result")
        let files = ["stdin", "stdout", "stderr"].map { folder.appendingPathComponent($0) }
        try job.input.replacingOccurrences(of: Babel.resultFileToken, with: result.path).write(to: files[0], atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: files[1].path, contents: nil)
        FileManager.default.createFile(atPath: files[2].path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Self.python3))
        process.currentDirectoryURL = folder
        process.standardInput = try FileHandle(forReadingFrom: files[0])
        process.standardOutput = try FileHandle(forWritingTo: files[1])
        process.standardError = try FileHandle(forWritingTo: files[2])
        try process.run()
        process.waitUntilExit()
        return BabelOutput(stdout: try String(contentsOf: files[1], encoding: .utf8), resultFile: try? String(contentsOf: result, encoding: .utf8),
                           stderr: try String(contentsOf: files[2], encoding: .utf8), status: process.terminationStatus)
    }

    nonisolated static let tbl = "#+NAME: tbl\n| a | b |\n|---+---|\n| 1 | x |\n| 2 | y |\n\n"

    /// Blocks without a session, as `BabelTests` and `BabelScriptTests` run them against Emacs.
    @Test(.enabled(if: python3 != nil), arguments: [
        "#+begin_src python\nreturn 42\n#+end_src\n",
        "#+begin_src python\nreturn 'hello'\n#+end_src\n",
        "#+begin_src python\nreturn [[1, 2], [3, 4]]\n#+end_src\n",
        "#+begin_src python\nreturn [1, 'a', 2.5]\n#+end_src\n",
        "#+begin_src python\nreturn 1/3\n#+end_src\n",
        "#+begin_src python\nx = 2\nif x:\n    return x * 21\n#+end_src\n",
        "#+begin_src python :results output\nprint('one')\nprint('two')\n#+end_src\n",
        "#+begin_src python :results output\nfor i in range(12): print(i)\n#+end_src\n",
        "#+begin_src python :var n=3 :var s=\"hi\"\nreturn s * n\n#+end_src\n",
        "#+NAME: nums\n| 1 | 2 |\n| 3 | 4 |\n\n#+begin_src python :var t=nums\nreturn [[c * 10 for c in r] for r in t]\n#+end_src\n",
        "#+begin_src python :results list\nreturn ['a', 'b']\n#+end_src\n",
        "#+begin_src python :results verbatim\nreturn [1, 2]\n#+end_src\n",
        "#+begin_src python\ns = '''multi\n  line'''\nreturn s\n#+end_src\n",
        "#+begin_src python\nreturn None\n#+end_src\n",
        "#+begin_src python :results pp\nreturn {'k': list(range(30)), 'v': 'text'}\n#+end_src\n",
        "#+begin_src python :results list\nreturn {'a': 1, 'b': 2}\n#+end_src\n",
        "#+begin_src python :results table\nreturn {'a': 1, 'b': 2}\n#+end_src\n",
        "#+begin_src python :return x\nx = 'returned'\n#+end_src\n",
        "#+begin_src python :prologue import math\nreturn math.floor(2.5)\n#+end_src\n",
        "#+begin_src python :results output :prologue print('a') :epilogue print('c')\nprint('b')\n#+end_src\n",
        "#+begin_src python :results output\nimport sys\nprint('out')\nprint('err', file=sys.stderr)\n#+end_src\n",
        "#+begin_src python :results output raw\nprint('| a | b |')\n#+end_src\n",
        "#+begin_src python\nreturn int('x')\n#+end_src\n",
        "#+begin_src python :var l='(1 2) m='((1 2) (3 4)) n=(+ 1 2) s='(\"a\" \"b\")\nreturn [l, m, n, s]\n#+end_src\n",
        tbl + "#+begin_src python :var t=tbl\nreturn t\n#+end_src\n",
        tbl + "#+begin_src python :var t=tbl :colnames yes\nreturn [r + [9] for r in t]\n#+end_src\n",
        tbl + "#+begin_src python :var t=tbl :rownames yes :colnames yes\nreturn [[c * 2 for c in r] for r in t]\n#+end_src\n",
        tbl + "#+begin_src python :var t=tbl :hlines yes\nreturn t\n#+end_src\n",
    ])
    func matchesPython3(_ text: String) async throws {
        let job = try job(text)
        let pyodide = try #require(try await PythonBlocks.run(job, directory: FileManager.default.temporaryDirectory))
        let python3 = try installed(job)
        #expect(added(text, job, pyodide) == added(text, job, python3))
        #expect(pyodide.status == python3.status)
        #expect(pyodide.stderr.split(separator: "\n").last == python3.stderr.split(separator: "\n").last)
    }
    #endif

    @Test func runsValueAndOutputBlocks() async throws {
        PythonBlocks.stop()
        let start = ContinuousClock.now
        #expect(try await run("#+begin_src python\nreturn 6 * 7\n#+end_src\n") == "\n#+RESULTS:\n: 42\n")
        print("Pyodide's first result after \(ContinuousClock.now - start)")
        #expect(try await run("#+begin_src python :results output\nprint('one')\nprint('two')\n#+end_src\n") == "\n#+RESULTS:\n: one\n: two\n")
        #expect(try await run("#+begin_src python\nreturn [[1, 2], None, [3, 4]]\n#+end_src\n") == "\n#+RESULTS:\n| 1 | 2 |\n|---+---|\n| 3 | 4 |\n")
        #expect(try await run("#+begin_src python :results pp\nreturn {'b': [1, 2], 'a': 'x'}\n#+end_src\n") == "\n#+RESULTS:\n: {'a': 'x', 'b': [1, 2]}\n")
    }

    @Test func passesVariables() async throws {
        #expect(try await run("#+NAME: nums\n| 1 | 2 |\n| 3 | 4 |\n\n#+begin_src python :var t=nums\nreturn [[c * 10 for c in r] for r in t]\n#+end_src\n")
            .hasSuffix("#+RESULTS:\n| 10 | 20 |\n| 30 | 40 |\n"))
        #expect(try await run("#+begin_src python :var n=3 :var s=\"hi\"\nreturn s * n\n#+end_src\n") == "\n#+RESULTS:\n: hihihi\n")
        #expect(try await run("#+begin_src python :var l='(1 2) x=2.5\nreturn [l, x]\n#+end_src\n") == "\n#+RESULTS:\n| (1 2) | 2.5 |\n")
    }

    @Test func blocksWithoutASessionDontShareVariables() async throws {
        _ = try await run("#+begin_src python :results output\nleft = 1\n#+end_src\n")
        let output = try await output("#+begin_src python :results output\nprint(left)\n#+end_src\n")
        #expect(output.status == 1)
        #expect(output.stderr.hasSuffix("NameError: name 'left' is not defined\n"))
    }

    @Test func sessionsKeepState() async throws {
        _ = try await run("#+begin_src python :session py :results output\na = 2\nprint('set')\n#+end_src\n")
        #expect(try await run("#+begin_src python :session py\na * 3\n#+end_src\n") == "\n#+RESULTS:\n: 6\n")
        #expect(try await run("#+begin_src python :session py :results output\nprint(a + 1)\n#+end_src\n") == "\n#+RESULTS:\n: 3\n")
        // An error leaves the session going, as in the interactive interpreter.
        let failed = try await output("#+begin_src python :session py :results output\nraise ValueError('x')\n#+end_src\n")
        #expect(failed.status == 0 && failed.stderr.hasSuffix("ValueError: x\n"))
        #expect(try await run("#+begin_src python :session py\n[a, a]\n#+end_src\n") == "\n#+RESULTS:\n| 2 | 2 |\n")
        let other = try await output("#+begin_src python :session other :results output\nprint('a' in globals())\n#+end_src\n")
        #expect(other.stdout == "False\n")
    }

    @Test func reportsErrorsAsPython3Does() async throws {
        let output = try await output("#+begin_src python\nx = 1\nreturn x / 0\n#+end_src\n")
        #expect(output.status == 1)
        #expect(output.stderr.hasPrefix("Traceback (most recent call last):\n  File \"<stdin>\", line "))
        #expect(output.stderr.hasSuffix("ZeroDivisionError: division by zero\n"))
        #expect(output.problem == "Exited with status 1: Traceback (most recent call last):")
        let syntax = try await self.output("#+begin_src python :results output\nprint(\n#+end_src\n")
        #expect(syntax.status == 1 && syntax.stderr.hasPrefix("  File \"<stdin>\", line 1") && syntax.stderr.contains("SyntaxError"))
        let exit = try await self.output("#+begin_src python :results output\nimport sys\nprint('bye')\nsys.exit(3)\n#+end_src\n")
        #expect(exit.status == 3 && exit.stdout == "bye\n")
    }

    @Test func hasOnlyTheStandardLibrary() async throws {
        #expect(try await run("#+begin_src python\nimport json, statistics\nreturn json.dumps(statistics.mean([1, 2, 6]))\n#+end_src\n") == "\n#+RESULTS:\n: 3\n")
        let output = try await output("#+begin_src python :results output\nimport matplotlib\n#+end_src\n")
        #expect(output.stderr.contains("ModuleNotFoundError"))
        await #expect(throws: Babel.Failure.message("Python blocks can't draw graphics in this version of orgstar: matplotlib isn't included.")) {
            _ = try await self.output("#+begin_src python :results graphics file :file plot.png\nimport matplotlib\n#+end_src\n")
        }
    }

    @Test func writesTheValueToAFile() async throws {
        let text = "#+begin_src python :results file :file out.txt\nreturn 'saved'\n#+end_src\n"
        let output = try await output(text)
        let file = try #require(Babel.fileResult(try job(text), output: output))
        #expect(file.path == "out.txt" && file.contents == "saved")
    }

    @Test func stopsARunThatTakesTooLongAndStartsAgain() async throws {
        await #expect(throws: Babel.Failure.message("The block took longer than 2.0 seconds and was stopped.")) {
            _ = try await self.output("#+begin_src python :session py\nwhile True: pass\n#+end_src\n", timeout: .seconds(2))
        }
        let start = ContinuousClock.now
        #expect(try await run("#+begin_src python :session py\n'a' in globals()\n#+end_src\n") == "\n#+RESULTS:\n: False\n")
        // A new web view, not one still busy with the loop.
        #expect(ContinuousClock.now - start < .seconds(60))
    }

    /// Without `DocumentSession.programs`, a python block whose `:var` refers to another runs both.
    @Test func runsReferencedBlocksInTheDocument() async throws {
        #expect(DocumentSession.runner == nil)
        let notes = try Folder()
        let text = "#+begin_src python :var t=tbl\nreturn [len(t), t[1][0]]\n#+end_src\n\n#+NAME: tbl\n#+begin_src python\nreturn [[1, 2], [3, 4]]\n#+end_src\n"
        let file = try notes.write("py.org", text)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        guard case .external(.babel(let job)) = session.perform(ExecuteSrcBlock(), path: file.path, at: 3, expect: nil) else {
            Issue.record("not planned")
            return
        }
        #expect(await session.runBabel(job) == "Code block evaluation complete.")
        #expect(session.document?.text.contains("#+end_src\n\n#+RESULTS:\n| 2 | 3 |\n") == true)
    }

    @Test func leavesOtherBlocksAlone() async throws {
        #expect(try await PythonBlocks.run(job("#+begin_src js\nreturn 1\n#+end_src\n"), directory: FileManager.default.temporaryDirectory) == nil)
        PythonBlocks.folder = nil
        #expect(try await PythonBlocks.run(job("#+begin_src python\nreturn 1\n#+end_src\n"), directory: FileManager.default.temporaryDirectory) == nil)
    }
}
