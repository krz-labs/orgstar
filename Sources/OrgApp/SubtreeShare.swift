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
    /// Share Subtree… for the entry at `offset` in the open file at `path`, as it is on disk:
    /// its tagged entries encrypted; a heading inside an encrypted entry as an entry of its own,
    /// "Encrypted entry" with the tag, whose one message holds the whole subtree. Nil when
    /// there's no entry there, or `refusesSubtreeShare`.
    public func subtreeShare(_ path: String, at offset: Int) -> SubtreeShare? {
        guard case .success(let source) = shareSource(path, at: offset) else { return nil }
        return SubtreeShare(text: source.text, at: source.offset, path: path, settings: defaults)
    }

    /// Why the entry at `offset` in `path` isn't shared: its file is encrypted, or what's
    /// encrypted on disk can't be encrypted in the copy (no passphrase, or one that fails).
    public func refusesSubtreeShare(_ path: String, at offset: Int) -> String? {
        if case .failure(let refusal) = shareSource(path, at: offset) { return refusal.message }
        return nil
    }

    struct ShareRefusal: Error {
        let message: String
    }

    /// The text to share the entry at `offset` from, and where in it.
    private func shareSource(_ path: String, at offset: Int) -> Result<(text: String, offset: Int), ShareRefusal> {
        let name = (path as NSString).lastPathComponent
        if Self.isEncryptedFile(path) { return .failure(ShareRefusal(message: String(localized: "\(name) is encrypted; its entries aren't shared."))) }
        guard let text = document(of: path)?.text else { return .success((text: "", offset: offset)) }
        guard crypt.sealsEntries(for: path), let heading = OrgCrypt.heading(text, at: offset), let range = subtreeRange(text, at: offset) else {
            return .success((text, offset))
        }
        let needsPassphrase = ShareRefusal(message: String(localized: "Tagged entries in the subtree aren't encrypted; give the passphrase with Encrypt… first."))
        if OrgCrypt.isInTaggedText(text, at: heading, tag: cryptTag) {
            guard let passphrase = crypt.passphrase(for: path) else { return .failure(needsPassphrase) }
            let subtree = (text as NSString).substring(with: NSRange(range))
            do {
                let message = try OpenPGP.encrypt(Data((subtree.hasSuffix("\n") ? subtree : subtree + "\n").utf8), passphrase: passphrase)
                return .success(("* " + String(localized: "Encrypted entry") + " :" + cryptTag + ":\n" + message, 0))
            } catch {
                return .failure(ShareRefusal(message: error.localizedDescription))
            }
        }
        guard !OrgCrypt.unencrypted(text, tag: cryptTag, within: range).isEmpty else { return .success((text, offset)) }
        guard let passphrase = crypt.passphrase(for: path) else { return .failure(needsPassphrase) }
        do {
            return .success((try OrgCrypt.seal(text, passphrase: passphrase, tag: cryptTag, within: range).text, heading))
        } catch {
            return .failure(ShareRefusal(message: error.localizedDescription))
        }
    }

    private func subtreeRange(_ text: String, at offset: Int) -> Range<Int>? {
        guard let heading = OrgCrypt.heading(text, at: offset) else { return nil }
        return heading..<max(heading + 1, OrgCrypt.bodyRange(text, at: heading)?.upperBound ?? heading)
    }
}
