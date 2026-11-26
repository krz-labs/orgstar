import Foundation
import GRDB
import OrgCore

/// What completion asks the index: link targets, property values and words. The open file's
/// own come from its buffer, so `excluding` leaves its rows out.
extension IndexStore {
    /// Every heading in org files, and every file with an ID, with its ID if it has one:
    /// what `[[id:` completes.
    public func linkTargets(excluding path: String? = nil) throws -> [CompletionItem] {
        try database.read { db in
            let files = try Row.fetchAll(db, sql: """
                SELECT path, org_id, title FROM files WHERE org_id IS NOT NULL AND kind = 'org' AND path IS NOT ? ORDER BY path
                """, arguments: [path]).map { row in
                let path: String = row["path"]
                let title = (row["title"] as String?) ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                return CompletionItem(title: title, id: row["org_id"], path: path, start: 0, heading: false)
            }
            let headings = try Row.fetchAll(db, sql: """
                SELECT f.path, h.title, h.org_id, h.start_offset FROM headings h JOIN files f ON f.id = h.file_id
                WHERE f.kind = 'org' AND f.path IS NOT ? ORDER BY f.path, h.ordinal
                """, arguments: [path]).map { row in
                CompletionItem(title: row["title"], id: row["org_id"], path: row["path"], start: row["start_offset"], heading: true)
            }
            return files + headings
        }
    }

    /// Values headings give `name` themselves, most used first, and the values its `_ALL`
    /// properties allow, in order.
    public func propertyValues(_ name: String, excluding path: String? = nil) throws -> (used: [String], allowed: [String]) {
        try database.read { db in
            let used = try String.fetchAll(db, sql: """
                SELECT p.value FROM properties p JOIN headings h ON h.id = p.heading_id JOIN files f ON f.id = h.file_id
                WHERE upper(p.key) = upper(?) AND p.inherited = 0 AND f.path IS NOT ? AND p.value != ''
                GROUP BY p.value ORDER BY count(*) DESC, p.value
                """, arguments: [name, path])
            let allowed = try String.fetchAll(db, sql: """
                SELECT p.value FROM properties p JOIN headings h ON h.id = p.heading_id JOIN files f ON f.id = h.file_id
                WHERE upper(p.key) = upper(?) AND p.inherited = 0 AND f.path IS NOT ?
                """, arguments: [name + "_ALL", path])
            return (used, allowed.flatMap(PropertyValues.readList).filter { $0 != ":ETC" })
        }
    }

    /// Words starting with `prefix`, ignoring case, in headings and text before first
    /// headings that the full-text index finds for it.
    public func words(_ prefix: String, excluding path: String? = nil, limit: Int = 50) throws -> [String] {
        let term = prefix.lowercased().split { !$0.isLetter && !$0.isNumber }.first.map(String.init) ?? ""
        guard !term.isEmpty else { return [] }
        let match = "\"" + term + "\"*"
        let texts = try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT headings_fts.title || char(10) || headings_fts.body FROM headings_fts
                JOIN headings h ON h.id = headings_fts.rowid JOIN files f ON f.id = h.file_id
                WHERE headings_fts MATCH ? AND f.path IS NOT ? LIMIT 200
                """, arguments: [match, path])
                + String.fetchAll(db, sql: """
                    SELECT files_fts.body FROM files_fts JOIN files f ON f.id = files_fts.rowid
                    WHERE files_fts MATCH ? AND f.path IS NOT ? LIMIT 50
                    """, arguments: [match, path])
        }
        return Dabbrev.words(prefix, in: texts, limit: limit)
    }
}
