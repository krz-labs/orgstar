import Foundation
import OrgCore

/// The iOS suggestion row: completion candidates in the key bar's place, tapped as the
/// system's QuickType bar is. It shows the candidates the completion list would; the list
/// stays for a hardware keyboard, whose keys move through it.
public enum SuggestionRow {
    /// A candidate as the row shows it: what is inserted, and what the list adds after it
    /// (a snippet's name, a template's block, a heading's file).
    public struct Item: Equatable, Sendable {
        public let candidate: String
        public let detail: String?
        public let snippet: Bool
    }

    /// The most candidates the row holds; it scrolls through them.
    public static let limit = 30

    /// Candidates show in the row rather than the floating list: while the on-screen keyboard
    /// is used, so not with a hardware keyboard.
    public static func usesRow(hardwareKeyboard: Bool) -> Bool {
        !hardwareKeyboard
    }

    /// The row takes the key bar's place: there are candidates, and the row wasn't put away
    /// for this completion.
    public static func shows(_ completion: Completion?, dismissed: Bool) -> Bool {
        guard let completion, !dismissed else { return false }
        return !completion.candidates.isEmpty
    }

    /// The candidates in the list's order, up to `limit`.
    public static func items(_ completion: Completion, limit: Int = limit) -> [Item] {
        completion.candidates.prefix(limit).map { candidate in
            let label = completion.label(candidate)
            let detail = label.hasPrefix(candidate) ? label.dropFirst(candidate.count).trimmingCharacters(in: .whitespaces) : ""
            return Item(candidate: candidate, detail: detail.isEmpty ? nil : detail, snippet: completion.kind == .snippet)
        }
    }
}
