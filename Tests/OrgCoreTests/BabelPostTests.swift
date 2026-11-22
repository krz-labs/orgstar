import Foundation
import Testing
@testable import OrgCore

/// `:post` with `*this*`, and noweb references that run a block.
struct BabelPostTests {
    static let helpers = """
        #+NAME: wrap
        #+begin_src emacs-lisp :var x="" :var y=">"
        (format "<%s%s" x y)
        #+end_src

        #+NAME: double
        #+begin_src emacs-lisp :var n=0
        (* 2 n)
        #+end_src

        #+NAME: bump
        #+begin_src emacs-lisp :var rows='()
        (mapcar (lambda (row) (mapcar #'1+ row)) rows)
        #+end_src

        #+NAME: pair
        #+begin_src emacs-lisp :var x=""
        (list (list x (length x)))
        #+end_src

        #+NAME: twice
        #+begin_src emacs-lisp :var n=0 :post double(n=*this*)
        (* 2 n)
        #+end_src

        #+NAME: said
        #+begin_src sh :results output :var x=""
        echo "said $x"
        #+end_src

        #+NAME: greet
        #+begin_src sh
        echo hello
        #+end_src

        #+NAME: lines
        #+begin_src sh :results output
        printf 'a\\nb\\n'
        #+end_src

        #+NAME: grid
        #+begin_src emacs-lisp
        '((1 2) (3 4))
        #+end_src

        #+NAME: inc
        #+begin_src sh :noweb yes
        echo <<double(n=5)>>
        #+end_src

        #+NAME: drawn
        #+begin_src sh :results file :file orgstar-post-ref.txt
        echo drawn
        #+end_src


        """

    /// Each ends with the block to run, which `MAIN` marks.
    static let cases: [String] = [
        "#+begin_src sh :post wrap(x=*this*)\necho hello\n#+end_src\n",
        "#+begin_src sh :post double(n=*this*)\necho 21\n#+end_src\n",
        "#+begin_src sh :post wrap(x=*this*, y=\"!\")\necho hello\n#+end_src\n",
        "#+begin_src sh :post bump(rows=*this*)\nprintf '1 2\\n3 4\\n'\n#+end_src\n",
        "#+begin_src sh :post pair(x=*this*)\necho hello\n#+end_src\n",
        "#+begin_src sh :post twice(n=*this*)\necho 3\n#+end_src\n",
        "#+begin_src sh :post said(x=*this*)\necho hello\n#+end_src\n",
        "#+begin_src sh :post wrap(x=*this*) :results output\necho one; echo two\n#+end_src\n",
        "#+begin_src sh :post wrap(x=*this*) :results file :file orgstar-post.txt\necho data\n#+end_src\n",
        "#+begin_src sh :post wrap(x=*this*) :results file drawer :file orgstar-post.txt :file-desc out\necho data\n#+end_src\n",
        "#+begin_src sh :post wrap(x=*this*) :results file\necho orgstar-post.txt\n#+end_src\n",
        "#+begin_src sh :post wrap(x=*this*) :results raw\necho hello\n#+end_src\n",
        "#+begin_src sh :post bump(rows=*this*) :results list\nprintf '1 2\\n3 4\\n'\n#+end_src\n",
        "#+begin_src sh :post wrap(x=*this*)\necho new\n#+end_src\n\n#+RESULTS:\n: old\n",
        "#+NAME: main\n#+begin_src sh :post double(n=*this*) :var a=double(n=2)\necho $a\n#+end_src\n",
        "#+begin_src emacs-lisp :post double(n=*this*) :cache yes\n(+ 1 2)\n#+end_src\n",
        "#+begin_src sh :post grid\necho gone\n#+end_src\n",
        "#+begin_src sh :var p=drawn\necho $p\n#+end_src\n",
        "Text src_sh[:post wrap(x=*this*)]{echo hello} here.\n",
        "#+CALL: greet() :post wrap(x=*this*)\n",
        "#+begin_src sh :noweb yes\necho <<double(n=4)>>\n#+end_src\n",
        "#+begin_src sh :noweb yes\necho <<greet()>> world\n#+end_src\n",
        "#+begin_src emacs-lisp :noweb yes\n(length '<<grid()>>)\n#+end_src\n",
        "#+begin_src emacs-lisp :noweb yes\n(format \"%S\" '<<bump(rows=grid)>>)\n#+end_src\n",
        "#+begin_src sh :noweb yes :results output\n# <<lines()>>\necho done\n#+end_src\n",
        "#+begin_src sh :noweb yes :noweb-prefix no :results output\necho <<lines()>>\n#+end_src\n",
        "#+begin_src sh :results output\necho '<<double(n=4)>>'\n#+end_src\n",
        "#+begin_src sh :noweb eval\necho <<twice(n=2)>>\n#+end_src\n",
        "#+begin_src sh :noweb tangle :results output\necho '<<double(n=4)>>'\n#+end_src\n",
        "#+begin_src sh :noweb yes\n<<inc>>\n#+end_src\n",
        "#+begin_src sh :var v=inc\necho $v\n#+end_src\n",
        "#+begin_src sh :noweb yes\necho <<drawn()>>\n#+end_src\n",
        "#+begin_src sh :noweb yes :post double(n=*this*)\necho <<double(n=1)>>\n#+end_src\n",
    ]

    static func caret(_ text: String) -> Int { helpers.utf16.count + (text.hasPrefix("#+NAME") ? 14 : text.hasPrefix("Text") ? 8 : 2) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        let folder = FileManager.default.temporaryDirectory
        var emacsCases: [EmacsOracle.Case] = []
        var ours: [(text: String, failure: String?)] = []
        for last in Self.cases {
            let text = Self.helpers + last
            ours.append(try TestBabelRunner.execute(text, caret: Self.caret(last), directory: folder))
            emacsCases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(Self.caret(last), in: text), form: """
            (progn
              (require 'ob-shell)
              (setq org-confirm-babel-evaluate nil
                    default-directory temporary-file-directory)
              (org-ctrl-c-ctrl-c))
            """))
        }
        let emacs = try EmacsOracle.run(emacsCases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine.text == theirs.text && (mine.failure != nil) == !theirs.error.isEmpty,
                    "case \(i):\nours (\(mine.failure ?? "")):\n\(mine.text.dropFirst(Self.helpers.count))\nemacs (\(theirs.error)):\n\(theirs.text.dropFirst(Self.helpers.count))")
            #expect(mine.text != Self.helpers + Self.cases[i], "case \(i) changed nothing")
        }
    }

    /// Emacs Lisp in the interpreter, as on iOS and in the Mac App Store version.
    @Test func runsInTheInterpreter() throws {
        let folder = FileManager.default.temporaryDirectory
        for (last, result) in [
            ("#+begin_src emacs-lisp :post double(n=*this*)\n(+ 1 2)\n#+end_src\n", "#+RESULTS:\n: 6\n"),
            ("#+begin_src emacs-lisp :post bump(rows=*this*)\n'((1 2) (3 4))\n#+end_src\n", "#+RESULTS:\n| 2 | 3 |\n| 4 | 5 |\n"),
            ("#+begin_src emacs-lisp :noweb yes\n(+ 1 <<double(n=4)>>)\n#+end_src\n", "#+RESULTS:\n: 9\n"),
        ] {
            let ran = try TestBabelRunner.execute(Self.helpers + last, caret: Self.caret(last), directory: folder, native: true)
            #expect(ran.failure == nil && ran.text.hasSuffix(result), "\(last)\n\(ran)")
        }
    }

    static func plan(_ text: String, at marker: String = "#+begin_src") -> Result<BabelJob, Babel.Failure> {
        let caret = (text as NSString).range(of: marker, options: .backwards).location + 2
        return Babel.plan(EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret]))
    }

    @Test func refusesBeforeAnythingRuns() {
        for (text, message) in [
            ("#+NAME: a\n#+begin_src sh :post a()\necho\n#+end_src\n", "a refers to itself through :post"),
            ("#+NAME: b\n#+begin_src sh :post a()\necho\n#+end_src\n#+NAME: a\n#+begin_src sh :post b()\necho\n#+end_src\n", "b refers to itself through :post"),
            ("#+NAME: a\n#+begin_src sh :noweb yes\necho <<a()>>\n#+end_src\n", "a refers to itself through a noweb reference"),
            ("#+NAME: b\n#+begin_src sh :var x=a\necho\n#+end_src\n#+NAME: a\n#+begin_src sh :noweb yes\necho <<b()>>\n#+end_src\n", "b refers to itself through a noweb reference"),
            ("#+NAME: off\n#+begin_src sh :eval never\necho\n#+end_src\n#+begin_src sh :post off(x=*this*)\necho\n#+end_src\n",
             "Evaluation of this sh code block (off) is disabled."),
            ("#+NAME: off\n#+begin_src sh :eval never\necho\n#+end_src\n#+begin_src sh :noweb yes\necho <<off()>>\n#+end_src\n",
             "Evaluation of this sh code block (off) is disabled."),
            ("#+NAME: off\n#+begin_src sh :eval never\necho\n#+end_src\n#+NAME: gen\n#+begin_src sh\necho\n#+end_src\n#+begin_src sh :var v=gen :post off(x=*this*)\necho\n#+end_src\n",
             "Evaluation of this sh code block (off) is disabled."),
            ("#+begin_src sh :post missing(x=*this*)\necho\n#+end_src\n", "References like missing(x=*this*) aren't supported yet."),
            ("#+begin_src sh :noweb yes\necho <<missing()>>\n#+end_src\n", "References like missing() aren't supported yet."),
            ("#+NAME: other\n#+begin_src cobol\nDISPLAY\n#+end_src\n#+begin_src sh :post other()\necho\n#+end_src\n", "No way to run cobol blocks yet."),
        ] {
            guard case .failure(.message(let got)) = Self.plan(text) else {
                Issue.record("planned: \(text)")
                continue
            }
            #expect(got == message)
        }
    }

    /// The trust prompt covers the block and every block its `:post` and noweb references run.
    @Test func asksOnceForEveryBlockReached() throws {
        let post = "#+NAME: p\n#+begin_src sh :var x=\"\" :noweb yes\necho <<q()>>\n#+end_src\n#+NAME: q\n#+begin_src sh\necho q\n#+end_src\n"
            + "#+NAME: inc\n#+begin_src sh :noweb yes\necho <<r()>>\n#+end_src\n#+NAME: r\n#+begin_src sh :eval query\necho r\n#+end_src\n"
        for main in ["#+begin_src sh :post p(x=*this*)\necho main\n#+end_src\n", "#+begin_src sh :noweb yes\necho <<p()>>\n#+end_src\n"] {
            guard case .success(let job) = Self.plan(post + main), let need = job.needs.first else {
                Issue.record("not planned: \(main)")
                continue
            }
            #expect(job.approved.count == 3 && job.approved.contains(need.job.blockText) && job.referenced == ["sh", "sh"])
            #expect(job.blockText.contains("echo main") || job.blockText.contains("echo <<p()>>"))
            #expect(job.blockText.contains("echo <<q()>>") && job.blockText.contains("echo q") && !job.alwaysAsk)
        }
        // Through a reference that brings a body in, and `:eval query` on the block it runs.
        guard case .success(let job) = Self.plan(post + "#+begin_src sh :noweb yes\n<<inc>>\n#+end_src\n") else {
            Issue.record("not planned")
            return
        }
        #expect(job.alwaysAsk && job.approved.count == 2 && job.blockText.contains("echo r"))
    }

    /// The block runs before its `:post` reference, which gets its result; a block that isn't
    /// among those agreed to is not handed back as the next to run.
    @Test func runsTheBlockThenItsPost() throws {
        let text = Self.helpers + "#+begin_src sh :post double(n=*this*)\necho 21\n#+end_src\n"
        let tree = OrgParser.parse(text)
        guard case .success(let first) = Self.plan(text), let main = first.needs.first else {
            Issue.record("not planned")
            return
        }
        #expect(first.known == nil && main.job.input.contains("echo 21"))
        guard case .success(let second) = Babel.resume(first, need: main, output: BabelOutput(stdout: "21\n"), text: text, tree: tree),
              let post = second.needs.first else {
            Issue.record("not resumed")
            return
        }
        #expect(post.job.lispForm?.contains("(n '21)") == true && first.approved.contains(post.job.blockText))
        let output = BabelOutput(stdout: #"{"s":"42","S":"42","string":false,"rows":null}"#)
        guard case .success(let last) = Babel.resume(second, need: post, output: output, text: text, tree: tree) else {
            Issue.record("not resumed")
            return
        }
        #expect(last.needs.isEmpty && last.known == BabelOutput(stdout: "42") && first.approved.contains(last.blockText))
    }

    @Test func tanglingRefusesAReferenceThatRuns() throws {
        let text = Self.helpers + "#+begin_src sh :noweb yes :tangle out.sh\necho <<double(n=4)>>\n#+end_src\n"
        let model = DocumentModel(tree: OrgParser.parse(text))
        let block = model.srcBlocks.last!
        #expect(throws: Babel.Failure.message("The noweb reference <<double(n=4)>> would run a block while tangling, which isn't supported yet; nothing was tangled.")) {
            try Babel.expandNoweb(block, params: try Babel.Params(block: block, model: model, text: text as NSString), model: model, text: text as NSString, tangling: true)
        }
    }
}
