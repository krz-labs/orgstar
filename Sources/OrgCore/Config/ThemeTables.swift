/// The tables of config.toml the theme reads: `[theme]` and `[theme.…]`.
public enum ThemeTables {
    /// Keys of `[theme]` that aren't colors; config.toml's settings handle them.
    public static let typeKeys: Set<String> = ["font", "body-font", "font-size", "line-spacing", "text-width", "heading-size-step", "theme-file", "light-theme", "dark-theme"]

    /// Whether a table holds theme colors.
    public static func isThemeTable(_ name: String) -> Bool {
        name == "theme" || name.hasPrefix("theme.")
    }
}
