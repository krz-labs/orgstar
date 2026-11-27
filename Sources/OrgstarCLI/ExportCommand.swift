import Foundation
import OrgConfig
import OrgCore

/// `orgstar export` and `orgstar tangle`.
@MainActor
enum ExportCommand {
    static let help = """
    Usage: orgstar export <file> --to <format> [-o <path>]

    Exports the whole file with the settings of config.toml and the file's own, as File ▸ Export
    does. Formats: html, md, latex, txt, odt, reveal, and pdf, which runs the LaTeX export
    through latexmk or pdflatex, as Emacs does (the app's PDF export doesn't need TeX).

    The output goes beside the file, named by #+EXPORT_FILE_NAME or the file's name, unless
    -o names a path; -o - writes it to standard output.

    Options:
      --to <format>       html, md, pdf, latex, odt, txt or reveal
      -o, --output <path> where to write the export
    """

    static let tangleHelp = """
    Usage: orgstar tangle <file>

    Writes the file's code blocks with :tangle to their files, as org-babel-tangle does: a file
    whose contents haven't changed is left alone, :mkdirp makes its folder, :tangle-mode sets
    its mode.
    """

    static let extensions = ["html": "html", "md": "md", "pdf": "pdf", "latex": "tex", "odt": "odt", "txt": "txt", "reveal": "html"]

    static func run(_ words: [String], _ workspace: Workspace) throws(Failure) {
        let arguments = try Arguments(words, command: "export", flags: [], options: ["--to", "--output"], aliases: ["-o": "--output"])
        try arguments.expect(1, 1, "export")
        guard let format = arguments.value("--to") else { throw Failure(.usage, "export: --to is html, md, pdf, latex, odt, txt or reveal") }
        guard let ext = extensions[format] else { throw Failure(.usage, "export: unknown format \(format); use html, md, pdf, latex, odt, txt or reveal") }
        let host = workspace.host
        let path = host.absolute(arguments.positional[0])
        let text = try workspace.text(path)
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let settings = workspace.settings(for: text, path: path)
        let language = OrgPreferences.exportLanguage(workspace.defaults)
        let base = url.deletingPathExtension().lastPathComponent
        let data: Data
        do {
            switch format {
            case "html":
                data = Data(HTMLExport.page(text, fallbackTitle: base, settings: settings, path: path, language: language).utf8)
            case "md":
                data = Data(MarkdownExport.document(text, settings: settings, path: path, bodyOnly: false).utf8)
            case "latex":
                data = Data(try LaTeXExport.document(text, settings: settings, path: path, bodyOnly: false, author: NSFullUserName(), language: language, file: true).utf8)
            case "txt":
                data = Data(try ASCIIExport.document(text, settings: settings, path: path, bodyOnly: false, author: NSFullUserName(), language: language, file: true).utf8)
            case "odt":
                data = try ODTExport.document(text, settings: settings, path: path, author: NSFullUserName(), language: language)
            case "reveal":
                let library = bundledScripts(host).map { $0.url(forResource: "Reveal", withExtension: nil) } ?? nil
                let mathJax = bundledScripts(host).map { $0.url(forResource: "tex-svg-full", withExtension: "js", subdirectory: "MathJax") } ?? nil
                data = Data(RevealExport.document(text, fallbackTitle: base, settings: settings, path: path, language: language, library: library, mathJax: mathJax).utf8)
            default:
                let latex = try LaTeXExport.document(text, settings: settings, path: path, bodyOnly: false, author: NSFullUserName(), language: language, file: true)
                data = try pdf(latex: latex, name: base, directory: url.deletingLastPathComponent(), host)
            }
        } catch let failure as Failure {
            throw failure
        } catch let error as LaTeXExport.Unsupported {
            throw Failure(.failure, "Can't export \(name) to \(format == "txt" ? "plain text" : "LaTeX"): \(error.reason)")
        } catch {
            throw Failure(.failure, "Can't export \(name): \(error.localizedDescription)")
        }
        if arguments.value("--output") == "-" {
            host.output(data)
            return
        }
        let target = arguments.value("--output").map { URL(fileURLWithPath: host.absolute($0)) }
            ?? ExportScope.output(for: url, name: ExportScope.fileName(text, settings: settings), extension: ext)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            throw Failure(.failure, "Can't write \(target.path): \(error.localizedDescription)")
        }
        host.print("Exported to \(target.path)")
    }

    /// The app's bundle of scripts (reveal.js, MathJax): beside this executable in a build
    /// folder, or in the app's resources.
    static func bundledScripts(_ host: Host) -> Bundle? {
        let folder = host.executable.deletingLastPathComponent()
        let candidates = [folder, folder.deletingLastPathComponent().appendingPathComponent("Resources")]
        return candidates.lazy.compactMap { Bundle(url: $0.appendingPathComponent("Orgstar_OrgMathJax.bundle")) }.first
    }

    /// `org-latex-export-to-pdf`: `latex` compiled in a temporary folder, run from `directory`
    /// so that relative image paths resolve, by latexmk or else pdflatex three times.
    static func pdf(latex: String, name: String, directory: URL, _ host: Host) throws -> Data {
        let path = (host.environment["PATH"] ?? "/usr/bin:/bin") + ":/Library/TeX/texbin"
        func find(_ program: String) -> String? {
            path.split(separator: ":").map { "\($0)/\(program)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let tex = work.appendingPathComponent(name + ".tex")
        try latex.write(to: tex, atomically: true, encoding: .utf8)
        let runs: [(String, [String])]
        if let latexmk = find("latexmk") {
            runs = [(latexmk, ["-f", "-pdf", "-interaction=nonstopmode", "-output-directory=\(work.path)", tex.path])]
        } else if let pdflatex = find("pdflatex") {
            runs = Array(repeating: (pdflatex, ["-interaction", "nonstopmode", "-output-directory", work.path, tex.path]), count: 3)
        } else {
            throw Failure(.failure, "PDF export from the command line needs TeX (latexmk or pdflatex), such as MacTeX. Export to PDF in orgstar, which doesn't.")
        }
        for (program, arguments) in runs {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        guard let data = FileManager.default.contents(atPath: work.appendingPathComponent(name + ".pdf").path) else {
            throw Failure(.failure, "TeX made no PDF from \(name).tex; export to LaTeX and run it to see why.")
        }
        return data
    }

    static func tangle(_ words: [String], _ workspace: Workspace) throws(Failure) {
        let arguments = try Arguments(words, command: "tangle", flags: [])
        try arguments.expect(1, 1, "tangle")
        let path = workspace.host.absolute(arguments.positional[0])
        let text = try workspace.text(path)
        let tree = OrgParser.parse(text, defaults: workspace.settings(for: text, path: path))
        switch Tangle.run(text: text, path: path, scope: .all, tree: tree) {
        case .failure(.message(let message)):
            throw Failure(.failure, message)
        case .success(let output):
            do {
                try TangleWriter.write(output, source: path)
            } catch {
                throw Failure(.failure, error.message)
            }
            workspace.host.print(TangleWriter.message(output, source: path))
        }
    }
}
