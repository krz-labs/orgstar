import Foundation

/// A replace across files: plain text or a regexp in the dialect of the editor's find bar and
/// `:s` (ICU, as `NSRegularExpression` reads it, `^` and `$` at line ends), with Emacs's case
/// rules. `case-fold-search` folds case unless the pattern has an upper-case letter
/// (`search-upper-case`); while it folds, `case-replace` makes the replacement follow the
/// case of each match as `replace-match` does.
public struct TextReplace: Sendable, Equatable {
    public var pattern: String
    /// Literal for plain text. For a regexp, `\N` or `$N` is group N, `\&` or `$0` the whole
    /// match, `\\` a backslash and `\$` a dollar sign.
    public var replacement: String
    public var isRegexp: Bool
    /// `case-fold-search`.
    public var caseFold: Bool
    /// `case-replace`.
    public var caseReplace: Bool

    public init(pattern: String, replacement: String, isRegexp: Bool = false, caseFold: Bool = true, caseReplace: Bool = true) {
        self.pattern = pattern
        self.replacement = replacement
        self.isRegexp = isRegexp
        self.caseFold = caseFold
        self.caseReplace = caseReplace
    }

    public enum InvalidPattern: Error, Equatable {
        case empty
        /// ICU can't compile it.
        case invalid
    }

    /// Whether matching ignores case: `case-fold-search` on and no upper-case letter in the
    /// pattern.
    public var foldsCase: Bool { caseFold && !Self.hasUpperCase(pattern, regexp: isRegexp) }

    /// The pattern compiled, or why it can't be.
    public func regex() throws -> NSRegularExpression {
        guard !pattern.isEmpty else { throw InvalidPattern.empty }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if foldsCase { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: isRegexp ? pattern : NSRegularExpression.escapedPattern(for: pattern), options: options)
        } catch {
            throw InvalidPattern.invalid
        }
    }

    /// Every match in `text` outside `skipping`, as changes. `regex` is `regex()`, compiled
    /// once for many files.
    public func changes(in text: String, skipping: [Range<Int>] = [], regex: NSRegularExpression? = nil) throws -> [ProposedChange] {
        let regex = try regex ?? self.regex()
        let ns = text as NSString
        let lines = LineStarts(ns)
        let casifies = caseReplace && foldsCase
        var changes: [ProposedChange] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range.location..<NSMaxRange(match.range)
            guard !EncryptedText.overlaps(range, skipping) else { continue }
            var new = isRegexp ? Self.expand(replacement, match: match, in: ns) : replacement
            if casifies { new = Self.casified(new, like: ns.substring(with: match.range)) }
            changes.append(lines.change(id: changes.count, TextEdit(range: range, replacement: new)))
        }
        return changes
    }

    /// `isearch-no-upper-case-p` negated: whether `pattern` has an upper-case letter, not
    /// counting, in a regexp, a letter after a backslash or in `[:class:]` and `\p{…}`.
    static func hasUpperCase(_ pattern: String, regexp: Bool) -> Bool {
        guard regexp else { return pattern.contains { $0.isUppercase } }
        var stripped = pattern.replacingOccurrences(of: "\\[:[a-z]+:\\]", with: "", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: "\\\\[pP]\\{[^}]*\\}", with: "", options: .regularExpression)
        var escaped = false
        for character in stripped {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character.isUppercase { return true }
        }
        return false
    }

    /// `template` with the match's groups in place of `\N`, `$N`, `\&`.
    static func expand(_ template: String, match: NSTextCheckingResult, in ns: NSString) -> String {
        func group(_ n: Int) -> String {
            guard n < match.numberOfRanges else { return "" }
            let range = match.range(at: n)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
        var result = ""
        var characters = template[...]
        while let c = characters.popFirst() {
            if c == "\\" || c == "$", let next = characters.first {
                if let digit = next.wholeNumberValue, next.isASCII {
                    characters.removeFirst()
                    result += group(digit)
                    continue
                }
                if c == "\\", next == "&" {
                    characters.removeFirst()
                    result += group(0)
                    continue
                }
                if c == "\\", next == "\\" || next == "$" {
                    characters.removeFirst()
                    result.append(next)
                    continue
                }
            }
            result.append(c)
        }
        return result
    }

    /// `replace-match`'s case conversion: `new` in capitals when `matched` is in capitals
    /// with a word of two or more letters (or is one capital letter), with each word's
    /// initial capitalized when every word of `matched` starts with a capital, else as it is.
    static func casified(_ new: String, like matched: String) -> String {
        var someMultiletterWord = false, someLowercase = false, someUppercase = false, someNonuppercaseInitial = false
        var previous: Character = "\n"
        for c in matched {
            if c.isLowercase {
                someLowercase = true
                if isWord(previous) { someMultiletterWord = true } else { someNonuppercaseInitial = true }
            } else if c.isUppercase {
                someUppercase = true
                if isWord(previous) { someMultiletterWord = true }
            } else if !isWord(previous), isWord(c) {
                someNonuppercaseInitial = true
            }
            previous = c
        }
        if !someLowercase, someMultiletterWord { return new.uppercased() }
        if !someNonuppercaseInitial, someMultiletterWord { return upcaseInitials(new) }
        if !someNonuppercaseInitial, someUppercase { return new.uppercased() }
        return new
    }

    /// Word constituents in Org mode's syntax table: letters and digits.
    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// `upcase-initials`: the first letter of each word in capitals, the rest as it is.
    private static func upcaseInitials(_ text: String) -> String {
        var result = ""
        var previous: Character = "\n"
        for c in text {
            result += !isWord(previous) && c.isLetter ? c.uppercased() : String(c)
            previous = c
        }
        return result
    }
}
