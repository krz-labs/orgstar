import Foundation
import Testing
@testable import OrgCore

/// Evil's `gi`, `g;`, `g,`, `gJ`, `&`, the numbered and read-only registers, sentences, tags
/// and scrolling by lines and columns.
struct VimEvilTests {
    static let sentences = "One two. Three four!  Five\nsix seven? Eight.\n\n\nNine ten. Eleven\n"
    static let lines = "One two.\nThree four. Five\n\nSix. Seven\n"
    static let tags = "<a><b>x y</b> z</a>\n<p class=\"k\">\nline\n</p>\n<br/> tail\n"
    static let joined = "a b\n  c d\ne\n\nf\n"
    static let words = "alpha beta\ngamma delta\nepsilon zeta\neta theta\n"

    static let cases: [(String, Int, String)] = {
        var cases: [(String, Int, String)] = []
        for point in [0, 4, 9, 12, 22, 30, 38, 45, 46, 47, 58] {
            cases.append((sentences, point, ")"))
            if point > 0 { cases.append((sentences, point, "(")) }
        }
        cases += [(sentences, 0, "2 )"), (sentences, 0, "5 )"), (sentences, 58, "3 ("), (sentences, 4, "v ) d"), (sentences, 30, "y ( P")]
        for point in [0, 8, 9, 20, 21, 22, 45, 47, 58] {
            cases.append((sentences, point, "d i s"))
            cases.append((sentences, point, "d a s"))
        }
        for point in [0, 9, 21, 26, 27, 32] {
            cases.append((lines, point, "d i s"))
            cases.append((lines, point, "d a s"))
        }
        cases += [
            (sentences, 0, "d 2 a s"), (sentences, 0, "d 2 i s"), (sentences, 0, "d 3 i s"), (sentences, 12, "c a s X ESC"),
            (sentences, 12, "v i s d"), (sentences, 12, "y i s P"),
            (lines, 0, "d )"), (lines, 12, "d ("), (lines, 12, "d )"), (lines, 21, "d )"), (lines, 27, "d ("), (lines, 32, "d )"),
        ]
        for point in [0, 3, 6, 8, 10, 14, 18, 20, 34, 37, 46] {
            cases.append((tags, point, "d i t"))
            cases.append((tags, point, "d a t"))
        }
        cases += [(tags, 7, "d 2 i t"), (tags, 7, "d 2 a t"), (tags, 7, "c i t X ESC"), (tags, 7, "v a t d"), (tags, 7, "y i t P")]
        cases += ["g J", "3 g J", "V j g J", "j g J", "j j j g J", "g J .", "v j j g J"].map { (joined, 1, $0) }
        cases += [
            "g i X ESC", "A X ESC g g g i Y ESC", "w i X Y ESC j j g i Z ESC", "A X ESC g g O n e w ESC j j g i Y ESC",
            "A X ESC g g g i Y ESC j .",
            "x j x j x g ;", "x j x j x g ; g ;", "x j x j x g ; g ; g ,", "x j x j x g ; g ; g ; g ;", "A a b c ESC g g g ;",
            "x w x w x j g ; g ;", "A 1 2 3 4 5 6 7 8 9 0 ESC j 0 x g g g ; g ;", "j d d j x g g g ; g ;",
            "y w j d w j d d g g \" 1 P", "y w j d w j d d g g \" 2 P", "y w j d w j d d g g \" 3 P", "y w j d w j d d g g \" 0 P",
            "y w j d w j d d g g \" - P", "d w j d d g g \" - P", "x j x j d w g g \" 1 P", "x j x j d w g g \" 3 p",
            "\" a y w j d w g g \" 1 P", "\" a y w j d w g g \" 0 P", "v e d j \" - P", "y y j \" 1 p",
            "A f o o ESC g g \" . P", "c w n e w ESC j 0 \" . P",
        ].map { (words, 0, $0) }
        return cases
    }()

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEvil() throws {
        let repos = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/emacs/.local/straight/repos")
        guard FileManager.default.fileExists(atPath: repos.appendingPathComponent("goto-chg/goto-chg.el").path) else { return }
        let forms = Self.cases.map { c in
            EmacsOracle.Case(text: c.0, point: c.1 + 1, form: """
            (progn
              (setq evil-want-Y-yank-to-eol t evil-undo-system 'undo-redo sentence-end-double-space nil)
              (dolist (d '("evil" "goto-chg")) (add-to-list 'load-path (concat \(lispString(repos.path)) "/" d)))
              (require 'evil)
              (require 'goto-chg)
              (setq kill-ring nil register-alist nil evil-last-small-deletion nil evil-last-insertion nil)
              (buffer-enable-undo)
              (setq buffer-undo-list nil)
              (switch-to-buffer (current-buffer))
              (evil-local-mode 1)
              (evil-normal-state)
              (ignore-errors (execute-kbd-macro (kbd \(lispString(c.2.replacingOccurrences(of: "ESC", with: "<escape>"))))))
              (let ((p (point)) (s evil-state))
                (goto-char (point-max))
                (insert (format "\\n@@STATE %s" s))
                (goto-char p)))
            """)
        }
        let results = try EmacsOracle.run(forms)
        for (c, result) in zip(Self.cases, results) {
            let (text, point, keys) = c
            var driver = VimDriver(text, caret: point)
            driver.type(KeySequence.parse(keys)!)
            guard let marker = result.text.range(of: "\n@@STATE ") else {
                Issue.record("\(keys): \(result.error)")
                continue
            }
            let emacsText = String(result.text[..<marker.lowerBound])
            let state = String(result.text[marker.upperBound...])
            let ours = driver.vim.mode == .insert ? "insert" : driver.vim.mode == .normal ? "normal" : "visual"
            let emacsCaret = EmacsOracle.offset(result.point, in: result.text)
            #expect(driver.text == emacsText && driver.caret == emacsCaret && ours == state,
                    "\(keys.debugDescription) on \(text.debugDescription) at \(point)\nours:  \(driver.text.debugDescription) @\(driver.caret) \(ours)\nevil:  \(emacsText.debugDescription) @\(emacsCaret) \(state) \(result.error)")
        }
    }

    private func run(_ text: String, at caret: Int = 0, _ keys: String) -> VimDriver {
        var driver = VimDriver(text, caret: caret)
        driver.type(KeySequence.parse(keys)!)
        return driver
    }

    @Test func resumesInsertAtTheLastInsertion() {
        #expect(run(Self.words, "A X ESC g g g i Y ESC").text.hasPrefix("alpha betaXY\n"))
        // The mark moves with later edits.
        #expect(run(Self.words, "A X ESC 0 x j j g i Y ESC").text.hasPrefix("lpha betaXY\n"))
        #expect(run(Self.words, "g i X ESC").text.hasPrefix("Xalpha"))
    }

    @Test func goesThroughTheChangeList() {
        #expect(run(Self.words, "x j x j x g g g ;").caret == 21)
        #expect(run(Self.words, "x j x j x g g g ; g ;").caret == 10)
        #expect(run(Self.words, "x j x j x g g g ; g ; g ,").caret == 21)
        // A change within eight characters of a later one is passed over.
        #expect(run(Self.words, "x w x G g ;").caret == 5)
        #expect(run(Self.words, "x w x G g ; g ;").caret == 5)
        #expect(run(Self.words, "3 j g ;").caret == 36)
        // Another command starts over from the latest change.
        #expect(run(Self.words, "x j x j x g ; g ; j g ;").caret == 21)
    }

    @Test func joinsWithoutChangingBlanks() {
        #expect(run(Self.joined, at: 1, "g J").text == "a b  c d\ne\n\nf\n")
        #expect(run(Self.joined, at: 1, "3 g J").text == "a b  c de\n\nf\n")
        #expect(run(Self.joined, at: 1, "V j j g J").text == "a b  c de\n\nf\n")
        #expect(run(Self.joined, at: 1, "g J").caret == 3)
    }

    @Test func repeatsTheLastSubstitution() {
        #expect(run(Self.words, "&").actions == [.ex("&")])
        #expect(run(Self.words, "g &").actions == [.ex("%&&")])
    }

    @Test func numberedRegistersHoldEarlierKills() {
        let keys = "y w j d w j d d g g "
        #expect(run(Self.words, keys + "\" 1 P").text.hasPrefix("epsilon zeta\nalpha beta\n"))
        #expect(run(Self.words, keys + "\" 2 P").text.hasPrefix("gamma alpha beta\n"))
        #expect(run(Self.words, keys + "\" 3 P").text.hasPrefix("alpha alpha beta\n"))
        #expect(run(Self.words, keys + "\" 0 P").text.hasPrefix("alpha alpha beta\n"))
        #expect(run(Self.words, keys + "\" - P").text.hasPrefix("gamma alpha beta\n"))
        var vim = Vim()
        let context = Vim.Context(text: "abcdefghijkl\n", caret: 0)
        for _ in 0..<11 { _ = vim.feed(KeyChord("x"), context) }
        #expect(vim.registers["9"]?.text == "a" && vim.registers["1"]?.text == "a" && vim.registers.keys.filter(\.isNumber).count == 9)
    }

    @Test func readOnlyRegisters() {
        #expect(run(Self.words, "A f o o ESC 0 \" . P").text.hasPrefix("fooalpha betafoo\n"))
        var driver = VimDriver(Self.words, caret: 0)
        driver.fileName = "/notes/todo.org"
        driver.lastEx = "s/a/b"
        driver.type(KeySequence.parse("\" % P")!)
        #expect(driver.text.hasPrefix("/notes/todo.orgalpha"))
        driver.type(KeySequence.parse("j 0 \" : P")!)
        #expect(driver.text.contains("\ns/a/bgamma"))
        _ = driver.vim.search("zeta", forward: true, Vim.Context(text: driver.text, caret: 0))
        driver.type(KeySequence.parse("2 j 0 \" / P")!)
        #expect(driver.text.contains("\nzetaeta theta"))
        // Without a file, a command or a search there is nothing to put.
        #expect(run(Self.words, "\" % P \" : P \" / P \" . P").text == Self.words)
    }

    @Test func sentenceMotionsAndObjects() {
        #expect(run(Self.sentences, ")").caret == 9)
        #expect(run(Self.sentences, at: 38, ")").caret == 45)
        #expect(run(Self.sentences, at: 47, "(").caret == 46)
        #expect(run(Self.sentences, at: 12, "d i s").text.hasPrefix("One two.   Five\n"))
        #expect(run(Self.sentences, at: 12, "d a s").text.hasPrefix("One two. Five\n"))
        #expect(run(Self.lines, at: 21, "d a s").text.hasPrefix("One two.\nThree four.\n\n"))
        #expect(run(Self.lines, "d a s").text.hasPrefix("\nThree four."))
        #expect(run(Self.sentences, "d 2 a s").text.hasPrefix("Five\n"))
        // In Org, a heading and a list item begin sentences of their own.
        var driver = VimDriver("* Head\nBody one. Two\n- item\n", caret: 0)
        driver.org = true
        driver.type(KeySequence.parse(")")!)
        #expect(driver.caret == 7)
        driver.type(KeySequence.parse(") )")!)
        #expect(driver.caret == 21)
    }

    @Test func tagObjects() {
        #expect(run(Self.tags, at: 7, "d i t").text.hasPrefix("<a><b></b> z</a>\n"))
        #expect(run(Self.tags, at: 7, "d a t").text.hasPrefix("<a> z</a>\n"))
        #expect(run(Self.tags, at: 7, "d 2 i t").text.hasPrefix("<a></a>\n"))
        #expect(run(Self.tags, at: 35, "d i t").text.contains("<p class=\"k\"></p>"))
        #expect(run(Self.tags, at: 46, "d a t").text == Self.tags)
        // A pair that fills its lines goes with them.
        #expect(run(Self.tags, at: 35, "d a t").text == "<a><b>x y</b> z</a>\n<br/> tail\n")
    }

    @Test func scrollsByLinesAndColumns() {
        #expect(run(Self.words, "C-e").actions == [.scrollLines(1)])
        #expect(run(Self.words, "3 C-y").actions == [.scrollLines(-3)])
        #expect(run(Self.words, "z l").actions == [.scrollColumns(1, halfWidths: false)])
        #expect(run(Self.words, "4 z h").actions == [.scrollColumns(-4, halfWidths: false)])
        #expect(run(Self.words, "z L").actions == [.scrollColumns(1, halfWidths: true)])
        #expect(run(Self.words, "z H").actions == [.scrollColumns(-1, halfWidths: true)])
    }
}
