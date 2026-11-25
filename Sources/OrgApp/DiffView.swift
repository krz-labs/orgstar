import OrgDocument
import SwiftUI

/// Lines removed and added between two versions, with a few lines of context around each change.
public struct DiffView: View {
    let lines: [DiffLine]
    var context = 3
    let removedColor: Color
    let addedColor: Color
    let foreground: Color?
    let background: Color?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @ScaledMetric(relativeTo: .caption) private var wordWidth: CGFloat = 64

    /// `removed` and `added` tint the changed lines; `foreground` and `background` default to
    /// the system's text colours.
    public init(old: String, new: String, removed: Color = .red, added: Color = .green, foreground: Color? = nil, background: Color? = nil) {
        lines = lineDiff(old: old, new: new)
        removedColor = removed
        addedColor = added
        self.foreground = foreground
        self.background = background
    }

    /// Lines to show, nil standing for a run of unchanged lines left out.
    private var shown: [DiffLine?] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for i in changed { keep.formUnion(max(0, i - context)...min(lines.count - 1, i + context)) }
        var out: [DiffLine?] = []
        var skipped = false
        for i in lines.indices {
            if keep.contains(i) {
                out.append(lines[i])
                skipped = false
            } else if !skipped {
                out.append(nil)
                skipped = true
            }
        }
        return out
    }

    public var body: some View {
        let shown = shown
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                if shown.isEmpty { Text("No differences").foregroundStyle(.secondary).padding(8) }
                ForEach(shown.indices, id: \.self) { i in
                    if let line = shown[i] {
                        row(line)
                    } else {
                        Text("⋯").foregroundStyle(.secondary)
                    }
                }
            }
            #if os(macOS)
            .font(.system(.callout, design: .monospaced))
            #else
            .font(.system(.footnote, design: .monospaced))
            #endif
            .foregroundStyle(foreground ?? .primary)
            .textSelection(.enabled)
            .padding(8)
        }
        .defaultScrollAnchor(.topLeading)
        #if os(macOS)
        .background(background ?? Color(nsColor: .textBackgroundColor))
        #else
        .background(background ?? Color(uiColor: .secondarySystemBackground))
        #endif
    }

    private func row(_ line: DiffLine) -> some View {
        let text = line.text.trimmingCharacters(in: .newlines)
        return HStack(spacing: 0) {
            // Differentiate Without Colour: the change in words before the line.
            if withoutColor {
                Text(word(line.kind) ?? "")
                    .font(.caption.weight(.semibold))
                    .frame(width: wordWidth, alignment: .leading)
            }
            Text(prefix(line.kind) + text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint(line.kind))
        .overlay(alignment: .leading) {
            // Increase Contrast: a solid bar at the edge of each changed line.
            if contrast == .increased, line.kind != .same {
                Rectangle().fill(line.kind == .removed ? removedColor : addedColor).frame(width: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word(line.kind).map { "\($0): \(text)" } ?? text)
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .same: "  "
        case .removed: "- "
        case .added: "+ "
        }
    }

    private func word(_ kind: DiffLine.Kind) -> String? {
        switch kind {
        case .same: nil
        case .removed: String(localized: "diff.removed", defaultValue: "Removed", comment: "A line removed, in a comparison of two versions")
        case .added: String(localized: "diff.added", defaultValue: "Added", comment: "A line added, in a comparison of two versions")
        }
    }

    private func tint(_ kind: DiffLine.Kind) -> Color {
        let strength = contrast == .increased ? 0.35 : 0.18
        return switch kind {
        case .same: .clear
        case .removed: removedColor.opacity(strength)
        case .added: addedColor.opacity(strength)
        }
    }
}
