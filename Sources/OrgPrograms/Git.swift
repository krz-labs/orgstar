#if os(macOS)
import Foundation

/// The system git, run as a process that can't prompt for anything and is stopped after a time
/// limit.
public struct Git: Sendable {
    public let executable: URL

    public struct Output: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public var succeeded: Bool { status == 0 }
        /// The first line of what git said went wrong.
        public var problem: String {
            let lines = (stderr + "\n" + stdout).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.first ?? "git exited with status \(status)"
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public init(executable: URL) {
        self.executable = executable
    }

    /// `ORGSTAR_GIT`, the usual install locations, then the `PATH` Babel uses. `/usr/bin/git` only
    /// when the developer tools are installed: without them it asks to install them.
    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment) -> Git? {
        let path = (BabelRunner.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/git" }
        let candidates = [environment["ORGSTAR_GIT"]].compactMap { $0 } + [
            "/opt/homebrew/bin/git", "/usr/local/bin/git", "/run/current-system/sw/bin/git",
        ] + path
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if candidate == "/usr/bin/git", !developerToolsInstalled { continue }
            return Git(executable: URL(fileURLWithPath: candidate))
        }
        return nil
    }

    static let developerToolsInstalled: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let folder = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: folder + "/usr/bin/git")
    }()

    /// Babel's environment with every way git or ssh could ask for a password or a host key
    /// turned into a failure, English messages, and no optional index locks.
    static var environment: [String: String] {
        var environment = BabelRunner.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_EDITOR"] = "/usr/bin/false"
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        return environment
    }

    /// Runs git with `arguments` in `directory`. Output goes through files, so a child that
    /// keeps a descriptor open can't hold up the result. Throws when the time limit passes.
    public func run(_ arguments: [String], in directory: URL, timeout: Duration = .seconds(30)) async throws -> Output {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outURL = folder.appendingPathComponent("out"), errURL = folder.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer {
            try? out.close()
            try? err.close()
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "core.quotePath=false"] + arguments
        process.currentDirectoryURL = directory
        process.environment = Self.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now > deadline {
                process.terminate()
                throw Failure(description: "git \(arguments.first ?? "") took longer than \(timeout.components.seconds) seconds and was stopped")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self),
            stderr: String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        )
    }

    /// The work tree and git folder holding `directory`, with symbolic links resolved; nil
    /// outside a repository.
    public func repository(containing directory: URL) async -> (top: URL, gitDir: URL)? {
        guard let output = try? await run(["rev-parse", "--show-toplevel", "--absolute-git-dir"], in: directory), output.succeeded else { return nil }
        let lines = output.stdout.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return nil }
        return (URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath(), URL(fileURLWithPath: lines[1]).resolvingSymlinksInPath())
    }

    /// `file` relative to the work tree `top`, after resolving symbolic links.
    public static func relativePath(_ file: URL, in top: URL) -> String? {
        let path = file.resolvingSymlinksInPath().path, base = top.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    /// The operation git is in the middle of in `gitDir`, which a commit or pull would disturb:
    /// `rebase`, `merge`, `cherry-pick`, `revert`, `bisect`, or `index.lock` while another git
    /// command holds the index. Nil when there is none.
    public static func operationInProgress(_ gitDir: URL) -> String? {
        let marks: [(String, String)] = [
            ("rebase-merge", "rebase"), ("rebase-apply", "rebase"), ("MERGE_HEAD", "merge"),
            ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"), ("BISECT_LOG", "bisect"),
            ("index.lock", "index.lock"),
        ]
        return marks.first { FileManager.default.fileExists(atPath: gitDir.appendingPathComponent($0.0).path) }?.1
    }

    /// Whether git's message says the remote refused or couldn't ask for credentials.
    public static func isAuthenticationFailure(_ message: String) -> Bool {
        let signs = [
            "Authentication failed", "could not read Username", "could not read Password", "terminal prompts disabled",
            "Permission denied (publickey", "Host key verification failed", "returned error: 403", "returned error: 401",
        ]
        return signs.contains { message.localizedCaseInsensitiveContains($0) }
    }
}
#endif
