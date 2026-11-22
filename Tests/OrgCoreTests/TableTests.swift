import Foundation
import Testing
@testable import OrgCore

struct TableTests {
    @Test func aligns() {
        let result = runCommand(TableCommand(.align), "|a|bb|\n|ccc|1|\n", caret: 1).text
        #expect(result == "| a   | bb |\n| ccc |  1 |\n")
    }

    static let variants = [
        "|a|bb|\n|ccc|1|\n",
        "| Name | Qty |\n|-\n| apple | 3 |\n| pear | 12 |\n",
        "  | x | y |\n  |---+---|\n  | 1 | 2 |\n",
        "| [[https://example.com][link]] | *bold* | =code= |\n| a | b | c |\n",
        "| \\\\alpha | a_{bc} | x^2 |\n| 1 | 2 | 3 |\n",
        "| <r> | <c5> |\n| a | b |\n",
        "| 1 | 2 |\n| 3 | 4 |\n#+TBLFM: $2=$1*2::@2$1=7\n",
        "text\n| a |\n| b |\nmore\n",
        "| ü | 漢字 |\n| x | y |\n",
        "| a | b\n| c |\n",
        "|-+-|\n",
    ]

    static let commands: [(command: any OrgCommand, form: String, headingLineOnly: Bool)] = [
        (TableCommand(.align), "(org-table-align)", false),
        (TableCommand(.nextField), "(org-table-next-field)", false),
        (TableCommand(.previousField), "(org-table-previous-field)", false),
        (TableCommand(.nextRow), "(org-table-next-row)", false),
        (TableCommand(.moveRowUp), "(org-table-move-row-up)", false),
        (TableCommand(.moveRowDown), "(org-table-move-row-down)", false),
        (TableCommand(.moveColumnLeft), "(org-table-move-column-left)", false),
        (TableCommand(.moveColumnRight), "(org-table-move-column-right)", false),
        (TableCommand(.insertColumn), "(org-table-insert-column)", false),
        (TableCommand(.deleteColumn), "(org-table-delete-column)", false),
        (TableCommand(.killRow), "(org-table-kill-row)", false),
        (TableCommand(.insertRowAbove), "(org-table-insert-row)", false),
        (TableCommand(.insertHline), "(org-table-insert-hline)", false),
    ]

    static func tableCarets(_ text: String) -> [Int] {
        EmacsOracle.positions(text).filter { offset in
            let ns = text as NSString
            let line = ns.lineRange(for: NSRange(location: min(offset, max(0, ns.length - 1)), length: 0))
            return offset < ns.length && ns.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("|")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func tableCommandsMatchEmacs() throws {
        let inputs = Self.variants.map { ($0, Self.tableCarets($0)) }
        try compareWithEmacs(inputs, Self.commands)
        try compareWithEmacs(inputs, Self.commands, options: doomOptions)
    }

    /// TAB realigns only after an edit (`org-table-may-need-update`), which here changes the width
    /// of the field left behind. The last row is out of line, so a realign shows. Emacs starts
    /// as if just aligned, makes the edit, then TABs; we TAB in the same text after the same edit.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func nextFieldRealignsOnlyAfterAWidthChange() throws {
        let table = "| a    | b  |\n|------+----|\n| cc   | dd |\n| eeeeeeee | f |\n"
        let dd = (table as NSString).range(of: "dd").upperBound
        func edit(_ range: Range<Int>, _ replacement: String) -> String {
            (table as NSString).replacingCharacters(in: NSRange(range), with: replacement)
        }
        let cases: [(label: String, form: String, caret: Int, text: String, after: Int)] = [
            ("no edit", "", 3, table, 3),
            ("typed into spare space", "(let ((last-command-event ?x)) (org-self-insert-command 1))", 3, edit(3..<3, "x"), 4),
            ("typed past the column's width", "(insert \"xxxxxxxxxx\")", 3, edit(3..<3, "xxxxxxxxxx"), 13),
            ("deleted with spare space left", "(org-delete-backward-char 1)", 3, edit(2..<3, ""), 2),
            ("deleted from a full field", "(org-delete-backward-char 1)", dd, edit(dd - 1..<dd, ""), dd - 1),
        ]
        let emacs = try EmacsOracle.run(cases.map {
            EmacsOracle.Case(text: table, point: EmacsOracle.point($0.caret, in: table), form: "(progn (setq org-table-may-need-update nil) \($0.form) (org-table-next-field))")
        })
        for (c, theirs) in zip(cases, emacs) {
            let ours = runCommand(TableCommand(.nextField), c.text, caret: c.after)
            let caret = EmacsOracle.offset(theirs.point, in: theirs.text)
            #expect(ours.text == theirs.text && ours.caret == caret, "\(c.label): ours \(ours.text.debugDescription)@\(ours.caret) emacs \(theirs.text.debugDescription)@\(caret)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func createTableMatchesEmacs() throws {
        for (text, caret) in [("", 0), ("x\n", 1), ("  \n", 2)] {
            for size in ["3x2", "1x1", "2x3"] {
                let emacs = try EmacsOracle.run([EmacsOracle.Case(text: text, point: caret + 1, form: "(org-table-create \"\(size)\")")])[0]
                let ours = runCommand(CreateTable(), text, caret: caret, answers: ["size": size])
                #expect(ours.text == emacs.text && ours.caret == EmacsOracle.offset(emacs.point, in: emacs.text), "\(size) in \(text.debugDescription): ours \(ours.text.debugDescription)@\(ours.caret) emacs \(emacs.text.debugDescription)@\(EmacsOracle.offset(emacs.point, in: emacs.text))")
            }
        }
    }

    /// Real tables: `ORGSTAR_ORACLE_CORPUS=<folder>` aligns and TABs in the first cell of up to
    /// eight table rows per file, in up to 60 files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"] != nil))
    func tablesMatchEmacsOnACorpus() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"]!)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "org" }.sorted { $0.path < $1.path }
        var samples: [(String, [Int])] = []
        for file in files where samples.count < 60 {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.utf16.count <= 30_000, !text.contains("\r") else { continue }
            let ns = text as NSString
            var carets: [Int] = []
            var location = 0
            var inBlock = false
            while location < ns.length, carets.count < 8 {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                let content = ns.substring(with: line)
                let trimmed = content.trimmingCharacters(in: .whitespaces).lowercased()
                if trimmed.hasPrefix("#+begin_") { inBlock = true }
                if trimmed.hasPrefix("#+end_") { inBlock = false }
                if !inBlock, trimmed.hasPrefix("|"), let bar = content.firstIndex(of: "|") {
                    carets.append(line.location + content.distance(from: content.startIndex, to: bar) + 2)
                }
                location = NSMaxRange(line)
            }
            if !carets.isEmpty { samples.append((text, carets)) }
        }
        let commands: [(command: any OrgCommand, form: String, headingLineOnly: Bool)] = [
            (TableCommand(.align), "(org-table-align)", false),
            (TableCommand(.nextField), "(org-table-next-field)", false),
        ]
        try compareWithEmacs(samples, commands)
        try compareWithEmacs(samples, commands, options: doomOptions)
    }
}
