import Foundation

/// Converts Markdown inline text to org: emphasis, code, links, images, footnote references,
/// math and entities; with `obsidian`, also wikilinks, embeds, highlights and `#tags`.
final class MarkdownInline {
    let obsidian: Bool
    let definitions: [String: String]
    let targets: MarkdownTargets
    /// Links written, wikilinks and embeds included.
    var links = 0
    /// `#tags` found since the last `takeTags`.
    private(set) var tags: [String] = []
    var issues: [MarkdownImportIssue] = []

    init(obsidian: Bool, definitions: [String: String], targets: MarkdownTargets) {
        self.obsidian = obsidian
        self.definitions = definitions
        self.targets = targets
    }

    func takeTags() -> [String] {
        defer { tags = [] }
        return tags
    }

    func convert(_ text: String) -> String {
        convert(Array(text)[...])
    }

    private func convert(_ chars: ArraySlice<Character>) -> String {
        var out = ""
        var i = chars.startIndex
        let end = chars.endIndex
        func at(_ k: Int) -> Character? { k >= chars.startIndex && k < end ? chars[k] : nil }
        while i < end {
            let c = chars[i]
            switch c {
            case "\\":
                if let next = at(i + 1), next.isASCII, next.isPunctuation || next.isSymbol {
                    out.append(next)
                    i += 2
                    continue
                }
            case "`":
                let run = runLength(chars, i, "`")
                if let close = findRun(chars, from: i + run, "`", run) {
                    var body = String(chars[(i + run)..<close]).replacingOccurrences(of: "\n", with: " ")
                    if body.count >= 2, body.first == " ", body.last == " ", body.contains(where: { $0 != " " }) { body = String(body.dropFirst().dropLast()) }
                    out += code(body)
                    i = close + run
                    continue
                }
                out += String(repeating: "`", count: run)
                i += run
                continue
            case "$":
                if let math = math(chars, i) {
                    out += math.text
                    i = math.end
                    continue
                }
            case "!":
                if obsidian, at(i + 1) == "[", at(i + 2) == "[", let close = findClose(chars, from: i + 3, "]]") {
                    out += wikilink(String(chars[(i + 3)..<close]), embed: true)
                    i = close + 2
                    continue
                }
                if at(i + 1) == "[", let link = link(chars, i + 1) {
                    out += image(destination: link.destination, alt: link.text)
                    i = link.end
                    continue
                }
            case "^":
                if at(i + 1) == "[", let close = matchingBracket(chars, i + 1) {
                    out += "[fn:: " + convert(chars[(i + 2)..<close]) + "]"
                    i = close + 1
                    continue
                }
            case "[":
                if obsidian, at(i + 1) == "[", let close = findClose(chars, from: i + 2, "]]") {
                    out += wikilink(String(chars[(i + 2)..<close]), embed: false)
                    i = close + 2
                    continue
                }
                if at(i + 1) == "^", let close = chars[i...].firstIndex(of: "]"), close > i + 2,
                   !chars[(i + 2)..<close].contains(where: { $0 == " " || $0 == "\n" }) {
                    out += "[fn:" + MarkdownToOrg.footnoteLabel(String(chars[(i + 2)..<close])) + "]"
                    i = close + 1
                    continue
                }
                if let link = link(chars, i) {
                    out += linkText(destination: link.destination, text: link.text)
                    i = link.end
                    continue
                }
            case "<":
                if let close = chars[i...].firstIndex(of: ">") {
                    let inner = String(chars[(i + 1)..<close])
                    if !inner.contains(" "), !inner.contains("\n"), let colon = inner.firstIndex(of: ":"),
                       inner[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }), inner.distance(from: inner.startIndex, to: colon) >= 2 {
                        links += 1
                        out += "[[" + MarkdownToOrg.escapeLinkPath(inner) + "]]"
                        i = close + 1
                        continue
                    }
                    if !inner.contains(" "), inner.contains("@"), inner.contains(".") {
                        links += 1
                        out += "[[mailto:" + inner + "]]"
                        i = close + 1
                        continue
                    }
                    if let first = inner.first, first.isLetter || first == "/" || first == "!" {
                        out += "@@html:<" + inner + ">@@"
                        i = close + 1
                        continue
                    }
                }
            case "&":
                if let entity = entity(chars, i) {
                    out += entity.text
                    i = entity.end
                    continue
                }
            case "*", "_":
                if let emphasis = emphasis(chars, i, c, previous: at(i - 1)) {
                    out += emphasis.text
                    i = emphasis.end
                    continue
                }
                let run = runLength(chars, i, c)
                out += String(repeating: c, count: run)
                i += run
                continue
            case "~":
                if at(i + 1) == "~", at(i + 2).map({ !$0.isWhitespace }) == true, let close = findDelimiter(chars, from: i + 2, "~", 2) {
                    out += "+" + convert(chars[(i + 2)..<close]) + "+"
                    i = close + 2
                    continue
                }
            case "=":
                if obsidian, at(i + 1) == "=", at(i + 2).map({ !$0.isWhitespace }) == true, let close = findDelimiter(chars, from: i + 2, "=", 2) {
                    out += "*" + convert(chars[(i + 2)..<close]) + "*"
                    i = close + 2
                    continue
                }
            case "#":
                if obsidian, at(i - 1).map({ $0.isWhitespace || $0 == "(" }) ?? true {
                    var j = i + 1
                    while let next = at(j), next.isLetter || next.isNumber || next == "_" || next == "-" || next == "/" { j += 1 }
                    let tag = String(chars[(i + 1)..<j])
                    if !tag.isEmpty, tag.contains(where: { !$0.isNumber }) {
                        tags.append(MarkdownToOrg.tag(tag))
                        out += "#" + tag
                        i = j
                        continue
                    }
                }
            default:
                break
            }
            out.append(c)
            i += 1
        }
        return out
    }

    // MARK: - Pieces

    private func code(_ body: String) -> String {
        if !body.contains("~") { return "~" + body + "~" }
        if !body.contains("=") { return "=" + body + "=" }
        return "~" + body + "~"
    }

    private func runLength(_ chars: ArraySlice<Character>, _ i: Int, _ c: Character) -> Int {
        var j = i
        while j < chars.endIndex, chars[j] == c { j += 1 }
        return j - i
    }

    /// A run of exactly `count` `c`s at or after `from`.
    private func findRun(_ chars: ArraySlice<Character>, from: Int, _ c: Character, _ count: Int) -> Int? {
        var j = from
        while j < chars.endIndex {
            if chars[j] == c {
                let run = runLength(chars, j, c)
                if run == count { return j }
                j += run
            } else {
                j += 1
            }
        }
        return nil
    }

    private func findClose(_ chars: ArraySlice<Character>, from: Int, _ close: String) -> Int? {
        let pattern = Array(close)
        var j = from
        while j + pattern.count <= chars.endIndex {
            if chars[j] == "\n" { return nil }
            if Array(chars[j..<(j + pattern.count)]) == pattern { return j }
            j += 1
        }
        return nil
    }

    /// The `]` matching the `[` at `open`, skipping code spans and escapes.
    private func matchingBracket(_ chars: ArraySlice<Character>, _ open: Int) -> Int? {
        var depth = 0
        var j = open
        while j < chars.endIndex {
            switch chars[j] {
            case "\\": j += 1
            case "`":
                let run = runLength(chars, j, "`")
                if let close = findRun(chars, from: j + run, "`", run) { j = close + run - 1 } else { j += run - 1 }
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return j }
            default: break
            }
            j += 1
        }
        return nil
    }

    /// A closing delimiter run of `count` `c`s after a non-space, skipping code spans.
    private func findDelimiter(_ chars: ArraySlice<Character>, from: Int, _ c: Character, _ count: Int) -> Int? {
        var j = from
        while j < chars.endIndex {
            let char = chars[j]
            if char == "\\" {
                j += 2
                continue
            }
            if char == "`" {
                let run = runLength(chars, j, "`")
                if let close = findRun(chars, from: j + run, "`", run) { j = close + run } else { j += run }
                continue
            }
            if char == "[", let close = matchingBracket(chars, j) {
                // Links and their destinations are skipped whole.
                j = close + 1
                if j < chars.endIndex, chars[j] == "(", let paren = destinationEnd(chars, j) { j = paren + 1 }
                continue
            }
            if char == c {
                let run = runLength(chars, j, c)
                let before = chars[j - 1]
                let after = j + run < chars.endIndex ? chars[j + run] : nil
                if run == count, j > from, !before.isWhitespace, c != "_" || !(after.map { $0.isLetter || $0.isNumber } ?? false) { return j }
                j += run
                continue
            }
            j += 1
        }
        return nil
    }

    private func emphasis(_ chars: ArraySlice<Character>, _ i: Int, _ c: Character, previous: Character?) -> (text: String, end: Int)? {
        let run = runLength(chars, i, c)
        guard (1...3).contains(run), i + run < chars.endIndex, !chars[i + run].isWhitespace else { return nil }
        if c == "_", let previous, previous.isLetter || previous.isNumber { return nil }
        guard let close = findDelimiter(chars, from: i + run, c, run) else { return nil }
        let body = convert(chars[(i + run)..<close])
        guard !body.isEmpty else { return nil }
        switch run {
        case 1: return ("/" + body + "/", close + 1)
        case 2: return ("*" + body + "*", close + 2)
        default: return ("*/" + body + "/*", close + 3)
        }
    }

    private func math(_ chars: ArraySlice<Character>, _ i: Int) -> (text: String, end: Int)? {
        var j = i + 1
        if j < chars.endIndex, chars[j] == "$" {
            j += 1
            while j + 1 < chars.endIndex {
                if chars[j] == "$", chars[j + 1] == "$" { return ("\\[" + String(chars[(i + 2)..<j]) + "\\]", j + 2) }
                j += 1
            }
            return nil
        }
        guard j < chars.endIndex, !chars[j].isWhitespace, !chars[j].isNumber || obsidian else { return nil }
        while j < chars.endIndex {
            if chars[j] == "\n", j + 1 < chars.endIndex, chars[j + 1] == "\n" { return nil }
            if chars[j] == "\\" {
                j += 2
                continue
            }
            if chars[j] == "$" {
                let after = j + 1 < chars.endIndex ? chars[j + 1] : nil
                if !chars[j - 1].isWhitespace, !(after?.isNumber ?? false) { return ("\\(" + String(chars[(i + 1)..<j]) + "\\)", j + 1) }
                return nil
            }
            j += 1
        }
        return nil
    }

    private static let entities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{a0}", "copy": "©", "mdash": "—", "ndash": "–", "hellip": "…"]

    private func entity(_ chars: ArraySlice<Character>, _ i: Int) -> (text: String, end: Int)? {
        guard let semicolon = chars[i...].prefix(12).firstIndex(of: ";") else { return nil }
        let name = String(chars[(i + 1)..<semicolon])
        if let value = Self.entities[name] { return (value, semicolon + 1) }
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            if let value, let scalar = Unicode.Scalar(value) { return (String(Character(scalar)), semicolon + 1) }
        }
        return nil
    }

    /// The end of a `(destination "title")` starting at `open`, parentheses balanced.
    private func destinationEnd(_ chars: ArraySlice<Character>, _ open: Int) -> Int? {
        var depth = 0
        var j = open
        var angle = false
        while j < chars.endIndex {
            let char = chars[j]
            if char == "\\" {
                j += 2
                continue
            }
            if char == "<", j == open + 1 { angle = true }
            if angle, char == ">" { angle = false }
            if !angle {
                if char == "(" { depth += 1 }
                if char == ")" {
                    depth -= 1
                    if depth == 0 { return j }
                }
            }
            if char == "\n", j + 1 < chars.endIndex, chars[j + 1] == "\n" { return nil }
            j += 1
        }
        return nil
    }

    /// `[text](destination)`, `[text][label]`, `[label][]` or `[label]` with a definition.
    private func link(_ chars: ArraySlice<Character>, _ open: Int) -> (text: ArraySlice<Character>, destination: String, end: Int)? {
        guard let close = matchingBracket(chars, open) else { return nil }
        let text = chars[(open + 1)..<close]
        let after = close + 1
        if after < chars.endIndex, chars[after] == "(", let end = destinationEnd(chars, after) {
            var inside = String(chars[(after + 1)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            var destination: String
            if inside.hasPrefix("<"), let angle = inside.firstIndex(of: ">") {
                destination = String(inside[inside.index(after: inside.startIndex)..<angle])
            } else {
                if let space = inside.firstIndex(where: { $0 == " " || $0 == "\n" }) {
                    let title = inside[space...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if title.first == "\"" || title.first == "'" || title.first == "(" { inside = String(inside[..<space]) }
                }
                destination = inside
            }
            destination = destination.replacingOccurrences(of: "\\(", with: "(").replacingOccurrences(of: "\\)", with: ")")
            return (text, destination, end + 1)
        }
        if after < chars.endIndex, chars[after] == "[", let labelClose = chars[after...].firstIndex(of: "]") {
            var label = String(chars[(after + 1)..<labelClose])
            if label.isEmpty { label = String(text) }
            if let destination = definitions[MarkdownBlocks.normalizeLabel(label)] { return (text, destination, labelClose + 1) }
            return nil
        }
        if let destination = definitions[MarkdownBlocks.normalizeLabel(String(text))] { return (text, destination, after) }
        return nil
    }

    private static func isURL(_ destination: String) -> Bool {
        guard let colon = destination.firstIndex(of: ":") else { return false }
        let scheme = destination[..<colon]
        return scheme.count >= 2 && scheme.allSatisfy { $0.isLetter || $0.isNumber || "+.-".contains($0) }
    }

    private func path(for destination: String, image: Bool) -> String {
        if let resolved = targets.link(destination, image) { return resolved }
        if Self.isURL(destination) { return destination }
        let decoded = destination.removingPercentEncoding ?? destination
        return decoded.hasPrefix("#") ? decoded : "file:" + decoded
    }

    private func linkText(destination: String, text: ArraySlice<Character>) -> String {
        links += 1
        var description = convert(text).replacingOccurrences(of: "\n", with: " ")
        // An image as the description is written as its path, which org shows as the image.
        if description.hasPrefix("[["), description.hasSuffix("]]"), description.components(separatedBy: "[[").count == 2, !description.contains("][") {
            description = String(description.dropFirst(2).dropLast(2))
        }
        let target = path(for: destination, image: false)
        let path = target.hasPrefix("#") ? "*" + target.dropFirst() : target
        if description.isEmpty || description == destination { return "[[" + MarkdownToOrg.escapeLinkPath(path) + "]]" }
        return "[[" + MarkdownToOrg.escapeLinkPath(path) + "][" + description.replacingOccurrences(of: "]]", with: "] ]") + "]]"
    }

    private func image(destination: String, alt: ArraySlice<Character>) -> String {
        links += 1
        return "[[" + MarkdownToOrg.escapeLinkPath(path(for: destination, image: true)) + "]]"
    }

    /// `target#heading|alias`, `target#^block` or `target|300` for an embedded image.
    private func wikilink(_ body: String, embed: Bool) -> String {
        var target = body
        var alias: String?
        if let bar = body.firstIndex(of: "|") {
            target = String(body[..<bar])
            alias = String(body[body.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
        }
        var fragment: String?
        if let hash = target.firstIndex(of: "#") {
            fragment = String(target[target.index(after: hash)...])
            target = String(target[..<hash])
        }
        target = target.trimmingCharacters(in: .whitespaces)
        guard let resolved = targets.wikilink(target, fragment, embed) else {
            issues.append(.unresolvedLink(body))
            return alias ?? body
        }
        links += 1
        if embed, resolved.image { return "[[" + MarkdownToOrg.escapeLinkPath(resolved.path) + "]]" }
        var description = alias.flatMap { $0.allSatisfy(\.isNumber) || $0.isEmpty ? nil : $0 }
        if description == nil {
            let name = target.isEmpty ? "" : (target as NSString).lastPathComponent
            let heading = fragment.map { $0.split(separator: "#").last.map(String.init) ?? $0 }?.trimmingCharacters(in: CharacterSet(charactersIn: "^"))
            description = [name, heading].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " > ")
        }
        return "[[" + MarkdownToOrg.escapeLinkPath(resolved.path) + "][" + (description ?? target) + "]]"
    }
}
