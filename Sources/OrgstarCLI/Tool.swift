import Foundation

/// The `orgstar` command: reads the command line, runs a command, and returns the exit status.
@MainActor
enum Tool {
    static let help = """
    Usage: orgstar <command> [<arguments>]

    Works on your org files directly, with orgstar's configuration folder and folders, whether or
    not the app is running.

    Commands:
      agenda [<view>]                 print the agenda or a view of views.toml
      capture <key> [<text>]          file an entry with a capture template
      clock in <file>::<heading>      start the clock on a heading
      clock out                       stop the running clock
      clock status                    show the running clock
      export <file> --to <format>     export to html, md, pdf, latex, odt, txt or reveal
      tangle <file>                   write the file's code blocks to their files
      open <file>[::<heading>]        open a file in orgstar, at a heading

    Options:
      -h, --help                      this help; orgstar <command> --help for a command's
      --version                       the version

    Exit status:
      0  done
      1  failed: a file couldn't be read, written or exported, or changed meanwhile
      2  usage: an unknown command or option, or a missing argument
      3  not found: no such file, heading, view or template; no running clock
      4  refused: a capture question without an answer, or a file that can't be changed here
         (encrypted, not UTF-8, or a command that needs the app)

    Environment:
      ORGSTAR_CONFIG_DIR  the configuration folder, else $XDG_CONFIG_HOME/orgstar or ~/.config/orgstar
      ORGSTAR_DATA_DIR    the data folder (the app's folder list, running clock and recovery
                          versions), else ~/Library/Application Support/Orgstar
      ORGSTAR_ROOT        a folder to read besides those added in the app
    """

    static let openHelp = """
    Usage: orgstar open <file>[::<heading>]
           orgstar open <file>::id:<id> | id:<id>

    Opens the file in orgstar, at the heading when one is named: its title (with or without a
    leading *), #custom-id or id:ID.
    """

    static func run(_ arguments: [String], host: Host) -> Int32 {
        guard let command = arguments.first else {
            host.error(help + "\n")
            return ExitCode.usage.rawValue
        }
        let rest = Array(arguments.dropFirst())
        let helps = ["agenda": AgendaCommand.help, "capture": CaptureCommand.help, "clock": ClockCommand.help, "export": ExportCommand.help,
                     "tangle": ExportCommand.tangleHelp, "open": openHelp]
        switch command {
        case "-h", "--help", "help":
            if let topic = rest.first {
                guard let text = helps[topic] else { return fail(Failure(.usage, "help: no command \(topic)"), host) }
                host.print(text)
            } else {
                host.print(help)
            }
            return ExitCode.success.rawValue
        case "--version":
            host.print("orgstar \(version(host))")
            return ExitCode.success.rawValue
        default:
            break
        }
        guard let text = helps[command] else { return fail(Failure(.usage, "unknown command \(command); see orgstar --help"), host) }
        if rest.contains("--help") || rest.contains("-h") {
            host.print(text)
            return ExitCode.success.rawValue
        }
        let workspace = Workspace(host: host)
        do {
            switch command {
            case "agenda": try AgendaCommand.run(rest, workspace)
            case "capture": try CaptureCommand.run(rest, workspace)
            case "clock": try ClockCommand.run(rest, workspace)
            case "export": try ExportCommand.run(rest, workspace)
            case "tangle": try ExportCommand.tangle(rest, workspace)
            default: try open(rest, workspace)
            }
        } catch {
            return fail(error, host)
        }
        return ExitCode.success.rawValue
    }

    static func fail(_ failure: Failure, _ host: Host) -> Int32 {
        if !failure.message.isEmpty { host.error("orgstar: \(failure.message)\n") }
        return failure.code.rawValue
    }

    /// The app's version, from the Info.plist of the app around this executable.
    static func version(_ host: Host) -> String {
        guard let app = host.app, let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String else { return "(development build)" }
        let build = info["CFBundleVersion"] as? String
        return build.map { $0 == version ? version : "\(version) (\($0))" } ?? version
    }

    /// `open`: the app's own link to the entry, `orgstar://entry`, opened by the app this
    /// executable is in, else by whichever app handles the link.
    static func open(_ words: [String], _ workspace: Workspace) throws(Failure) {
        let arguments = try Arguments(words, command: "open", flags: [])
        try arguments.expect(1, 1, "open")
        let target = try workspace.target(arguments.positional[0])
        var link = URLComponents()
        link.scheme = "orgstar"
        link.host = "entry"
        link.queryItems = [URLQueryItem(name: "path", value: target.path), URLQueryItem(name: "offset", value: String(target.offset ?? 0))]
        guard let url = link.url?.absoluteString else { throw Failure(.failure, "Can't make a link to \(target.path)") }
        let status = workspace.host.open((workspace.host.app.map { ["-a", $0.path] } ?? []) + [url])
        guard status == 0 else { throw Failure(.failure, "open couldn't open \(url)") }
    }
}
