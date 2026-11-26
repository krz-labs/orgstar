import Foundation

/// One run of the checkers over a file. The tree is walked once to collect what the checkers
/// read; checkers that org-lint runs as regexp searches over the buffer search the text and ask
/// the tree which element each line belongs to.
struct Linter {
    let text: String
    let ns: NSString
    let tree: OrgTree
    let path: String?
    let env: LintEnvironment
    let model: DocumentModel
    var findings: [LintFinding] = []

    /// UTF-16 offset of each line's first character.
    let lineStarts: [Int]
    /// The innermost element each line belongs to.
    var lineTags: [Tag]
    /// Encrypted entry bodies, which aren't linted.
    var excluded: [Range<Int>] = []

    enum Tag: Equatable {
        case none, other, heading, paragraph, planning, drawer, propertyDrawer, dynamicBlock
        /// A block whose contents aren't parsed: comment, example, export, src and verse blocks.
        case verbatimBlock
        case block
    }

    var links: [SyntaxNode] = []
    var footnoteReferences: [SyntaxNode] = []
    var footnoteDefinitions: [SyntaxNode] = []
    var targets: [SyntaxNode] = []
    var keywords: [SyntaxNode] = []
    var propertyDrawers: [SyntaxNode] = []
    var drawers: [SyntaxNode] = []
    var blocks: [SyntaxNode] = []
    var plannings: [SyntaxNode] = []
    var clocks: [SyntaxNode] = []
    var timestamps: [SyntaxNode] = []

    /// `#+NAME` values of elements, and `#+RESULTS` values, for fuzzy links.
    var names: [(offset: Int, value: String)] = []
    var resultNames: [String] = []

    init(text: String, tree: OrgTree, path: String?, environment: LintEnvironment) {
        self.text = text
        ns = text as NSString
        self.tree = tree
        self.path = path
        env = environment
        model = DocumentModel(tree: tree)
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        if starts.count > 1, starts.last == ns.length { starts.removeLast() }
        lineStarts = starts
        lineTags = Array(repeating: .none, count: starts.count)
    }

    mutating func run() {
        excluded = encryptedBodies()
        walk(tree.root)
        keywordChecks()
        linkChecks()
        attachmentChecks()
        duplicateChecks()
        drawerChecks()
        blockChecks()
        lineChecks()
        headingChecks()
        propertyChecks()
        timestampChecks()
        footnoteChecks()
    }

    // MARK: - Lines

    /// 0-based line of a UTF-16 offset.
    func lineIndex(_ offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Line `index`'s text, without its line ending.
    func line(_ index: Int) -> String {
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] : ns.length
        var s = ns.substring(with: NSRange(location: start, length: end - start))
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        return s
    }

    mutating func report(_ checker: LintChecker, at offset: Int, _ message: String) {
        guard !excluded.contains(where: { $0.contains(offset) }) else { return }
        findings.append(LintFinding(offset: offset, line: lineIndex(offset) + 1, checker: checker, message: message))
    }

    func matches(_ pattern: String, caseInsensitive: Bool = false, anchorsMatchLines: Bool = true) -> [NSTextCheckingResult] {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if anchorsMatchLines { options.insert(.anchorsMatchLines) }
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    }

    func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
        m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
    }

    var folder: String? { path.map { ($0 as NSString).deletingLastPathComponent } }

    // MARK: - Collecting

    static let verbatimBlocks: Set<String> = ["comment", "example", "export", "src", "verse"]

    /// The name after `#+begin_` on a block's first line, as written.
    static func blockName(_ node: SyntaxNode) -> String {
        let first = node.text.prefix { $0 != "\n" && $0 != "\r" }.drop { $0 == " " || $0 == "\t" }
        return String(first.dropFirst("#+begin_".count).prefix { !$0.isWhitespace })
    }

    mutating func tag(_ node: SyntaxNode, _ tag: Tag) {
        let first = lineIndex(node.range.lowerBound)
        let last = lineIndex(max(node.range.lowerBound, node.range.upperBound - 1))
        for i in first...last { lineTags[i] = tag }
    }

    mutating func walk(_ node: SyntaxNode) {
        for child in node.children {
            switch child.kind {
            case .section, .zerothSection, .title, .linkDescription, .itemTag, .tableRow, .tableCell:
                walk(child)
            case .heading:
                tag(child, .heading)
                walk(child)
            case .block:
                tag(child, Self.verbatimBlocks.contains(Self.blockName(child).lowercased()) ? .verbatimBlock : .block)
                blocks.append(child)
            case .dynamicBlock:
                tag(child, .dynamicBlock)
            case .drawer:
                tag(child, .drawer)
                drawers.append(child)
                walk(child)
            case .propertyDrawer:
                tag(child, .propertyDrawer)
                propertyDrawers.append(child)
            case .planning:
                tag(child, .planning)
                plannings.append(child)
            case .clock:
                tag(child, .other)
                clocks.append(child)
            case .paragraph:
                tag(child, .paragraph)
                walk(child)
            case .keyword, .affiliatedKeyword:
                tag(child, .other)
                keywords.append(child)
            case .footnoteDefinition:
                tag(child, .other)
                footnoteDefinitions.append(child)
                walk(child)
            case .link:
                links.append(child)
                walk(child)
            case .footnoteReference:
                footnoteReferences.append(child)
                walk(child)
            case .target:
                targets.append(child)
            case .timestamp:
                timestamps.append(child)
            case .bold, .italic, .underline, .strikeThrough, .citation, .citationReference, .superscript, .subscript, .radioTarget:
                walk(child)
            case .verbatim, .code, .statisticsCookie, .macro, .inlineSourceBlock, .latexFragment, .lineBreak, .entity, .exportSnippet,
                 .inlineBabelCall:
                break
            default:
                tag(child, .other)
                walk(child)
            }
        }
    }

    /// The bodies of entries tagged with the crypt tag that hold an armored message: from its
    /// begin line through its end line.
    func encryptedBodies() -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for (index, heading) in model.headings.enumerated() where heading.localTags.contains(env.cryptTag) {
            let bodyEnd = model.headings.dropFirst(index + 1).first { $0.parent == index }?.sectionRange.lowerBound ?? heading.sectionRange.upperBound
            let body = NSRange(location: heading.headingRange.upperBound, length: max(0, bodyEnd - heading.headingRange.upperBound))
            let begin = ns.range(of: "-----BEGIN PGP MESSAGE-----", range: body)
            guard begin.location != NSNotFound else { continue }
            let after = NSRange(location: NSMaxRange(begin), length: NSMaxRange(body) - NSMaxRange(begin))
            let end = ns.range(of: "-----END PGP MESSAGE-----", range: after)
            let stop = end.location == NSNotFound ? NSMaxRange(body) : NSMaxRange(ns.lineRange(for: end))
            ranges.append(ns.lineRange(for: begin).location..<stop)
        }
        return ranges
    }
}
