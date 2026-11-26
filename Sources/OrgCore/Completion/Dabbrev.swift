import Foundation

/// `dabbrev-expand` with Emacs's defaults: the word before the caret completed from words that
/// start with it, ignoring case, in the buffer (before the caret nearest first, then after it
/// nearest first), then in the other open buffers from their start, then in the index. Each
/// expansion is offered once; its case follows the abbreviation's as
/// `dabbrev--substitute-expansion` makes it.
public enum Dabbrev {
    /// Word and symbol constituents of Org's syntax table: letters, digits and `$%'&*+-/=\_|~`.
    static let wordClass = "[\\p{L}\\p{M}\\p{N}$%'&*+\\-/=\\\\_|~]"

    static func isWordCharacter(_ c: unichar) -> Bool {
        if c < 128 {
            guard let scalar = UnicodeScalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || "$%'&*+-/=\\_|~".unicodeScalars.contains(scalar)
        }
        guard let scalar = UnicodeScalar(c) else { return true }
        return CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters).contains(scalar)
    }

    /// The abbreviation before `caret`: back to the start of its word. Nil when the character
    /// before the caret isn't part of a word.
    public static func abbreviation(in text: String, caret: Int) -> Range<Int>? {
        let ns = text as NSString
        let caret = min(caret, ns.length)
        var start = caret
        while start > 0, isWordCharacter(ns.character(at: start - 1)) { start -= 1 }
        return start < caret ? start..<caret : nil
    }

    /// Words starting with `abbrev`, ignoring case, that are longer than it, in `text`, with
    /// where they start.
    static func words(_ abbrev: String, in text: String) -> [(start: Int, word: String)] {
        let pattern = "(?<!\(wordClass))" + NSRegularExpression.escapedPattern(for: abbrev) + "\(wordClass)+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ($0.range.location, ns.substring(with: $0.range)) }
    }

    /// Expansions in the buffer: words before `start` nearest first, then words from `end`
    /// on nearest first, as typed in the buffer.
    public static func expansions(of abbrev: String, in text: String, before start: Int, after end: Int) -> [String] {
        let found = words(abbrev, in: text)
        return unique(found.filter { $0.start < start }.reversed().map(\.word) + found.filter { $0.start >= end }.map(\.word))
    }

    /// Expansions in another buffer, from its start.
    public static func expansions(of abbrev: String, in text: String) -> [String] {
        unique(words(abbrev, in: text).map(\.word))
    }

    /// The first of each set equal ignoring case.
    public static func unique(_ words: [String], excluding: Set<String> = []) -> [String] {
        var seen = excluding
        return words.filter { seen.insert($0.lowercased()).inserted }
    }

    /// The text that replaces `old` (the abbreviation, or the expansion inserted before on a
    /// repeat): `expansion` with its case made to follow `abbrev`'s, unless the expansion has
    /// mixed case or the abbreviation does and the expansion starts with it as typed.
    public static func substitute(_ expansion: String, for abbrev: String, replacing old: String) -> String {
        guard let firstLetter = abbrev.firstIndex(where: \.isLetter) else { return expansion }
        let rest = String(expansion.dropFirst())
        let restOneCase = rest == rest.lowercased() || rest == rest.uppercased()
        let lettersAfterFirst = abbrev.distance(from: firstLetter, to: abbrev.endIndex)
        let abbrevOneCase = abbrev == abbrev.lowercased() || (abbrev == abbrev.uppercased() && lettersAfterFirst > 1)
        if !(restOneCase && abbrevOneCase), expansion.hasPrefix(abbrev) { return expansion }
        return caseLike(old, expansion.lowercased())
    }

    /// `replace-match`'s case conversion: `text` in capitals when `old` is all capitals with a
    /// word of more than one letter, with capital initials when every word of `old` starts
    /// with a capital, else as it is.
    static func caseLike(_ old: String, _ text: String) -> String {
        let words = old.split { !$0.isLetter && !$0.isNumber }
        guard old.contains(where: \.isUppercase) else { return text }
        if !old.contains(where: \.isLowercase) {
            return words.contains(where: { $0.filter(\.isLetter).count > 1 }) ? text.uppercased() : capitalized(text)
        }
        let initialsCapital = words.allSatisfy { word in word.first { $0.isLetter }.map(\.isUppercase) ?? true }
        return initialsCapital ? capitalized(text) : text
    }

    /// The first letter of each word in capitals (`upcase-initials`).
    static func capitalized(_ text: String) -> String {
        var out = ""
        var inWord = false
        for c in text {
            let wordCharacter = c.isLetter || c.isNumber
            out += !inWord && wordCharacter ? c.uppercased() : String(c)
            inWord = wordCharacter
        }
        return out
    }

    /// The words that complete the one before the caret, from the buffer and `others` (the
    /// other open buffers' text), as they would be inserted, with the index to ask for more.
    public static func completion(_ context: EditContext, others: [String] = []) -> Completion? {
        guard let range = abbreviation(in: context.text, caret: context.caret) else { return nil }
        let abbrev = (context.text as NSString).substring(with: NSRange(range))
        let found = unique(expansions(of: abbrev, in: context.text, before: range.lowerBound, after: range.upperBound) + others.flatMap { expansions(of: abbrev, in: $0) })
        var completion = Completion(kind: .word, range: range, candidates: candidates(found, abbrev: abbrev))
        completion.typed = abbrev
        completion.pool = found
        completion.query = .words(abbrev)
        return completion
    }

    /// A word completion after more is typed: the expansions found when it opened that
    /// still start with the abbreviation.
    public static func narrowed(_ completion: Completion, to range: Range<Int>, in text: String) -> Completion {
        var narrowed = completion
        let abbrev = (text as NSString).substring(with: NSRange(range))
        narrowed.range = range
        narrowed.typed = abbrev
        narrowed.candidates = candidates(completion.pool.filter { $0.lowercased().hasPrefix(abbrev.lowercased()) && $0.count > abbrev.count }, abbrev: abbrev)
        return narrowed
    }

    /// `completion` with words the index found added after the buffers'.
    public static func adding(_ words: [String], to completion: Completion) -> Completion {
        var added = completion
        added.pool += unique(words, excluding: Set(completion.pool.map { $0.lowercased() } + [completion.typed.lowercased()]))
        added.candidates = candidates(added.pool, abbrev: completion.typed)
        added.query = nil
        return added
    }

    /// `expansions` as inserted in place of `abbrev`, each once.
    public static func candidates(_ expansions: [String], abbrev: String) -> [String] {
        var seen = Set<String>()
        return expansions.map { substitute($0, for: abbrev, replacing: abbrev) }.filter { seen.insert($0).inserted }
    }

    /// Words starting with `prefix`, ignoring case, in `texts` in order: what the index adds.
    public static func words(_ prefix: String, in texts: [String], limit: Int = 50) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for text in texts {
            for (_, word) in words(prefix, in: text) where seen.insert(word.lowercased()).inserted {
                result.append(word)
                if result.count == limit { return result }
            }
        }
        return result
    }
}

/// `dabbrev-expand` repeated: each call replaces what the last inserted with the next
/// expansion; past the last, the abbreviation comes back.
public struct DabbrevExpansion: Sendable, Equatable {
    /// Where the abbreviation starts.
    public let start: Int
    public let abbrev: String
    /// Expansions as found, the index's added when they arrive.
    public private(set) var expansions: [String]
    /// The next expansion to use.
    public private(set) var next = 0
    /// What is between `start` and the caret now.
    public private(set) var inserted: String

    public init?(_ context: EditContext, others: [String] = []) {
        guard let range = Dabbrev.abbreviation(in: context.text, caret: context.caret) else { return nil }
        start = range.lowerBound
        let abbrev = (context.text as NSString).substring(with: NSRange(range))
        self.abbrev = abbrev
        inserted = abbrev
        expansions = Dabbrev.unique(Dabbrev.expansions(of: abbrev, in: context.text, before: range.lowerBound, after: range.upperBound)
            + others.flatMap { Dabbrev.expansions(of: abbrev, in: $0) })
    }

    public var end: Int { start + inserted.utf16.count }

    /// Adds expansions found later (the index's), leaving out those already found.
    public mutating func add(_ more: [String]) {
        expansions += Dabbrev.unique(more, excluding: Set(expansions.map { $0.lowercased() } + [abbrev.lowercased()]))
    }

    /// The edit for the next expansion, or for the abbreviation again when there is none
    /// left; `exhausted` says which.
    public mutating func advance() -> (edit: TextEdit, exhausted: Bool) {
        let range = start..<end
        guard next < expansions.count else {
            inserted = abbrev
            next = expansions.count + 1
            return (TextEdit(range: range, replacement: abbrev), true)
        }
        let text = Dabbrev.substitute(expansions[next], for: abbrev, replacing: inserted)
        next += 1
        inserted = text
        return (TextEdit(range: range, replacement: text), false)
    }

    /// What the echo area says when nothing is inserted.
    public var failure: String {
        expansions.isEmpty ? "No dynamic expansion for `\(abbrev)' found" : "No further dynamic expansion for `\(abbrev)' found"
    }
}
