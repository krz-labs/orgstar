import Foundation

/// Where captured entries wait for triage in a file: the entries a capture template's target
/// files new entries as.
public enum TriageScope: Sendable, Equatable {
    /// Top-level headings: `file` and `file+regexp` targets.
    case file
    /// The children of the first heading with this title: `file+headline`.
    case headline(String)
    /// The children of the heading at this outline path: `file+olp`.
    case outline([String])
    /// The entries filed in a date tree, under the outline path or at the top of the file.
    case datetree([String])
    /// The children of the heading with this `ID` property: `id` targets.
    case id(String)

    /// The scope of a capture target; nil for `clock`, which has no fixed place.
    public init?(_ target: CaptureTemplate.Target) {
        switch target {
        case .file, .regexp: self = .file
        case .headline(_, let headline): self = .headline(headline)
        case .outline(_, let path): self = .outline(path)
        case .datetree(_, let path, _): self = .datetree(path)
        case .id(let id): self = .id(id)
        case .clock, .heading: return nil
        }
    }
}

public enum Triage {
    /// The entries waiting in `source` under `scope`, in file order, as tag-match lines.
    /// Entries in archived or commented trees are left out.
    public static func entries(_ source: AgendaSource, scope: TriageScope, options: AgendaOptions = AgendaOptions()) -> [AgendaItem] {
        let headings = source.headings
        var chosen: [Int] = []
        func children(of parent: Int) -> [Int] {
            let level = headings[parent].level
            var found: [Int] = []
            var i = parent + 1
            while i < headings.count, headings[i].level > level {
                if headings[i].level == level + 1 { found.append(i) }
                i += 1
            }
            return found
        }
        switch scope {
        case .file:
            chosen = headings.indices.filter { headings[$0].level == 1 }
        case .headline(let title):
            if let parent = headings.firstIndex(where: { $0.title == title }) { chosen = children(of: parent) }
        case .outline(let path):
            if let parent = outlineHeading(path, in: headings) { chosen = children(of: parent) }
        case .datetree(let path):
            var range = headings.indices
            if !path.isEmpty {
                guard let parent = outlineHeading(path, in: headings) else { break }
                let end = headings[(parent + 1)...].firstIndex { $0.level <= headings[parent].level } ?? headings.count
                range = (parent + 1)..<end
            }
            for i in range where !isDateTreeTitle(headings[i].title) {
                // The nearest heading above at a lower level is its parent.
                guard let parent = headings[range.lowerBound..<i].lastIndex(where: { $0.level < headings[i].level }) else { continue }
                if isDateTreeTitle(headings[parent].title) { chosen.append(i) }
            }
        case .id(let id):
            if let parent = headings.firstIndex(where: { $0.properties["ID"] == id }) { chosen = children(of: parent) }
        }
        return chosen.filter { !headings[$0].skipped }.map { item(source, heading: $0, options: options) }
    }

    /// The entry whose heading starts at `offset`, as `entries` lists it; nil when no heading
    /// starts there.
    public static func entry(_ source: AgendaSource, at offset: Int, options: AgendaOptions = AgendaOptions()) -> AgendaItem? {
        source.headings.firstIndex { $0.start == offset }.map { item(source, heading: $0, options: options) }
    }

    /// The heading's own text, without the heading line: its planning, drawers and body, to
    /// the next heading.
    public static func body(_ source: AgendaSource, at offset: Int) -> String? {
        guard let index = source.headings.firstIndex(where: { $0.start == offset }) else { return nil }
        let ns = source.text as NSString
        let lineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: offset, length: 0)))
        let end = index + 1 < source.headings.count ? source.headings[index + 1].start : ns.length
        guard end > lineEnd else { return "" }
        return ns.substring(with: NSRange(location: lineEnd, length: end - lineEnd)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The file's TODO keywords, active then done.
    public static func keywords(_ source: AgendaSource) -> [String] { source.keywords }

    static func item(_ source: AgendaSource, heading index: Int, options: AgendaOptions) -> AgendaItem {
        let heading = source.headings[index]
        return Agenda.format(source, heading, kind: .tagsMatch, marker: heading.start, extra: "", dotime: nil, removing: nil,
                             trailing: "", prefix: options.prefix("tags"), urgency: { $0 })
    }

    /// The heading at the end of `path`, each title one level below the one before, as
    /// `file+olp` finds it.
    static func outlineHeading(_ path: [String], in headings: [AgendaSource.Heading]) -> Int? {
        var range = headings.indices
        var found: Int?
        for title in path {
            guard let hit = range.first(where: { headings[$0].title == title && (found == nil || headings[$0].level > headings[found!].level) }) else { return nil }
            found = hit
            let end = headings[(hit + 1)...].firstIndex { $0.level <= headings[hit].level } ?? headings.count
            range = (hit + 1)..<end
        }
        return found
    }

    nonisolated(unsafe) static let dateTreeTitle = /[12][0-9]{3}(-Q[1-4]|-W[0-5][0-9]|-[01][0-9] \w+|-[01][0-9]-[0-3][0-9] \w+)?/

    /// A year, quarter, month, week or day heading of a date tree.
    static func isDateTreeTitle(_ title: String) -> Bool { title.wholeMatch(of: dateTreeTitle) != nil }
}
