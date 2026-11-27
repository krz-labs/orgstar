import Foundation
import OrgConfig
import OrgCore
import OrgDocument
import OrgIndex
import OrgWorkspace

/// Settings held in memory: config.toml is applied to them as the app applies it to its user
/// defaults, and no defaults domain is written.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    convenience init() {
        self.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

/// The app's configuration and folders as the tool finds them: the configuration folder, the
/// data folder (the folder list, the running clock, recovery versions), the settings of
/// config.toml, and the files of the folders.
@MainActor
final class Workspace {
    let host: Host
    let configDirectory: URL
    let dataDirectory: URL
    let defaults = MemoryDefaults()
    let settings: OrgSettings
    let options: EditingOptions
    /// The folders, by path, sorted as the app sorts them.
    let roots: [String]
    private var scanned: [(path: String, relative: String, kind: FileKind)]?

    init(host: Host) {
        self.host = host
        let environment = host.environment
        configDirectory = UserConfig.defaultDirectory(environment: environment, home: NSHomeDirectory(), sandboxed: false)
        dataDirectory = environment["ORGSTAR_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orgstar")
        var roots: Set<String> = []
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("roots.json")),
           let saved = try? JSONDecoder().decode([WorkspaceRoot].self, from: data) {
            for root in saved {
                if let url = try? root.resolve(sandboxed: false).url { roots.insert(url.standardizedFileURL.path) }
            }
        }
        if let root = environment["ORGSTAR_ROOT"] { roots.insert(host.absolute(root)) }
        self.roots = roots.sorted()
        if let text = try? String(contentsOf: Self.configFile("config.toml", in: configDirectory, environment: environment), encoding: .utf8) {
            for problem in UserConfig.apply(text, to: defaults) { host.error("orgstar: \(problem)\n") }
        }
        settings = OrgPreferences.orgSettings(defaults)
        options = OrgPreferences.options(defaults)
    }

    /// A file of the configuration folder; without a folder from the environment, one that
    /// exists only where earlier versions kept it is read from there, as the app does.
    func configFile(_ name: String) -> URL {
        Self.configFile(name, in: configDirectory, environment: host.environment)
    }

    private static func configFile(_ name: String, in directory: URL, environment: [String: String]) -> URL {
        let url = directory.appendingPathComponent(name)
        guard environment["ORGSTAR_CONFIG_DIR"] == nil, environment["ORGSTAR_DATA_DIR"] == nil else { return url }
        let legacy = UserConfig.legacyDirectory.appendingPathComponent(name)
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path), manager.fileExists(atPath: legacy.path) { return legacy }
        return url
    }

    // MARK: - Files

    /// The folders' files, as the app lists them with Settings ▸ General's hidden-file and
    /// ignored-folder settings.
    var files: [(path: String, relative: String, kind: FileKind)] {
        if let scanned { return scanned }
        let rules = ScanRules(
            hiddenFiles: OrgPreferences.bool("showHiddenFiles", defaults),
            ignoredFolders: Set(OrgPreferences.string("ignoredFolders", defaults).split(separator: " ").map(String.init))
        )
        var found: [(path: String, relative: String, kind: FileKind)] = []
        for root in roots {
            guard let discovery = try? WorkspaceScanner.scan(URL(fileURLWithPath: root), rules: rules) else { continue }
            let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/"
            for file in discovery.files {
                let path = file.url.path
                let resolved = file.url.resolvingSymlinksInPath().path
                let relative = resolved.hasPrefix(base) ? String(resolved.dropFirst(base.count)) : file.url.lastPathComponent
                found.append((path, relative, file.kind))
            }
        }
        scanned = found
        return found
    }

    /// `(org-agenda-files)`: `org-agenda-files` resolved, or when it is empty the org files at
    /// the top of each folder, or below it with `agenda-include-subfolders`.
    var agendaFiles: [String] {
        let list = OrgPreferences.agendaFiles(defaults)
        if !list.isEmpty { return AgendaFiles.resolve(list, base: roots.first) }
        let subfolders = OrgPreferences.agendaSubfolders(defaults)
        return files
            .filter { $0.kind == .org && !($0.path as NSString).lastPathComponent.hasPrefix(".") && (subfolders || !$0.relative.contains("/")) }
            .map(\.path)
            .sorted()
    }

    /// The text of the file at `path`.
    func text(_ path: String) throws(Failure) -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            let name = (path as NSString).lastPathComponent
            if FileManager.default.fileExists(atPath: path) { throw Failure(.failure, "Can't read \(name)") }
            throw Failure(.notFound, "No such file: \(path)")
        }
        return SourceText(bytes: [UInt8](data)).text
    }

    /// The settings for `text`, the file at `path`, with its setup files.
    func settings(for text: String, path: String) -> OrgSettings {
        settings.resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile)
    }

    // MARK: - Changing files

    /// Runs `command` at `offset` in the file at `path` and writes the file as the app saves a
    /// file that isn't open: through a temporary file, merged with a change made meanwhile,
    /// the versions it replaces kept in the recovery folder as the app keeps them. The
    /// command's result and the text after it.
    @discardableResult
    func perform(_ command: any OrgCommand, path: String, at offset: Int) throws(Failure) -> (result: EditResult, text: String) {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !path.hasSuffix(".gpg") else { throw Failure(.refused, "\(name) is encrypted; change it in orgstar.") }
        let fileSystem = CoordinatedFileSystem(writesInPlaceWhenDenied: false)
        let bytes: [UInt8]
        do {
            guard let read = try fileSystem.read(url) else { throw Failure(.notFound, "No such file: \(path)") }
            bytes = read
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(.failure, "Can't read \(name): \(error.localizedDescription)")
        }
        var state = DocumentState(bytes: bytes, defaults: settings(for: SourceText(bytes: bytes).text, path: path))
        guard state.isEditable else { throw Failure(.refused, "\(name) isn't UTF-8, so it can't be changed.") }
        let step: CommandStep
        do {
            step = try state.run(command, selection: [offset..<offset], now: host.now, calendar: host.calendar, options: options)
        } catch {
            throw Failure(.failure, "Can't change \(name): \(error)")
        }
        switch step {
        case .commit(let result):
            if state.isDirty { try save(&state, to: url) }
            return (result, state.text)
        case .failed(let message):
            throw Failure(.failure, message)
        case .prompt(let prompt):
            throw Failure(.refused, "\(name): this needs an answer to \"\(prompt.message)\"; do it in orgstar.")
        case .external:
            throw Failure(.refused, "\(name): this needs a program orgstar runs; do it in orgstar.")
        }
    }

    private func save(_ state: inout DocumentState, to url: URL) throws(Failure) {
        let name = url.lastPathComponent
        let saver = Saver(fileSystem: CoordinatedFileSystem(writesInPlaceWhenDenied: false),
                          recovery: FileRecoveryStore(directory: dataDirectory.appendingPathComponent("Recovery")))
        do {
            switch try saver.save(&state, to: url) {
            case .saved, .mergedAndSaved:
                break
            case .conflict:
                throw Failure(.failure, "\(name) changed on disk; nothing was changed.")
            case .overwroteExternalChange, .changedAfterWrite:
                host.error("orgstar: \(name) changed while it was written; the other version is kept in History.\n")
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(.failure, "Can't write \(name): \(error.localizedDescription)")
        }
    }

    // MARK: - Headings

    /// A heading or a whole file named on the command line.
    struct Target {
        let path: String
        /// The heading's start; nil for the whole file.
        let offset: Int?
        let title: String?
    }

    /// `file`, `file::Heading`, `file::*Heading`, `file::#custom-id`, `file::id:ID` or `id:ID`.
    func target(_ spec: String) throws(Failure) -> Target {
        if spec.hasPrefix("id:"), !spec.contains("::") {
            let id = String(spec.dropFirst(3))
            for path in Array(Set(files.filter { $0.kind == .org }.map(\.path) + agendaFiles)).sorted() {
                guard let text = try? text(path), text.contains(id),
                      let heading = headings(text, path: path).first(where: { $0.id == id }) else { continue }
                return Target(path: path, offset: heading.headingRange.lowerBound, title: heading.title)
            }
            throw Failure(.notFound, "No heading with ID \(id)")
        }
        let parts = spec.components(separatedBy: "::")
        let path = host.absolute(parts[0])
        let text = try text(path)
        guard parts.count > 1 else { return Target(path: path, offset: nil, title: nil) }
        let search = parts.dropFirst().joined(separator: "::")
        let all = headings(text, path: path)
        let found: HeadingInfo?
        if search.hasPrefix("id:") {
            found = all.first { $0.id == String(search.dropFirst(3)) }
        } else if search.hasPrefix("#") {
            let custom = String(search.dropFirst())
            found = all.first { $0.properties.contains { $0.key.uppercased() == "CUSTOM_ID" && $0.value == custom } }
        } else {
            let title = search.hasPrefix("*") ? String(search.dropFirst()) : search
            found = all.first { $0.title == title } ?? all.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
        }
        guard let found else { throw Failure(.notFound, "No heading \(search) in \((path as NSString).lastPathComponent)") }
        return Target(path: path, offset: found.headingRange.lowerBound, title: found.title)
    }

    func headings(_ text: String, path: String) -> [HeadingInfo] {
        DocumentModel(tree: OrgParser.parse(text, defaults: settings(for: text, path: path))).headings
    }

    /// The 1-based line of `offset`, a UTF-16 offset in `text`.
    static func line(of offset: Int, in text: String) -> Int {
        let ns = text as NSString
        var line = 1
        var index = 0
        let end = min(offset, ns.length)
        while index < end {
            let found = ns.range(of: "\n", options: [], range: NSRange(location: index, length: end - index))
            guard found.location != NSNotFound else { break }
            line += 1
            index = found.location + 1
        }
        return line
    }
}
