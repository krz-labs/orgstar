import Foundation

/// What the tool takes from outside the files: the environment, the time, the standard streams
/// and `open`. Tests give their own.
struct Host {
    var environment: [String: String]
    var now: Date
    var calendar: Calendar
    var currentDirectory: String
    /// Standard input's text; nil when it is a terminal.
    var input: () -> String?
    var output: (Data) -> Void
    var error: (String) -> Void
    /// Runs `/usr/bin/open` with these arguments and returns its exit status.
    var open: ([String]) -> Int32
    /// The running executable, through any links to it.
    var executable: URL

    static func process() -> Host {
        Host(
            environment: ProcessInfo.processInfo.environment,
            now: Date(),
            calendar: .current,
            currentDirectory: FileManager.default.currentDirectoryPath,
            input: {
                guard isatty(STDIN_FILENO) == 0 else { return nil }
                return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            },
            output: { FileHandle.standardOutput.write($0) },
            error: { FileHandle.standardError.write(Data($0.utf8)) },
            open: { arguments in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = arguments
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus
                } catch {
                    return 1
                }
            },
            executable: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        )
    }

    func print(_ text: String) {
        output(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
    }

    /// The app this executable is inside, as `Contents/Helpers/orgstar`; nil for a build run
    /// from its build folder.
    var app: URL? {
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard executable.deletingLastPathComponent().lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }

    /// `path` from the command line: `~` expanded, and relative to the current folder.
    func absolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        return ((currentDirectory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }
}

enum ExitCode: Int32 {
    case success = 0
    /// A file couldn't be read, written or exported.
    case failure = 1
    /// An unknown command or option, or a missing argument.
    case usage = 2
    /// No such file, heading, view or template, or no running clock.
    case notFound = 3
    /// The command won't do it: questions without answers, a file it can't change.
    case refused = 4
}

struct Failure: Error {
    let code: ExitCode
    let message: String

    init(_ code: ExitCode, _ message: String) {
        self.code = code
        self.message = message
    }
}
