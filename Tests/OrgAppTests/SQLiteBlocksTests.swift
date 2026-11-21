import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// sqlite blocks with the SQLite library, compared with macOS's `sqlite3` and with Emacs
/// running it.
struct SQLiteBlocksTests {
    static let sqlite3 = "/usr/bin/sqlite3"
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil && FileManager.default.isExecutableFile(atPath: sqlite3)

    static let values = """
        select 1 as a, 'x y' as b, null as c, 2.50 as d, 'it''s' as e, '' as f, -7 as g, 0.1 + 0.2 as h
        union all select 22, 'é,ü', 'q"t', 1e20, '<&>', ' lead', 3.0, 'tab\tin';
        """

    /// Options as ob-sqlite writes them, and scripts.
    static let cli: [([String], String)] = [
        (["-noheader", "-csv"], values),
        (["-header", "-csv"], values),
        (["-noheader", "-list"], values),
        (["-noheader", "-header", "-list"], values),
        (["-noheader", "-column"], "select 1 as a, 'xx' as long_name, 2.5 as mid union all select -10, null, 'text';\nselect 'second' as s;"),
        (["-noheader", "-html"], values),
        (["-noheader", "-line"], values + "\nselect 'a\nb\n' as multi, 'c' as longer_name;"),
        (["-noheader", "-separator", "X"], values),
        (["-header", "-separator", ";"], values),
        (["-noheader", "-separator", "X", "-nullvalue", "N"], values),
        (["-noheader", "-nullvalue", "N", "-csv"], values),
        (["-noheader", "-csv"], "\nselect 1;\n\n  select 2; select 3;\n# comment\nselect 4\n;\nselect 5"),
        (["-noheader", "-echo", "-csv"], "\nselect 1;\n   select 2;   select 3;\n# c\n.mode list\n\nselect 4\n;\n"),
        (["-noheader", "-csv"], ".headers on\nselect 1 as a;\n.mode column\nselect 2 as b;\n.mode list\nselect 3 as c;\n.mode csv\nselect 4 as d;\n"),
        (["-noheader", "-csv"], ".mode column\n.headers off\nselect 1 as a, null as n;\n.headers on\n.mode html\n.nullvalue N\nselect 1 as a, null as n;"),
        (["-noheader", "-csv"], ".mode line\n.separator X\nselect 1 as a, null as n;\n.mode csv\n.separator :\nselect 'a:b' as a, 'c,d';"),
        (["-noheader", "-csv"], ".nullvalue N\nselect null;\n.mode list\nselect null;\n.nullvalue M\nselect null, 1;"),
        (["-noheader", "-csv"], "create table t(a integer, b text, c real);\ninsert into t values (1, 'one', 1.5), (2, null, -0.25), (30, 'thirty', 1e100);\nselect * from t order by a;\nselect count(*) as n from t;\nselect a from t where 0;"),
        (["-noheader", "-column"], "create table t(a, b);\ninsert into t values (1, 'xx'), (22, null), (3.5, 'y');\nselect * from t;\nselect a from t where 0;\n"),
        (["-noheader", "-csv"], "select 1;\nselect * from nope;\nselect 2;\nselect 3; select * from nope; select 4;\nselect 5;"),
        (["-noheader", "-bail", "-csv"], "select 1;\nselect * from nope;\nselect 2;"),
        (["-noheader", "-csv"], "select 1 union all select abs(-9223372036854775808);\nselect 2;"),
        (["-noheader", "-csv"], "create table t(a unique);\ninsert into t values (1);\ninsert into t values (1);\nselect count(*) from t;"),
        (["-noheader", "-csv"], "select 1 -- a comment\n;\n/* c */ select 2;\n-- only a comment\nselect 3 /* trailing"),
        (["-noheader", "-csv"], "select $x, ?, :y;"),
        (["-noheader", "-html"], "select 'a''b\"c<d>e&f' as \"<h>\";"),
        (["-noheader", "-csv"], "select 'line\ntwo', 'a,b', '\"', 'plain' as \"col name\", 'x' as \"q\"\"n\";"),
        (["-noheader", "-csv"], ".mode list\n.separator ,\nselect 'a,b', 'c';\n.mode list\nselect 'a,b';"),
        (["-noheader", "-header", "-csv"], "create table t(a, b);\n.headers on\nselect * from t;\ninsert into t values (1, 2);\nselect * from t;"),
    ]

    static func cliOutput(_ arguments: [String], _ input: String, folder: URL) throws -> (stdout: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlite3)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    @Test(.enabled(if: oracle))
    func shellMatchesSqlite3() throws {
        for (arguments, script) in Self.cli {
            let input = script + "\n"
            let theirFolder = try Folder(), ourFolder = try Folder()
            let theirs = try Self.cliOutput(arguments, input, folder: theirFolder.url)
            var shell = try SQLiteBlocks.Shell(arguments: arguments)
            let ours = try shell.run(input, folder: ourFolder.url)
            #expect(ours.stdout == theirs.stdout, "\(arguments) \(script.debugDescription)\nours:\n\(ours.stdout.debugDescription)\nsqlite3:\n\(theirs.stdout.debugDescription)")
            #expect(ours.status == theirs.status, "\(arguments) \(script.debugDescription)")
        }
    }

    static let table = "#+NAME: tbl\n| id | name  |\n|----+-------|\n|  1 | one   |\n|  2 | two   |\n|  3 | x, \"y\" |\n\n"

    static let blocks: [String] = [
        "#+begin_src sqlite\nselect 1 as a, 'x y' as b, null as c, 2.50 as d;\nselect 'q\"t', 'é', '007', '\"quoted\"';\n#+end_src\n",
        "#+begin_src sqlite :colnames yes\nselect 1 as a, 2 as b;\nselect 3, 4;\n#+end_src\n",
        "#+begin_src sqlite\nselect 42;\n#+end_src\n",
        "#+begin_src sqlite\nselect 'line\ntwo', 'a,b';\n#+end_src\n",
        "#+begin_src sqlite :list\nselect 1, 'x y';\n#+end_src\n",
        "#+begin_src sqlite :column\nselect 1 as a, 'x y' as b;\n#+end_src\n",
        "#+begin_src sqlite :html\nselect 1 as a, 'x' as b;\n#+end_src\n",
        "#+begin_src sqlite :line\nselect 1 as a, 'x' as b;\n#+end_src\n",
        "#+begin_src sqlite :separator X\nselect 1 as a, 'x y' as b;\n#+end_src\n",
        "#+begin_src sqlite :separator , :nullvalue N\nselect 1, null, 'a b';\n#+end_src\n",
        "#+begin_src sqlite :header\nselect 1 as a, 2 as b;\n#+end_src\n",
        "#+begin_src sqlite :csv\nselect 1 as a, 'b c' as b;\n#+end_src\n",
        "#+begin_src sqlite :results output\nselect 1, 2;\n#+end_src\n",
        "#+begin_src sqlite :results output\nselect 'line\ntwo', 'a,b';\n#+end_src\n",
        "#+begin_src sqlite :results verbatim\nselect 1, 2;\nselect 3, 4;\n#+end_src\n",
        "#+begin_src sqlite :results raw\nselect '*bold*';\n#+end_src\n",
        "#+begin_src sqlite :results table\nselect 7;\n#+end_src\n",
        "#+begin_src sqlite :results list\nselect 1, 2;\nselect 3, 4;\n#+end_src\n",
        "#+begin_src sqlite\ncreate table t(a);\n#+end_src\n",
        "#+begin_src sqlite\nselect 1 where 0;\n#+end_src\n",
        "#+begin_src sqlite :db test.db\ncreate table if not exists t(a, b);\ninsert into t values (1, 'one'), (2, 'two');\nselect * from t order by a;\n#+end_src\n",
        "#+begin_src sqlite :db test2.db :readonly yes\nselect 1;\n#+end_src\n",
        "#+begin_src sqlite :var x=3 name=\"two\"\nselect $x * 2, '$name', $X;\n#+end_src\n",
        "#+begin_src sqlite :var x=2.50\nselect $x;\n#+end_src\n",
        table + "#+begin_src sqlite :var t=tbl\ncreate table v(id integer, name text);\n.mode csv\n.import $t v\nselect name, id * 10 from v order by id;\n#+end_src\n",
        table + "#+begin_src sqlite :var t=tbl :colnames yes\ncreate table v(id integer, name text);\n.import --csv $t v\n.headers on\nselect * from v;\n#+end_src\n",
        "#+begin_src sqlite :prologue \"create table p(a);\" :epilogue \"select count(*) from p;\"\ninsert into p values (1), (2);\n#+end_src\n",
        "#+begin_src sqlite\nselect 1;\nselect * from nope;\nselect 2;\n#+end_src\n",
        "#+begin_src sqlite :bail\nselect 1;\nselect * from nope;\nselect 2;\n#+end_src\n",
        "#+begin_src sqlite :echo :results output\nselect 1;\nselect 2;\n#+end_src\n",
        "#+begin_src sqlite\nselect ' a ', '\"b\"', 'c\"d', '-', '1e3', '+5', '.5', '1.';\n#+end_src\n",
        "#+begin_src sqlite :list\nselect 'a b', 'c';\nselect 'single';\n#+end_src\n",
        "#+begin_src sqlite :list\nselect 'a' || char(9) || 'b', 'c';\nselect 'd' || char(9) || 'e';\n#+end_src\n",
        "#+begin_src sqlite :separator ,\nselect 1, 2;\nselect 3;\n#+end_src\n",
        "#+begin_src sqlite\nselect '';\n#+end_src\n",
        "#+begin_src sqlite\nselect 1, '';\nselect '', '';\n#+end_src\n",
    ]

    /// More blocks: each matches Emacs or is refused.
    static let probes: [String] = [
        "#+begin_src sqlite :column\nselect 1 as n, null as z, 'abc' as t union all select 12345, 'x', '';\n#+end_src\n",
        "#+begin_src sqlite :html\nselect '<b>' as \"a&b\", null;\n#+end_src\n",
        "#+begin_src sqlite :line\nselect 'a\nb' as x, 2 as longer;\nselect 3 as y;\n#+end_src\n",
        "#+begin_src sqlite\nselect null, 1;\n#+end_src\n",
        "#+begin_src sqlite\nselect 9223372036854775807, -9223372036854775808, 1.5e300;\n#+end_src\n",
        "#+begin_src sqlite\nselect 'a' union all select 'b' union all select 'c';\n#+end_src\n",
        "#+begin_src sqlite :list :nullvalue N\nselect null, 1;\n#+end_src\n",
        "#+begin_src sqlite :csv\n.mode column\nselect 1 as a, 22 as bb;\n#+end_src\n",
        "#+begin_src sqlite\nselect 'a|b', 'c';\n#+end_src\n",
        "#+begin_src sqlite\n-- only a comment\n#+end_src\n",
        "#+begin_src sqlite :results scalar\nselect 1, 2;\n#+end_src\n",
        "#+begin_src sqlite :results table\nselect 'x';\n#+end_src\n",
        "#+begin_src sqlite :colnames yes :list\nselect 1 as a, 2 as b;\n#+end_src\n",
        "#+begin_src sqlite :colnames yes\nselect 1 as a;\n#+end_src\n",
        "#+begin_src sqlite :results list\nselect 1;\n#+end_src\n",
        "#+begin_src sqlite :results drawer\nselect 1, 2;\n#+end_src\n",
        "#+begin_src sqlite :wrap example\nselect 1, 2;\n#+end_src\n",
        "#+begin_src sqlite :separator , \nselect 'a b', 2;\n#+end_src\n",
        "#+begin_src sqlite :list\nselect '  lead', 'trail  ';\n#+end_src\n",
        "#+begin_src sqlite\nselect '  lead', 'trail  ', ' ';\n#+end_src\n",
        "#+begin_src sqlite\nselect 'tab' || char(9) || 'x', 2;\n#+end_src\n",
        "#+begin_src sqlite\nselect 'α', '日本', 'x';\n#+end_src\n",
        "#+begin_src sqlite :column\nselect 'a b' as \"c d\";\n#+end_src\n",
        "#+begin_src sqlite\nselect 1;\nselect 2, 3;\n#+end_src\n",
        "#+begin_src sqlite\nselect '\"a\" \"b\"', '\"c\\\"d\"';\n#+end_src\n",
        "#+begin_src sqlite\nselect '1e5', '0x10', '1,5', '--1';\n#+end_src\n",
        "#+begin_src sqlite :var n=2\nselect $n + $n1;\n#+end_src\n",
        "#+NAME: h\n| a | b |\n|---+---|\n| 1 | 2 |\n|---+---|\n| 3 | 4 |\n\n#+begin_src sqlite :var t=h :hlines yes\ncreate table v(a, b);\n.import --csv $t v\nselect * from v;\n#+end_src\n",
        "#+NAME: s\n| x y | 2.50 |\n| \"q\" | 007 |\n\n#+begin_src sqlite :var t=s\ncreate table v(a, b);\n.import --csv $t v\nselect a, b, typeof(b) from v;\n#+end_src\n",
        "#+begin_src sqlite :echo :list\nselect 1;\n#+end_src\n",
        "#+begin_src sqlite :echo :results output\nselect 1;\n#+end_src\n",
        "#+begin_src sqlite :list\nselect '';\nselect 1;\n#+end_src\n",
        "#+begin_src sqlite :list\nselect '';\n#+end_src\n",
        "#+begin_src sqlite :list\nselect 1;\nselect '';\n#+end_src\n",
        "#+begin_src sqlite :list\nselect '';\nselect 1, 2;\n#+end_src\n",
        "#+begin_src sqlite :results list\nselect 1, 2;\n#+end_src\n",
        "#+begin_src sqlite :results list :list\nselect 'a', 'b c';\n#+end_src\n",
        "#+begin_src sqlite :results output :line\nselect 1 as a;\nselect 2 as b;\n#+end_src\n",
        "#+begin_src sqlite\ncreate table t(a);\ninsert into t values (1);\nselect changes(), total_changes();\n#+end_src\n",
    ]

    @MainActor
    @Test(.enabled(if: oracle))
    func probesMatchEmacsOrAreRefused() async throws {
        let (ours, emacs, messages) = try await Self.compare(Self.probes)
        for (i, text) in Self.probes.enumerated() where !messages[i].hasPrefix("This sqlite block can't run here") {
            if emacs[i].hasPrefix("ERROR: ") {
                // Emacs fails the run: the same message, and nothing written.
                #expect(messages[i] == emacs[i].dropFirst("ERROR: ".count) && ours[i] == text, "\(text)\nours (\(messages[i])):\n\(ours[i])\nemacs:\n\(emacs[i])")
                continue
            }
            #expect(ours[i] == emacs[i], "\(text)\nours (\(messages[i])):\n\(ours[i])\nemacs:\n\(emacs[i])")
        }
    }

    /// The results the app inserts, as Emacs inserts them running `sqlite3`.
    @MainActor
    @Test(.enabled(if: oracle))
    func resultsMatchEmacs() async throws {
        let (ours, emacs, _) = try await Self.compare(Self.blocks)
        for (i, text) in Self.blocks.enumerated() {
            #expect(ours[i] == emacs[i], "\(text)\nours:\n\(ours[i])\nemacs:\n\(emacs[i])")
        }
    }

    /// Each block run by the app, and by Emacs, with the app's messages.
    @MainActor
    static func compare(_ blocks: [String]) async throws -> (ours: [String], emacs: [String], messages: [String]) {
        let ourFolder = try Folder(), theirFolder = try Folder()
        var forms: [String] = []
        var ours: [String] = []
        var messages: [String] = []
        for text in blocks {
            let caret = (text as NSString).range(of: "#+begin_src").location + 2
            let file = try ourFolder.write("b.org", text)
            let session = DocumentSession(recovery: FileRecoveryStore(directory: ourFolder.url.appendingPathComponent(".r")))
            session.open(file.path)
            switch session.perform(ExecuteSrcBlock(), path: file.path, at: caret, expect: nil) {
            case .external(.babel(let job)): messages.append(await session.runBabel(job))
            case let other: messages.append("\(other)")
            }
            ours.append(session.document?.text ?? "")
            let quoted = "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            forms.append("(with-temp-buffer (insert \(quoted)) (org-mode) (goto-char \(caret + 1)) (princ (condition-case e (progn (org-babel-execute-src-block) (concat (buffer-string) \"\\f\")) (error (format \"ERROR: %s\\f\" (error-message-string e))))))")
        }
        let emacs = try Self.emacs("""
            (progn (require 'org) (require 'ob-sqlite)
              (setq org-confirm-babel-evaluate nil org-babel-sqlite3-command "\(Self.sqlite3)" default-directory "\(theirFolder.url.path)/")
              \(forms.joined(separator: "\n")))
            """).split(separator: "\u{0C}", omittingEmptySubsequences: false).map(String.init)
        return (ours, emacs, messages)
    }

    /// Emacs in a UTF-8 locale, as it runs on the Mac.
    static func emacs(_ form: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ProcessInfo.processInfo.environment["ORGSTAR_EMACS"] ?? "emacs", "-Q", "--batch", "--eval", form]
        process.environment = ProcessInfo.processInfo.environment.merging(["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func plan(_ text: String) throws -> BabelJob {
        let caret = (text as NSString).range(of: "#+begin_src").location + 2
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
        guard case .success(let job) = Babel.plan(context) else { throw Babel.Failure.message("not planned: \(text)") }
        return job
    }

    /// What can't be shown as `sqlite3` shows it is refused, with nothing written.
    @Test func refusals() throws {
        let refused: [(String, SQLiteBlocks.Refusal)] = [
            ("#+begin_src sqlite :db \"my file.db\"\nselect 1;\n#+end_src\n", .init(.shell)),
            ("#+begin_src sqlite :separator |\nselect 1;\n#+end_src\n", .init(.shell)),
            ("#+begin_src sqlite :header :separator ;\nselect 1;\n#+end_src\n", .init(.shell)),
            ("#+begin_src sqlite\n.separator ;\nselect 1;\n#+end_src\n", .init(.dotCommand(".separator"))),
            ("#+begin_src sqlite :db ~/x.db\nselect 1;\n#+end_src\n", .init(.shell)),
            ("#+begin_src sqlite\n.tables\n#+end_src\n", .init(.dotCommand(".tables"))),
            ("#+begin_src sqlite\n.mode box\nselect 1;\n#+end_src\n", .init(.dotCommand(".mode"))),
            ("#+begin_src sqlite\n.separator \"\\t\"\nselect 1;\n#+end_src\n", .init(.dotCommand(".separator"))),
            ("#+begin_src sqlite\nselect x'00';\n#+end_src\n", .init(.blob)),
            ("#+begin_src sqlite\nselect 'a' || char(13) || 'b';\n#+end_src\n", .init(.control)),
            ("#+begin_src sqlite :column\nselect 'é';\n#+end_src\n", .init(.width)),
            ("#+begin_src sqlite :column\nselect 'a\nb';\n#+end_src\n", .init(.width)),
            ("#+begin_src sqlite\nexplain select 1;\n#+end_src\n", .init(.explain)),
            ("#+begin_src sqlite :echo\nselect 1;\n#+end_src\n", .init(.echo)),
            ("#+begin_src sqlite\ncreate table t(a);\nselect x'01';\n#+end_src\n", .init(.blob, partly: true)),
            (Self.table + "#+begin_src sqlite :var t=tbl\n.import --csv $t v\n#+end_src\n", .init(.newTable)),
            (Self.table + "#+begin_src sqlite :var t=tbl\ncreate table v(a);\n.import --csv $t v\n#+end_src\n", .init(.importRows, partly: true)),
        ]
        let folder = try Folder()
        for (text, refusal) in refused {
            #expect(throws: Babel.Failure.message(refusal.message), "\(text)") { try SQLiteBlocks.run(Self.plan(text), directory: folder.url) }
        }
        #expect(try SQLiteBlocks.run(Self.plan("#+begin_src js\n1\n#+end_src\n"), directory: folder.url) == nil)
    }

    /// The sandboxed builds run calc blocks natively, and say why they refuse one.
    @MainActor
    @Test func calcBlocksRunInTheSession() async throws {
        let folder = try Folder()
        for (text, message, result) in [
            ("#+begin_src calc\n1/3\n#+end_src\n", "Code block evaluation complete.", "#+RESULTS:\n: 0.333333333333\n"),
            ("#+begin_src calc\n1\n'x\n#+end_src\n", "This calc block can't be calculated here: stack command 'x.", ""),
        ] {
            let file = try folder.write("c.org", text)
            let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.url.appendingPathComponent(".r")))
            session.open(file.path)
            guard case .external(.babel(let job)) = session.perform(ExecuteSrcBlock(), path: file.path, at: 2, expect: nil) else {
                Issue.record("not planned: \(text)")
                return
            }
            #expect(await session.runBabel(job) == message)
            #expect(session.document?.text == text + (result.isEmpty ? "" : "\n" + result))
        }
    }
}
