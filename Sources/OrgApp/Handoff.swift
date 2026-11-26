import Foundation
import OrgCore

/// The open file and the caret's place in it, as Handoff passes them between orgstar on a Mac,
/// iPhone and iPad. Only where the file is and where the caret is go in the activity, never the
/// file's text.
///
/// A folder is found on the other device by its path in iCloud Drive (or another iCloud
/// container) when it is in iCloud, since that path is the same on every device; otherwise by
/// the added folder's name, since other providers (Dropbox, Working Copy, a local folder) put
/// the same folder at a different path on each device.
public struct HandoffPlace: Equatable, Sendable {
    /// The activity type, listed under `NSUserActivityTypes` in both apps' Info.plist.
    public static let activityType = "sh.krz.orgstar.editing"

    /// The added folder's name.
    public var folder: String
    /// The file's path inside iCloud's containers (`com~apple~CloudDocs/org/todo.org`), when it
    /// is in iCloud.
    public var cloudPath: String?
    /// The file's path relative to the added folder.
    public var file: String
    /// The titles of the caret's heading and the headings above it, outermost first.
    public var outline: [String]
    /// The caret's heading's `ID`.
    public var id: String?
    /// The caret's line, from 1.
    public var line: Int
    /// The caret's heading's line, from 1; 0 before the first heading.
    public var headingLine: Int

    public init(folder: String, cloudPath: String?, file: String, outline: [String], id: String?, line: Int, headingLine: Int) {
        self.folder = folder
        self.cloudPath = cloudPath
        self.file = file
        self.outline = outline
        self.id = id
        self.line = line
        self.headingLine = headingLine
    }

    // MARK: - userInfo

    public var userInfo: [String: Any] {
        var info: [String: Any] = ["folder": folder, "file": file, "outline": outline, "line": line, "headingLine": headingLine]
        if let cloudPath { info["cloudPath"] = cloudPath }
        if let id { info["id"] = id }
        return info
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo, let folder = info["folder"] as? String, let file = info["file"] as? String,
              !file.isEmpty, !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else { return nil }
        self.init(folder: folder, cloudPath: info["cloudPath"] as? String, file: file, outline: info["outline"] as? [String] ?? [],
                  id: info["id"] as? String, line: max(1, info["line"] as? Int ?? 1), headingLine: max(0, info["headingLine"] as? Int ?? 0))
    }

    // MARK: - Advertising

    /// Whether a file may be advertised: not an encrypted one.
    public static func advertises(_ path: String) -> Bool {
        !path.hasSuffix(".gpg")
    }

    /// The place of `caret` in `text`, the file at `path` inside one of `roots`; nil when the
    /// file is in none of them or is encrypted.
    public static func make(path: String, text: String, caret: Int, roots: [String], settings: OrgSettings = .default) -> HandoffPlace? {
        guard advertises(path), let root = roots.filter({ inside(path, $0) }).max(by: { $0.count < $1.count }) else { return nil }
        let file = String(path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
        guard !file.isEmpty else { return nil }
        let model = DocumentModel(tree: OrgParser.parse(text, defaults: settings))
        let ns = text as NSString
        let caret = max(0, min(caret, ns.length))
        var outline: [String] = []
        var id: String?
        var headingLine = 0
        if let index = model.headings.lastIndex(where: { $0.headingRange.lowerBound <= caret }) {
            id = model.headings[index].id
            headingLine = line(of: model.headings[index].headingRange.lowerBound, in: ns)
            var next: Int? = index
            while let i = next {
                outline.insert(model.headings[i].title, at: 0)
                next = model.headings[i].parent
            }
        }
        return HandoffPlace(folder: (root as NSString).lastPathComponent, cloudPath: cloudPath(of: path), file: file,
                            outline: outline, id: id, line: line(of: caret, in: ns), headingLine: headingLine)
    }

    /// `path` inside iCloud's containers: what follows `Mobile Documents/`, which is the same on
    /// a Mac (`~/Library/Mobile Documents`) and on iOS (`/var/mobile/Library/Mobile Documents`).
    public static func cloudPath(of path: String) -> String? {
        guard let range = path.range(of: "/Mobile Documents/") else { return nil }
        let rest = String(path[range.upperBound...])
        return rest.isEmpty ? nil : rest
    }

    static func inside(_ path: String, _ root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The 1-based line of `offset`.
    static func line(of offset: Int, in text: NSString) -> Int {
        var line = 1
        var index = 0
        let end = min(offset, text.length)
        while index < end {
            let found = text.range(of: "\n", options: [], range: NSRange(location: index, length: end - index))
            guard found.location != NSNotFound else { break }
            line += 1
            index = found.location + 1
        }
        return line
    }

    /// The offset where 1-based `line` starts, or the end of the text.
    static func offset(ofLine line: Int, in text: NSString) -> Int {
        var index = 0
        var current = 1
        while current < line {
            let found = text.range(of: "\n", options: [], range: NSRange(location: index, length: text.length - index))
            guard found.location != NSNotFound else { return text.length }
            index = found.location + 1
            current += 1
        }
        return index
    }

    // MARK: - Continuing

    public enum Match: Equatable, Sendable {
        /// The file on this device.
        case file(String)
        /// No added folder is the advertised one.
        case noFolder
        /// The folder is here, without the file (not synced yet, or since moved).
        case noFile
    }

    /// The file on this device: in a root that has the same iCloud path, or else in a root with
    /// the folder's name.
    public func resolve(roots: [String], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Match {
        var candidates: [String] = []
        if let cloudPath {
            for root in roots {
                guard let cloudRoot = Self.cloudPath(of: root), cloudPath.hasPrefix(cloudRoot + "/") else { continue }
                candidates.append((root as NSString).appendingPathComponent(String(cloudPath.dropFirst(cloudRoot.count + 1))))
            }
        }
        if candidates.isEmpty {
            candidates = roots.filter { ($0 as NSString).lastPathComponent == folder }.map { ($0 as NSString).appendingPathComponent(file) }
        }
        guard !candidates.isEmpty else { return .noFolder }
        return candidates.first(where: exists).map(Match.file) ?? .noFile
    }

    /// Where the caret goes in `text`, this device's copy of the file: the heading with the
    /// `ID`, else the one at the outline path, at the same line within it; else the same line.
    public func offset(in text: String, settings: OrgSettings = .default) -> Int {
        let ns = text as NSString
        let model = DocumentModel(tree: OrgParser.parse(text, defaults: settings))
        var found: Int?
        if let id { found = model.headings.firstIndex { $0.id == id } }
        if found == nil, !outline.isEmpty {
            var parent: Int?
            for title in outline {
                guard let next = model.headings.indices.first(where: { model.headings[$0].parent == parent && model.headings[$0].title == title }) else {
                    parent = nil
                    break
                }
                parent = next
            }
            found = parent
        }
        guard let found, headingLine > 0 else { return Self.offset(ofLine: line, in: ns) }
        let start = model.headings[found].headingRange.lowerBound
        // The caret was in the heading's own text, before the next heading.
        let limit = found + 1 < model.headings.count ? max(start, model.headings[found + 1].headingRange.lowerBound - 1) : ns.length
        let target = Self.line(of: start, in: ns) + max(0, line - headingLine)
        return min(Self.offset(ofLine: target, in: ns), limit)
    }
}

/// The activity that advertises the focused file to the other devices. `place` gives what to
/// advertise when the file or the caret changes; the activity is current only while it gives
/// one.
@MainActor
public final class HandoffAdvertiser {
    public var place: () -> HandoffPlace? = { nil }
    private var activity: NSUserActivity?
    private var pending: Task<Void, Never>?

    public init() {}

    /// The file or caret changed: the activity follows a moment later, so typing and moving
    /// the caret don't parse the file on every key.
    public func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    /// Advertises the place now, or stops advertising when there is none.
    public func update() {
        guard let place = place() else {
            activity?.invalidate()
            activity = nil
            return
        }
        let activity = activity ?? NSUserActivity(activityType: HandoffPlace.activityType)
        activity.title = (place.file as NSString).lastPathComponent
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.userInfo = place.userInfo
        activity.needsSave = true
        self.activity = activity
        activity.becomeCurrent()
    }

    /// Stops advertising.
    public func stop() {
        pending?.cancel()
        activity?.invalidate()
        activity = nil
    }
}

extension HandoffPlace {
    /// What to say when the file can't be continued here; nil when it can.
    public func problem(_ match: Match) -> String? {
        let name = (file as NSString).lastPathComponent
        switch match {
        case .file: return nil
        case .noFolder: return String(localized: "Can't continue \(name): no folder named “\(folder)” is added on this device.", comment: "Handoff from another device")
        case .noFile: return String(localized: "Can't continue \(name): it isn't in “\(folder)” on this device yet.", comment: "Handoff from another device")
        }
    }
}

extension DocumentSession {
    /// The open file at `path`, or the focused one, and its caret, for Handoff; nil for a file
    /// in none of `roots` or an encrypted one.
    public func handoffPlace(_ path: String? = nil, roots: [String]) -> HandoffPlace? {
        guard let path = path ?? self.path, let text = document(of: path)?.text else { return nil }
        return HandoffPlace.make(path: path, text: text, caret: caret(of: path) ?? 0, roots: roots, settings: defaults)
    }
}
