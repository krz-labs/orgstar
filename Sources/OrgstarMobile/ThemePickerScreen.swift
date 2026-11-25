#if os(iOS)
import OrgCore
import OrgPresentation
import SwiftUI

/// The built-in palettes of one appearance, each as a few lines of Org in its colors.
struct ThemePickerScreen: View {
    let model: MobileModel
    let appearance: Palette.Appearance

    var body: some View {
        let _ = model.settingsVersion
        let current = Self.current(appearance).id
        List(ThemeSpec.palettes(appearance), id: \.id) { palette in
            Button {
                model.set(appearance == .light ? "themeLight" : "themeDark", to: .string(palette.id))
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(palette.displayName).foregroundStyle(.primary)
                            // Below 4.5:1 for body text or coloured roles in places.
                            if palette.lowContrast { Text("Low contrast").font(.caption).foregroundStyle(.secondary) }
                        }
                        Self.sample(palette)
                    }
                    Spacer()
                    if palette.id == current { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(appearance == .light ? "Light Theme" : "Dark Theme")
    }

    /// The palette `light-theme` or `dark-theme` names, Default when unknown.
    static func current(_ appearance: Palette.Appearance) -> Palette {
        let id = UserDefaults.standard.string(forKey: appearance == .light ? "themeLight" : "themeDark") ?? ""
        return ThemeSpec.palette(id, appearance) ?? ThemeSpec.palettes(appearance)[0]
    }

    private static func sample(_ palette: Palette) -> some View {
        func color(_ key: String) -> Color {
            guard let c = palette.colors[key] else { return .primary }
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
        }
        let font = Font.system(.footnote, design: .monospaced)
        func run(_ text: String, _ key: String, bold: Bool = false, underline: Bool = false) -> AttributedString {
            var run = AttributedString(text)
            run.foregroundColor = color(key)
            if bold { run.inlinePresentationIntent = .stronglyEmphasized }
            if underline { run.underlineStyle = .single }
            return run
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(run("* ", "heading-1") + run("TODO ", "todo", bold: true) + run("Plan the trip ", "heading-1", bold: true) + run(":travel:", "tags"))
            Text(run("  SCHEDULED: ", "metadata") + run("<2026-10-20 Tue>", "timestamp"))
            Text(run("  Book via ", "foreground") + run("the site", "link", underline: true) + run(", ", "foreground") + run("~code~", "code"))
            Text(run("** ", "heading-2") + run("DONE ", "done", bold: true) + run("Passport", "heading-2", bold: true))
        }
        .font(font)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color("background"), in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif
