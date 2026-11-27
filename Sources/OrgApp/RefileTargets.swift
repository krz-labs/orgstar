import Foundation
import OrgCore
import OrgDocument
import OrgIndex
import OrgPresentation

extension RefileSettings {
    /// For an answer that isn't a target, `parent/child` with `parent` one: the target and the
    /// new heading's title, as `org-refile-get-location` splits it.
    public static func newNode(_ answer: String, in targets: [RefileTarget]) -> (parent: RefileTarget, child: String)? {
        guard let m = answer.firstMatch(of: /^(.*)\/([^\/]+)$/) else { return nil }
        let parent = String(m.1).replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        let child = String(m.2).trimmingCharacters(in: .whitespaces)
        guard !child.isEmpty, let target = targets.first(where: { $0.label == parent }) else { return nil }
        return (target, child)
    }
}

extension WorkspaceModel {
    /// The refile targets, as `org-refile-get-targets` lists them for `settings`: entry by
    /// entry, file by file, in buffer order, with a file's own target first when the outline
    /// path starts with the file. `openPath` is the file refiled from, read from `document`.
    public func refileTargets(openPath: String?, document: DocumentState?, settings: RefileSettings = OrgPreferences.refileSettings()) -> [RefileTarget] {
        var targets: [RefileTarget] = []
        var seen: Set<String> = []
        func add(_ target: RefileTarget) {
            if seen.insert("\(target.path)\u{0}\(target.start ?? -1)\u{0}\(target.label)").inserted { targets.append(target) }
        }
        let orgFiles = files.filter { $0.kind == .org }
        let relative = Dictionary(orgFiles.map { ($0.path, $0.relativePath) }, uniquingKeysWith: { a, _ in a })
        // Closed files' headings, from the index, for the targets that go by level.
        let levels = settings.targets.compactMap { target -> Int? in
            switch target.spec {
            case .all: Int.max
            case .level(let n), .maxLevel(let n): n
            default: nil
            }
        }
        let indexed = levels.isEmpty ? [] : (try? index.outline(maxLevel: min(levels.max()!, 1000))) ?? []
        let indexedByPath = Dictionary(grouping: indexed, by: \.location.path)
        for entry in settings.targets {
            let paths: [String]
            switch entry.files {
            case .current: paths = openPath.map { [$0] } ?? []
            case .workspace: paths = orgFiles.map(\.path)
            case .agendaFiles:
                let list = OrgPreferences.agendaFiles()
                if list.isEmpty {
                    let subfolders = OrgPreferences.agendaSubfolders()
                    paths = orgFiles.filter { !$0.name.hasPrefix(".") && (subfolders || !$0.relativePath.contains("/")) }.map(\.path).sorted()
                } else {
                    paths = AgendaFiles.resolve(list, base: rootPaths.first)
                }
            case .paths(let list):
                let base = openPath.map { ($0 as NSString).deletingLastPathComponent } ?? rootPaths.first
                paths = list.map { entry in
                    let path = OrgPaths.expandingTilde(entry)
                    return ((path.hasPrefix("/") || base == nil ? path : (base! as NSString).appendingPathComponent(path)) as NSString).standardizingPath
                }
            }
            for path in paths {
                let name = relative[path] ?? (path as NSString).lastPathComponent
                // The headings: from the buffer, the index, or the file's text.
                var text: String?
                var hash: String
                var headings: [(start: Int, level: Int, path: [String])] = []
                if path == openPath, let document {
                    text = document.text
                    hash = FileRecord.hash(document.mergeBase)
                } else if let level = Self.level(entry.spec), let records = indexedByPath[path] {
                    hash = records.first?.location.contentHash ?? ""
                    headings = records.filter { level($0.level) }.map { ($0.location.start, $0.level, $0.outlinePath) }
                } else {
                    guard let data = FileManager.default.contents(atPath: path) else { continue }
                    let state = DocumentState(bytes: [UInt8](data))
                    text = state.text
                    hash = FileRecord.hash(state.mergeBase)
                }
                if let text {
                    headings = Self.headings(text, spec: entry.spec)
                }
                let base: String? = switch settings.outlinePath {
                case .file, .bufferName: name
                case .fullFilePath: path
                case .title: text.flatMap { Self.fileTitle($0) } ?? Self.diskTitle(path) ?? name
                case .none, .full: nil
                }
                // Targets in other files name the file after them, but not with paths that start with it.
                let elsewhere = path != openPath && [.none, .full, .bufferName].contains(settings.outlinePath)
                let suffix = elsewhere ? " (\((path as NSString).lastPathComponent))" : ""
                if let base, settings.outlinePath != .none, settings.outlinePath != .full {
                    add(RefileTarget(label: base + suffix, path: path, start: nil, title: "", level: 0, contentHash: hash))
                }
                for heading in headings {
                    let escaped = heading.path.map { $0.replacingOccurrences(of: "/", with: "\\/") }
                    var label = settings.outlinePath == .none ? heading.path.last ?? "" : ((base.map { [$0] } ?? []) + escaped).joined(separator: "/")
                    label += suffix
                    add(RefileTarget(label: label, path: path, start: heading.start, title: heading.path.last ?? "", level: heading.level, contentHash: hash))
                }
            }
        }
        return targets
    }

    /// The test a level-based spec makes of a heading's level; nil for the others.
    static func level(_ spec: RefileSettings.Spec) -> ((Int) -> Bool)? {
        switch spec {
        case .all: { _ in true }
        case .level(let n): { $0 == n }
        case .maxLevel(let n): { $0 <= n }
        default: nil
        }
    }

    /// The headings `spec` finds in `text`, as `org-refile-get-targets` searches: each match
    /// of its regexp (case-sensitive) on a heading line gives that heading.
    static func headings(_ text: String, spec: RefileSettings.Spec) -> [(start: Int, level: Int, path: [String])] {
        let outline = Presentation.outline(OrgParser.parse(text))
        var paths: [[String]] = []
        for entry in outline { paths.append((entry.parent.map { paths[$0] } ?? []) + [entry.title]) }
        let byStart = Dictionary(outline.indices.map { (outline[$0].start, $0) }, uniquingKeysWith: { a, _ in a })
        guard let regex = try? NSRegularExpression(pattern: EmacsRegex.translate(RefileSettings.regexp(spec)), options: .anchorsMatchLines) else { return [] }
        let ns = text as NSString
        var found: [(Int, Int, [String])] = []
        var at = 0
        while at <= ns.length, let m = regex.firstMatch(in: text, options: [.withoutAnchoringBounds, .withTransparentBounds], range: NSRange(location: at, length: ns.length - at)) {
            let end = NSMaxRange(m.range)
            let line = ns.lineRange(for: NSRange(location: min(end, max(0, ns.length - 1)), length: 0))
            let lineStart = end == ns.length && end > 0 && ns.character(at: end - 1) == 10 ? end : line.location
            if let index = byStart[lineStart] {
                found.append((lineStart, outline[index].level, paths[index]))
                var lineEnd = NSMaxRange(line)
                if lineEnd > line.location, ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
                at = max(lineEnd, end, at + 1)
            } else {
                at = max(end, at + 1)
            }
        }
        return found
    }

    /// `org-get-title`: the `#+TITLE` lines joined.
    static func fileTitle(_ text: String) -> String? {
        let titles = text.components(separatedBy: "\n").compactMap { line -> String? in
            guard let r = line.range(of: "^#\\+(?i:title):[ \\t]*", options: .regularExpression) else { return nil }
            return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return titles.isEmpty ? nil : titles.joined(separator: " ")
    }

    static func diskTitle(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }.flatMap { fileTitle($0) }
    }
}
