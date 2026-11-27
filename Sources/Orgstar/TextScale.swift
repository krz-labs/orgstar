import AppKit
import OrgPresentation
import SwiftUI

extension EnvironmentValues {
    /// Settings ▸ Appearance ▸ Size over its default, never below 1: how much larger than the
    /// system's sizes the agenda and sidebars show text. macOS has no Dynamic Type to do this.
    @Entry var textScale: CGFloat = 1
}

extension Font {
    /// `style` at the system's size for it times `scale`.
    static func scaled(_ style: Font.TextStyle, _ scale: CGFloat) -> Font {
        .system(size: NSFont.preferredFont(forTextStyle: style.appKit).pointSize * scale)
    }
}

extension Font.TextStyle {
    fileprivate var appKit: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

private struct TextScaled: ViewModifier {
    @AppStorage("themeFontSize") private var size = ThemeSpec.default.fontSize

    func body(content: Content) -> some View {
        content.environment(\.textScale, max(1, CGFloat(size) / CGFloat(ThemeSpec.default.fontSize)))
    }
}

extension View {
    /// Sets `textScale` from Settings ▸ Appearance ▸ Size.
    func textScaled() -> some View { modifier(TextScaled()) }
}
