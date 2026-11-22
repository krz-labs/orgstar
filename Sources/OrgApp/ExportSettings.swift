import Foundation

/// A file's export choices: what the export dialog shows for it, and the scope and body-only
/// choice its single-format export commands follow, as `C-s` and `C-b` in Org's dispatcher.
/// Kept in the defaults by the file's path.
public struct ExportSettings: Codable, Equatable, Sendable {
    public var format = "html"
    /// The subtree at the caret, not the whole file.
    public var subtree = false
    public var bodyOnly = false
    public var openAfter = false

    public static let key = "exportSettings"
    /// Shown when body only is on and the format is a whole document.
    public static let noBodyOnly = "This format has no body-only export. Turn body-only export off for this file first."

    public init() {}

    /// PDF, Word, RTF, plain text, ODT and iCalendar are whole documents.
    public static func allowsBodyOnly(_ format: String) -> Bool {
        !["pdf", "print-pdf", "odt", "docx", "rtf", "plain-text", "icalendar"].contains(format)
    }

    /// The settings kept for the file at `path`. Without any: the format and open-after choice
    /// last exported with, the whole file, and the whole document.
    public static func saved(for path: String, defaults: UserDefaults = .standard) -> ExportSettings {
        if let kept = all(defaults)[path] { return kept }
        var settings = ExportSettings()
        settings.format = defaults.string(forKey: "exportFormat") ?? settings.format
        settings.openAfter = defaults.bool(forKey: "exportOpenAfter")
        return settings
    }

    /// Keeps the settings for the file at `path`; with `lastUsed`, the format and open-after
    /// choice also become what a file without settings starts with.
    public func save(for path: String, lastUsed: Bool = false, defaults: UserDefaults = .standard) {
        var all = Self.all(defaults)
        all[path] = self
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
        guard lastUsed else { return }
        defaults.set(format, forKey: "exportFormat")
        defaults.set(openAfter, forKey: "exportOpenAfter")
    }

    /// The scope and body-only choice a single-format export command follows for `format`. Nil
    /// when body only is on and the format has none. The agenda files' calendars are not the
    /// file's export, so they follow neither.
    public func commandOptions(_ format: String) -> (subtree: Bool, bodyOnly: Bool)? {
        if format.hasPrefix("icalendar-") { return (false, false) }
        guard !bodyOnly || Self.allowsBodyOnly(format == "html-open" ? "html" : format) else { return nil }
        return (subtree, bodyOnly)
    }

    /// The message after an export to the file named `name`, saying what was exported when it
    /// was not the whole file as a whole document.
    public static func exported(_ name: String, subtree: Bool, bodyOnly: Bool) -> String {
        switch (subtree, bodyOnly) {
        case (true, true): "Exported the subtree's body to \(name)"
        case (true, false): "Exported the subtree to \(name)"
        case (false, true): "Exported the body to \(name)"
        case (false, false): "Exported to \(name)"
        }
    }

    private static func all(_ defaults: UserDefaults) -> [String: ExportSettings] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: ExportSettings].self, from: $0) } ?? [:]
    }
}
