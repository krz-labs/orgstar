import Foundation
import OrgCore

/// Share Subtree…: the entry at the caret as an org file of its own or as text, with the files
/// attached to it and to the entries under it. The entry is taken as the file holds it, so an
/// encrypted entry is shared encrypted.
public struct SubtreeShare: Sendable, Identifiable {
    public let id = UUID()
    /// The entry with the file's keyword lines, as `ExportScope.entry` gives it.
    public let text: String
    /// The `.org` file's name: the heading's title.
    public let fileName: String
    /// Files in the attachment folders of the entry and the entries under it.
    public let attachments: [URL]

    /// The entry at `offset` in `text`, the file at `path`; nil before the first heading.
    /// `idDir` and `inherit` are `org-attach-id-dir` and `org-attach-use-inheritance`.
    public init?(text: String, at offset: Int, path: String, settings: OrgSettings = .default,
                 idDir: String = OrgPreferences.attachIDDir(), inherit: Bool? = OrgPreferences.attachUseInheritance()) {
        guard let entry = ExportScope.entry(text, at: offset, settings: settings) else { return nil }
        self.text = entry.text
        let tree = OrgParser.parse(text, defaults: settings)
        let headings = DocumentModel(tree: tree).headings.filter { entry.range.contains($0.headingRange.lowerBound) }
        fileName = Self.fileName(entry.title)
        var folders: [String] = []
        for heading in headings {
            guard let dir = OrgAttach.directory(tree: tree, at: heading.headingRange.lowerBound, path: path, idDir: idDir, inherit: inherit, isDirectory: Attachments.isDirectory),
                  !folders.contains(dir) else { continue }
            folders.append(dir)
        }
        // Files only: hidden files and folders inside stay behind.
        attachments = folders.flatMap { dir in
            Attachments.files(in: dir).filter { !$0.hasPrefix(".") }.map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
                .filter { !Attachments.isDirectory($0.path) }
        }
    }

    /// `title` as a file name: characters other systems refuse replaced, at most 80 long, with
    /// `.org`.
    static func fileName(_ title: String) -> String {
        var name = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return (name.isEmpty ? "Subtree" : name) + ".org"
    }

    /// Writes the entry as `fileName` in a new temporary folder; its URL.
    public func writeFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-" + id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// What the share sheet sends: the written file and, when asked, the attachments, each as
    /// an item of its own.
    public func files(file: URL, withAttachments: Bool) -> [URL] {
        [file] + (withAttachments ? attachments : [])
    }
}

extension DocumentSession {
    /// Share Subtree… for the entry at `offset` in the open file at `path`.
    public func subtreeShare(_ path: String, at offset: Int) -> SubtreeShare? {
        guard let text = document(of: path)?.text else { return nil }
        return SubtreeShare(text: text, at: offset, path: path, settings: defaults)
    }
}
