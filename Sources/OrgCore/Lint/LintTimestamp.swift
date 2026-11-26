import Foundation

/// Timestamps and clock lines as Org writes them back after reading them
/// (`org-element-timestamp-parser` then `org-element-timestamp-interpreter`), which
/// org-lint's timestamp-syntax and clock-syntax compare with the text.
enum LintTimestamp {
    static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    /// `org-ts-regexp0`, as `org-parse-time-string` reads a date and time.
    static let dateTime = try! NSRegularExpression(pattern: "([0-9]{4})-([0-9]{2})-([0-9]{2})( +[^\\]+0-9>\\r\\n -]+)?( +([0-9]{1,2}):([0-9]{2}))?")
    static let rawValue = try! NSRegularExpression(pattern: "^([<\\[].*?)[\\]>](?:--([<\\[][0-9]{4}-[0-9]{2}-[0-9]{2}(?: .*?)?[\\]>]))?$")
    static let timeRange = try! NSRegularExpression(pattern: "[012]?[0-9]:[0-5][0-9](-([012]?[0-9]):([0-5][0-9]))")
    static let repeater = try! NSRegularExpression(pattern: "(\\+\\+|\\.\\+|\\+)([0-9]+)([hdwmy])(?:/([0-9]+)([hdwmy]))?")
    static let warning = try! NSRegularExpression(pattern: "(-)?-([0-9]+)([hdwmy])")

    struct DateTime {
        var year, month, day: Int
        var hour, minute: Int?
    }

    static func groups(_ regex: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
    }

    /// `org-parse-time-string` with NODEFAULT.
    static func parseTime(_ s: String) -> DateTime? {
        guard let g = groups(dateTime, s), let year = Int(g[1]!), let month = Int(g[2]!), let day = Int(g[3]!) else { return nil }
        return DateTime(year: year, month: month, day: day, hour: g[6].flatMap { Int($0) }, minute: g[7].flatMap { Int($0) })
    }

    /// `format-time-string` of `org-time-stamp-format` without brackets, after `encode-time`
    /// rolls out-of-range values over.
    static func format(_ t: DateTime, time: Bool) -> String {
        let minutes = (t.hour ?? 0) * 60 + (t.minute ?? 0)
        let extraDays = Int((Double(minutes) / 1440).rounded(.down))
        let absolute = Days.absolute(year: t.year, month: t.month, day: t.day) + extraDays
        let date = Days.date(absolute)
        var s = digits(date.year, 4) + "-" + digits(date.month, 2) + "-" + digits(date.day, 2) + " " + dayNames[Days.weekday(absolute)]
        if time {
            let inDay = minutes - extraDays * 1440
            s += " " + digits(inDay / 60, 2) + ":" + digits(inDay % 60, 2)
        }
        return s
    }

    /// `%0Nd`.
    static func digits(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// The timestamp as Org writes it back; nil for a diary timestamp or one Org can't read.
    static func canonical(_ raw: String) -> String? {
        if let canonical = parsedCanonical(raw) { return canonical }
        guard !raw.contains("%%"), let g = groups(rawValue, raw), let dateStart = g[1], let start = parseTime(dateStart) else { return nil }
        let active = raw.hasPrefix("<")
        let (open, close) = active ? ("<", ">") : ("[", "]")
        let dateEnd = g[2].flatMap(parseTime)
        let range = groups(timeRange, dateStart).map { (Int($0[2]!)!, Int($0[3]!)!) }

        var suffix = ""
        if let r = groups(repeater, raw) {
            suffix += " " + r[1]! + String(Int(r[2]!)!) + r[3]!
            if let value = r[4], let unit = r[5] { suffix += "/" + String(Int(value)!) + unit }
        }
        if let w = groups(warning, raw) {
            suffix += " " + (w[1] == nil ? "-" : "--") + String(Int(w[2]!)!) + w[3]!
        }

        var s = open + format(start, time: start.hour != nil && start.minute != nil)
        let hourEnd = dateEnd?.hour ?? range?.0 ?? start.hour
        let minuteEnd = dateEnd?.minute ?? range?.1 ?? start.minute
        if let dateEnd {
            var end = dateEnd
            end.hour = hourEnd
            end.minute = minuteEnd
            s += suffix + close + "--" + open + format(end, time: hourEnd != nil && minuteEnd != nil)
        } else if let hourEnd, let minuteEnd, range != nil {
            s += String(format: "-%02d:%02d", hourEnd, minuteEnd)
        }
        return s + suffix + close
    }

    /// `canonical` for a timestamp `Timestamp.parse` reads, other than a date range, without
    /// regular expressions: Org reads those the same way.
    static func parsedCanonical(_ raw: String) -> String? {
        if let dashes = raw.range(of: ">--<") ?? raw.range(of: "]--[") {
            // A date range without repeaters or warnings: each end on its own, the end's time
            // defaulting to the start's.
            let first = raw[..<raw.index(after: dashes.lowerBound)], second = raw[raw.index(before: dashes.upperBound)...]
            guard let a = Timestamp.parse(first), let b = Timestamp.parse(second), a.end == nil, b.end == nil,
                  a.repeater == nil, a.warning == nil, b.repeater == nil, b.warning == nil else { return nil }
            let (open, close) = a.active ? ("<", ">") : ("[", "]")
            let start = DateTime(year: a.start.year, month: a.start.month, day: a.start.day, hour: a.start.hour, minute: a.start.minute)
            let end = DateTime(year: b.start.year, month: b.start.month, day: b.start.day, hour: b.start.hour ?? a.start.hour, minute: b.start.minute ?? a.start.minute)
            return open + format(start, time: start.hour != nil && start.minute != nil) + close + "--"
                + open + format(end, time: end.hour != nil && end.minute != nil) + close
        }
        guard let stamp = Timestamp.parse(raw) else { return nil }
        let (open, close) = stamp.active ? ("<", ">") : ("[", "]")
        let start = DateTime(year: stamp.start.year, month: stamp.start.month, day: stamp.start.day, hour: stamp.start.hour, minute: stamp.start.minute)
        var s = open + format(start, time: start.hour != nil && start.minute != nil)
        if let end = stamp.end, let hour = end.hour, let minute = end.minute { s += "-" + digits(hour, 2) + ":" + digits(minute, 2) }
        if let repeater = stamp.repeater {
            let kind = switch repeater.kind {
            case .cumulate: "+"
            case .catchUp: "++"
            case .restart: ".+"
            }
            s += " " + kind + String(repeater.interval.value) + String(repeater.interval.unit.rawValue)
            if let deadline = repeater.habitDeadline { s += "/" + String(deadline.value) + String(deadline.unit.rawValue) }
        }
        if let warning = stamp.warning {
            s += " " + (warning.firstOccurrenceOnly ? "--" : "-") + String(warning.interval.value) + String(warning.interval.unit.rawValue)
        }
        return s + close
    }

    /// A clock line, trimmed, as Org writes it back; nil when Org can't read it.
    static func canonicalClock(_ line: String) -> String? {
        guard line.hasPrefix("CLOCK:") else { return nil }
        let rest = line.dropFirst(6).drop { $0 == " " || $0 == "\t" }
        guard let end = rest.firstIndex(where: { $0 == "]" || $0 == ">" }) else { return nil }
        var stampEnd = rest.index(after: end)
        if rest[stampEnd...].hasPrefix("--"), let second = rest[stampEnd...].firstIndex(where: { $0 == "]" || $0 == ">" }) {
            stampEnd = rest.index(after: second)
        }
        guard let stamp = canonical(String(rest[..<stampEnd])) else { return nil }
        var s = "CLOCK: " + stamp
        if let arrow = line.range(of: "=> ") {
            let duration = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            let parts = duration.split(separator: ":", omittingEmptySubsequences: true)
            guard !duration.isEmpty, !duration.contains(where: \.isWhitespace), parts.count >= 2 else { return nil }
            s += " => " + pad(String(parts[0]), 2) + ":" + pad(String(parts[1]), 2)
        }
        return s
    }

    /// `%Ns`: padded with spaces on the left.
    static func pad(_ s: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - s.count)) + s
    }
}
