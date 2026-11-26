import Foundation
import OrgCore

/// File ▸ Import ▸ Markdown Files… and Obsidian Vault…: converts Markdown files to new org
/// files in one of the person's folders, leaving the sources alone.
///
/// A chosen file becomes `name.org` in the destination; a chosen folder or vault becomes a new
/// folder of the same name holding its notes at the same relative paths. Names already taken
/// get ` 2`, ` 3`… Files a note links to or embeds are copied: a folder's into the new folder
/// at the same relative path, a loose file's into `attachments` in the destination. Links
/// between notes become `file:` links to the converted files.
public enum MarkdownImport {
    public enum Kind: Sendable {
        case markdown, obsidian
    }

    public struct Problem: Sendable, Hashable {
        public enum Reason: Sendable, Hashable {
            case converted(MarkdownImportIssue)
            /// Not UTF-8 or unreadable.
            case unreadable
            /// An Obsidian canvas or base, which has no org equivalent.
            case notConverted
        }

        /// The source file, relative to what was chosen.
        public let file: String
        public let reason: Reason
    }

    /// What an import will write, for the preview, and the text to write.
    public struct Plan: Sendable {
        public let kind: Kind
        public let destination: URL
        public fileprivate(set) var notes = 0
        public fileprivate(set) var headings = 0
        public fileprivate(set) var links = 0
        public fileprivate(set) var attachments = 0
        public fileprivate(set) var problems: [Problem] = []
        /// Names chosen instead of the source's because the destination has that name.
        public fileprivate(set) var renamed: [(from: String, to: String)] = []

        struct Top {
            var name: String
            let natural: String
            let folder: Bool
            /// `attachments`, which may already exist and is shared by loose files.
            let shared: Bool
        }

        enum Content {
            case text(String)
            case copy(URL)
        }

        struct Output {
            let top: Int
            /// The path inside the top folder; empty for a loose file.
            var inner: String
            let content: Content
        }

        fileprivate var tops: [Top] = []
        fileprivate var outputs: [Output] = []
    }

    // MARK: - Planning

    /// A note or attachment in the sources, by where it ends up.
    fileprivate struct SourceFile {
        let url: URL
        /// The chosen item's index.
        let top: Int
        /// Path below the chosen folder; the file name for a loose file.
        let relative: String
        let note: Bool
    }

    static let noteExtensions: Set<String> = ["md", "markdown"]

    /// Reads `sources` (files, folders or a vault) and converts every note, choosing names
    /// that are free in `destination`. Reads files, so call it off the main actor.
    public static func plan(_ kind: Kind, sources: [URL], into destination: URL) throws -> Plan {
        var plan = Plan(kind: kind, destination: destination)
        let manager = FileManager.default
        var takenTop = Set<String>()
        var files: [SourceFile] = []
        for source in sources {
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: source.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                let natural = source.lastPathComponent
                let name = freeName(natural, in: destination, taken: takenTop)
                takenTop.insert(name.lowercased())
                if name != natural { plan.renamed.append((natural, name)) }
                plan.tops.append(Plan.Top(name: name, natural: natural, folder: true, shared: false))
                let top = plan.tops.count - 1
                for relative in folderFiles(source) {
                    let url = source.appendingPathComponent(relative)
                    let ext = url.pathExtension.lowercased()
                    if ext == "canvas" || ext == "base" {
                        plan.problems.append(Problem(file: natural + "/" + relative, reason: .notConverted))
                    }
                    files.append(SourceFile(url: url, top: top, relative: relative, note: noteExtensions.contains(ext)))
                }
            } else if noteExtensions.contains(source.pathExtension.lowercased()) {
                let natural = source.deletingPathExtension().lastPathComponent + ".org"
                let name = freeName(natural, in: destination, taken: takenTop)
                takenTop.insert(name.lowercased())
                if name != natural { plan.renamed.append((source.lastPathComponent, name)) }
                plan.tops.append(Plan.Top(name: name, natural: natural, folder: false, shared: false))
                files.append(SourceFile(url: source, top: plan.tops.count - 1, relative: source.lastPathComponent, note: true))
            }
        }

        // Where each note goes, relative to the destination.
        var outputPath: [URL: String] = [:]
        var takenInner: [Int: Set<String>] = [:]
        for file in files where file.note {
            let top = plan.tops[file.top]
            if top.folder {
                let natural = (file.relative as NSString).deletingPathExtension + ".org"
                var inner = natural
                var n = 2
                while takenInner[file.top, default: []].contains(inner.lowercased()) {
                    inner = (natural as NSString).deletingPathExtension + " \(n).org"
                    n += 1
                }
                takenInner[file.top, default: []].insert(inner.lowercased())
                outputPath[file.url.standardizedFileURL] = top.name + "/" + inner
            } else {
                outputPath[file.url.standardizedFileURL] = top.name
            }
        }

        let collector = Collector()
        let index = VaultIndex(files: files.filter { plan.tops[$0.top].folder })
        plan.tops.append(Plan.Top(name: "attachments", natural: "attachments", folder: true, shared: true))
        let attachmentsTop = plan.tops.count - 1

        // Parse every note first, so links can name headings in other notes.
        var parsed: [URL: MarkdownToOrg.Parsed] = [:]
        var texts: [(file: SourceFile, parsed: MarkdownToOrg.Parsed)] = []
        for file in files where file.note {
            let label = display(file, plan)
            guard let data = try? Data(contentsOf: file.url), let text = String(data: data, encoding: .utf8) else {
                plan.problems.append(Problem(file: label, reason: .unreadable))
                continue
            }
            let result = MarkdownToOrg.parse(text, obsidian: kind == .obsidian)
            parsed[file.url.standardizedFileURL] = result
            texts.append((file, result))
        }

        for (file, note) in texts {
            let url = file.url.standardizedFileURL
            guard let own = outputPath[url] else { continue }
            let ownFolder = (own as NSString).deletingLastPathComponent
            let label = display(file, plan)
            let folderTop = plan.tops[file.top].folder ? file.top : nil
            let context = LinkContext(note: url, own: own, ownFolder: ownFolder, folderTop: folderTop, topName: plan.tops[file.top].name,
                                      attachmentsTop: plan.tops[attachmentsTop].name, destination: destination,
                                      outputPath: outputPath, parsed: parsed, index: index, collector: collector, obsidian: kind == .obsidian)
            let targets = MarkdownTargets(link: { destination, image in context.link(destination, image: image) },
                                          wikilink: { target, fragment, embed in context.wikilink(target, fragment: fragment, embed: embed) })
            let title = kind == .obsidian ? url.deletingPathExtension().lastPathComponent : nil
            let result = MarkdownToOrg.render(note, title: title, targets: targets)
            plan.notes += 1
            plan.headings += result.headings
            plan.links += result.links
            plan.problems += (result.issues + collector.take()).map { Problem(file: label, reason: .converted($0)) }
            let inner = plan.tops[file.top].folder ? String(own.dropFirst(plan.tops[file.top].name.count + 1)) : ""
            plan.outputs.append(Plan.Output(top: file.top, inner: inner, content: .text(result.text)))
        }

        // Attachments: a folder's at the same path inside the new folder, a loose note's in
        // `attachments` under a free name.
        var takenAttachments = Set<String>()
        for (source, place) in collector.attachments.sorted(by: { $0.key.path < $1.key.path }) {
            switch place {
            case .inFolder(let top, let relative):
                plan.outputs.append(Plan.Output(top: top, inner: relative, content: .copy(source)))
            case .loose(let name):
                takenAttachments.insert(name.lowercased())
                if name != source.lastPathComponent { plan.renamed.append((source.lastPathComponent, "attachments/" + name)) }
                plan.outputs.append(Plan.Output(top: attachmentsTop, inner: name, content: .copy(source)))
            }
            plan.attachments += 1
        }
        if takenAttachments.isEmpty { plan.tops[attachmentsTop].name = "" }
        plan.problems = plan.problems.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        return plan
    }

    private static func display(_ file: SourceFile, _ plan: Plan) -> String {
        plan.tops[file.top].folder ? plan.tops[file.top].natural + "/" + file.relative : file.relative
    }

    /// Files below `folder`, relative to it, leaving out hidden files and folders
    /// (`.obsidian`, `.trash`, `.git`).
    static func folderFiles(_ folder: URL) -> [String] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var out: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            out.append(String(path.dropFirst(base.count + 1)))
        }
        return out.sorted()
    }

    /// `natural`, or `name 2.ext`, `name 3.ext`… when that name is in `folder` or `taken`
    /// (lowercased).
    static func freeName(_ natural: String, in folder: URL, taken: Set<String>) -> String {
        let ext = (natural as NSString).pathExtension
        let stem = (natural as NSString).deletingPathExtension
        var name = natural
        var n = 2
        while taken.contains(name.lowercased()) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = stem + " \(n)" + (ext.isEmpty ? "" : "." + ext)
            n += 1
        }
        return name
    }

    /// `path` relative to the folder `from`, both relative to the same folder.
    static func relative(_ path: String, from folder: String) -> String {
        let target = path.split(separator: "/").map(String.init)
        let base = folder.split(separator: "/").map(String.init)
        var common = 0
        while common < min(target.count - 1, base.count), target[common] == base[common] { common += 1 }
        return (Array(repeating: "..", count: base.count - common) + target[common...]).joined(separator: "/")
    }

    // MARK: - Links

    enum Placement: Sendable {
        case inFolder(top: Int, relative: String)
        case loose(name: String)
    }

    /// Attachments links ask for, gathered while notes render.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var attachments: [URL: Placement] = [:]
        private var looseNames = Set<String>()
        private var issues: [MarkdownImportIssue] = []

        func add(_ issue: MarkdownImportIssue) {
            lock.withLock { issues.append(issue) }
        }

        func take() -> [MarkdownImportIssue] {
            lock.withLock {
                defer { issues = [] }
                return issues
            }
        }

        /// Where `source` is copied, choosing a free name in `attachments` for a loose note's.
        func place(_ source: URL, inFolder: (top: Int, relative: String)?, attachments folder: URL?) -> Placement {
            lock.withLock {
                if let placed = attachments[source] { return placed }
                let placement: Placement
                if let inFolder {
                    placement = .inFolder(top: inFolder.top, relative: inFolder.relative)
                } else {
                    let name = MarkdownImport.freeName(source.lastPathComponent, in: folder ?? source, taken: looseNames)
                    looseNames.insert(name.lowercased())
                    placement = .loose(name: name)
                }
                attachments[source] = placement
                return placement
            }
        }
    }

    /// A folder's files by name, for wikilinks, which name a note or file anywhere in the vault.
    struct VaultIndex: Sendable {
        /// Lowercased names (notes without their extension) to the files with them.
        let byName: [String: [(url: URL, top: Int, relative: String)]]
        let byPath: [String: (url: URL, top: Int, relative: String)]
        let byURL: [URL: (top: Int, relative: String)]

        fileprivate init(files: [SourceFile]) {
            var byName: [String: [(url: URL, top: Int, relative: String)]] = [:]
            var byPath: [String: (url: URL, top: Int, relative: String)] = [:]
            var byURL: [URL: (top: Int, relative: String)] = [:]
            for file in files {
                let entry = (file.url.standardizedFileURL, file.top, file.relative)
                byURL[file.url.standardizedFileURL] = (file.top, file.relative)
                let key = (file.note ? (file.relative as NSString).deletingPathExtension : file.relative).lowercased()
                byPath["\(file.top)/" + key] = entry
                byName[(key as NSString).lastPathComponent, default: []].append(entry)
            }
            for key in byName.keys { byName[key]?.sort { $0.relative.count < $1.relative.count } }
            self.byName = byName
            self.byPath = byPath
            self.byURL = byURL
        }
    }

    /// Resolves one note's links.
    struct LinkContext: Sendable {
        let note: URL
        /// The note's output path, relative to the destination.
        let own: String
        let ownFolder: String
        /// The note's chosen folder, when it's in one.
        let folderTop: Int?
        let topName: String
        let attachmentsTop: String
        let destination: URL
        let outputPath: [URL: String]
        let parsed: [URL: MarkdownToOrg.Parsed]
        let index: VaultIndex
        let collector: Collector
        let obsidian: Bool

        /// The org path for a note at `target` with `fragment`, relative to this note.
        func notePath(_ target: URL, fragment: String?, original: String) -> String? {
            guard let output = outputPath[target] else { return nil }
            let same = target == note
            var search = ""
            if let fragment, !fragment.isEmpty {
                let part = fragment.split(separator: "#").last.map(String.init) ?? fragment
                if part.hasPrefix("^") {
                    if parsed[target]?.blockIDs.contains(String(part.dropFirst())) == true {
                        search = String(part.dropFirst())
                    } else {
                        collector.add(.missingHeading(original))
                    }
                } else if let title = MarkdownToOrg.heading(part, in: parsed[target]?.headings ?? []) {
                    search = "*" + title
                } else {
                    collector.add(.missingHeading(original))
                }
            }
            if same, !search.isEmpty { return search }
            let path = "file:" + MarkdownImport.relative(output, from: ownFolder)
            return search.isEmpty ? path : path + "::" + search
        }

        /// The org path for a file copied as an attachment.
        func attachmentPath(_ url: URL) -> String {
            let inFolder: (top: Int, relative: String)?
            if let folderTop, let found = index.byURL[url], found.top == folderTop {
                inFolder = (folderTop, found.relative)
            } else {
                inFolder = nil
            }
            let placement = collector.place(url, inFolder: inFolder, attachments: destination.appendingPathComponent(attachmentsTop))
            switch placement {
            case .inFolder(_, let relative): return "file:" + MarkdownImport.relative(topName + "/" + relative, from: ownFolder)
            case .loose(let name): return "file:" + MarkdownImport.relative(attachmentsTop + "/" + name, from: ownFolder)
            }
        }

        func link(_ destination: String, image: Bool) -> String? {
            if destination.hasPrefix("#") {
                return notePath(note, fragment: String(destination.dropFirst()), original: destination) ?? destination
            }
            if let colon = destination.firstIndex(of: ":"), destination[..<colon].count >= 2,
               destination[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) { return nil }
            var path = destination
            var fragment: String?
            if let hash = path.firstIndex(of: "#") {
                fragment = String(path[path.index(after: hash)...])
                path = String(path[..<hash])
            }
            path = path.removingPercentEncoding ?? path
            let folder = note.deletingLastPathComponent()
            var candidates = [path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)]
            if obsidian, let folderTop {
                if let entry = index.byPath["\(folderTop)/" + ((path as NSString).pathExtension.lowercased() == "md" ? (path as NSString).deletingPathExtension : path).lowercased()] {
                    candidates.append(entry.url)
                }
                if let entry = index.byName[((path as NSString).pathExtension.lowercased() == "md" ? (path as NSString).deletingPathExtension : path).lowercased()]?.first {
                    candidates.append(entry.url)
                }
            }
            for candidate in candidates.map(\.standardizedFileURL) {
                if outputPath[candidate] != nil { return notePath(candidate, fragment: fragment, original: destination) }
                var isFolder: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isFolder), !isFolder.boolValue {
                    if MarkdownImport.noteExtensions.contains(candidate.pathExtension.lowercased()) { break }
                    return attachmentPath(candidate)
                }
            }
            collector.add(.unresolvedLink(destination))
            return nil
        }

        func wikilink(_ target: String, fragment: String?, embed: Bool) -> (path: String, image: Bool)? {
            let original = target + (fragment.map { "#" + $0 } ?? "")
            if target.isEmpty {
                guard let path = notePath(note, fragment: fragment, original: original) else { return nil }
                return (path, false)
            }
            var key = target.lowercased()
            if (key as NSString).pathExtension == "md" { key = (key as NSString).deletingPathExtension }
            let entry: (url: URL, top: Int, relative: String)?
            if key.contains("/") {
                entry = folderTop.flatMap { index.byPath["\($0)/" + key] } ?? index.byName[(key as NSString).lastPathComponent]?.first { $0.relative.lowercased().hasSuffix(key) }
            } else {
                entry = index.byName[key]?.first
            }
            guard let entry else {
                // Obsidian links to notes that don't exist yet; the link goes where one would be.
                collector.add(.unresolvedLink(original))
                let ext = (key as NSString).pathExtension
                guard ext.isEmpty else { return nil }
                return ("file:" + MarkdownImport.relative((folderTop == nil ? "" : topName + "/") + target + ".org", from: ownFolder), false)
            }
            if outputPath[entry.url] != nil {
                guard let path = notePath(entry.url, fragment: fragment, original: original) else { return nil }
                return (path, false)
            }
            return (attachmentPath(entry.url), MarkdownToOrg.imageExtensions.contains(entry.url.pathExtension.lowercased()))
        }
    }

    // MARK: - Writing

    public struct Written: Sendable {
        /// Every file written, notes and attachments.
        public var paths: [String] = []
        /// Names taken since the preview, and what was used instead.
        public var renamed: [(from: String, to: String)] = []
    }

    /// Writes `plan`'s files. Nothing existing is replaced: a name taken since the plan was
    /// made gets another free name. Each file appears whole or not at all.
    public static func write(_ plan: Plan) throws -> Written {
        let manager = FileManager.default
        var written = Written()
        var tops = plan.tops
        for (k, top) in tops.enumerated() where top.folder && !top.name.isEmpty {
            if top.shared {
                try manager.createDirectory(at: plan.destination.appendingPathComponent(top.name), withIntermediateDirectories: true)
                continue
            }
            var name = top.name
            while true {
                do {
                    try manager.createDirectory(at: plan.destination.appendingPathComponent(name), withIntermediateDirectories: false)
                    break
                } catch CocoaError.fileWriteFileExists {
                    name = freeName(top.natural, in: plan.destination, taken: Set(tops.map { $0.name.lowercased() }))
                }
            }
            if name != top.name { written.renamed.append((top.name, name)) }
            tops[k].name = name
        }
        for output in plan.outputs {
            let top = tops[output.top]
            guard !top.name.isEmpty else { continue }
            var url = top.folder ? plan.destination.appendingPathComponent(top.name).appendingPathComponent(output.inner) : plan.destination.appendingPathComponent(top.name)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            switch output.content {
            case .text(let text): try Data(text.utf8).write(to: temporary, options: .withoutOverwriting)
            case .copy(let source): try manager.copyItem(at: source, to: temporary)
            }
            while renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) != 0 {
                guard errno == EEXIST else {
                    let code = errno
                    try? manager.removeItem(at: temporary)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
                }
                let taken = url.lastPathComponent
                url = url.deletingLastPathComponent().appendingPathComponent(freeName(taken, in: url.deletingLastPathComponent(), taken: []))
                written.renamed.append((taken, url.lastPathComponent))
            }
            written.paths.append(url.path)
        }
        return written
    }
}
