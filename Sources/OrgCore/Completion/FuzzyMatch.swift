import Foundation

/// Subsequence matching for quick open: every query character must appear in order. Matches
/// at word starts and runs of consecutive characters score higher; shorter names win ties.
public enum FuzzyMatch {
    /// What a match at a word start adds, before `score` scales it by 100.
    public static let wordStartBonus = 8

    public static func score(_ query: String, _ candidate: String) -> Int? {
        let query = Array(query.lowercased().filter { !$0.isWhitespace })
        let text = Array(candidate.lowercased())
        guard !query.isEmpty else { return 0 }
        var score = 0
        var q = 0
        var previousMatch = -2
        for (i, c) in text.enumerated() where q < query.count && c == query[q] {
            score += 1
            if i == previousMatch + 1 { score += 5 }
            if i == 0 || "/ -_.".contains(text[i - 1]) { score += wordStartBonus }
            previousMatch = i
            q += 1
        }
        guard q == query.count else { return nil }
        return score * 100 - text.count
    }
}
