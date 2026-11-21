#if canImport(SQLite3)
import Foundation
import OrgCore
import SQLite3

/// sqlite blocks with the SQLite library, as `sqlite3` (macOS's, 3.54.0) runs them for ob-sqlite,
/// for builds that can't start it. The command-line options ob-sqlite writes and the dot-commands
/// `.headers`, `.mode`, `.separator`, `.nullvalue` and `.import` into an existing table are
/// emulated in the list, csv, column, html and line modes. Anything else, and values whose text
/// `sqlite3` would escape or lay out by display width, is refused rather than shown differently.
public enum SQLiteBlocks {
    /// Runs `job` when it is an sqlite block, in `directory` or its `:dir`; nil for other jobs.
    public static func run(_ job: BabelJob, directory: URL) throws -> BabelOutput? {
        guard job.language == "sqlite", let command = job.sqlite else { return nil }
        let folder = job.directory.map { URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL } ?? directory
        guard FileManager.default.fileExists(atPath: folder.path) else { throw Babel.Failure.message("No folder \(folder.path) for :dir.") }
        do {
            guard let arguments = command.arguments else { throw Refusal(.shell) }
            var shell = try Shell(arguments: arguments)
            var input = job.input
            var temporary: URL?
            if !job.dataFiles.isEmpty {
                let files = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-sqlite-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
                temporary = files
                for (token, contents) in job.dataFiles {
                    let file = files.appendingPathComponent("sql-data-\(token.filter(\.isNumber))")
                    try contents.write(to: file, atomically: true, encoding: .utf8)
                    input = input.replacingOccurrences(of: token, with: file.path)
                }
            }
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            return try shell.run(input, folder: folder)
        } catch let refusal as Refusal {
            throw Babel.Failure.message(refusal.message)
        }
    }

    /// Why a block can't run as `sqlite3` would run it.
    struct Refusal: Error, Equatable {
        enum Reason: Equatable {
            case shell, dotCommand(String), blob, control, width, explain, newTable, importRows, encoding
        }
        let reason: Reason
        /// Statements before the refused one ran.
        var partly = false
        init(_ reason: Reason, partly: Bool = false) { (self.reason, self.partly) = (reason, partly) }

        var message: String {
            let what: String
            switch reason {
            case .shell: what = String(localized: "header arguments with shell syntax", comment: "Why an sqlite block can't run here")
            case .dotCommand(let name): what = String(localized: "the dot-command \(name)", comment: "Why an sqlite block can't run here")
            case .blob: what = String(localized: "BLOB values", comment: "Why an sqlite block can't run here")
            case .control: what = String(localized: "control characters in values", comment: "Why an sqlite block can't run here")
            case .width: what = String(localized: "text other than plain ASCII in column or line mode", comment: "Why an sqlite block can't run here")
            case .explain: what = String(localized: "EXPLAIN statements", comment: "Why an sqlite block can't run here")
            case .newTable: what = String(localized: ".import into a table that doesn't exist yet", comment: "Why an sqlite block can't run here")
            case .importRows: what = String(localized: ".import of rows that don't fit the table", comment: "Why an sqlite block can't run here")
            case .encoding: what = String(localized: "text that isn't UTF-8", comment: "Why an sqlite block can't run here")
            }
            return partly
                ? String(localized: "This sqlite block can't run here: \(what). The statements before it ran.", comment: "An sqlite block refused partway")
                : String(localized: "This sqlite block can't run here: \(what).", comment: "An sqlite block refused before it ran")
        }
    }

    /// `sqlite3` reading the input as a script.
    struct Shell {
        enum Mode: String { case list, csv, column, html, line }
        var mode = Mode.list
        var header = false
        /// Set by `.headers`, which outlasts a change of mode; the command-line options don't.
        var headerFlag: Bool?
        var separator = "|"
        var rowSeparator = "\n"
        var nullValue = ""
        var echo = false
        var bail = false
        var readonly = false
        var database: String?

        init(arguments: [String]) throws {
            var i = 0
            while i < arguments.count {
                let argument = arguments[i]
                switch argument {
                case "-header": header = true
                case "-noheader": header = false
                case "-separator", "-nullvalue":
                    guard i + 1 < arguments.count else { throw Refusal(.shell) }
                    i += 1
                    if argument == "-separator" { separator = arguments[i] } else { nullValue = arguments[i] }
                case "-echo": echo = true
                case "-bail": bail = true
                case "-readonly": readonly = true
                case "-csv", "-list", "-column", "-html", "-line": change(to: Mode(rawValue: String(argument.dropFirst()))!)
                default:
                    guard !argument.hasPrefix("-"), database == nil else { throw Refusal(.shell) }
                    database = argument
                }
                i += 1
            }
        }

        mutating func change(to new: Mode) {
            mode = new
            separator = ["csv": ",", "list": "|", "line": ": "][new.rawValue] ?? ""
            rowSeparator = new == .csv ? "\r\n" : "\n"
            nullValue = ""
            header = headerFlag ?? (new == .column || new == .html)
        }

        /// What `process_input` reads: dot-commands, lines it only echoes, and SQL.
        enum Item {
            case echo(String)
            case dot(String, [String])
            case sql(String, line: Int)
        }

        static func isSpace(_ c: UInt8) -> Bool { c == 32 || (9...13).contains(c) }

        /// `line_is_all_whitespace`: spaces and SQL comments.
        static func isAllWhitespace(_ line: String) -> Bool {
            let z = Array(line.utf8)
            var i = 0
            while i < z.count {
                if isSpace(z[i]) { i += 1; continue }
                if z[i] == UInt8(ascii: "/"), i + 1 < z.count, z[i + 1] == UInt8(ascii: "*") {
                    i += 2
                    while i < z.count, !(z[i] == UInt8(ascii: "*") && i + 1 < z.count && z[i + 1] == UInt8(ascii: "/")) { i += 1 }
                    if i >= z.count { return false }
                    i += 2
                    continue
                }
                if z[i] == UInt8(ascii: "-"), i + 1 < z.count, z[i + 1] == UInt8(ascii: "-") {
                    while i < z.count, z[i] != UInt8(ascii: "\n") { i += 1 }
                    if i >= z.count { return true }
                    continue
                }
                return false
            }
            return true
        }

        static func items(_ input: String) throws -> [Item] {
            var lines = input.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            var items: [Item] = []
            var sql = ""
            var start = 0
            for (n, line) in lines.enumerated() {
                if sql.isEmpty, isAllWhitespace(line) {
                    items.append(.echo(line))
                    continue
                }
                if sql.isEmpty, line.hasPrefix(".") || line.hasPrefix("#") {
                    items.append(line.hasPrefix(".") ? .dot(line, try dotArguments(line)) : .echo(line))
                    continue
                }
                if sql.isEmpty {
                    sql = String(decoding: line.utf8.drop(while: isSpace), as: UTF8.self)
                    start = n + 1
                } else {
                    sql += "\n" + line
                }
                if line.contains(";"), sqlite3_complete(sql) != 0 {
                    items.append(.sql(sql, line: start))
                    sql = ""
                } else if !sql.isEmpty, isAllWhitespace(sql) {
                    items.append(.echo(sql))
                    sql = ""
                }
            }
            if !sql.isEmpty { items.append(.sql(sql, line: start)) }
            return items
        }

        /// A dot-command's words, refused unless it is one of those emulated, written plainly.
        static func dotArguments(_ line: String) throws -> [String] {
            let words = line.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let name = words.first ?? ""
            let refusal = Refusal(.dotCommand("." + name))
            guard !line.contains(where: { "\"'\\\r;".contains($0) }) else { throw refusal }
            switch name {
            case "header", "headers":
                guard words.count == 2, ["on", "off", "yes", "no", "1", "0", "true", "false"].contains(words[1]) else { throw refusal }
            case "mode":
                guard words.count == 2, Mode(rawValue: words[1]) != nil else { throw refusal }
            case "separator", "nullvalue":
                guard words.count == 2 else { throw refusal }
            case "import":
                let rest = words.dropFirst().filter { $0 != "--csv" && $0 != "-csv" }
                guard rest.count == 2, !rest[rest.startIndex].hasPrefix("-"), !rest[rest.startIndex].hasPrefix("|"),
                      !rest[rest.startIndex].hasPrefix("<<"), !rest.last!.hasPrefix("-"), !rest.last!.contains(".") else { throw refusal }
            default:
                throw refusal
            }
            return words
        }

        mutating func run(_ input: String, folder: URL) throws -> BabelOutput {
            let items = try Self.items(input)
            var out = Data()
            var err = ""
            func write(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
            var db: OpaquePointer?
            let flags = readonly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            let path = database.map { URL(fileURLWithPath: $0, relativeTo: folder).standardizedFileURL.path } ?? ":memory:"
            defer { sqlite3_close(db) }
            if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
                let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
                if Sandbox.isActive || !Self.onMac {
                    throw Babel.Failure.message(String(localized: "Can't open the database \(database ?? ""): \(reason). orgstar can open files only in the folders it has access to.", comment: "An sqlite block's database that can't be opened"))
                }
                return BabelOutput(stdout: "", stderr: "Error: unable to open database \"\(database ?? "")\": \(reason)\n", status: 1)
            }
            var errors = 0
            var ran = false
            for item in items {
                if errors > 0, bail { break }
                switch item {
                case .echo(let line):
                    if echo { write(line + "\n") }
                case .dot(let line, let words):
                    if echo { write(line + "\n") }
                    do {
                        if try dot(words, db: db!, error: &err) { errors += 1 }
                    } catch var refusal as Refusal {
                        refusal.partly = ran
                        throw refusal
                    }
                    ran = true
                case .sql(let sql, let line):
                    if echo { write(sql + "\n") }
                    do {
                        if try execute(sql, line: line, db: db!, write: write, error: &err) { errors += 1 }
                    } catch var refusal as Refusal {
                        refusal.partly = refusal.partly || ran
                        throw refusal
                    }
                    ran = true
                }
            }
            return BabelOutput(stdout: String(decoding: out, as: UTF8.self), stderr: err, status: errors > 0 ? 1 : 0)
        }

        static var onMac: Bool {
            #if os(macOS)
            true
            #else
            false
            #endif
        }

        /// A dot-command; true when it failed.
        mutating func dot(_ words: [String], db: OpaquePointer, error: inout String) throws -> Bool {
            switch words[0] {
            case "header", "headers":
                headerFlag = ["on", "yes", "1", "true"].contains(words[1])
                header = headerFlag!
            case "mode":
                change(to: Mode(rawValue: words[1])!)
            case "separator":
                separator = words[1]
            case "nullvalue":
                nullValue = words[1]
            default:
                return try importFile(words, db: db, error: &error)
            }
            return false
        }

        /// `.import FILE TABLE` into a table that exists, as CSV.
        func importFile(_ words: [String], db: OpaquePointer, error: inout String) throws -> Bool {
            let rest = words.dropFirst().filter { $0 != "--csv" && $0 != "-csv" }
            let csvOption = words.count != rest.count + 1
            let (file, table) = (rest[rest.startIndex], rest[rest.startIndex + 1])
            var columnSeparator = csvOption ? UInt8(ascii: ",") : (separator.utf8.first ?? UInt8(ascii: ","))
            if columnSeparator >= 0x80 { columnSeparator = UInt8(ascii: ",") }
            var statement: OpaquePointer?
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM pragma_table_info('\(table.replacingOccurrences(of: "'", with: "''"))')", -1, &statement, nil) == SQLITE_OK else {
                throw Refusal(.newTable)
            }
            let columns = sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
            sqlite3_finalize(statement)
            guard columns > 0 else { throw Refusal(.newTable) }
            guard let data = FileManager.default.contents(atPath: file) else {
                error += "Error: cannot open \"\(file)\"\n"
                return true
            }
            let rows = try Self.csvRows(Array(data), separator: columnSeparator)
            guard rows.allSatisfy({ $0.count == columns }) else { throw Refusal(.importRows) }
            let insert = "INSERT INTO \(quoted) VALUES(" + Array(repeating: "?", count: columns).joined(separator: ",") + ")"
            guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else { throw Refusal(.newTable) }
            defer { sqlite3_finalize(statement) }
            let commit = sqlite3_get_autocommit(db) != 0
            if commit { sqlite3_exec(db, "BEGIN", nil, nil, nil) }
            var failed = false
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (n, row) in rows.enumerated() {
                for (i, field) in row.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), field, -1, transient) }
                sqlite3_step(statement)
                if sqlite3_reset(statement) != SQLITE_OK {
                    error += "\(file):\(n + 1): INSERT failed: \(String(cString: sqlite3_errmsg(db)))\n"
                    failed = true
                    if bail { break }
                }
            }
            if commit { sqlite3_exec(db, "COMMIT", nil, nil, nil) }
            return failed
        }

        /// `csv_read_one_field` over a file of well-formed CSV: rows of fields.
        static func csvRows(_ bytes: [UInt8], separator: UInt8) throws -> [[String]] {
            let quote = UInt8(ascii: "\""), newline = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")
            var rows: [[String]] = []
            var row: [String] = []
            var i = 0
            // Any quote must open a field and close it; else the reader's warnings and
            // recovery would apply.
            while i < bytes.count {
                var field: [UInt8] = []
                if bytes[i] == quote {
                    i += 1
                    while true {
                        guard i < bytes.count else { throw Refusal(.importRows) }
                        if bytes[i] == quote {
                            if i + 1 < bytes.count, bytes[i + 1] == quote {
                                field.append(quote)
                                i += 2
                                continue
                            }
                            i += 1
                            break
                        }
                        field.append(bytes[i])
                        i += 1
                    }
                    guard i == bytes.count || bytes[i] == separator || bytes[i] == newline else { throw Refusal(.importRows) }
                } else {
                    while i < bytes.count, bytes[i] != separator, bytes[i] != newline {
                        guard bytes[i] != quote else { throw Refusal(.importRows) }
                        field.append(bytes[i])
                        i += 1
                    }
                    if i < bytes.count, bytes[i] == newline, field.last == cr { field.removeLast() }
                }
                guard let text = String(bytes: field, encoding: .utf8) else { throw Refusal(.encoding) }
                row.append(text)
                if i < bytes.count, bytes[i] == separator {
                    i += 1
                    if i == bytes.count { row.append("") }
                } else {
                    rows.append(row)
                    row = []
                    if i < bytes.count { i += 1 }
                }
            }
            if !row.isEmpty { rows.append(row) }
            // The first-row byte-order mark the reader skips.
            if let first = rows.first?.first, first.hasPrefix("\u{FEFF}") { throw Refusal(.encoding) }
            return rows
        }

        /// `shell_exec` of one group of statements; true when one failed.
        func execute(_ sql: String, line: Int, db: OpaquePointer, write: (String) -> Void, error: inout String) throws -> Bool {
            var bytes = Array(sql.utf8CString)
            return try bytes.withUnsafeMutableBufferPointer { buffer -> Bool in
                var next: UnsafePointer<CChar>? = UnsafePointer(buffer.baseAddress!)
                while let start = next, start.pointee != 0 {
                    var statement: OpaquePointer?
                    var tail: UnsafePointer<CChar>?
                    if sqlite3_prepare_v2(db, start, -1, &statement, &tail) != SQLITE_OK {
                        error += "Parse error near line \(line): \(String(cString: sqlite3_errmsg(db)))\n"
                        return true
                    }
                    next = tail
                    while let rest = next, rest.pointee != 0, Self.isSpace(UInt8(bitPattern: rest.pointee)) { next = rest + 1 }
                    guard let statement else { continue }
                    defer { sqlite3_finalize(statement) }
                    if sqlite3_stmt_isexplain(statement) != 0 { throw Refusal(.explain) }
                    let failed = try output(statement, db: db, write: write)
                    if failed {
                        error += "Error near line \(line): \(String(cString: sqlite3_errmsg(db)))\n"
                        return true
                    }
                }
                return false
            }
        }

        /// A value as text, with its type; nil text for NULL.
        struct Cell {
            let text: String?
            let numeric: Bool
        }

        func cell(_ statement: OpaquePointer, _ i: Int32) throws -> Cell {
            switch sqlite3_column_type(statement, i) {
            case SQLITE_NULL: return Cell(text: nil, numeric: false)
            case SQLITE_BLOB: throw Refusal(.blob)
            case let type:
                guard let pointer = sqlite3_column_text(statement, i) else { return Cell(text: nil, numeric: false) }
                let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, i)))
                guard let text = String(bytes: bytes, encoding: .utf8) else { throw Refusal(.encoding) }
                try Self.check(text)
                return Cell(text: text, numeric: type == SQLITE_INTEGER || type == SQLITE_FLOAT)
            }
        }

        /// Control characters other than tab and newline `sqlite3` escapes.
        static func check(_ text: String) throws {
            if text.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\t" && $0 != "\n") || $0.value == 0x7F }) {
                throw Refusal(.control)
            }
        }

        /// Writes the statement's rows in the mode; true when stepping failed.
        func output(_ statement: OpaquePointer, db: OpaquePointer, write: (String) -> Void) throws -> Bool {
            let count = sqlite3_column_count(statement)
            let names = try (0..<count).map { i -> String in
                let name = sqlite3_column_name(statement, i).map { String(cString: $0) } ?? ""
                try Self.check(name)
                return name
            }
            var rows: [[Cell]] = []
            var failed = false
            var buffered = ""
            func emit(_ s: String) { if mode == .column { buffered += s } else { write(s) } }
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    failed = true
                    break
                }
                guard count > 0 else { continue }
                let row = try (0..<count).map { try cell(statement, $0) }
                switch mode {
                case .column:
                    rows.append(row)
                case .line:
                    let width = try names.map { name -> Int in
                        guard name.allSatisfy({ $0.isASCII }) else { throw Refusal(.width) }
                        return name.utf8.count
                    }.max() ?? 0
                    if !rows.isEmpty { emit("\n") }
                    rows.append([])
                    for (name, value) in zip(names, row) {
                        let pieces = (value.text ?? nullValue).components(separatedBy: "\n")
                        var lines = Array(pieces)
                        // A final newline ends the last line.
                        if lines.count > 1, lines.last == "" { lines.removeLast() }
                        emit(String(repeating: " ", count: width - name.utf8.count) + name + separator + lines[0] + "\n")
                        for more in lines.dropFirst() {
                            emit(String(repeating: " ", count: width + separator.utf8.count) + more + "\n")
                        }
                    }
                case .html:
                    if rows.isEmpty, header {
                        emit("<TR>\n" + names.map { "<TH>" + Self.html($0) + "\n" }.joined() + "</TR>\n")
                    }
                    rows.append([])
                    emit("<TR>\n" + row.map { "<TD>" + ($0.text.map(Self.html) ?? "null") + "\n" }.joined() + "</TR>\n")
                case .list, .csv:
                    if rows.isEmpty, header {
                        emit(names.map { mode == .csv ? csv($0) : $0 }.joined(separator: separator) + rowSeparator)
                    }
                    rows.append([])
                    emit(row.map { value in
                        guard let text = value.text else { return nullValue }
                        return mode == .csv && !value.numeric ? csv(text) : text
                    }.joined(separator: separator) + rowSeparator)
                }
            }
            if mode == .column, !rows.isEmpty {
                try column(names: names, rows: rows, emit: emit)
                write(buffered)
            }
            return failed
        }

        /// CSV quoting: a field with a control character, space, quote, apostrophe, DEL or byte
        /// above ASCII, or with the separator, is quoted.
        func csv(_ text: String) -> String {
            let special = text.isEmpty || text.utf8.contains { $0 < 0x20 || $0 == 0x20 || $0 == 0x22 || $0 == 0x27 || $0 >= 0x7F }
            guard special || (!separator.isEmpty && text.contains(separator)) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }

        /// `sqlite3`'s HTML escaping, which writes `>` as `&lt;`.
        static func html(_ text: String) -> String {
            var out = ""
            for c in text.unicodeScalars {
                switch c {
                case "<", ">": out += "&lt;"
                case "&": out += "&amp;"
                case "\"": out += "&quot;"
                case "'": out += "&#39;"
                default: out.unicodeScalars.append(c)
                }
            }
            return out
        }

        /// Column mode: each column as wide as its widest text, the titles centered over a rule,
        /// numbers to the right, two spaces between columns, no spaces at the ends of lines.
        func column(names: [String], rows: [[Cell]], emit: (String) -> Void) throws {
            func plain(_ s: String) throws -> String {
                guard s.allSatisfy({ $0.isASCII && $0 != "\t" && $0 != "\n" }) else { throw Refusal(.width) }
                return s
            }
            let texts = try rows.map { try $0.map { try plain($0.text ?? nullValue) } }
            let titles = try names.map(plain)
            var widths = Array(repeating: 0, count: names.count)
            for (i, title) in titles.enumerated() where header { widths[i] = max(widths[i], title.count) }
            for row in texts { for (i, text) in row.enumerated() { widths[i] = max(widths[i], text.count) } }
            func line(_ cells: [String], _ align: (Int) -> Character) -> String {
                var s = ""
                for (i, text) in cells.enumerated() {
                    let space = widths[i] - text.count
                    switch align(i) {
                    case "c": s += String(repeating: " ", count: space / 2) + text + String(repeating: " ", count: space - space / 2)
                    case "r": s += String(repeating: " ", count: space) + text
                    default: s += text + String(repeating: " ", count: space)
                    }
                    if i < cells.count - 1 { s += "  " }
                }
                while s.last == " " { s.removeLast() }
                return s + "\n"
            }
            if header {
                emit(line(titles) { _ in "c" })
                emit(line(widths.map { String(repeating: "-", count: $0) }) { _ in "l" })
            }
            for (row, cells) in zip(texts, rows) {
                emit(line(row) { cells[$0].numeric ? "r" : "l" })
            }
        }
    }
}
#endif
