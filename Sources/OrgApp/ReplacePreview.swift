import OrgCore
import SwiftUI

/// Which of the commands over files a sheet runs.
public enum ReplaceKind: String, Identifiable, Sendable {
    case replace, renameTag, renameKeyword
    public var id: String { rawValue }

    /// The command that opens it.
    public init?(command: String) {
        switch command {
        case "app.replace-in-files": self = .replace
        case "app.rename-tag": self = .renameTag
        case "app.rename-todo-keyword": self = .renameKeyword
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .replace: String(localized: "Replace in Files", comment: "Window title")
        case .renameTag: String(localized: "Rename Tag", comment: "Window title")
        case .renameKeyword: String(localized: "Rename TODO Keyword", comment: "Window title")
        }
    }

    /// What the sheet starts with for a heading line at `caret`: its tag under the caret or
    /// first tag, or its TODO keyword.
    public func initial(text: String, caret: Int, keywords: Set<String>) -> String {
        guard self != .replace else { return "" }
        let ns = text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        guard line.hasPrefix("*") else { return "" }
        let words = line.drop { $0 == "*" }.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if self == .renameKeyword {
            return words.first.map(String.init).flatMap { keywords.contains($0) ? $0 : nil } ?? ""
        }
        guard let tags = line.firstMatch(of: /[ \t]:([\p{L}\p{N}_@#%:]+):[ \t]*$/) else { return "" }
        let start = line.utf16.distance(from: line.startIndex, to: tags.1.startIndex)
        var at = start
        for tag in tags.1.split(separator: ":") {
            let end = at + tag.utf16.count
            if (lineRange.location + at...lineRange.location + end).contains(caret) { return String(tag) }
            at = end + 1
        }
        return tags.1.split(separator: ":").first.map(String.init) ?? ""
    }

    /// The button that applies the ticked changes.
    public var applyTitle: String {
        switch self {
        case .replace: String(localized: "Replace", comment: "Replace in Files: applies the ticked changes")
        case .renameTag, .renameKeyword: String(localized: "Rename", comment: "Rename Tag or TODO Keyword: applies the ticked changes")
        }
    }
}

/// The changes a search found, by file and line, each with a checkbox: the line with the part
/// that goes struck through in `removed` and what replaces it in `added`.
public struct ReplacePreview: View {
    let model: ReplaceInFiles
    let removed: Color
    let added: Color
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    public init(model: ReplaceInFiles, removed: Color = .red, added: Color = .green) {
        self.model = model
        self.removed = removed
        self.added = added
    }

    public var body: some View {
        List {
            if let change = model.configChange, model.changesConfig {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(change.key) = \"\(change.new.replacingOccurrences(of: "\n", with: "\\n"))\"")
                            .font(.system(.callout, design: .monospaced))
                        Text("Was \"\(change.old.replacingOccurrences(of: "\n", with: "\\n"))\"", comment: "Rename: the config.toml setting before the change")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(verbatim: "config.toml")
                }
            }
            ForEach(model.files) { file in
                Section {
                    // Ids unique across files: a List reuses rows by id across its sections.
                    ForEach(file.changes.map { (key: file.path + "#\($0.id)", change: $0) }, id: \.key) { item in
                        let change = item.change
                        Toggle(isOn: Binding(get: { !file.unticked.contains(change.id) }, set: { model.setTicked($0, change: change.id, in: file.path) })) {
                            row(change)
                        }
                    }
                } header: {
                    Toggle(isOn: Binding(get: { file.isIncluded }, set: { model.setTicked($0, file: file.path) })) {
                        HStack(spacing: 6) {
                            Text(verbatim: file.name).bold()
                            Text(verbatim: file.relativePath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text("\(file.changes.count - file.unticked.count) of \(file.changes.count)", comment: "Replace in Files: ticked changes of the file's changes")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
    }

    private func row(_ change: ProposedChange) -> some View {
        let line = change.lineText as NSString
        let start = min(change.changed.lowerBound, line.length), end = min(change.changed.upperBound, line.length)
        var old = AttributedString(Self.collapsed(line.substring(with: NSRange(location: start, length: end - start))))
        old.strikethroughStyle = .single
        old.foregroundColor = removed
        var new = AttributedString(Self.collapsed(change.replacement.replacingOccurrences(of: "\n", with: "⏎")))
        new.foregroundColor = added
        if withoutColor { new.underlineStyle = .single }
        let text = AttributedString(Self.trimmedStart(Self.collapsed(line.substring(to: start)))) + old + new
            + AttributedString(Self.collapsed(line.substring(from: end)))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(change.line)").foregroundStyle(.secondary).monospacedDigit()
            Text(text).lineLimit(2).font(.system(.callout, design: .monospaced))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Line \(change.line): \(change.lineText)", comment: "Replace in Files: a change, for VoiceOver"))
        .accessibilityValue(Text("Becomes \(line.substring(to: start) + change.replacement + line.substring(from: end))", comment: "Replace in Files: the line after the change, for VoiceOver"))
    }

    /// Runs of blanks as one space, so the spaces that align tags don't fill the row.
    static func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
    }

    /// A long start of a line, cut to its last 40 characters so the change shows.
    static func trimmedStart(_ text: String) -> String {
        text.count > 40 ? "…" + text.suffix(40) : text
    }
}
