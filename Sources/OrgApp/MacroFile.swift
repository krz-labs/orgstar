import Foundation
import OrgCore

/// `macros.toml` in the configuration folder: keyboard macros by name, in a `[macros]` table of
/// key sequences in the keymap's notation.
public enum MacroFile {
    public static var url: URL { UserConfig.file(NamedMacros.fileName) }

    static let header = """
        # Keyboard macros named with Name Last Macro (C-x C-k n in the Emacs preset). Each runs as
        # the command macro.named.<name>, which keymap.toml can bind. Keys are in keymap.toml's
        # notation; a prompt's answer is the keys typed into it, then RET.

        """

    /// Reads the file into `store`, and has `store` write macros named from now on into it.
    /// The problems found; a missing file is none.
    @discardableResult
    public static func load(into store: NamedMacros = .shared, from url: URL = url) -> [String] {
        store.setSaver { name, keys in try save(name, keys, to: url) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            store.replace([:])
            return []
        }
        var problems: [String] = []
        do {
            store.replace(try NamedMacros.parse(text, problems: &problems))
        } catch {
            problems.append("\(error)")
        }
        return problems
    }

    /// Writes `name` into the file, keeping what else it holds.
    public static func save(_ name: String, _ keys: [KeyChord], to url: URL = url) throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? header
        let updated = UserConfig.setting(text, section: NamedMacros.table, key: name, to: .string(KeySequence.format(keys)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
    }
}
