import Foundation

/// How the completion list behaves, from `config.toml`, with the preset's choices resolved.
public struct CompletionOptions: Sendable, Equatable, Codable {
    /// The list opens by itself after typing (`corfu-auto`).
    public var auto = false
    /// The pause after typing before it opens, in seconds (`corfu-auto-delay`).
    public var delay = 0.4
    /// Characters typed before it opens (`corfu-auto-prefix`).
    public var prefix = 2
    /// Candidates match when the typed characters appear in order, best first, as the
    /// palette matches; otherwise they start with what's typed.
    public var fuzzy = false
    /// Words from the buffers and the index fill the list that opens by itself where Org
    /// offers nothing.
    public var words = false

    public init(auto: Bool = false, delay: Double = 0.4, prefix: Int = 2, fuzzy: Bool = false, words: Bool = false) {
        self.auto = auto
        self.delay = delay
        self.prefix = prefix
        self.fuzzy = fuzzy
        self.words = words
    }
}

/// When the list opens by itself.
public enum CompletionAuto {
    /// The pause after a change before the list opens, or nil when it doesn't: the setting is
    /// off, Vim keys are outside insert state, or the file isn't org and words aren't offered.
    public static func delay(_ options: CompletionOptions, modal: Bool, insertState: Bool, isOrg: Bool) -> Double? {
        guard options.auto, !modal || insertState, isOrg || options.words else { return nil }
        return max(0, options.delay)
    }

    /// Whether `completion`, found after the pause, opens the list: enough typed, and
    /// something to show now or from the index.
    public static func opens(_ completion: Completion?, _ options: CompletionOptions) -> Bool {
        guard let completion, completion.range.count >= max(1, options.prefix) else { return false }
        return !completion.candidates.isEmpty || completion.query != nil
    }
}

/// The open list, as corfu keeps it: the completion shown and the chosen row, nil while the
/// typed text stands (`corfu-preselect` prompt).
public struct CompletionList: Sendable, Equatable {
    public private(set) var completion: Completion
    public private(set) var selection: Int?

    public init(_ completion: Completion, selection: Int? = nil) {
        self.completion = completion
        self.selection = selection.flatMap { completion.candidates.indices.contains($0) ? $0 : nil }
    }

    /// New candidates; the chosen one stays chosen if it is still there.
    public mutating func update(_ completion: Completion) {
        if completion.candidates != self.completion.candidates { selection = selected.flatMap { completion.candidates.firstIndex(of: $0) } }
        self.completion = completion
    }

    /// corfu-cycle: past either end the choice wraps through the typed text.
    public mutating func move(_ delta: Int) {
        let count = completion.candidates.count
        guard count > 0 else { return }
        if let s = selection {
            let next = s + delta
            selection = next < 0 || next >= count ? nil : next
        } else {
            selection = delta > 0 ? 0 : count - 1
        }
    }

    public var selected: String? { selection.map { completion.candidates[$0] } }

    /// The rows shown when at most `rows` fit: those around the choice.
    public func visible(rows: Int) -> Range<Int> {
        let count = completion.candidates.count
        let first = max(0, min((selection ?? 0) - rows + 1, count - rows))
        return first..<min(count, first + rows)
    }

    public enum Action: Equatable {
        /// The choice moved, or the key did nothing more; show the list again.
        case shown
        /// Insert this candidate and close the list.
        case insert(String)
        /// Insert the part the candidates share, keeping the list open.
        case common(String)
        /// Close the list.
        case close
        /// Close the list and let the key do what it otherwise does.
        case closeAndPass
        /// Not the list's key.
        case pass
    }

    /// What a key does while the list is open.
    public mutating func key(_ chord: KeyChord) -> Action {
        switch chord {
        case KeyChord("n", .control), KeyChord("<down>"), KeyChord("j", .control):
            move(1)
            return .shown
        case KeyChord("p", .control), KeyChord("<up>"), KeyChord("k", .control):
            move(-1)
            return .shown
        case KeyChord("TAB"):
            // corfu-complete: the choice, else the candidates' common start.
            let candidates = completion.candidates
            if let selected { return .insert(selected) }
            if candidates.count == 1 { return .insert(candidates[0]) }
            guard let first = candidates.first, ![.template, .snippet, .idLink, .denoteLink].contains(completion.kind) else { return .shown }
            let common = candidates.dropFirst().reduce(first) { $0.commonPrefix(with: $1) }
            if common.utf16.count > completion.range.count, common.lowercased().hasPrefix(completion.typed.lowercased()) { return .common(common) }
            return .shown
        case KeyChord("RET"):
            return selected.map { .insert($0) } ?? .closeAndPass
        case KeyChord("ESC"):
            return .closeAndPass
        case KeyChord("g", .control):
            return .close
        default:
            return .pass
        }
    }
}

/// The steps both editors take with a list: finding the completion at the caret again as
/// typing goes on, and inserting a link.
public enum CompletionFlow {
    /// The index's answer for the completion of `kind` starting at `start`.
    public typealias Fetched = (kind: Completion.Kind, start: Int, result: CompletionResult)

    /// The completion at the caret for a list showing `open`, or for a new list of words
    /// (`words`) or of what Org offers. Words narrow what was found when the list opened;
    /// the rest are found again, with the index's answer added when it was for this place.
    public static func current(_ context: EditContext, open: Completion?, words: Bool, others: () -> [String], fetched: Fetched?) -> Completion? {
        if let open, open.kind == .word {
            guard let range = Dabbrev.abbreviation(in: context.text, caret: context.caret), range.lowerBound == open.range.lowerBound else { return nil }
            return Dabbrev.narrowed(open, to: range, in: context.text)
        }
        guard let found = words ? Dabbrev.completion(context, others: others()) : OrgCompletion.at(context) else { return nil }
        if let fetched, fetched.kind == found.kind, fetched.start == found.range.lowerBound, found.query != nil {
            return OrgCompletion.filled(found, with: fetched.result, fuzzy: context.options.completion.fuzzy)
        }
        return found
    }

    /// `org-id-get-create` on `item`'s heading in this buffer: the edits giving it `newID`.
    public static func createID(_ item: CompletionItem, in context: EditContext, newID: String) -> [TextEdit]? {
        let at = EditContext(revision: context.revision, text: context.text, tree: context.tree, selection: [item.start..<item.start], options: context.options)
        guard case .commit(let result) = CreateID(newID: { newID }).run(in: at) else { return nil }
        return result.edits
    }

    /// The edit putting the link to `item`, with `id`, in place of the link typed, after
    /// `earlier` edits (an ID given in this buffer) moved the text.
    public static func linkEdit(_ completion: Completion, _ item: CompletionItem, id: String, after earlier: [TextEdit] = []) -> TextEdit {
        let range = completion.link ?? completion.range
        let shift = earlier.filter { $0.range.upperBound <= range.lowerBound }.reduce(0) { $0 + $1.replacement.utf16.count - $1.range.count }
        return TextEdit(range: (range.lowerBound + shift)..<(range.upperBound + shift), replacement: completion.link(item, id: id))
    }
}
