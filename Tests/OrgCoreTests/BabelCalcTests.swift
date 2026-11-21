import Foundation
import Testing
@testable import OrgCore

/// calc blocks on `Calc`, compared with ob-calc in Emacs.
struct BabelCalcTests {
    static let table = "#+NAME: tb\n| 1 | 2 |\n| 3 | 4 |\n\n"

    static let cases: [String] = [
        "#+begin_src calc\n1+2\n#+end_src\n",
        "#+begin_src calc\n1/3\n#+end_src\n",
        "#+begin_src calc\n10 / 4\n#+end_src\n",
        "#+begin_src calc\n7 % 3\n#+end_src\n",
        "#+begin_src calc\n3.0\n#+end_src\n",
        "#+begin_src calc\n1e3\n#+end_src\n",
        "#+begin_src calc\n1.5e20 * 3\n#+end_src\n",
        "#+begin_src calc\n1:3 + 1:6\n#+end_src\n",
        "#+begin_src calc\nsqrt(2)\n#+end_src\n",
        "#+begin_src calc\nsin(30)\n#+end_src\n",
        "#+begin_src calc\n  5  \n\n#+end_src\n",
        "#+begin_src calc\n3\n4\n'+\n#+end_src\n",
        "#+begin_src calc\n1\n2\n'-\n#+end_src\n",
        "#+begin_src calc\n1\n3\n'/\n#+end_src\n",
        "#+begin_src calc\n2\n10\n'^\n#+end_src\n",
        "#+begin_src calc\n7\n2\n'%\n#+end_src\n",
        "#+begin_src calc\n7\n2\n'\\\n#+end_src\n",
        "#+begin_src calc\n2\n'n\n#+end_src\n",
        "#+begin_src calc\n4\n'&\n#+end_src\n",
        "#+begin_src calc\n9\n'Q\n#+end_src\n",
        "#+begin_src calc\n-3\n'A\n#+end_src\n",
        "#+begin_src calc\n1.0\n2\n'+\n#+end_src\n",
        "#+begin_src calc\n1\n2\n#+end_src\n",
        "#+begin_src calc :var x=5 y=2.5\nx*y+1\n#+end_src\n",
        "#+begin_src calc :var x=5\nx\n#+end_src\n",
        "#+begin_src calc :var x=5\nx*2\n#+end_src\n",
        "#+begin_src calc :var x=5\n2 x\n#+end_src\n",
        "#+begin_src calc :var x=5\n[x, 2 x]\n#+end_src\n",
        "#+begin_src calc :var x=5\nx\nx\n'*\n#+end_src\n",
        "#+begin_src calc :var x=2.5\nx\n2\n'*\n#+end_src\n",
        "#+begin_src calc :var x=0.1\nx * 3\n#+end_src\n",
        "#+begin_src calc :var x=1e20\nx\n#+end_src\n",
        "#+begin_src calc :var xy=5 x=2\nxy\n#+end_src\n",
        "#+begin_src calc :var x=5 :results table\nx\n#+end_src\n",
        "#+begin_src calc\nx + 1\n#+end_src\n",
        "#+begin_src calc\n2 x + 3 x\n#+end_src\n",
        "#+begin_src calc\n[1, 2, 3]\n#+end_src\n",
        "#+begin_src calc\n[[1, 2], [3, 4]]\n#+end_src\n",
        "#+begin_src calc\n[1, [2, 3]]\n#+end_src\n",
        "#+begin_src calc\n[[1, 2], [3]]\n#+end_src\n",
        "#+begin_src calc :results scalar\n[1, 2, 3]\n#+end_src\n",
        "#+begin_src calc :results output\n1+1\n#+end_src\n",
        "#+begin_src calc :results verbatim\n1/4\n#+end_src\n",
        "#+begin_src calc :var v='(1 2 3)\nvsum(v)\n#+end_src\n",
        "#+begin_src calc :var v='(1 2 3)\nv\n#+end_src\n",
        table + "#+begin_src calc :var m=tb\nm\n#+end_src\n",
        "#+begin_src calc :prologue \"2\" :epilogue \"'*\"\n3\n#+end_src\n",
        "#+NAME: hd\n| a | b |\n|---+---|\n| 1 | 2 |\n| 3 | 4 |\n\n#+begin_src calc :var m=hd\nm\n#+end_src\n",
        // Errors in Emacs: the result isn't written.
        "#+begin_src calc :var x=5\n3\n'+\n#+end_src\n",
        "#+begin_src calc :var x=5\nx*2\n3\n'+\n#+end_src\n",
        "#+begin_src calc\n'+\n#+end_src\n",
        "#+begin_src calc\n#+end_src\n",
    ]

    static func caret(_ text: String) -> Int { (text as NSString).range(of: "#+begin_src").location + 2 }

    /// The block run with `Babel.evaluateCalc`.
    static func native(_ text: String) throws -> (text: String, failure: String?) {
        try TestBabelRunner.execute(text, caret: caret(text), directory: FileManager.default.temporaryDirectory, native: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func blocksMatchEmacs() throws {
        let folder = FileManager.default.temporaryDirectory
        var emacsCases: [EmacsOracle.Case] = []
        var ours: [(text: String, failure: String?)] = []
        var fallback: [(text: String, failure: String?)] = []
        for text in Self.cases {
            ours.append(try Self.native(text))
            fallback.append(try TestBabelRunner.execute(text, caret: Self.caret(text), directory: folder))
            emacsCases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(Self.caret(text), in: text), form: """
            (progn (require 'ob-calc) (setq org-confirm-babel-evaluate nil)
              ;; A new stack, as in a new Emacs.
              (save-window-excursion (calc) (when (> (calc-stack-size) 0) (calc-pop (calc-stack-size))) (calc-quit))
              (org-babel-execute-src-block))
            """))
        }
        let emacs = try EmacsOracle.run(emacsCases)
        for (i, theirs) in emacs.enumerated() {
            #expect(ours[i].text == theirs.text, "case \(i):\n\(Self.cases[i])\nours (\(ours[i].failure ?? "")):\n\(ours[i].text)\nemacs (\(theirs.error)):\n\(theirs.text)")
            #expect((ours[i].failure != nil) == !theirs.error.isEmpty, "case \(i): ours \(ours[i].failure ?? "ok"), emacs \(theirs.error)")
            #expect(fallback[i].text == theirs.text, "case \(i) in Emacs:\n\(Self.cases[i])\nours:\n\(fallback[i].text)\nemacs:\n\(theirs.text)")
        }
    }

    /// More blocks: each matches Emacs or is refused.
    static let probes: [String] = [
        "2^0.5", "-5 % 3", "1/0", "fact(5)", "round(2.5)", "12345678901234 * 10", "1e-5", "0.1 + 0.2", "2 * pi", "max(3, 5)",
        "1:2 * 2", "e", "sqrt(-1)", "1e100", "[1, 2] + [3, 4]", "-0.5", "100000000000000", "1.23456789012345", "3 x + y", "x^2",
        "ln(10)", "exp(1)", "7 \\ 2", "abs(-2.5)", "floor(-2.5)", "1 / 7", "2^-2", "[1, 2, 3] * 2", "\"abc\"", "a b c",
    ].map { "#+begin_src calc\n\($0)\n#+end_src\n" } + [
        "#+begin_src calc :var x=-3\nabs(x)\n#+end_src\n",
        "#+begin_src calc :var x=3\nx^2\n#+end_src\n",
        "#+begin_src calc :var x=5\nx - x\n#+end_src\n",
        "#+begin_src calc :var v='(1 2 3)\nv * 2\n#+end_src\n",
        "#+begin_src calc :var v='(1 2 3)\nv\n'n\n#+end_src\n",
        "#+begin_src calc :results list\n[1, 2, 3]\n#+end_src\n",
        "#+begin_src calc :results raw\n1/3\n#+end_src\n",
        "#+begin_src calc :var x=4 y=x\ny\n#+end_src\n",
        "#+begin_src calc :results vector\n5\n#+end_src\n",
        "#+begin_src calc :rownames yes\n[[1, 2], [3, 4]]\n#+end_src\n",
        "#+NAME: hd2\n| a | b |\n|---+---|\n| 1 | 2 |\n\n#+begin_src calc :var m=hd2\nm * 2\n#+end_src\n",
        "#+begin_src calc\n1\n\n2\n'+\n3\n'*\n#+end_src\n",
        "#+begin_src calc\n2.\n3\n'/\n#+end_src\n",
        "#+begin_src calc :epilogue \"'n\"\n4\n#+end_src\n",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func probesMatchEmacsOrAreRefused() throws {
        var cases: [EmacsOracle.Case] = []
        var ours: [(text: String, failure: String?)?] = []
        for text in Self.probes {
            ours.append(try? Self.native(text))
            cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(Self.caret(text), in: text), form: """
            (progn (require 'ob-calc) (setq org-confirm-babel-evaluate nil)
              (save-window-excursion (calc) (when (> (calc-stack-size) 0) (calc-pop (calc-stack-size))) (calc-quit))
              (org-babel-execute-src-block))
            """))
        }
        let emacs = try EmacsOracle.run(cases)
        for (i, theirs) in emacs.enumerated() {
            guard let mine = ours[i] else { continue }
            #expect(mine.text == theirs.text, "\(Self.probes[i])\nours (\(mine.failure ?? "")):\n\(mine.text)\nemacs (\(theirs.error)):\n\(theirs.text)")
        }
    }

    /// What Calc here doesn't do as Emacs's does is refused, with the reason.
    @Test func refusals() throws {
        let refused: [(String, String)] = [
            ("#+begin_src calc\n1\n'x\n#+end_src\n", "stack command 'x"),
            ("#+begin_src calc\n1\n2\n'TAB\n#+end_src\n", "stack command 'TAB"),
            ("#+begin_src calc :var s=\"abc\"\ns\n#+end_src\n", "value of :var s"),
            ("#+begin_src calc :var v='(1.5 2)\nv\n#+end_src\n", "value of :var v"),
            ("#+begin_src calc :var v='(1)\nv\n#+end_src\n", "value of :var v"),
            ("#+begin_src calc :var e=5\ne\n#+end_src\n", "value of :var e"),
            ("#+begin_src calc :var my_x=5\nmy_x\n#+end_src\n", "value of :var my_x"),
            ("#+begin_src calc :prologue 2\n3\n#+end_src\n", "numeric :prologue or :epilogue"),
            ("#+begin_src calc\n2^100\n#+end_src\n", "integer size"),
            ("#+begin_src calc\n[]\n#+end_src\n", "empty vector"),
            (Self.table + "#+begin_src calc :var m=tb\ndet(m)\n#+end_src\n", "function det"),
        ]
        for (text, reason) in refused {
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [Self.caret(text)..<Self.caret(text)])
            guard case .success(let job) = Babel.plan(context) else { Issue.record("not planned: \(text)"); continue }
            #expect(job.runner == .emacs)
            #expect(throws: Calc.Unsupported.self, "\(text)") { try Babel.evaluateCalc(job) }
            do {
                _ = try Babel.evaluateCalc(job)
            } catch let error as Calc.Unsupported {
                #expect(error.reason == reason, "\(text)")
            }
        }
    }
}
