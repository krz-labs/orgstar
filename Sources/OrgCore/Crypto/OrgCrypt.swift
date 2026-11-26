import CryptoKit
import Foundation

/// org-crypt (org-crypt.el, Org 9.8.7) with symmetric encryption, as with `org-crypt-key`
/// nil: an entry's text after its planning, properties and logbook, through the end of its
/// subtree, replaced by an armored OpenPGP message under the heading.
public enum OrgCrypt {
    public struct Failure: Error, Equatable, CustomStringConvertible, LocalizedError {
        public let description: String
        public init(_ description: String) { self.description = description }
        public var errorDescription: String? { description }
    }

    /// `org-end-of-meta-data 'standard`: past planning, the property drawer, clock lines,
    /// blank lines and logbook drawers.
    static func metaDataEnd(_ buffer: EmacsBuffer) {
        buffer.endOfMetaData()
        guard !buffer.atHeading else { return }
        let end = buffer.saveExcursion { () -> Int in buffer.outlineNextHeading(); return buffer.point }
        while !buffer.eobp {
            if buffer.lookingAt("[ \\t]*$|^[ \\t]*CLOCK:") != nil {
                buffer.forwardLine(1)
            } else if buffer.lookingAt("[ \\t]*:LOGBOOK:[ \\t]*$") != nil {
                guard buffer.searchForward("^[ \\t]*:END:[ \\t]*$", bound: end, caseInsensitive: true) != nil else { return }
                buffer.forwardLine(1)
            } else {
                return
            }
        }
    }

    /// The heading the entry at `offset` is under, or nil before the first.
    public static func heading(_ text: String, at offset: Int) -> Int? {
        let buffer = EmacsBuffer(text, point: min(offset, (text as NSString).length))
        return try? buffer.backToHeading()
    }

    /// `org-at-encrypted-entry-p`: the message's lines, from its begin line through the line
    /// after its end line.
    public static func encryptedRange(_ text: String, at offset: Int) -> Range<Int>? {
        let buffer = EmacsBuffer(text, point: min(offset, (text as NSString).length))
        guard (try? buffer.backToHeading()) != nil else { return nil }
        metaDataEnd(buffer)
        guard buffer.lookingAt("[ \\t]*-----BEGIN PGP MESSAGE-----[ \\t]*$") != nil else { return nil }
        let start = buffer.point
        guard let match = buffer.searchForward("^(?:([ \\t]*-----END PGP MESSAGE-----)[ \\t]*$|\\*+ )", caseInsensitive: false),
              match[1] != nil else { return nil }
        let line = buffer.lineEnd(match[0]!.lowerBound)
        return start..<min(line + 1, buffer.length)
    }

    /// What `org-encrypt-entry` encrypts: after the meta-data through the subtree's end, less
    /// the blank lines before the next heading.
    public static func bodyRange(_ text: String, at offset: Int) -> Range<Int>? {
        let buffer = EmacsBuffer(text, point: min(offset, (text as NSString).length))
        guard let heading = try? buffer.backToHeading() else { return nil }
        metaDataEnd(buffer)
        let start = buffer.point
        buffer.point = heading
        buffer.endOfSubtree(toHeading: true)
        buffer.backOverEmptyLines()
        return start..<max(start, buffer.point)
    }

    /// `org-encrypt-entry`: the text with the entry at `offset` encrypted, or nil when it's
    /// encrypted already.
    public static func encrypt(_ text: String, at offset: Int, passphrase: String, now: Date = Date()) throws -> String? {
        guard heading(text, at: offset) != nil else { throw Failure("Before first headline") }
        guard encryptedRange(text, at: offset) == nil, let range = bodyRange(text, at: offset) else { return nil }
        let ns = text as NSString
        let contents = ns.substring(with: NSRange(range))
        let message = try OpenPGP.encrypt(Data(contents.utf8), passphrase: passphrase, now: now)
        return ns.replacingCharacters(in: NSRange(range), with: message)
    }

    /// The decrypted text of the entry at `offset` and where its message is.
    public static func decrypt(_ text: String, at offset: Int, passphrase: String) throws -> (plaintext: String, range: Range<Int>) {
        guard let range = encryptedRange(text, at: offset) else { throw Failure("Not an encrypted entry") }
        let message = (text as NSString).substring(with: NSRange(range))
        let data: Data
        do {
            data = try OpenPGP.decrypt(OpenPGP.dearmor(message), passphrase: passphrase)
        } catch let failure as OpenPGP.Failure {
            throw Failure(failure == OpenPGP.wrongPassphrase ? "Wrong passphrase" : failure.description)
        }
        var plain = String(decoding: data, as: UTF8.self)
        // epg encrypts in text mode, with CRLF line ends, and `decode-coding-string` with
        // `utf-8` takes them back to LF.
        if plain.contains("\r\n"), !plain.replacingOccurrences(of: "\r\n", with: "").contains("\n") {
            plain = plain.replacingOccurrences(of: "\r\n", with: "\n")
        }
        return (plain, range)
    }

    /// `org-decrypt-entry`: the text with the entry's message replaced by what it holds, its
    /// headings moved below the entry's level when they aren't.
    public static func decryptInPlace(_ text: String, at offset: Int, passphrase: String) throws -> String {
        var (plain, range) = try decrypt(text, at: offset, passphrase: passphrase)
        let ns = text as NSString
        let headingStart = heading(text, at: offset)!
        let level = ns.substring(from: headingStart).prefix { $0 == "*" }.count
        let pattern = "(?m)^\\*{1,\(level)} "
        if plain.range(of: pattern, options: .regularExpression) != nil {
            let minLevel = plain.matches(of: try! Regex(pattern)).map { plain[$0.range].count - 1 }.min() ?? level
            let prefix = String(repeating: "*", count: 1 + level - minLevel)
            plain = plain.replacing(#/(?m)^\*+ /#) { prefix + $0.output }
        }
        return ns.replacingCharacters(in: NSRange((range.lowerBound - 1)..<range.upperBound), with: "\n" + plain)
    }

    /// The entry's message replaced by `plaintext` encrypted again.
    public static func replacing(_ text: String, at offset: Int, with plaintext: String, passphrase: String, now: Date = Date()) throws -> String {
        guard let range = encryptedRange(text, at: offset) else { throw Failure("Not an encrypted entry") }
        let message = try OpenPGP.encrypt(Data(plaintext.utf8), passphrase: passphrase, now: now)
        return (text as NSString).replacingCharacters(in: NSRange(range), with: message)
    }

    /// The headings with `tag` (`org-crypt-tag-matcher`), inherited or their own, in order.
    public static func taggedHeadings(_ text: String, tag: String = "crypt", settings: OrgSettings = .default) -> [Int] {
        let model = DocumentModel(tree: OrgParser.parse(text, defaults: settings))
        return model.headings.indices.filter { model.tags(of: $0).contains { $0.value == tag } }.map { model.headings[$0].headingRange.lowerBound }
    }

    /// `org-encrypt-entries`: every tagged entry not encrypted yet, from the top, so that an
    /// entry's tagged children go inside its message. The text and how many were encrypted.
    public static func encryptAll(_ text: String, passphrase: String, tag: String = "crypt", settings: OrgSettings = .default, now: Date = Date()) throws -> (String, Int) {
        var text = text
        var count = 0
        var from = 0
        while let next = taggedHeadings(text, tag: tag, settings: settings).first(where: { $0 >= from }) {
            if let encrypted = try encrypt(text, at: next, passphrase: passphrase, now: now) {
                text = encrypted
                count += 1
            }
            from = next + 1
        }
        return (text, count)
    }

    /// What saving does with the tagged entry at `heading`: nil when nothing (its text is a
    /// message, or it has no text), else its text's range, the message at its start if any,
    /// and whether it has text that isn't blank outside a message.
    static func pending(_ text: String, at heading: Int) -> (body: Range<Int>, message: Range<Int>?, hasText: Bool)? {
        guard let body = bodyRange(text, at: heading) else { return nil }
        let ns = text as NSString
        func blank(_ range: Range<Int>) -> Bool {
            range.isEmpty || ns.substring(with: NSRange(range)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let message = encryptedRange(text, at: heading) {
            // Text typed below the message isn't encrypted.
            let tail = min(message.upperBound, body.upperBound)..<max(message.upperBound, body.upperBound)
            return blank(tail) ? nil : (body, message, true)
        }
        return (body, nil, !blank(body))
    }

    /// The tagged entries `seal` encrypts whose text isn't blank: those a save can't write
    /// without the passphrase, text below a message included. Their headings' offsets.
    public static func unencrypted(_ text: String, tag: String = "crypt", settings: OrgSettings = .default, within: Range<Int>? = nil) -> [Int] {
        guard text.contains(tag) else { return [] }
        var found: [Int] = []
        var covered = 0
        for heading in taggedHeadings(text, tag: tag, settings: settings) where heading >= covered && within?.contains(heading) ?? true {
            guard let entry = pending(text, at: heading) else { continue }
            // Tagged children go inside this entry's message.
            covered = entry.body.upperBound
            if entry.hasText { found.append(heading) }
        }
        return found
    }

    /// `org-encrypt-entries` as `org-crypt-use-before-save-magic` runs it before a save. An
    /// entry whose text `reuse` knows by its `checksum` gets that message again, as org-crypt
    /// keeps an entry decrypted and left unchanged byte for byte. Text below an entry's message
    /// goes into one message with what the old one held. The text, and each message with the
    /// text the entry had.
    public static func seal(
        _ text: String, passphrase: String, tag: String = "crypt", settings: OrgSettings = .default,
        reuse: (String) -> String? = { _ in nil }, within: Range<Int>? = nil, now: Date = Date()
    ) throws -> (text: String, messages: [(message: String, plaintext: String)]) {
        guard text.contains(tag) else { return (text, []) }
        var result = text as NSString
        var messages: [(String, String)] = []
        var shift = 0
        var covered = 0
        for heading in taggedHeadings(text, tag: tag, settings: settings) where heading >= covered && within?.contains(heading) ?? true {
            let current = result as String
            guard let entry = pending(current, at: heading + shift) else { continue }
            let range = entry.body
            covered = range.upperBound - shift
            let contents = result.substring(with: NSRange(range))
            var plaintext = contents
            if let old = entry.message {
                let opened: String
                do {
                    opened = try decrypt(current, at: heading + shift, passphrase: passphrase).plaintext
                } catch {
                    throw Failure("An entry has text below a message that this passphrase doesn't open; entries encrypted to a public key aren't supported")
                }
                plaintext = opened + result.substring(with: NSRange(old.upperBound..<range.upperBound))
            }
            let message = try reuse(checksum(contents)) ?? OpenPGP.encrypt(Data(plaintext.utf8), passphrase: passphrase, now: now)
            result = result.replacingCharacters(in: NSRange(range), with: message) as NSString
            shift += (message as NSString).length - range.count
            messages.append((message, contents))
        }
        return (result as String, messages)
    }

    /// Whether `offset` is in the text of an entry with `tag`, which a message holds on disk.
    public static func isInTaggedText(_ text: String, at offset: Int, tag: String = "crypt", settings: OrgSettings = .default) -> Bool {
        guard text.contains(tag) else { return false }
        return taggedHeadings(text, tag: tag, settings: settings).contains { heading in
            heading < offset && (bodyRange(text, at: heading)?.contains(offset) ?? false)
        }
    }

    /// What an entry's text is known by, as `org-crypt-checksum` is.
    public static func checksum(_ contents: String) -> String {
        SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The first entry's message in `text` encrypted with a passphrase; entries encrypted to a
    /// public key are passed over.
    public static func firstMessage(_ text: String) -> String? {
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let begin = ns.range(of: "-----BEGIN PGP MESSAGE-----", options: [], range: search)
            guard begin.location != NSNotFound else { return nil }
            let lineStart = ns.lineRange(for: NSRange(location: begin.location, length: 0)).location
            if let range = encryptedRange(text, at: lineStart), range.lowerBound == lineStart {
                let message = ns.substring(with: NSRange(range))
                if let data = try? OpenPGP.dearmor(message), OpenPGP.isSymmetric(data) { return message }
            }
            search = NSRange(location: NSMaxRange(begin), length: ns.length - NSMaxRange(begin))
        }
    }

    /// Whether `passphrase` opens `message`.
    public static func opens(_ message: String, passphrase: String) -> Bool {
        (try? OpenPGP.decrypt(OpenPGP.dearmor(message), passphrase: passphrase)) != nil
    }
}
