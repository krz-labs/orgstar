#if os(iOS)
import OrgApp
import SwiftUI
import UIKit

/// An editor's panes in a scene, as a Mac window has them: one to start, split right or below
/// (`app.split-right`, `app.split-below`), each showing a buffer in its own view, with its own
/// caret and scroll, over the buffer every scene shares.
@MainActor
@Observable
final class EditorSplit {
    private(set) var layout: PaneLayout
    private(set) var panes: [PaneID: EditorPane] = [:]
    private(set) var paths: [PaneID: String] = [:]
    var focused: PaneID
    @ObservationIgnored nonisolated(unsafe) private var release: (() -> Void)?

    init(path: String, session: DocumentSession, store: MobileEditorStore) {
        let pane = session.makePane()
        layout = .pane(pane.id)
        focused = pane.id
        panes = [pane.id: pane]
        paths = [pane.id: path]
        release = { [weak self, weak session] in
            guard let self, let session else { return }
            for (id, pane) in panes {
                if let path = paths[id] { store.release(id, path: path) }
                session.closePane(pane)
            }
        }
    }

    deinit {
        guard let release else { return }
        Task { @MainActor in release() }
    }

    var isSplit: Bool { layout.panes.count > 1 }

    /// Runs a pane command; returns why it did nothing, or nil.
    func run(_ id: String, session: DocumentSession, store: MobileEditorStore) -> String? {
        switch id {
        case "app.split-right", "app.split-below":
            guard let path = paths[focused] else { return nil }
            let pane = session.makePane()
            panes[pane.id] = pane
            paths[pane.id] = path
            layout = layout.splitting(focused, axis: id == "app.split-right" ? .horizontal : .vertical, new: pane.id)
        case "app.pane-next":
            focused = layout.next(after: focused)
        case "app.pane-close":
            guard isSplit else { return String(localized: "This is the only pane.", comment: "Close Pane with one pane") }
            close(focused, session: session, store: store)
        case "app.pane-only":
            for id in layout.panes where id != focused { close(id, session: session, store: store) }
        default:
            return nil
        }
        return nil
    }

    /// Sets the first side's share of the split between `before` and `after`, as dragging its
    /// divider does.
    func setFraction(_ fraction: Double, ofSplitBetween before: PaneID, and after: PaneID) {
        layout = layout.settingFraction(fraction, ofSplitBetween: before, and: after)
    }

    private func close(_ id: PaneID, session: DocumentSession, store: MobileEditorStore) {
        guard let rest = layout.removing(id) else { return }
        let next = layout.next(after: id)
        layout = rest
        if let path = paths[id] { store.release(id, path: path) }
        if let pane = panes[id] { session.closePane(pane) }
        panes[id] = nil
        paths[id] = nil
        if focused == id { focused = next }
    }
}

/// The editor route's screen: its panes, with the focused one's title and toolbar.
struct EditorSplitScreen: View {
    let path: String
    let offset: Int?
    let workspace: WorkspaceModel
    let session: DocumentSession
    @State private var split: EditorSplit?
    @State private var message: String?
    @Environment(MobileModel.self) private var model

    var body: some View {
        Group {
            if let split {
                layoutView(split.layout, split: split)
                    .navigationTitle(split.paths[split.focused].map { session.bufferName($0) + (session.dirtyPaths.contains($0) ? " •" : "") } ?? "")
                    .navigationBarTitleDisplayMode(.inline)
                    // The menu bar's editor commands act on the focused pane.
                    .focusedSceneValue(\.editorActions, split.paths[split.focused].flatMap { model.editors.existing($0) }.map(EditorActions.init))
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if split == nil { split = EditorSplit(path: path, session: session, store: model.editors) }
        }
    }

    private func layoutView(_ layout: PaneLayout, split: EditorSplit) -> AnyView {
        switch layout {
        case .pane(let id):
            guard let pane = split.panes[id], let file = split.paths[id] else { return AnyView(EmptyView()) }
            return AnyView(
                EditorScreen(
                    path: file, offset: id == split.layout.panes.first ? offset : nil, workspace: workspace, session: session,
                    givenPane: pane, inSplit: split.isSplit, isFocused: split.focused == id,
                    onFocus: { split.focused = id },
                    onPaneCommand: { split.run($0, session: session, store: model.editors) }
                )
                .id(id)
                .overlay(alignment: .top) {
                    if split.isSplit, split.focused == id { Rectangle().fill(Color.accentColor).frame(height: 2) }
                }
            )
        case .split(let axis, let first, let second, let fraction):
            return AnyView(GeometryReader { geometry in
                let total = axis == .horizontal ? geometry.size.width : geometry.size.height
                let firstSize = max(120, min(max(120, total - 120), total * fraction))
                let divider = PaneDivider(axis: axis, firstSize: firstSize, total: total) { size in
                    split.setFraction(size / max(total, 1), ofSplitBetween: first.panes[first.panes.count - 1], and: second.panes[0])
                }
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        layoutView(first, split: split).frame(width: firstSize)
                        divider
                        layoutView(second, split: split).frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        layoutView(first, split: split).frame(height: firstSize)
                        divider
                        layoutView(second, split: split).frame(maxHeight: .infinity)
                    }
                }
            })
        }
    }
}

/// The line between two panes, with a wider area to drag; dragging resizes the first pane.
private struct PaneDivider: View {
    let axis: PaneLayout.Axis
    let firstSize: CGFloat
    let total: CGFloat
    let resize: (CGFloat) -> Void
    @State private var start: CGFloat?

    var body: some View {
        let horizontal = axis == .horizontal
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            .frame(maxWidth: horizontal ? 1 : .infinity, maxHeight: horizontal ? .infinity : 1)
            .overlay {
                Capsule().fill(Color(uiColor: .tertiaryLabel))
                    .frame(width: horizontal ? 4 : 36, height: horizontal ? 36 : 4)
            }
            .overlay {
                Color.clear
                    .frame(width: horizontal ? 20 : nil, height: horizontal ? nil : 20)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                        let base = start ?? firstSize
                        start = base
                        resize(base + (horizontal ? drag.translation.width : drag.translation.height))
                    }.onEnded { _ in start = nil })
                    .hoverEffect(.highlight)
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Pane Divider"))
            .accessibilityValue(Text(Double(firstSize / max(total, 1)), format: .percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                resize(firstSize + (direction == .increment ? 0.1 : -0.1) * total)
            }
    }
}
#endif
