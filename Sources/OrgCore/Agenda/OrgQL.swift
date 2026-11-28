import Foundation

// org-ql queries: the sexp form, `(and (todo "NEXT") (tags "work"))`, and the plain form,
// `todo:NEXT tags:work`, read into a `OrgQL.Query` and matched against an `AgendaSource`'s
// headings. Only the predicates in `OrgQL.supported` are read; org-ql's others are refused by
// name. Every heading is matched, archived and commented ones included, as org-ql does.

public enum OrgQL {
    public struct QueryError: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    public enum Comparator: String, Sendable {
        case equal = "=", less = "<", greater = ">", lessOrEqual = "<=", greaterOrEqual = ">="

        func test(_ a: Int, _ b: Int) -> Bool {
            switch self {
            case .equal: a == b
            case .less: a < b
            case .greater: a > b
            case .lessOrEqual: a <= b
            case .greaterOrEqual: a >= b
            }
        }
    }

    public enum TagScope: Sendable { case both, local, inherited }
    public enum StampType: Sendable { case both, active, inactive }
    public enum Planning: Sendable { case deadline, scheduled, closed }

    /// A `:from`, `:to` or `:on` value: days from today, or a day with an optional time
    /// (seconds into the day).
    public enum DateBound: Equatable, Sendable {
        case days(Int)
        case date(day: Int, seconds: Int?)
    }

    public struct DateRange: Equatable, Sendable {
        public var from: DateBound?
        public var to: DateBound?
        /// `:with-time`: only timestamps with a time (true) or without one (false).
        public var withTime: Bool?
    }

    public indirect enum Query: Equatable, Sendable {
        case and([Query])
        case or([Query])
        case not(Query)
        /// Empty: any keyword that isn't done.
        case todo([String])
        case done
        /// Empty: any tag.
        case tags(TagScope, [String])
        /// Empty without a comparator: any priority.
        case priority(Comparator?, [String])
        case planning(Planning, DateRange)
        /// `(deadline auto)`: deadlines within their warning period, or past.
        case deadlineWarning
        case ts(StampType, DateRange)
        /// A clock line in the entry whose time overlaps the range.
        case clocked(DateRange)
        case heading([String])
        case property(String, value: String?, inherit: Bool?)
        case level(Int, Int)
        case path([String])
        case habit
    }

    /// The predicate names read, aliases included.
    public static let supported: Set<String> = [
        "todo", "done", "tags", "tags-all", "tags&", "tags-local", "local-tags", "tags-l", "ltags", "tags-inherited", "inherited-tags",
        "tags-i", "itags", "priority", "deadline", "scheduled", "closed", "clocked", "ts", "ts-active", "ts-a", "ts-inactive", "ts-i", "heading", "h",
        "property", "level", "path", "habit",
    ]

    /// org-ql's other predicate names.
    static let unsupported: Set<String> = [
        "blocked", "category", "c", "effort", "heading-regexp", "h*", "link", "outline-path", "olp", "outline-path-segment", "olps",
        "planning", "regexp", "r", "rifle", "smart", "src", "tags-regexp", "tags*", "ancestors", "parent",
        "children", "descendants",
    ]

    /// The names the plain form recognizes, longest first, as org-ql's grammar tries them.
    static let plainNames = (supported.union(unsupported)).sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }

    /// The sort keys `:sort` takes.
    public static let sortKeys: Set<String> = ["date", "deadline", "scheduled", "closed", "todo", "priority", "random", "reverse"]

    // MARK: - Reading

    /// A query in either form: the sexp form when it starts with `(`, the plain form otherwise.
    public static func parse(_ text: String) throws(QueryError) -> Query {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("(") else { return try plain(trimmed) }
        let sexp: Sexp
        let length: Int
        do {
            (sexp, length) = try LispReader.readFirst(trimmed)
        } catch {
            throw QueryError("Can't read the query: \(error)")
        }
        guard trimmed.dropFirst(length).allSatisfy(\.isWhitespace) else { throw QueryError("Text after the query: \(trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces))") }
        return try query(sexp)
    }

    /// A sexp query.
    public static func query(_ sexp: Sexp) throws(QueryError) -> Query {
        guard let items = sexp.elements, let name = items.first?.symbol else { throw QueryError("Not a query: \(sexp.description)") }
        return try predicate(name, Array(items.dropFirst()))
    }

    /// `org-ql--query-string-to-sexp`: terms separated by blanks, all of which must match; `!`
    /// negates a term; `name:a,b` gives a predicate its arguments and `key=value` a keyword one.
    public static func plain(_ text: String) throws(QueryError) -> Query {
        let chars = Array(text.unicodeScalars)
        var i = 0
        func isSpace(_ c: Unicode.Scalar) -> Bool { CharacterSet.whitespacesAndNewlines.contains(c) }
        func at(_ s: String, _ k: Int) -> Bool {
            let scalars = Array(s.unicodeScalars)
            return k + scalars.count <= chars.count && Array(chars[k..<(k + scalars.count)]) == scalars
        }
        /// A run of characters that aren't `,`, `"`, blanks or `stop`.
        func run(_ k: Int, stop: Unicode.Scalar? = nil) -> Int {
            var j = k
            while j < chars.count, chars[j] != ",", chars[j] != "\"", !isSpace(chars[j]), chars[j] != stop { j += 1 }
            return j
        }
        /// A quoted argument: its text and the index after the closing quote.
        func quoted(_ k: Int) -> (String, Int)? {
            guard k < chars.count, chars[k] == "\"" else { return nil }
            var j = k + 1
            while j < chars.count, chars[j] != ",", chars[j] != "\"" { j += 1 }
            guard j > k + 1, j < chars.count, chars[j] == "\"" else { return nil }
            return (String(String.UnicodeScalarView(chars[(k + 1)..<j])), j + 1)
        }
        var terms: [Query] = []
        while true {
            while i < chars.count, isSpace(chars[i]) { i += 1 }
            guard i < chars.count else { break }
            if at("\"\"", i) {
                i += 2
                continue
            }
            let negated = chars[i] == "!"
            if negated { i += 1 }
            var term: Query
            if let name = plainNames.first(where: { at($0, i) }), at(":", i + name.unicodeScalars.count) {
                i += name.unicodeScalars.count + 1
                var args: [Sexp] = []
                while i < chars.count {
                    let keywordEnd = run(i, stop: "=")
                    if keywordEnd > i, keywordEnd < chars.count, chars[keywordEnd] == "=" {
                        args.append(.symbol(":" + String(String.UnicodeScalarView(chars[i..<keywordEnd]))))
                        i = keywordEnd + 1
                    } else if let (value, next) = quoted(i) {
                        args.append(.string(value))
                        i = next
                    } else if run(i) > i {
                        let end = run(i)
                        args.append(.string(String(String.UnicodeScalarView(chars[i..<end]))))
                        i = end
                    } else {
                        break
                    }
                    if i < chars.count, chars[i] == "," { i += 1 }
                }
                term = try predicate(name, args)
            } else {
                let word: String
                if let (value, next) = quoted(i) {
                    (word, i) = (value, next)
                } else if run(i) > i {
                    let end = run(i)
                    (word, i) = (String(String.UnicodeScalarView(chars[i..<end])), end)
                } else {
                    throw QueryError("Can't read the query at \(String(String.UnicodeScalarView(chars[i...])))")
                }
                throw QueryError("Words without a predicate search with org-ql's rifle predicate, which isn't supported: \(word). Use heading:\(word) to search headings.")
            }
            if negated { term = .not(term) }
            terms.append(term)
        }
        guard !terms.isEmpty else { throw QueryError("The query is empty") }
        return terms.count == 1 ? terms[0] : .and(terms)
    }

    /// `x` for `'x`.
    static func unquoted(_ sexp: Sexp) -> Sexp {
        if let items = sexp.elements, items.count == 2, items[0].symbol == "quote" { return items[1] }
        return sexp
    }

    static func predicate(_ name: String, _ args: [Sexp]) throws(QueryError) -> Query {
        func strings() throws(QueryError) -> [String] {
            var out: [String] = []
            for arg in args {
                guard let s = arg.string else { throw QueryError("\(name) takes strings, not \(arg.description)") }
                out.append(s)
            }
            return out
        }
        func none() throws(QueryError) {
            guard args.isEmpty else { throw QueryError("\(name) takes no arguments") }
        }
        switch name {
        case "and", "or":
            var parts: [Query] = []
            for arg in args { parts.append(try query(arg)) }
            return name == "and" ? .and(parts) : .or(parts)
        case "not":
            guard args.count == 1 else { throw QueryError("not takes one query") }
            return .not(try query(args[0]))
        case "todo": return .todo(try strings())
        case "done":
            try none()
            return .done
        case "tags": return .tags(.both, try strings())
        case "tags-all", "tags&": return .and(try strings().map { .tags(.both, [$0]) })
        case "tags-local", "local-tags", "tags-l", "ltags": return .tags(.local, try strings())
        case "tags-inherited", "inherited-tags", "tags-i", "itags": return .tags(.inherited, try strings())
        case "priority": return try priority(args)
        case "deadline":
            if args.count == 1, (args[0].symbol ?? args[0].string) == "auto" { return .deadlineWarning }
            return .planning(.deadline, try range(name, args, positional: true).range)
        case "scheduled":
            return .planning(.scheduled, try range(name, args, positional: true).range)
        case "closed":
            return .planning(.closed, try range(name, args, positional: false).range)
        case "clocked":
            return .clocked(try range(name, args, positional: false).range)
        case "ts", "ts-active", "ts-a", "ts-inactive", "ts-i":
            var (range, type) = try range(name, args, positional: false)
            if ["ts-active", "ts-a"].contains(name) { type = .active }
            if ["ts-inactive", "ts-i"].contains(name) { type = .inactive }
            return .ts(type, range)
        case "heading", "h": return .heading(try strings())
        case "property": return try property(args)
        case "level": return try level(args)
        case "path":
            let regexps = try strings()
            for regexp in regexps where (try? NSRegularExpression(pattern: EmacsRegex.translate(regexp))) == nil {
                throw QueryError("Invalid regexp \(regexp)")
            }
            return .path(regexps)
        case "habit":
            try none()
            return .habit
        default:
            if unsupported.contains(name) { throw QueryError("org-ql's \(name) predicate isn't supported") }
            throw QueryError("Unknown predicate \(name)")
        }
    }

    static func comparator(_ sexp: Sexp) -> Comparator? {
        let arg = unquoted(sexp)
        return (arg.symbol ?? arg.string).flatMap(Comparator.init(rawValue:))
    }

    static func number(_ sexp: Sexp) -> Int? {
        sexp.integer ?? sexp.string.flatMap { $0.wholeMatch(of: /-?[0-9]+/) != nil ? Int($0) : nil }
    }

    static func priority(_ args: [Sexp]) throws(QueryError) -> Query {
        if let first = args.first, unquoted(first).symbol != nil {
            guard let comparator = comparator(first), args.count == 2, let letter = args[1].string else {
                throw QueryError("priority takes letters, or a comparator and a letter: \((["priority"] + args.map(\.description)).joined(separator: " "))")
            }
            return .priority(comparator, [letter])
        }
        var letters: [String] = []
        for arg in args {
            guard let s = arg.string else { throw QueryError("priority takes strings, not \(arg.description)") }
            letters.append(s)
        }
        return .priority(nil, letters)
    }

    static func level(_ args: [Sexp]) throws(QueryError) -> Query {
        if args.count == 1, let n = number(args[0]) { return .level(n, n) }
        if args.count == 2, let a = number(args[0]), let b = number(args[1]) { return .level(min(a, b), max(a, b)) }
        if args.count == 2, let comparator = comparator(args[0]), let n = number(args[1]) {
            switch comparator {
            case .equal: return .level(n, n)
            case .less: return .level(Int.min, n - 1)
            case .lessOrEqual: return .level(Int.min, n)
            case .greater: return .level(n + 1, Int.max)
            case .greaterOrEqual: return .level(n, Int.max)
            }
        }
        throw QueryError("level takes a number, two numbers, or a comparator and a number")
    }

    static func flag(_ sexp: Sexp) -> Bool? {
        switch sexp.symbol ?? sexp.string {
        case "t": true
        case "nil": false
        default: nil
        }
    }

    static func property(_ args: [Sexp]) throws(QueryError) -> Query {
        var rest = args[...]
        guard let first = rest.popFirst(), var name = first.string ?? first.symbol else { throw QueryError("property takes a property name") }
        if first.symbol != nil, name.hasPrefix(":") { name.removeFirst() }
        var value: String?
        if let next = rest.first, let s = next.string {
            value = s
            rest.removeFirst()
        }
        var inherit: Bool?
        while let key = rest.popFirst() {
            guard key.symbol == ":inherit", let v = rest.popFirst(), let f = flag(v) else { throw QueryError("property takes a name, a value and :inherit t or nil") }
            inherit = f
        }
        return .property(name, value: value, inherit: inherit)
    }

    nonisolated(unsafe) static let dateRegex = /([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[ T]+(?:[A-Za-z]+\.?[ ]+)?([0-9]{1,2}):([0-9]{2}))?/

    static func bound(_ sexp: Sexp, _ name: String) throws(QueryError) -> DateBound {
        if let n = number(sexp) { return .days(n) }
        if (sexp.symbol ?? sexp.string) == "today" { return .days(0) }
        if let s = sexp.string, let m = s.trimmingCharacters(in: .whitespaces).wholeMatch(of: dateRegex),
           let month = Int(m.2), let day = Int(m.3), (1...12).contains(month), (1...31).contains(day) {
            let seconds = m.4.flatMap { h in m.5.map { Int(h)! * 3600 + Int($0)! * 60 } }
            return .date(day: Days.absolute(year: Int(m.1)!, month: month, day: day), seconds: seconds)
        }
        throw QueryError("\(name): can't read \(sexp.description) as a date or a number of days")
    }

    /// The `:from`, `:to`, `:on` and `:with-time` arguments, with `:type` for `ts`; a leading
    /// number is `:to` where `positional` allows it.
    static func range(_ name: String, _ args: [Sexp], positional: Bool) throws(QueryError) -> (range: DateRange, type: StampType) {
        var range = DateRange()
        var type = StampType.both
        var rest = args[...]
        if positional, let first = rest.first, let n = number(first) {
            range.to = .days(n)
            rest.removeFirst()
        }
        while let key = rest.popFirst() {
            guard let keyword = key.symbol, keyword.hasPrefix(":"), let value = rest.popFirst() else {
                throw QueryError("\(name) takes :from, :to, :on\(name.hasPrefix("ts") ? ", :type" : "") and :with-time, not \(key.description)")
            }
            switch keyword {
            case ":from": range.from = try bound(value, name)
            case ":to": range.to = try bound(value, name)
            case ":on":
                let b = try bound(value, name)
                (range.from, range.to) = (b, b)
            case ":with-time":
                guard let f = flag(value) else { throw QueryError("\(name): :with-time takes t or nil") }
                range.withTime = f
            case ":type" where name.hasPrefix("ts"):
                switch unquoted(value).symbol ?? value.string {
                case "active": type = .active
                case "inactive": type = .inactive
                case "both", "nil": type = .both
                default: throw QueryError("\(name): :type takes active, inactive or both")
                }
            default:
                throw QueryError("\(name) takes :from, :to, :on\(name.hasPrefix("ts") ? ", :type" : "") and :with-time, not \(keyword)")
            }
        }
        return (range, type)
    }

    /// `:sort` keys from a views.toml string (keys separated by spaces) or a block's sexp.
    public static func sortKeys(_ keys: [String]) throws(QueryError) -> [String] {
        if let bad = keys.first(where: { !sortKeys.contains($0) }) { throw QueryError("Unknown sort key \(bad)") }
        return keys
    }

    // MARK: - Matching

    /// What a query is matched with: today, as `Days` numbers it, and `org-deadline-warning-days`.
    public struct Context: Sendable {
        public var today: Int
        public var deadlineWarningDays: Int

        public init(today: Int, deadlineWarningDays: Int = 14) {
            self.today = today
            self.deadlineWarningDays = deadlineWarningDays
        }
    }

    /// A timestamp as seconds from the start of day 0, and whether it has a time.
    struct Instant {
        let seconds: Int
        let hasTime: Bool
    }

    nonisolated(unsafe) static let timeRegex = /([0-9]{1,2}):([0-9]{2})/

    /// The start of a timestamp's text without brackets: `2026-11-28 Sat 10:00-11:00`.
    static func instant(_ raw: String) -> Instant? {
        guard let day = Days.absolute(of: raw) else { return nil }
        let rest = raw.dropFirst(10)
        if let m = rest.firstMatch(of: timeRegex), let h = Int(m.1), let min = Int(m.2) {
            return Instant(seconds: day * 86400 + h * 3600 + min * 60, hasTime: true)
        }
        return Instant(seconds: day * 86400, hasTime: false)
    }

    static func from(_ bound: DateBound, today: Int) -> Int {
        switch bound {
        case .days(let n): (today + n) * 86400
        case .date(let day, let seconds): day * 86400 + (seconds ?? 0)
        }
    }

    static func to(_ bound: DateBound, today: Int) -> Int {
        switch bound {
        case .days(let n): (today + n) * 86400 + 86399
        case .date(let day, let seconds): day * 86400 + (seconds.map { $0 + 59 } ?? 86399)
        }
    }

    static func inRange(_ instant: Instant, _ range: DateRange, today: Int) -> Bool {
        if let withTime = range.withTime, instant.hasTime != withTime { return false }
        if let from = range.from, instant.seconds < Self.from(from, today: today) { return false }
        if let to = range.to, instant.seconds > Self.to(to, today: today) { return false }
        return true
    }

    static let stampRegex = try! NSRegularExpression(pattern: "([<\\[])([0-9]{4}-[0-9]{2}-[0-9]{2}(?: [^\\]>\\n]*?)?)([>\\]])")

    /// The timestamps in the entry of heading `index`, to the next heading: each one's text
    /// without brackets and whether it is active.
    static func stamps(_ source: AgendaSource, _ index: Int) -> [(raw: String, active: Bool)] {
        let ns = source.text as NSString
        let start = source.headings[index].start
        let end = index + 1 < source.headings.count ? source.headings[index + 1].start : ns.length
        return stampRegex.matches(in: source.text, range: NSRange(location: start, length: end - start)).compactMap { m in
            let open = ns.substring(with: m.range(at: 1)), close = ns.substring(with: m.range(at: 3))
            guard (open == "<") == (close == ">") else { return nil }
            return (ns.substring(with: m.range(at: 2)), open == "<")
        }
    }

    static let clockRegex = try! NSRegularExpression(pattern: "^[ \\t]*CLOCK:[ \\t]*\\[([^\\]\\n]+)\\](?:--\\[([^\\]\\n]+)\\])?", options: .anchorsMatchLines)

    /// The clock lines in the entry of heading `index`, to the next heading: when each started
    /// and ended. A running clock ends where it started.
    static func clocks(_ source: AgendaSource, _ index: Int) -> [(start: Instant, end: Instant)] {
        let ns = source.text as NSString
        let start = source.headings[index].start
        let end = index + 1 < source.headings.count ? source.headings[index + 1].start : ns.length
        return clockRegex.matches(in: source.text, range: NSRange(location: start, length: end - start)).compactMap { m in
            guard let begin = instant(ns.substring(with: m.range(at: 1))) else { return nil }
            let finish = m.range(at: 2).location == NSNotFound ? nil : instant(ns.substring(with: m.range(at: 2)))
            return (begin, finish ?? begin)
        }
    }

    /// The heading's text without stars, TODO keyword and tags (`org-get-heading t t`).
    static func headingText(_ heading: AgendaSource.Heading) -> String {
        var text = heading.head
        if let todo = heading.todo, text.hasPrefix(todo) {
            text = String(text.dropFirst(todo.count)).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }
        if let tags = text.range(of: "[ \\t]+:[^ \\t]+:[ \\t]*$", options: .regularExpression) { text.removeSubrange(tags) }
        return text
    }

    /// A priority's value: higher for a higher priority.
    static func priorityValue(_ priority: String) -> Int {
        if let n = Int(priority) { return -n }
        return -Int(priority.unicodeScalars.first?.value ?? 0)
    }

    /// Whether heading `index` of `source` matches `query`.
    public static func matches(_ query: Query, heading index: Int, in source: AgendaSource, context: Context) -> Bool {
        let heading = source.headings[index]
        switch query {
        case .and(let parts): return parts.allSatisfy { matches($0, heading: index, in: source, context: context) }
        case .or(let parts): return parts.contains { matches($0, heading: index, in: source, context: context) }
        case .not(let part): return !matches(part, heading: index, in: source, context: context)
        case .todo(let keywords):
            guard let todo = heading.todo else { return false }
            return keywords.isEmpty ? !heading.isDone : keywords.contains(todo)
        case .done: return heading.todo != nil && heading.isDone
        case .tags(let scope, let wanted):
            let tags: [String] = switch scope {
            case .both: heading.tags.map { $0.name }
            case .local: heading.localTags
            case .inherited: heading.tags.filter { $0.inherited }.map { $0.name }
            }
            return wanted.isEmpty ? !tags.isEmpty : tags.contains(where: wanted.contains)
        case .priority(let comparator, let letters):
            guard let priority = heading.priority else { return false }
            if let comparator, let letter = letters.first { return comparator.test(priorityValue(priority), priorityValue(letter)) }
            return letters.isEmpty || letters.contains(priority)
        case .planning(let kind, let range):
            let raw: String? = switch kind {
            case .deadline: heading.deadline?.raw
            case .scheduled: heading.scheduled?.raw
            case .closed: heading.planning["CLOSED"].map { String($0.dropFirst().dropLast()) }
            }
            guard let raw, let instant = instant(raw) else { return false }
            return inRange(instant, range, today: context.today)
        case .clocked(let range):
            return clocks(source, index).contains { clock in
                if let from = range.from, clock.end.seconds < Self.from(from, today: context.today) { return false }
                if let to = range.to, clock.start.seconds > Self.to(to, today: context.today) { return false }
                return true
            }
        case .deadlineWarning:
            guard let raw = heading.deadline?.raw, let day = Days.absolute(of: raw) else { return false }
            return day - Days.warningDays(raw, delay: false, defaultDays: context.deadlineWarningDays) <= context.today
        case .ts(let type, let range):
            return stamps(source, index).contains { stamp in
                if type == .active, !stamp.active { return false }
                if type == .inactive, stamp.active { return false }
                guard let instant = instant(stamp.raw) else { return false }
                return inRange(instant, range, today: context.today)
            }
        case .heading(let strings):
            let text = headingText(heading)
            return strings.allSatisfy { text.range(of: $0, options: .caseInsensitive) != nil }
        case .property(let name, let value, let inherit):
            let key = name.uppercased()
            var found: String?
            switch inherit {
            case nil: found = heading.matchProperties[key]
            case false?: found = heading.properties[key]
            case true?:
                found = heading.properties[key]
                var level = heading.level
                var i = index - 1
                while found == nil, i >= 0, level > 1 {
                    if source.headings[i].level < level {
                        level = source.headings[i].level
                        found = source.headings[i].properties[key]
                    }
                    i -= 1
                }
                found = found ?? heading.matchProperties[key]
            }
            guard let found else { return false }
            return value.map { $0 == found } ?? true
        case .level(let low, let high): return (low...high).contains(heading.level)
        case .path(let regexps):
            return regexps.isEmpty || regexps.contains { regexp in
                guard let regex = try? NSRegularExpression(pattern: EmacsRegex.translate(regexp)) else { return false }
                return regex.firstMatch(in: source.path, range: NSRange(location: 0, length: (source.path as NSString).length)) != nil
            }
        case .habit: return heading.isHabit
        }
    }

    // MARK: - Sorting

    /// `org-ql--sort-by`: each key sorts the whole list in turn, so the last key decides first.
    /// Dates go earliest first and higher priorities first; entries without the value go last.
    static func sorted(_ entries: [(source: AgendaSource, index: Int)], by keys: [String]) -> [(source: AgendaSource, index: Int)] {
        var entries = entries
        func stableSort(_ less: ((source: AgendaSource, index: Int), (source: AgendaSource, index: Int)) -> Bool) {
            entries = entries.enumerated().sorted { a, b in
                less(a.element, b.element) || (!less(b.element, a.element) && a.offset < b.offset)
            }.map(\.element)
        }
        func byDate(_ value: @escaping ((source: AgendaSource, index: Int)) -> String?) {
            stableSort { a, b in
                switch (value(a).flatMap(instant), value(b).flatMap(instant)) {
                case let (x?, y?): x.seconds < y.seconds
                case (_?, nil): true
                default: false
                }
            }
        }
        func heading(_ e: (source: AgendaSource, index: Int)) -> AgendaSource.Heading { e.source.headings[e.index] }
        for key in keys {
            switch key {
            case "date": byDate { heading($0).deadline?.raw ?? heading($0).scheduled?.raw }
            case "deadline": byDate { heading($0).deadline?.raw }
            case "scheduled": byDate { heading($0).scheduled?.raw }
            case "closed": byDate { heading($0).planning["CLOSED"].map { String($0.dropFirst().dropLast()) } }
            case "priority":
                stableSort { a, b in
                    switch (heading(a).priority, heading(b).priority) {
                    case let (x?, y?): priorityValue(x) > priorityValue(y)
                    case (_?, nil): true
                    default: false
                    }
                }
            case "todo":
                func position(_ e: (source: AgendaSource, index: Int)) -> Int {
                    heading(e).todo.flatMap { e.source.keywords.firstIndex(of: $0) } ?? e.source.keywords.count + 1
                }
                stableSort { position($0) < position($1) }
            case "reverse": entries.reverse()
            case "random": entries.shuffle()
            default: break
            }
        }
        return entries
    }

    /// The headings of `sources` that match, sorted by `sort`.
    public static func select(_ sources: [AgendaSource], query: Query, sort: [String] = [], context: Context) -> [(source: AgendaSource, index: Int)] {
        var found: [(source: AgendaSource, index: Int)] = []
        for source in sources {
            for index in source.headings.indices where matches(query, heading: index, in: source, context: context) { found.append((source, index)) }
        }
        return sorted(found, by: sort)
    }
}

extension Agenda {
    /// An org-ql query's entries, as lines like a tags match's, in file order or `sort`'s; nil
    /// when the query can't be read.
    public static func query(_ sources: [AgendaSource], query text: String, sort: [String] = [], today: Int, options: AgendaOptions = AgendaOptions()) -> [AgendaItem]? {
        guard let query = try? OrgQL.parse(text) else { return nil }
        let context = OrgQL.Context(today: today, deadlineWarningDays: options.deadlineWarningDays)
        var kept: [(source: AgendaSource, index: Int)] = []
        for source in sources {
            var skipper = Skipper(options.skip, source, caseFold: true)
            for index in source.headings.indices where OrgQL.matches(query, heading: index, in: source, context: context) {
                if skipper.skips(source.headings[index].start, heading: index) { continue }
                kept.append((source, index))
            }
        }
        let items = OrgQL.sorted(kept, by: sort).map { entry in
            let heading = entry.source.headings[entry.index]
            return format(entry.source, heading, kind: .tagsMatch, marker: heading.start, extra: "", dotime: nil, removing: nil,
                          trailing: "", prefix: options.prefix("tags"), urgency: { $0 })
        }
        return markBlocked(items, options: options)
    }
}

extension EmacsBuffer {
    /// `org-dblock-write:org-ql`: a table of the buffer's entries matching `:query` (a plain
    /// query as a string, a sexp query as a list), with `:columns`, `:sort`, `:take` and
    /// `:ts-format`.
    func orgQLBlock(paramText: String) throws -> String {
        let params = try ClockTable.Params(paramText, defaults: [:])
        guard let querySexp = params.values[":query"] else { throw UserError(message: "An org-ql block needs a :query") }
        let query: OrgQL.Query
        do {
            if let s = querySexp.string { query = try OrgQL.plain(s) } else { query = try OrgQL.query(querySexp) }
        } catch {
            throw UserError(message: error.description)
        }
        var sort: [String] = []
        if let value = params.values[":sort"], value.symbol != "nil" {
            let keys = value.symbol.map { [$0] } ?? value.elements?.compactMap(\.symbol) ?? []
            do { sort = try OrgQL.sortKeys(keys) } catch { throw UserError(message: error.description) }
        }
        let columns = params.values[":columns"]?.elements ?? [.symbol("heading"), .symbol("todo"), .list([.symbol("priority"), .string("P")])]
        let format = params.values[":ts-format"]?.string ?? "%Y-%m-%d %H:%M:%S %z"
        let source = AgendaSource(path: options.filePath ?? "", text: string, defaults: settings, checksBlocking: false)
        let context = OrgQL.Context(today: Days.absolute(now, calendar: calendar), deadlineWarningDays: settings.deadlineWarningDays)
        var entries = OrgQL.select([source], query: query, sort: sort, context: context).map(\.index)
        if let take = params.int(":take") { entries = take < 0 ? Array(entries.suffix(-take)) : Array(entries.prefix(take)) }

        // Each column's header and what it shows: a field, or `property` and the property's name.
        var specs: [(header: String, field: String, property: String?)] = []
        for column in columns {
            let items = column.elements
            let type = column.symbol.map { Sexp.symbol($0) } ?? items?.first
            let header: String
            if let symbol = column.symbol {
                header = symbol.capitalized
            } else if let items, items.count == 2 {
                header = items[1].string ?? items[1].symbol ?? items[1].description
            } else {
                throw UserError(message: "Can't read the org-ql column \(column.description)")
            }
            if let field = type?.symbol, ["heading", "todo", "priority", "deadline", "scheduled", "closed"].contains(field) {
                specs.append((header, field, nil))
            } else if let parts = type?.elements, parts.count == 2, parts[0].symbol == "property", let name = parts[1].symbol ?? parts[1].string {
                specs.append((header, "property", name))
            } else if type?.symbol == "property", let name = items?.last?.symbol ?? items?.last?.string {
                specs.append((header, "property", name))
            } else {
                throw UserError(message: "The org-ql column \(column.description) isn't supported")
            }
        }
        func stamp(_ raw: String?) throws -> String {
            guard let raw, let day = Days.absolute(of: raw) else { return "" }
            let time = raw.dropFirst(10).firstMatch(of: OrgQL.timeRegex)
            let d = Days.date(day)
            let components = DateComponents(year: d.year, month: d.month, day: d.day, hour: time.flatMap { Int($0.1) } ?? 0, minute: time.flatMap { Int($0.2) } ?? 0)
            let date = calendar.date(from: components) ?? now
            do {
                return try Elisp.formatTime(format, Int(date.timeIntervalSince1970), calendar: calendar)
            } catch {
                throw UserError(message: "Can't format timestamps with \(format)")
            }
        }
        var out = "| " + specs.map(\.header).joined(separator: " | ") + " |\n|- \n"
        for index in entries {
            let heading = source.headings[index]
            var cells: [String] = []
            for spec in specs {
                switch spec.field {
                case "heading":
                    let title = AgendaSource.isCommented(heading.title) ? String(heading.title.dropFirst("COMMENT".count)) : heading.title
                    let search = "*" + Links.normalize(title, context: false)
                    cells.append(Links.makeString(search, Links.displayFormat(search)))
                case "todo": cells.append(heading.todo ?? "")
                case "priority": cells.append(heading.priority ?? "")
                case "deadline": cells.append(try stamp(heading.deadline?.raw))
                case "scheduled": cells.append(try stamp(heading.scheduled?.raw))
                case "closed": cells.append(try stamp(heading.planning["CLOSED"]))
                default: cells.append(spec.property.flatMap { heading.properties[$0.uppercased()] } ?? "")
                }
            }
            out += "| " + cells.joined(separator: " | ") + " |\n"
        }
        return String(out.dropLast())
    }
}
