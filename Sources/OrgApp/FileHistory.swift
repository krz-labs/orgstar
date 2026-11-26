import Foundation

/// The versions of a file the History view lists: those kept in the recovery folder and, in the
/// download version where the folder is a git repository, the commits that changed it.
public enum FileHistory {
    /// A commit that changed the file, with the file's path in it relative to `repository`.
    public struct Commit: Hashable, Sendable {
        public let hash: String
        public let date: Date
        public let author: String
        public let subject: String
        public let path: String
        public let repository: URL

        public init(hash: String, date: Date, author: String, subject: String, path: String, repository: URL) {
            self.hash = hash
            self.date = date
            self.author = author
            self.subject = subject
            self.path = path
            self.repository = repository
        }
    }

    public enum Entry: Hashable, Sendable {
        case recovery(url: URL, date: Date, label: String)
        case commit(Commit)

        public var date: Date {
            switch self {
            case .recovery(_, let date, _): date
            case .commit(let commit): commit.date
            }
        }
    }

    /// Recovery versions and commits together, newest first.
    public static func merged(recovery: [(url: URL, date: Date, label: String)], commits: [Commit]) -> [Entry] {
        (recovery.map { Entry.recovery(url: $0.url, date: $0.date, label: $0.label) } + commits.map(Entry.commit))
            .sorted { $0.date > $1.date }
    }
}
