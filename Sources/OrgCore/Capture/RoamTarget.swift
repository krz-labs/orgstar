import Foundation

/// org-roam 2.3's capture targets (`org-roam-capture--setup-target-location`): a file that
/// gets an `ID` at its top when it has none, and with `file+head+olp`, the headings of the
/// outline path, made when missing.
public enum RoamTarget {
    /// `text` with the file's `ID` (`org-id-get-create` at the top), `properties` put after it
    /// as `org-entry-put` puts them, and the headings of `olp` that are missing
    /// (`org-roam-capture-find-or-create-olp`). The text and the file's ID.
    public static func prepare(
        _ text: String, properties: [(key: String, value: String)] = [], olp: [String] = [],
        newID: () -> String = { UUID().uuidString.lowercased() }
    ) -> (text: String, id: String) {
        let (withID, id) = OrgAttach.ensuringID(text, at: 0, newID: newID)
        let buffer = EmacsBuffer(withID, point: 0)
        for property in properties { buffer.entryPut(property.key, property.value) }
        var start = 0, end = buffer.length, level = 0
        for title in olp {
            buffer.point = start
            let pattern = "^(\\*+)[ \\t]+(?:[A-Z]+[ \\t]+)?(?:\\[#.\\][ \\t]*)?" + NSRegularExpression.escapedPattern(for: title) + "(?:[ \\t]+:[\\w@#%:]+:)?[ \\t]*$"
            var found: Int?
            while let match = buffer.searchForward(pattern, bound: end, caseInsensitive: false) {
                if match[1]!.count == level + 1 { found = buffer.lineStart(match[0]!.lowerBound) }
                buffer.point = match[0]!.upperBound
            }
            if found == nil {
                buffer.point = end
                if !buffer.bolp { buffer.insert("\n") }
                found = buffer.point
                buffer.insert(String(repeating: "*", count: level + 1) + " " + title + "\n")
            }
            level += 1
            start = found!
            end = buffer.saveExcursion { () -> Int in
                Capture.endOfSubtree(buffer, heading: start)
                return buffer.point
            }
        }
        return (buffer.text as String, id)
    }
}
