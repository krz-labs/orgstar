import Foundation
import OrgConfig
import OrgPresentation

extension OrgPreferences {
    /// `colors` with the type settings of `[theme]`: font, size, line spacing, heading step.
    public static func theme(_ colors: ThemeSpec, _ defaults: UserDefaults = .standard) -> ThemeSpec {
        var spec = colors
        spec.font = string("themeFont", defaults)
        spec.bodyFont = string("themeBodyFont", defaults)
        spec.fontSize = integer("themeFontSize", defaults)
        spec.lineSpacing = integer("themeLineSpacing", defaults)
        spec.textWidth = integer("themeTextWidth", defaults)
        spec.headingSizeStep = integer("themeHeadingStep", defaults)
        return spec
    }

    /// `pdf-margin`, `pdf-font` and `pdf-page-numbers`.
    @MainActor
    public static func pdfOptions(_ defaults: UserDefaults = .standard) -> PDFExport.Options {
        PDFExport.Options(margin: integer("pdfMargin", defaults), font: string("pdfFont", defaults), pageNumbers: bool("pdfPageNumbers", defaults))
    }

    /// `org-yank-dnd-method`.
    public static func yankDndMethod(_ defaults: UserDefaults = .standard) -> ImageYank.DropMethod {
        ImageYank.DropMethod(rawValue: string("yankDndMethod", defaults)) ?? .ask
    }
}
