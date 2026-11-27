import Foundation

extension Flashcards {
    /// What a card shows for one position, before and after it is flipped, as org-fc's card
    /// types set up and flip a heading during a review.
    public struct Face: Sendable, Equatable {
        public struct Side: Sendable, Equatable {
            /// The heading's title; nil while it is hidden.
            public var title: String?
            public var text: String
            /// Ranges of `title + "\n" + text`, in UTF-16 offsets, to emphasize: a cloze hole.
            public var marks: [Range<Int>]

            public init(title: String?, text: String, marks: [Range<Int>] = []) {
                self.title = title
                self.text = text
                self.marks = marks
            }
        }

        public var front: Side
        public var back: Side
        /// For text-input cards: the answer to type, without emphasis markers.
        public var expected: String?
    }

    /// `org-fc-type-cloze-hole-re`: 1 text, 2 hint, 3 the hole's position.
    static let holePattern = "\\{\\{((?:\\$[^$]+\\$|[^}])*)\\}(?:\\{((?:\\$[^$]\\$|[^}])*)\\})?(?:@([0-9]+))?\\}"
    static let holeRegex = try! NSRegularExpression(pattern: holePattern)

    /// The card's face for `position`; nil for a type orgstar doesn't know or a position the
    /// card doesn't have.
    public static func face(_ card: Card, position: String) -> Face? {
        func join(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: "\n\n") }
        let answer = join([card.body, card.children])
        switch card.cardType {
        case .normal, .textInput:
            let front = Face.Side(title: card.title, text: card.back == nil ? "" : card.body)
            let expected = card.cardType == .textInput ? card.answerLine.map(deemphasize) : nil
            return Face(front: front, back: Face.Side(title: card.title, text: answer), expected: expected)
        case .double:
            switch position {
            case "front": return Face(front: Face.Side(title: card.title, text: card.back == nil ? "" : card.body), back: Face.Side(title: card.title, text: answer))
            case "back":
                let front = card.back.map { Face.Side(title: card.title, text: $0) } ?? Face.Side(title: nil, text: card.body)
                return Face(front: front, back: Face.Side(title: card.title, text: answer))
            default: return nil
            }
        case .cloze:
            guard let id = Int(position), let type = card.clozeType else { return nil }
            return cloze(card, hole: id, type: type)
        case nil:
            return nil
        }
    }

    /// `org-fc-type-cloze-hide-holes` and the flip that follows it.
    static func cloze(_ card: Card, hole: Int, type: ClozeType) -> Face? {
        let source = card.title + "\n" + card.body as NSString
        let matches = holeRegex.matches(in: source as String, range: NSRange(location: 0, length: source.length)).filter { $0.range(at: 3).location != NSNotFound }
        guard let current = matches.firstIndex(where: { Int(source.substring(with: $0.range(at: 3))) == hole }) else { return nil }
        func visible(_ i: Int) -> Bool {
            switch type {
            case .enumeration: i < current
            case .deletion: true
            case .single: false
            case .context: abs(i - current) <= clozeContext
            }
        }
        func render(flipped: Bool) -> (String, [Range<Int>]) {
            var out = ""
            var marks: [Range<Int>] = []
            var at = 0
            for (i, match) in matches.enumerated() {
                out += source.substring(with: NSRange(location: at, length: match.range.location - at))
                let text = source.substring(with: match.range(at: 1))
                let shown: String
                if i == current {
                    let hint = match.range(at: 2).location == NSNotFound ? "" : source.substring(with: match.range(at: 2))
                    shown = flipped ? text : "[..." + hint + "]"
                    let start = (out as NSString).length
                    marks.append(start..<(start + (shown as NSString).length))
                } else {
                    shown = visible(i) ? text : "..."
                }
                out += shown
                at = NSMaxRange(match.range)
            }
            out += source.substring(from: at)
            return (out, marks)
        }
        func side(flipped: Bool) -> Face.Side {
            let (text, marks) = render(flipped: flipped)
            let split = text.firstIndex(of: "\n")!
            var body = String(text[text.index(after: split)...])
            if flipped, !card.children.isEmpty { body += (body.isEmpty ? "" : "\n\n") + card.children }
            return Face.Side(title: String(text[..<split]), text: body, marks: marks)
        }
        return Face(front: side(flipped: false), back: side(flipped: true))
    }

    /// `org-fc-deemphasize`: the text of the line's first emphasis, else the line.
    static func deemphasize(_ line: String) -> String {
        guard let match = line.firstMatch(of: /(?:^|[\s\-('"{])([*\/_=~+])(\S|\S.*?\S)\1(?:[\s\-.,:!?;'")}\[\\]|$)/) else { return line }
        return String(match.2)
    }
}
