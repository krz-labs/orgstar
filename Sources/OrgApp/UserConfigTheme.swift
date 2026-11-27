import Foundation
import OrgConfig
import OrgCore
import OrgPresentation

extension UserConfig {
    /// The theme `config.toml` (`text`) sets: its `[theme]` tables' colors over those of
    /// `theme-file` (a path relative to `folder`), over the palettes `light-theme` and
    /// `dark-theme` name; with problems in all three. Nil when `text` isn't TOML.
    public static func theme(
        config text: String, themeFile name: String?, lightTheme: String? = nil, darkTheme: String? = nil, in folder: URL,
        read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) -> (theme: ThemeSpec, problems: [String])? {
        guard let tables = try? TOML.parse(text) else { return nil }
        var (spec, problems) = ThemeSpec.base(light: lightTheme, dark: darkTheme)
        if let name, !name.isEmpty {
            if let themeText = read(folder.appendingPathComponent(name)) {
                do {
                    let (read, more) = ThemeSpec.reading(try TOML.parse(themeText), over: spec, file: name)
                    spec = read
                    problems += more
                } catch {
                    problems.append("\(name): \(error)")
                }
            } else {
                problems.append("config.toml: theme-file \(name) can't be read")
            }
        }
        let (merged, more) = ThemeSpec.reading(tables, over: spec)
        return (merged, problems + more)
    }

    /// The file Copy to Config Folder writes.
    public static let copiedThemeFile = "my-theme.toml"

    /// Writes the two palettes into `folder` as `copiedThemeFile`; false, writing nothing, when
    /// the file is already there.
    public static func copyTheme(light: Palette, dark: Palette, to folder: URL) throws -> Bool {
        let file = folder.appendingPathComponent(copiedThemeFile)
        guard !FileManager.default.fileExists(atPath: file.path) else { return false }
        try ThemeSpec.themeFile(light: light, dark: dark).write(to: file, atomically: true, encoding: .utf8)
        return true
    }
}
