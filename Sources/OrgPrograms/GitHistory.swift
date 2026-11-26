#if os(macOS)
import Foundation
import OrgApp
import OrgCore

/// A file's commits, read with the system git.
public enum GitHistory {
    /// The commits that changed `file`, newest first, following renames (`git log --follow`);
    /// each with the file's path in that commit. Empty outside a repository or without git.
    public static func commits(for file: URL, git: Git? = Git.find(), limit: Int = 200) async -> [FileHistory.Commit] {
        guard let git, let repository = await git.repository(containing: file.deletingLastPathComponent()),
              let path = Git.relativePath(file, in: repository.top) else { return [] }
        let arguments = ["log", "--follow", "-n", String(limit), "--name-only", "--format=%x1e%H%x1f%at%x1f%an%x1f%s", "--", path]
        guard let output = try? await git.run(arguments, in: repository.top), output.succeeded else { return [] }
        return output.stdout.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first, let name = lines.dropFirst().last else { return nil }
            let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let seconds = TimeInterval(fields[1]) else { return nil }
            return FileHistory.Commit(
                hash: fields[0], date: Date(timeIntervalSince1970: seconds), author: fields[2], subject: fields[3],
                path: String(name), repository: repository.top
            )
        }
    }

    /// The file's text in `commit`.
    public static func text(of commit: FileHistory.Commit, git: Git? = Git.find()) async -> String? {
        guard let git, let output = try? await git.run(["show", "\(commit.hash):\(commit.path)"], in: commit.repository), output.succeeded else { return nil }
        return SourceText(bytes: Array(output.stdout.utf8)).text
    }
}
#endif
