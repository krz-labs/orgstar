import OrgIndex
import SwiftUI

/// The graph of the workspace's nodes: a dot for each node, sized by its links, and a line for
/// each link. Dragging moves the picture, pinching and the buttons zoom it, and a click or tap
/// on a node opens it.
public struct RoamGraphView: View {
    /// The whole graph as it is now.
    let load: @MainActor () -> RoamGraph
    /// The node the caret is in, which is marked, and whose links the picture can be limited to.
    let current: String?
    /// Changes when the files or their unsaved text change.
    let version: Int
    let open: (HeadingLocation) -> Void

    @State private var graph = RoamGraph()
    @State private var points: [CGPoint] = []
    @State private var degrees: [Int] = []
    @State private var loaded = false
    @AppStorage("roamGraphLocal") private var local = false
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var drag: CGSize = .zero

    public init(load: @escaping @MainActor () -> RoamGraph, current: String?, version: Int, open: @escaping (HeadingLocation) -> Void) {
        self.load = load
        self.current = current
        self.version = version
        self.open = open
    }

    private struct Key: Equatable {
        var version: Int
        var local: Bool
        var current: String?
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Only the Open Note's Links", isOn: $local)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                Spacer()
                Text("Nodes: \(graph.nodes.count) · Links: \(graph.edges.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if graph.nodes.isEmpty, loaded {
                ContentUnavailableView {
                    Label("No Nodes", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text(local ? "The open note isn't a node, or nothing is open." : "Headings and files with an ID, or notes named as Denote names them, show here.")
                }
            } else {
                picture
            }
        }
        // The neighbours change with the caret's node only while the picture is limited to them.
        .task(id: Key(version: version, local: local, current: local ? current : nil)) { await reload() }
    }

    private var picture: some View {
        GeometryReader { geometry in
            let placed = place(in: geometry.size)
            Canvas { context, _ in
                var lines = Path()
                for edge in graph.edges where edge.a < placed.count && edge.b < placed.count {
                    lines.move(to: placed[edge.a])
                    lines.addLine(to: placed[edge.b])
                }
                context.stroke(lines, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
                let labelled = labels(placed)
                for (index, point) in placed.enumerated() {
                    let radius = radius(index)
                    let dot = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                    let isCurrent = graph.nodes[index].id == current
                    context.fill(dot, with: .color(isCurrent ? .orange : .accentColor))
                    if isCurrent { context.stroke(dot, with: .color(.primary), lineWidth: 2) }
                }
                // Over the dots, so a neighbour doesn't cover a title.
                for index in labelled.sorted() {
                    let text = context.resolve(Text(Self.short(graph.nodes[index].title)).font(.caption).foregroundStyle(.primary))
                    context.draw(text, at: CGPoint(x: placed[index].x, y: placed[index].y + radius(index) + 2), anchor: .top)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                if let index = nearest(to: tap.location, in: placed) { open(graph.nodes[index].location) }
            })
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    offset = CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height)
                    drag = .zero
                })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { value in
                    zoom = min(20, max(0.2, zoom * value.magnification))
                    pinch = 1
                })
            .overlay(alignment: .bottomTrailing) { zoomButtons }
            .accessibilityRepresentation {
                List(graph.nodes) { node in
                    Button(node.title.isEmpty ? "(untitled)" : node.title) { open(node.location) }
                }
            }
        }
    }

    private var zoomButtons: some View {
        HStack(spacing: 4) {
            Button { zoom = max(0.2, zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel("Zoom Out")
            Button {
                zoom = 1
                offset = .zero
            } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .accessibilityLabel("Zoom to Fit")
            Button { zoom = min(20, zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel("Zoom In")
        }
        .buttonStyle(.bordered)
        .padding(10)
    }

    private func reload() async {
        let whole = load()
        let shown = local ? (current.map { whole.neighbourhood(of: $0) } ?? RoamGraph()) : whole
        let laidOut = await Task.detached { shown.layout() }.value
        guard !Task.isCancelled else { return }
        (graph, points, degrees, loaded) = (shown, laidOut, shown.degrees, true)
    }

    /// The nodes' places in a view of `size`: the layout fitted inside it, then zoomed and moved.
    private func place(in size: CGSize) -> [CGPoint] {
        guard !points.isEmpty, points.count == graph.nodes.count else { return [] }
        let xs = points.map(\.x), ys = points.map(\.y)
        let (minX, maxX, minY, maxY) = (xs.min() ?? 0, xs.max() ?? 0, ys.min() ?? 0, ys.max() ?? 0)
        let margin: CGFloat = 48
        let fit = min((size.width - margin * 2) / max(maxX - minX, 1), (size.height - margin * 2) / max(maxY - minY, 1))
        let scale = max(fit, 1) * zoom * pinch
        let centre = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        return points.map {
            CGPoint(x: size.width / 2 + ($0.x - centre.x) * scale + offset.width + drag.width,
                    y: size.height / 2 + ($0.y - centre.y) * scale + offset.height + drag.height)
        }
    }

    private func radius(_ index: Int) -> CGFloat {
        4 + min(8, CGFloat(index < degrees.count ? degrees[index] : 0).squareRoot() * 2)
    }

    /// The nodes whose titles are drawn: all of them while they have room, else the node the
    /// caret is in and those with the most links, none closer than a title's width to another.
    private func labels(_ placed: [CGPoint]) -> Set<Int> {
        var shown: [Int] = []
        let order = placed.indices.sorted { a, b in
            let (first, second) = (graph.nodes[a].id == current, graph.nodes[b].id == current)
            if first != second { return first }
            return degrees[a] != degrees[b] ? degrees[a] > degrees[b] : a < b
        }
        for index in order where shown.allSatisfy({ abs(placed[$0].x - placed[index].x) > 90 || abs(placed[$0].y - placed[index].y) > 22 }) {
            shown.append(index)
        }
        return Set(shown)
    }

    private func nearest(to point: CGPoint, in placed: [CGPoint]) -> Int? {
        let near = placed.enumerated().map { (index: $0.offset, distance: hypot($0.element.x - point.x, $0.element.y - point.y)) }
            .min { $0.distance < $1.distance }
        guard let near, near.distance <= max(22, radius(near.index) + 8) else { return nil }
        return near.index
    }

    static func short(_ title: String) -> String {
        let title = title.isEmpty ? String(localized: "(untitled)") : title
        return title.count > 24 ? title.prefix(23) + "…" : title
    }
}
