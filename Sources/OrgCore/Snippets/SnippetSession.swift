import Foundation

/// An expanded snippet while its fields are filled in: TAB and S-TAB move between fields,
/// typing in a field changes its mirrors, and leaving the last field, Escape, or an edit or
/// caret outside the snippet ends it. Offsets are UTF-16 into the buffer.
public struct SnippetSession: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public let number: Int
        /// The field first, then its mirrors.
        public var ranges: [Range<Int>]
    }

    public private(set) var fields: [Field]
    /// Where the caret goes when the last field is left.
    public private(set) var exit: Range<Int>
    /// From the start of the snippet to its end.
    public private(set) var extent: Range<Int>
    /// The field being filled in.
    public private(set) var active = 0

    /// The session for `expansion` inserted at `offset`; nil when it has no fields.
    public init?(_ expansion: SnippetExpansion, at offset: Int) {
        guard !expansion.fields.isEmpty else { return nil }
        func shifted(_ range: Range<Int>) -> Range<Int> { (range.lowerBound + offset)..<(range.upperBound + offset) }
        fields = expansion.fields.map { Field(number: $0.number, ranges: $0.ranges.map(shifted)) }
        exit = shifted(expansion.exit)
        extent = offset..<(offset + expansion.text.utf16.count)
    }

    /// The active field's text range, which is selected on entering it.
    public var selection: Range<Int> { fields[active].ranges[0] }

    public enum Step: Sendable, Equatable {
        /// Select this field.
        case field(Range<Int>)
        /// The snippet is done; select `exit`.
        case exit(Range<Int>)
    }

    /// TAB: the next field, or the exit after the last.
    public mutating func next() -> Step {
        guard active + 1 < fields.count else { return .exit(exit) }
        active += 1
        return .field(selection)
    }

    /// S-TAB: the field before, or the first again.
    public mutating func previous() -> Range<Int> {
        if active > 0 { active -= 1 }
        return selection
    }

    /// Whether `offset` is in the snippet, its ends included.
    public func contains(_ offset: Int) -> Bool { extent.lowerBound <= offset && offset <= extent.upperBound }

    /// Follows `edit` of the buffer; false when the edit is outside the snippet, which ends it.
    /// Text typed at either end of the active field goes into it, and an edit replacing a
    /// mirror exactly becomes the mirror's text.
    public mutating func map(_ edit: TextEdit) -> Bool {
        let a = edit.range.lowerBound, b = edit.range.upperBound
        let n = edit.replacement.utf16.count
        let delta = n - (b - a)
        let primary = fields[active].ranges[0]
        let inActive = primary.lowerBound <= a && b <= primary.upperBound
        guard inActive || (extent.lowerBound <= a && b <= extent.upperBound) else { return false }
        // Replacing the whole snippet, as undoing its expansion does, ends it.
        if !inActive, a == extent.lowerBound, b == extent.upperBound, !extent.isEmpty { return false }
        /// A position; `right` keeps it after text inserted there.
        func point(_ p: Int, right: Bool) -> Int {
            if p < a { return p }
            if p > b { return p + delta }
            if a == b { return right ? p + n : p }
            if p == a { return p }
            if p == b { return p + delta }
            return right ? a + n : a
        }
        func range(_ r: Range<Int>, grows: Bool) -> Range<Int> {
            if grows { return point(r.lowerBound, right: false)..<point(r.upperBound, right: true) }
            if r.isEmpty {
                let p = point(r.lowerBound, right: true)
                return p..<p
            }
            let lower = point(r.lowerBound, right: true), upper = point(r.upperBound, right: false)
            return lower..<max(lower, upper)
        }
        var mirrorGrown = false
        for f in fields.indices {
            for r in fields[f].ranges.indices {
                let old = fields[f].ranges[r]
                var grows = false
                if inActive {
                    grows = f == active && r == 0
                } else if !mirrorGrown, r > 0, old == edit.range {
                    grows = true
                    mirrorGrown = true
                }
                fields[f].ranges[r] = range(old, grows: grows)
            }
        }
        exit = range(exit, grows: false)
        extent = point(extent.lowerBound, right: false)..<point(extent.upperBound, right: true)
        return true
    }

    /// Edits that make every mirror show its field's text in `text`, the buffer as it is now.
    public func mirrorEdits(in text: String) -> [TextEdit] {
        let ns = text as NSString
        func substring(_ r: Range<Int>) -> String? {
            guard r.upperBound <= ns.length else { return nil }
            return ns.substring(with: NSRange(location: r.lowerBound, length: r.count))
        }
        var edits: [TextEdit] = []
        for field in fields {
            guard let value = substring(field.ranges[0]) else { continue }
            for mirror in field.ranges.dropFirst() where substring(mirror) != value && mirror.upperBound <= ns.length {
                edits.append(TextEdit(range: mirror, replacement: value))
            }
        }
        return edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
