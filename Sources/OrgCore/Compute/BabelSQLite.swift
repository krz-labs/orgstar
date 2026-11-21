import Foundation

// ob-sqlite (Org 9.8.7): the body goes to `sqlite3` on standard input, with the options the
// header arguments name, and the output becomes the result through `org-table-convert-region`.

extension Babel {
    /// An sqlite block's `sqlite3` command line.
    public struct SQLiteCommand: Sendable, Equatable {
        /// The command for the shell, as ob-sqlite writes it.
        public let command: String
        /// The command's words after `sqlite3` when they hold nothing the shell would change;
        /// nil otherwise.
        public let arguments: [String]?
    }

    /// Stands, in a job's input, for a data file the runner writes (`BabelJob.dataFiles`).
    public static func dataFileToken(_ n: Int) -> String { "__ORGSTAR_DATA_FILE_\(n)__" }

    static func sqliteJob(body: String, vars: [(String, VarValue)], params: Params, finishBase: (BabelJob.Finish.Kind) -> BabelJob.Finish,
                          directory: String?, block: Range<Int>, blockText: String, alwaysAsk: Bool) throws -> BabelJob {
        let separator = params.single[":separator"], nullvalue = params.single[":nullvalue"], db = params.single[":db"]
        let headers = params.single[":colnames"] == "yes"
        let others = [":header", ":echo", ":bail", ":column", ":csv", ":html", ":line", ":list"].filter { params.single[$0] != nil }
        let formatted = others.contains { [":csv", ":column", ":line", ":list", ":html"].contains($0) } || separator != nil
        let fields: [(String, String)] = [
            ("cmd", "sqlite3"),
            ("header", headers ? "-header" : "-noheader"),
            ("separator", separator.map { "-separator \($0)" } ?? ""),
            ("nullvalue", nullvalue.map { "-nullvalue \($0)" } ?? ""),
            ("others", others.map { "-" + $0.dropFirst() }.joined(separator: " ")),
            ("csv", formatted ? "" : "-csv"),
            ("readonly", params.single[":readonly"] == "yes" ? "-readonly" : ""),
            ("db", db ?? ""),
        ]
        // `org-fill-template`.
        var command = "%cmd %header %separator %nullvalue %others %csv %readonly %db "
        for (key, value) in fields { command = command.replacingOccurrences(of: "%" + key, with: value) }
        let words = command.split(separator: " ").dropFirst().map(String.init)
        let plain = words.allSatisfy { $0.range(of: "^[A-Za-z0-9._/:@%+=,-]+$", options: .regularExpression) != nil }
            && !(db?.hasPrefix("-") ?? false) && words.count == command.split(separator: " ").count - 1

        // `org-babel-sql-expand-vars`: `$name` replaced, a table by a CSV file of it.
        var expanded = body
        var files: [String: String] = [:]
        for (name, value) in vars {
            guard name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw Failure.message(":var \(name) isn't supported for sqlite blocks; nothing was run.")
            }
            let replacement: String
            switch value {
            case .scalar(let s): replacement = s
            case .number(let n): replacement = n
            case .table(let rows):
                let token = dataFileToken(files.count)
                files[token] = try csvFile(rows, name: name)
                replacement = token
            case .list:
                throw Failure.message(":var \(name) is a list, which sqlite blocks can't take; nothing was run.")
            }
            expanded = replacingCaseInsensitively("$" + name, in: expanded, with: replacement)
        }
        let input = [params.single[":prologue"] ?? "", expanded, params.single[":epilogue"] ?? ""].joined(separator: "\n") + "\n"
        var finish = finishBase(.sqlite(csv: !formatted, headers: headers))
        // ob-sqlite doesn't put back the names `:var` tables gave up.
        (finish.colnames, finish.rownames) = (nil, nil)
        var job = BabelJob(language: "sqlite", runner: .process(executable: command, arguments: []), input: input, directory: directory,
                           block: block, blockText: blockText, alwaysAsk: alwaysAsk, finish: finish)
        job.sqlite = SQLiteCommand(command: command, arguments: plain ? words : nil)
        job.dataFiles = files
        return job
    }

    /// `replace-regexp-in-string` of a literal with `case-fold-search`.
    static func replacingCaseInsensitively(_ target: String, in text: String, with replacement: String) -> String {
        let ns = text as NSString
        var result = ""
        var location = 0
        while location <= ns.length {
            let found = ns.range(of: target, options: [.caseInsensitive, .literal], range: NSRange(location: location, length: ns.length - location))
            guard found.location != NSNotFound else { break }
            result += ns.substring(with: NSRange(location: location, length: found.location - location)) + replacement
            location = NSMaxRange(found)
        }
        return result + ns.substring(from: min(location, ns.length))
    }

    /// `orgtbl-to-csv` of a table: rules dropped, a field with `"` or `,` quoted, no final
    /// newline. Cells the Org exporter could change are refused.
    static func csvFile(_ rows: [[Cell]?], name: String) throws -> String {
        try rows.compactMap { $0 }.map { row in
            try row.map { cell in
                let text = cellText(cell)
                guard text.range(of: "[\\[\\]{}<>@\\\\\\n\\t]|src_|call_", options: .regularExpression) == nil,
                      text == text.trimmingCharacters(in: .whitespaces) else {
                    throw Failure.message(":var \(name) has a cell the Org exporter may change; nothing was run.")
                }
                return text.contains("\"") || text.contains(",") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    // MARK: - Results

    /// ob-sqlite's result from `sqlite3`'s output: the output
    /// as a string or through `org-table-convert-region` as a table, a single cell alone.
    static func sqliteValue(_ output: String, csv: Bool, headers: Bool, scalar: Bool) -> Value {
        // csv mode ends lines with CRLF, and Emacs keeps the CR.
        let text = output
        if scalar { return .string(text) }
        if text.isEmpty { return .string("") }
        guard var rows: [[String]?] = convertRegion(text, csv: csv) else { return .none }
        if headers, let first = rows.first {
            rows = [first, nil] + rows.dropFirst()
        }
        // `org-babel-sqlite-table-or-scalar`.
        if rows.count == 1, let only = rows[0], only.count == 1 { return .string(babelRead(only[0])) }
        return .table(rows.map { $0?.map(babelRead) })
    }

    /// The error Emacs stops with while making a table of the output, if any.
    static func sqliteFailure(_ finish: BabelJob.Finish, _ output: BabelOutput) -> String? {
        guard case .sqlite(let csv, _) = finish.kind, !resultCondScalar(finish.params), !finish.params.contains("discard"),
              !output.stdout.isEmpty, convertRegion(output.stdout, csv: csv) == nil else { return nil }
        return "Invalid search bound (wrong side of point)"
    }

    /// `org-babel-read` with Lisp evaluation inhibited: a number as Emacs prints it, a single
    /// quoted string read, else the cell.
    static func babelRead(_ cell: String) -> String {
        guard cell.contains(where: { !$0.isWhitespace }) else { return cell }
        if !cell.contains("\r"), let n = number(cell), cell.range(of: "^[0-9e.+ -]+$", options: .regularExpression) != nil { return n }
        let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.count >= 2, trimmed.hasSuffix("\""),
           let (sexp, length) = try? LispReader.readFirst(trimmed), length == trimmed.count, let s = sexp.string {
            return s
        }
        return cell
    }

    /// `org-table-convert-region` on the whole output, then `org-table-to-lisp` of the aligned
    /// table: rows of cells, padded to the widest row. Nil where Emacs fails: a last empty line
    /// in a region read without a comma separator puts point past the search bound.
    static func convertRegion(_ text: String, csv: Bool) -> [[String]?]? {
        var b = Array(text.unicodeScalars)
        let nl: Unicode.Scalar = "\n", tab: Unicode.Scalar = "\t", space: Unicode.Scalar = " ", comma: Unicode.Scalar = ",", quote: Unicode.Scalar = "\""
        var end = b.last == nl ? b.count - 1 : b.count
        var point = 0
        func bol(_ i: Int) -> Bool { i == 0 || b[i - 1] == nl }
        func replace(_ range: Range<Int>, _ s: [Unicode.Scalar]) {
            b.replaceSubrange(range, with: s)
            if end >= range.upperBound { end += s.count - range.count } else if end > range.lowerBound { end = range.lowerBound }
        }
        enum Separator { case comma, tab, spaces }
        var separator = Separator.comma
        if !csv {
            let lines = String(String.UnicodeScalarView(b[0..<end])).components(separatedBy: "\n").filter { !$0.isEmpty }
            if !lines.contains(where: { !$0.contains("\t") }) {
                separator = .tab
            } else if !lines.contains(where: { !$0.contains(",") }) {
                separator = .comma
            } else {
                separator = .spaces
            }
        }
        if separator == .comma {
            while point < end {
                if bol(point) {
                    replace(point..<point, ["|", " "])
                    point += 2
                    continue
                }
                var j = point
                while j < b.count, b[j] == space || b[j] == tab { j += 1 }
                if j == b.count || b[j] == nl {
                    // `[ \t]*$`, then the next line.
                    replace(point..<j, [" ", "|"])
                    point += 2
                    if let next = b[point...].firstIndex(of: nl) { point = next + 1 } else { point = b.count }
                    continue
                }
                if b[j] == quote, let close = b[(j + 1)...].firstIndex(of: quote) {
                    let content = b[(j + 1)..<close].map { $0 == nl ? space : $0 }
                    replace(point..<(close + 1), Array(content))
                    point += content.count
                    if point < b.count, b[point] == quote {
                        replace(point..<point, [quote])
                        point += 1
                    }
                    continue
                }
                if point < b.count, b[point] != comma, b[point] != nl {
                    while point < b.count, b[point] != comma, b[point] != nl { point += 1 }
                    continue
                }
                if j < b.count, b[j] == comma {
                    replace(point..<(j + 1), [" ", "|", " "])
                    point += 3
                    continue
                }
                if let next = b[point...].firstIndex(of: nl) { point = next + 1 } else { point = b.count }
            }
        } else {
            // `re-search-forward` of "^\\|\t", or "^ *\\| *\t *\\| \\{1,\\}", each match
            // replaced by "| ".
            while point <= end {
                var match: Range<Int>?
                var i = point
                while i <= end, match == nil {
                    if bol(i) {
                        var k = i
                        if separator == .spaces { while k < end, b[k] == space { k += 1 } }
                        match = i..<k
                    } else if i < end {
                        if separator == .tab {
                            if b[i] == tab { match = i..<(i + 1) }
                        } else {
                            var k = i
                            while k < end, b[k] == space { k += 1 }
                            if k < end, b[k] == tab {
                                var m = k + 1
                                while m < end, b[m] == space { m += 1 }
                                match = i..<m
                            } else if k > i {
                                match = i..<k
                            }
                        }
                    }
                    i += 1
                }
                guard let found = match else { break }
                if found.lowerBound == end { return nil }
                replace(found, ["|", " "])
                point = found.lowerBound + 2
            }
        }
        // The table: the lines from the start that begin with `|`.
        var rows: [[String]] = []
        for line in String(String.UnicodeScalarView(b)).components(separatedBy: "\n") {
            var s = Substring(line)
            s = s.drop { $0 == " " || $0 == "\t" }
            guard s.first == "|" else { break }
            s = s.dropFirst()
            var cells: [String] = []
            while true {
                s = s.drop { $0 == " " || $0 == "\t" }
                if s.isEmpty { break }
                let field = s.prefix { $0 != "|" }
                var cell = Substring(field)
                while let last = cell.last, last == " " || last == "\t" { cell = cell.dropLast() }
                cells.append(String(cell))
                s = s.dropFirst(field.count)
                if !s.isEmpty { s = s.dropFirst() }
            }
            rows.append(cells)
        }
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }
}
