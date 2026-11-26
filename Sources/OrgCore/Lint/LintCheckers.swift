import Foundation

// The checkers. Messages are org-lint's where org-lint has the checker.

extension Linter {
    // MARK: - Keywords

    /// `org-element-affiliated-keywords`.
    static let affiliatedKeys: Set<String> = ["CAPTION", "DATA", "HEADER", "HEADERS", "LABEL", "NAME", "PLOT", "RESNAME", "RESULT", "RESULTS", "SOURCE", "SRCNAME", "TBLNAME"]
    /// `org-element-keyword-translation-alist`, as `org-lint-obsolete-affiliated-keywords` names them.
    static let obsoleteKeys: [String: String] = ["DATA": "NAME", "LABEL": "NAME", "RESNAME": "NAME", "SOURCE": "NAME", "SRCNAME": "NAME", "TBLNAME": "NAME", "RESULT": "RESULTS", "HEADERS": "HEADER"]

    /// A keyword line's key, upcased and without a dual keyword's `[…]`, and its value.
    static func keyword(_ node: SyntaxNode) -> (key: String, value: String)? {
        let line = node.text.prefix { $0 != "\n" && $0 != "\r" }.drop { $0 == " " || $0 == "\t" }
        guard line.hasPrefix("#+"), let colon = line.firstIndex(of: ":") else { return nil }
        var key = line[line.index(line.startIndex, offsetBy: 2)..<colon]
        if let bracket = key.firstIndex(of: "[") { key = key[..<bracket] }
        return (key.uppercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    static func isAffiliated(_ key: String) -> Bool {
        affiliatedKeys.contains(key) || key.hasPrefix("ATTR_")
    }

    mutating func keywordChecks() {
        var categories = 0
        var run: [(node: SyntaxNode, key: String, value: String, line: Int)] = []
        func finishRun(_ linter: inout Linter) {
            guard let last = run.last else { return }
            let next = last.line + 1
            let following = next < linter.lineStarts.count ? linter.line(next) : nil
            let orphaned = following.map { $0.allSatisfy { $0 == " " || $0 == "\t" } || $0.firstMatch(of: #/^\*+ /#) != nil } ?? true
            if orphaned {
                for keyword in run where keyword.key != "RESULT" && keyword.key != "RESULTS" {
                    linter.report(.orphanedAffiliatedKeywords, at: keyword.node.range.lowerBound, "Orphaned affiliated keyword: \"\(keyword.key)\"")
                }
            } else {
                for keyword in run {
                    if let new = Linter.obsoleteKeys[keyword.key] {
                        linter.report(.obsoleteAffiliatedKeywords, at: keyword.node.range.lowerBound, "Obsolete affiliated keyword: \"\(keyword.key)\".  Use \"\(new)\" instead")
                    }
                }
                // The element's name is the last NAME before it.
                if let name = run.last(where: { $0.key == "NAME" }) { linter.names.append((name.node.range.lowerBound, name.value)) }
                for keyword in run where keyword.key == "RESULTS" && !keyword.value.isEmpty { linter.resultNames.append(keyword.value) }
            }
            run = []
        }
        for node in keywords {
            guard let (key, value) = Self.keyword(node) else { continue }
            let line = lineIndex(node.range.lowerBound)
            if let last = run.last, last.line + 1 != line || !Self.isAffiliated(key) { finishRun(&self) }
            if Self.isAffiliated(key) { run.append((node, key, value, line)) }
            switch key {
            case "CATEGORY":
                categories += 1
                if categories > 1 { report(.deprecatedCategorySetup, at: node.range.lowerBound, "Spurious CATEGORY keyword.  Set :CATEGORY: property instead") }
            case "SETUPFILE":
                var file = value
                if file.count >= 2, file.hasPrefix("\""), file.hasSuffix("\"") { file = String(file.dropFirst().dropLast()) }
                guard let folder, !file.isEmpty, file.firstMatch(of: /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) == nil, !Self.isRemote(file) else { break }
                if !env.fileExists(OrgAttach.expand(file, in: folder)) {
                    report(.nonExistentSetupfileParameter, at: node.range.lowerBound, "Non-existent setup file \"\(file)\"")
                }
            default:
                break
            }
        }
        finishRun(&self)
    }

    // MARK: - Links

    static func isRemote(_ path: String) -> Bool { path.firstMatch(of: /^\/[^\/:]+:/) != nil }

    static func words(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// A heading's title as `org-export-search-cells` reads it: without COMMENT, statistics
    /// cookies as blanks, upcased words.
    static func headlineKey(_ title: String) -> [String] {
        var t = title
        if t == "COMMENT" { t = "" } else if t.hasPrefix("COMMENT ") { t = String(t.dropFirst(8)) }
        if t.contains("[") { t = t.replacingOccurrences(of: "\\[[0-9]*(?:%|/[0-9]*)\\]", with: " ", options: .regularExpression) }
        return words(t).map { $0.uppercased() }
    }

    /// The link a link node is, read as `Links.link(at:)` reads it; nil for a radio link.
    func link(_ node: SyntaxNode, abbreviations: [String: String]) -> OrgLink? {
        if let path = node.tokens.first(where: { $0.kind == .linkPath })?.text {
            return Links.parse(bracket: path.contains("\n") ? node.linkPath! : path, abbreviations: abbreviations)
        }
        let whole = node.text
        if whole.hasPrefix("<"), whole.hasSuffix(">") { return Links.parse(plain: String(whole.dropFirst().dropLast())) }
        if tree.settings.radioTargets.contains(where: { Links.words($0) == Links.words(whole) }) { return nil }
        return Links.parse(plain: whole)
    }

    /// The heading `offset` is under.
    func headingIndex(at offset: Int) -> Int? {
        var low = 0, high = model.headings.count
        while low < high {
            let mid = (low + high) / 2
            if model.headings[mid].headingRange.lowerBound <= offset { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    func attachmentDirectory(_ heading: Int?, cache: inout [Int: String?]) -> String? {
        guard let path else { return nil }
        let key = heading ?? -1
        if let cached = cache[key] { return cached }
        let dir = OrgAttach.directory(model: model, heading: heading, path: path, idDir: env.attachIDDir, inherit: env.attachInherit, noFSCheck: false,
                                      isDirectory: env.isDirectory)
        cache[key] = dir
        return dir
    }

    /// Every `:ID:` in the file: entries' and the file's own.
    var localIDs: Set<String> {
        Set(propertyDrawers.flatMap(\.children).compactMap { Property(line: $0.text) }.filter { $0.key.uppercased() == "ID" && !$0.value.isEmpty }.map(\.value))
    }

    mutating func linkChecks() {
        let abbreviations = Links.abbreviations(in: tree.settings.setupKeywords + text)
        var headlines = Set<[String]>()
        var headingIDs = Set<String>()
        for heading in model.headings {
            headlines.insert(Self.headlineKey(heading.title))
            for property in heading.properties where !property.additive && ["ID", "CUSTOM_ID"].contains(property.key.uppercased()) {
                headingIDs.insert(property.value)
            }
        }
        let targetKeys = Set(targets.map { Self.words(String($0.text.dropFirst(2).dropLast(2))).map { $0.uppercased() } })
        let nameKeys = Set((names.map(\.value) + resultNames).map(Self.words))
        let ids = localIDs
        var attachDirs: [Int: String?] = [:]
        var searchIndexes: [String: SearchIndex?] = [:]

        for node in links {
            guard let link = link(node, abbreviations: abbreviations) else { continue }
            let at = node.range.lowerBound
            switch link.type {
            case "fuzzy":
                let starred = link.path.hasPrefix("*")
                let words = Self.words(starred ? String(link.path.dropFirst()) : link.path)
                let upper = words.map { $0.uppercased() }
                let found = starred ? headlines.contains(upper)
                    : targetKeys.contains(upper) || nameKeys.contains(words) || nameKeys.contains(upper) || headlines.contains(upper)
                if !found, !words.isEmpty {
                    report(.invalidFuzzyLink, at: at, "Unknown fuzzy location \"\(starred ? String(link.path.dropFirst()) : link.path)\"")
                }
            case "custom-id":
                if !headingIDs.contains(link.path) { report(.invalidCustomIDLink, at: at, "Unknown custom ID \"\(link.path)\"") }
            case "id":
                // An ID may hold `::` (invalid-id-property reports it); otherwise what follows is a search.
                let candidates = [link.path, link.path.components(separatedBy: "::")[0]]
                if !candidates.contains(where: ids.contains), candidates.allSatisfy({ env.idFiles?($0).isEmpty ?? true }) {
                    report(.invalidIDLink, at: at, "Unknown ID \"\(link.path)\"")
                }
            case "coderef":
                if Coderef.search(link.path, text: text, tree: tree) == nil { report(.invalidCoderefLink, at: at, "Unknown coderef \"\(link.path)\"") }
            case "file":
                if link.raw.hasPrefix("file+"), let colon = link.raw.firstIndex(of: ":") {
                    report(.fileApplication, at: at, "Deprecated \"\(link.raw[..<colon])\" link type")
                }
                guard let folder, !link.path.isEmpty, !Self.isRemote(link.path) else { continue }
                let file = OrgAttach.expand(link.path, in: folder)
                if !env.fileExists(file) {
                    report(.linkToLocalFile, at: at, "Link to non-existent local file \"\(link.path)\"")
                } else if let search = link.searchOption, !search.isEmpty, search.allSatisfy(\.isWhitespace) == false,
                          Int(search) == nil, file.hasSuffix(".org") || file.hasSuffix(".org_archive") {
                    if searchIndexes[file] == nil {
                        let other = file == path.map({ OrgAttach.expand($0, in: "/") }) ? text : env.readFile(file)
                        searchIndexes[file] = other.map { SearchIndex(OrgParser.parse($0, defaults: tree.settings)) }
                    }
                    if let index = searchIndexes[file] ?? nil, !index.finds(search) {
                        report(.invalidFileSearch, at: at, "Unknown location \"\(search)\" in \"\(link.path)\"")
                    }
                }
            case "attachment":
                guard let folder else { continue }
                var name = link.path
                if let range = name.range(of: "::") { name = String(name[..<range.lowerBound]) }
                let dir = attachmentDirectory(headingIndex(at: at), cache: &attachDirs) ?? folder
                let file = OrgAttach.expand(name, in: dir)
                if !env.fileExists(file) { report(.linkToLocalFile, at: at, "Link to non-existent local file \"\(file)\"") }
            default:
                break
            }
        }
    }

    // MARK: - Attachments

    mutating func attachmentChecks() {
        guard let path, let folder else { return }
        var attachDirs: [Int: String?] = [:]
        for (index, heading) in model.headings.enumerated() where heading.localTags.contains("ATTACH") {
            if attachmentDirectory(index, cache: &attachDirs) == nil {
                report(.missingAttachmentFolder, at: heading.headingRange.lowerBound, "Entry tagged ATTACH has no attachment folder")
            }
        }
        // Folders under the ID folder whose ID no entry has, here or, through the index, elsewhere.
        guard let idFiles = env.idFiles else { return }
        let ids = localIDs
        var roots = [OrgAttach.expand(env.attachIDDir, in: folder)]
        let fallback = OrgAttach.expand("data/", in: folder)
        if fallback != roots[0] { roots.append(fallback) }
        for root in roots where env.isDirectory(root) {
            func subfolders(_ dir: String) -> [String] {
                env.contentsOfDirectory(dir).filter { !$0.hasPrefix(".") && env.isDirectory((dir as NSString).appendingPathComponent($0)) }.sorted()
            }
            var candidates: [(id: String, relative: String)] = []
            for first in subfolders(root) {
                let firstPath = (root as NSString).appendingPathComponent(first)
                if first == "__" {
                    for letter in subfolders(firstPath) {
                        for id in subfolders((firstPath as NSString).appendingPathComponent(letter)) { candidates.append((id, "\(first)/\(letter)/\(id)")) }
                    }
                } else if first.count == 2 || first.count == 6 {
                    for rest in subfolders(firstPath) { candidates.append((first + rest, "\(first)/\(rest)")) }
                }
            }
            let shown = root.hasPrefix(folder + "/") ? String(root.dropFirst(folder.count + 1)) : root
            for candidate in candidates where !ids.contains(candidate.id) && idFiles(candidate.id).filter({ $0 != path }).isEmpty {
                let folderName = (shown as NSString).appendingPathComponent(candidate.relative)
                report(.orphanedAttachmentFolder, at: 0, "Attachment folder \"\(folderName)\" belongs to no entry")
            }
        }
    }

    // MARK: - Duplicates

    mutating func duplicateChecks() {
        func reportDuplicates(_ items: [(offset: Int, key: String)], _ checker: LintChecker, _ message: (String) -> String) {
            var counts: [String: Int] = [:]
            for item in items { counts[item.key, default: 0] += 1 }
            for item in items where counts[item.key]! > 1 { report(checker, at: item.offset, message(item.key)) }
        }
        var ids: [(offset: Int, key: String)] = []
        var customIDs: [(offset: Int, key: String)] = []
        for drawer in propertyDrawers {
            for node in drawer.children {
                guard let property = Property(line: node.text), !property.additive, !property.value.isEmpty else { continue }
                switch property.key.uppercased() {
                case "ID": ids.append((node.range.lowerBound, property.value))
                case "CUSTOM_ID": customIDs.append((node.range.lowerBound, property.value))
                default: break
                }
            }
        }
        reportDuplicates(customIDs, .duplicateCustomID) { "Duplicate CUSTOM_ID property \"\($0)\"" }
        reportDuplicates(names.map { ($0.offset, $0.value) }, .duplicateName) { "Duplicate NAME \"\($0)\"" }
        reportDuplicates(targets.map { ($0.range.lowerBound, Self.words(String($0.text.dropFirst(2).dropLast(2))).joined(separator: " ")) }, .duplicateTarget) {
            "Duplicate target <<\($0)>>"
        }
        reportDuplicates(footnoteDefinitions.compactMap { node in Self.definitionLabel(node).map { (node.range.lowerBound, $0) } }, .duplicateFootnoteDefinition) {
            "Duplicate footnote definition \"\($0)\""
        }
        var counts: [String: Int] = [:]
        for id in ids { counts[id.key, default: 0] += 1 }
        var elsewhere: [String: [String]] = [:]
        for id in ids where elsewhere[id.key] == nil {
            elsewhere[id.key] = (env.idFiles?(id.key) ?? []).filter { $0 != path }.map { ($0 as NSString).lastPathComponent }
        }
        for id in ids {
            let others = Array(Set(elsewhere[id.key]!)).sorted()
            guard counts[id.key]! > 1 || !others.isEmpty else { continue }
            report(.duplicateID, at: id.offset, "Duplicate ID \"\(id.key)\"" + (others.isEmpty ? "" : ", also in \(others.joined(separator: ", "))"))
        }
    }

    // MARK: - Drawers and blocks

    mutating func drawerChecks() {
        var drawerEnds: [Int: Int] = [:]
        for node in drawers + propertyDrawers {
            drawerEnds[lineIndex(node.range.lowerBound)] = lineIndex(node.range.upperBound - 1)
        }
        let pattern = "^[ \\t]*:((?:\\w|[-_])+):[ \\t]*$"
        let lines = matches(pattern).map { lineIndex($0.range.location) }
        var skipUntil = -1
        var k = 0
        while k < lines.count {
            let line = lines[k]
            k += 1
            guard line > skipUntil else { continue }
            switch lineTags[line] {
            case .drawer where drawerEnds[line] != nil:
                let end = drawerEnds[line]!
                while k < lines.count, lines[k] < end {
                    report(.incompleteDrawer, at: lineStarts[lines[k]], "Possible misleading drawer entry \"\(self.line(lines[k]).trimmingCharacters(in: .whitespaces))\"")
                    k += 1
                }
                skipUntil = end
            case .propertyDrawer where drawerEnds[line] != nil:
                skipUntil = drawerEnds[line]!
            case .verbatimBlock:
                break
            default:
                report(.incompleteDrawer, at: lineStarts[line], "Possible incomplete drawer \"\(self.line(line).trimmingCharacters(in: .whitespaces))\"")
            }
        }

        for node in drawers where line(lineIndex(node.range.lowerBound)).trimmingCharacters(in: .whitespaces) == ":PROPERTIES:" {
            report(.obsoletePropertiesDrawer, at: node.range.lowerBound, "Incorrect location for PROPERTIES drawer")
        }
        // `org-property-drawer-re`: only `:KEY:` lines between the first and the last.
        for node in propertyDrawers {
            let first = lineIndex(node.range.lowerBound), last = lineIndex(node.range.upperBound - 1)
            if (first + 1..<last).contains(where: { !Self.isPropertyLine(line($0)) }) {
                report(.obsoletePropertiesDrawer, at: node.range.lowerBound, "Incorrect contents for PROPERTIES drawer")
            }
        }
    }

    /// `[ \t]*:\S+:([ \t].*)?`, a line `org-property-drawer-re` allows: the first run of
    /// non-blanks after the colon is at least two long and ends in a colon.
    static func isPropertyLine(_ line: String) -> Bool {
        let rest = line.drop { $0 == " " || $0 == "\t" }
        guard rest.first == ":" else { return false }
        let run = rest.dropFirst().prefix { !$0.isWhitespace }
        return run.count >= 2 && run.last == ":"
    }

    static let deprecatedExportBlocks: Set<String> = ["ASCII", "BEAMER", "HTML", "LATEX", "MAN", "MARKDOWN", "MD", "ODT", "ORG", "TEXINFO"]

    mutating func blockChecks() {
        for m in matches("^[ \\t]*#\\+(BEGIN|END)(?::|_\\S*)?[ \\t]*", caseInsensitive: true) {
            let index = lineIndex(m.range.location)
            let name = line(index).trimmingCharacters(in: .whitespaces)
            let lineEnd = lineStarts[index] + (line(index) as NSString).length
            if group(m, 1)!.uppercased() == "END", NSMaxRange(m.range) < lineEnd {
                report(.invalidBlock, at: lineStarts[index], "Invalid block closing line \"\(name)\"")
            } else if ![.block, .verbatimBlock, .dynamicBlock].contains(lineTags[index]) {
                report(.invalidBlock, at: lineStarts[index], "Possible incomplete block \"\(name)\"")
            }
        }
        for node in blocks {
            let name = Self.blockName(node)
            let first = node.text.prefix { $0 != "\n" && $0 != "\r" }.drop { $0 == " " || $0 == "\t" }
            let parameters = first.dropFirst("#+begin_".count + name.count).trimmingCharacters(in: .whitespaces)
            switch name.lowercased() {
            case "src":
                if parameters.isEmpty || parameters.hasPrefix(":") || parameters.hasPrefix("-") || parameters.hasPrefix("+") {
                    report(.missingLanguageInSrcBlock, at: node.range.lowerBound, "Missing language in source block")
                }
            case "export":
                if parameters.isEmpty { report(.missingBackendInExportBlock, at: node.range.lowerBound, "Missing backend in export block") }
            case let lower where Self.deprecatedExportBlocks.contains(lower.uppercased()):
                report(.deprecatedExportBlocks, at: node.range.lowerBound, "Deprecated syntax for export block.  Use \"BEGIN_EXPORT \(name)\" instead")
            default:
                break
            }
        }
    }

    // MARK: - Lines org-lint searches for

    mutating func lineChecks() {
        for m in matches("^[ \\t]*(?:CLOSED|DEADLINE|SCHEDULED):", caseInsensitive: true) {
            let index = lineIndex(m.range.location)
            if ![.planning, .verbatimBlock].contains(lineTags[index]) {
                report(.misplacedPlanningInfo, at: lineStarts[index], "Misplaced planning info line")
            }
        }
        for m in matches("^[ \\t]+%%\\(") {
            let index = lineIndex(m.range.location)
            if lineTags[index] != .verbatimBlock { report(.indentedDiarySexp, at: lineStarts[index], "Possible indented diary-sexp") }
        }
        let dual = try! NSRegularExpression(pattern: "^[ \\t]*#\\+(?:CAPTION|RESULTS)(\\[.*\\])?:(?: |$)", options: .caseInsensitive)
        for m in matches("^[ \\t]*#\\+([^\\s:]*)(?: |$)") {
            let name = group(m, 1)!
            let upper = name.uppercased()
            if upper.hasPrefix("BEGIN") || upper.hasPrefix("END") { continue }
            let index = lineIndex(m.range.location)
            let content = line(index)
            if dual.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) != nil { continue }
            report(.invalidKeywordSyntax, at: m.range.location, "Possible missing colon in keyword \"\(name)\"")
        }
        for m in matches("[^*\\n\\r ,]\\*{2,} ", anchorsMatchLines: false) {
            let index = lineIndex(NSMaxRange(m.range))
            if [.paragraph, .heading].contains(lineTags[index]) { report(.misplacedHeading, at: m.range.location, "Possibly misplaced heading line") }
        }
    }

    // MARK: - Headings

    /// Keywords common in Org configurations: a heading starting with one the file doesn't
    /// define is likely meant as a TODO entry.
    static let commonKeywords: Set<String> = [
        "TODO", "DONE", "NEXT", "WAIT", "WAITING", "HOLD", "STARTED", "STRT", "SOMEDAY", "MAYBE", "CANCELLED", "CANCELED", "CANCEL",
        "CNCL", "KILL", "PROJ", "PROJECT", "LOOP", "IDEA", "DELEGATED", "INPROGRESS", "IN-PROGRESS", "DOING", "BLOCKED", "REVIEW",
    ]

    /// The edit distance of two words, a swap of neighbours counting one.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }

    mutating func headingChecks() {
        let known = tree.settings.todoKeywordNames
        let priorities = tree.settings.priorities
        for heading in model.headings {
            let at = heading.headingRange.lowerBound
            let title = heading.title
            var uncommented = title
            if uncommented == "COMMENT" { uncommented = "" } else if uncommented.hasPrefix("COMMENT ") { uncommented = String(uncommented.dropFirst(8)) }
            if uncommented.hasPrefix("QUOTE ") { report(.quoteSection, at: at, "Deprecated QUOTE section") }
            let words = Self.words(title)
            if let last = words.last, last.hasPrefix(":"), last.contains("::"), last.wholeMatch(of: /:[\p{L}\p{N}_@#%:]+:/) != nil {
                report(.spuriousColons, at: at, "Tags contain a spurious colon")
            }
            if let value = heading.priority {
                // `org-priority-value-regexp` reads 0 to 64 without leading zeros; other numbers aren't a priority.
                if let n = Int(value), String(n) != value || n > 64 {
                    report(.priority, at: at, "Invalid priority '\(value)'")
                } else if !Self.validPriority(value, priorities) {
                    report(.priority, at: at, "Out-of-bounds priority '\(value)'")
                }
            } else if title.hasPrefix("[#"), let m = title.prefixMatch(of: /\[#([^\[\]]*)(\]*)/) {
                // Org reads `[#a]` as a priority, case-folded, but not a valid one, and reports nothing.
                let lowerLetter = m.1.count == 1 && m.1.first!.isASCII && m.1.first!.isLowercase && !m.2.isEmpty
                if !lowerLetter { report(.priority, at: at, m.2.isEmpty ? "Malformed priority '\(m.0)'" : "Invalid priority '\(m.1)'") }
            }
            if heading.todo == nil, let word = words.first, let first = word.first, first.isASCII, first.isUppercase, word.count >= 2,
               word.wholeMatch(of: /[A-Z][A-Z0-9_-]*[A-Z0-9]/) != nil, !known.contains(word), word != "COMMENT",
               Self.commonKeywords.contains(word) || known.contains(where: { $0.count >= 4 && Self.distance(Array($0), Array(word)) == 1 }) {
                report(.unknownTodoKeyword, at: at, "Unknown TODO keyword \"\(word)\"")
            }
        }
    }

    static func validPriority(_ value: String, _ priorities: Priorities) -> Bool {
        if let n = Int(value), let high = Int(priorities.highest), let low = Int(priorities.lowest) { return (min(high, low)...max(high, low)).contains(n) }
        guard Int(value) == nil, Int(priorities.highest) == nil, Int(priorities.lowest) == nil else { return false }
        return priorities.highest <= value && value <= priorities.lowest
    }

    // MARK: - Properties

    /// `org-special-properties`.
    static let specialProperties: Set<String> = ["ALLTAGS", "BLOCKED", "CLOCKSUM", "CLOCKSUM_T", "CLOSED", "DEADLINE", "FILE", "ITEM", "PRIORITY", "SCHEDULED", "TAGS", "TIMESTAMP", "TIMESTAMP_IA", "TODO"]

    /// `org-duration-p`.
    static func isDuration(_ s: String) -> Bool {
        ColumnView.minutes(s) != nil && s.trimmingCharacters(in: .whitespaces).wholeMatch(of: /[0-9]+(?:\.[0-9]*)?/) == nil
    }

    mutating func propertyChecks() {
        for drawer in propertyDrawers {
            for node in drawer.children where node.kind == .nodeProperty {
                guard let property = Property(line: node.text) else { continue }
                let at = node.range.lowerBound
                if Self.specialProperties.contains(property.key.uppercased()) {
                    report(.specialPropertyInPropertiesDrawer, at: at, "Special property \"\(property.key)\" found in a properties drawer")
                }
                if property.key == "EFFORT", !property.additive, !property.value.isEmpty, !Self.isDuration(property.value) {
                    report(.invalidEffortProperty, at: at, "Invalid effort duration format: \"\(property.value)\"")
                }
                if property.key == "ID", property.value.contains("::") {
                    report(.invalidIDProperty, at: at, "IDs should not include \"::\": \"\(property.value)\"")
                }
            }
        }
    }

    // MARK: - Timestamps

    mutating func timestampChecks() {
        for node in timestamps {
            let stamp = node.text
            guard !stamp.contains("%%("), let canonical = LintTimestamp.canonical(stamp), canonical != stamp else { continue }
            report(.timestampSyntax, at: node.range.lowerBound, "Potentially malformed timestamp \(stamp).  Parsed as: \(canonical)")
        }
        for node in clocks {
            let actual = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let canonical = LintTimestamp.canonicalClock(actual), canonical != actual else { continue }
            report(.clockSyntax, at: node.range.lowerBound, "Potentially malformed CLOCK: line \(actual).  Parsed as: \(canonical)")
        }
        for node in plannings {
            // Each timestamp belongs to the keyword just before it.
            var stamps: [String: Timestamp] = [:]
            for child in node.children where child.kind == .timestamp {
                let before = ns.substring(with: NSRange(location: node.range.lowerBound, length: child.range.lowerBound - node.range.lowerBound))
                    .trimmingCharacters(in: .whitespaces)
                guard let keyword = ["SCHEDULED", "DEADLINE", "CLOSED"].first(where: { before.hasSuffix($0 + ":") }), stamps[keyword] == nil,
                      let stamp = Timestamp.parse(child.text) else { continue }
                stamps[keyword] = stamp
            }
            let at = node.range.lowerBound
            if let scheduled = stamps["SCHEDULED"], !scheduled.active {
                report(.planningInactive, at: at, "Inactive timestamp in SCHEDULED will not appear in agenda.")
            } else if let deadline = stamps["DEADLINE"], !deadline.active {
                report(.planningInactive, at: at, "Inactive timestamp in DEADLINE will not appear in agenda.")
            }
            if let s = stamps["SCHEDULED"]?.repeater, let d = stamps["DEADLINE"]?.repeater,
               s.kind != .restart, d.kind != .restart, s.interval.value > 0, d.interval.value > 0,
               s.kind != d.kind || s.interval != d.interval {
                report(.mismatchedPlanningRepeaters, at: at, "Different repeaters in SCHEDULED and DEADLINE timestamps.")
            }
        }
    }

    // MARK: - Footnotes

    /// A definition's label, from its `[fn:LABEL]`.
    static func definitionLabel(_ node: SyntaxNode) -> String? {
        guard let marker = node.tokens.first(where: { $0.kind == .marker }) else { return nil }
        let label = String(marker.text.dropFirst(4).dropLast())
        return label.isEmpty ? nil : label
    }

    /// A reference's label, nil for an anonymous one, and whether it defines the footnote too.
    static func referenceLabel(_ node: SyntaxNode) -> (label: String?, inline: Bool) {
        let inside = node.text.dropFirst(4).dropLast()
        guard let colon = inside.firstIndex(of: ":") else { return (String(inside), false) }
        let label = inside[..<colon]
        return (label.isEmpty ? nil : String(label), true)
    }

    mutating func footnoteChecks() {
        let references = footnoteReferences.map { (node: $0, reference: Self.referenceLabel($0)) }
        let definitions = footnoteDefinitions.compactMap { node in Self.definitionLabel(node).map { (node: node, label: $0) } }
        let defined = Set(definitions.map(\.label) + references.filter(\.reference.inline).compactMap(\.reference.label))
        let referenced = Set(references.compactMap(\.reference.label))
        for (node, reference) in references where !reference.inline {
            if let label = reference.label, !defined.contains(label) {
                report(.undefinedFootnoteReference, at: node.range.lowerBound, "Missing definition for footnote [\(label)]")
            }
        }
        for (node, label) in definitions where !referenced.contains(label) {
            report(.unreferencedFootnoteDefinition, at: node.range.lowerBound, "No reference for footnote definition [\(label)]")
        }
    }
}

/// The targets a `file:…::search` link can reach in an Org file, as `Links.search` finds them.
struct SearchIndex {
    let tree: OrgTree
    let text: String
    let customIDs: Set<String>
    let targets: Set<[String]>
    let names: Set<[String]>
    let headings: Set<[String]>

    init(_ tree: OrgTree) {
        self.tree = tree
        text = tree.text
        let model = DocumentModel(tree: tree)
        customIDs = Set(model.headings.flatMap { $0.properties.filter { $0.key.uppercased() == "CUSTOM_ID" }.map(\.value) })
        headings = Set(model.headings.map { Links.normalizedTitle($0.title).split(whereSeparator: \.isWhitespace).map { $0.uppercased() } })
        let ns = text as NSString
        targets = Set(try! NSRegularExpression(pattern: "(?<!<)<<([^<>\\n]+)>>(?!>)").matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            Linter.words(ns.substring(with: $0.range(at: 1))).map { $0.uppercased() }
        })
        names = Set(text.matches(of: /(?m)^[ \t]*#\+(?i:name): +(.*?)[ \t]*$/).map { Linter.words(String($0.1)).map { $0.uppercased() } })
    }

    func finds(_ s: String) -> Bool {
        let normalized = s.replacingOccurrences(of: "\\n[ \\t]*", with: " ", options: .regularExpression)
        if normalized.hasPrefix("#") { return customIDs.contains(String(normalized.dropFirst())) }
        if (normalized.hasPrefix("(") && normalized.hasSuffix(")")) || (normalized.count >= 2 && normalized.hasPrefix("/") && normalized.hasSuffix("/")) {
            if case .failed = Links.search(s, text: text, tree: tree) { return false }
            return true
        }
        let starred = normalized.hasPrefix("*")
        let words = Linter.words(starred ? String(s.dropFirst()) : s).map { $0.uppercased() }
        if !starred, targets.contains(words) || names.contains(words) { return true }
        return headings.contains(words)
    }
}
