import CoreGraphics
import Foundation
import OrgCore
import OrgIndex

/// org-roam's nodes, or Denote's notes, and the links between them.
public struct RoamGraph: Sendable, Equatable {
    public struct Node: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let location: HeadingLocation
    }

    /// A link from one node to another, as indices into `nodes`, the lower one first.
    public struct Edge: Sendable, Hashable {
        public let a: Int
        public let b: Int
    }

    public let nodes: [Node]
    public let edges: [Edge]

    public init(nodes: [Node] = [], edges: [Edge] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    /// The graph of `nodes`: an edge for each `id:` link, or `denote:` link with `denote`,
    /// from the node it is written in to the node it names. A link is written in the innermost
    /// heading with an ID around it (`sections`), else in its file's node. Links between the
    /// same two nodes make one edge; links to a node from itself and to unknown nodes make none.
    public init(
        nodes: [IndexStore.Node], links: [(source: HeadingLocation, target: String)],
        sections: [String: [(id: String, range: Range<Int>)]] = [:], denote: Bool = false
    ) {
        var index: [String: Int] = [:]
        var unique: [Node] = []
        for node in nodes where index[node.id] == nil {
            index[node.id] = unique.count
            unique.append(Node(id: node.id, title: node.title, location: node.location))
        }
        var fileNode: [String: Int] = [:]
        for (position, node) in unique.enumerated() where node.location.ordinal == HeadingLocation.fileOrdinal {
            fileNode[node.location.path] = position
        }
        func source(_ location: HeadingLocation) -> Int? {
            if !denote, location.ordinal != HeadingLocation.fileOrdinal,
               let inner = sections[location.path]?.filter({ $0.range.contains(location.start) }).max(by: { $0.range.lowerBound < $1.range.lowerBound }),
               let position = index[inner.id] {
                return position
            }
            return fileNode[location.path]
        }
        func target(_ link: String) -> Int? {
            let prefix = denote ? "denote:" : "id:"
            guard link.lowercased().hasPrefix(prefix) else { return nil }
            return index[link.dropFirst(prefix.count).components(separatedBy: "::")[0]]
        }
        var seen = Set<Edge>()
        var edges: [Edge] = []
        for link in links {
            guard let from = source(link.source), let to = target(link.target), from != to else { continue }
            let edge = Edge(a: min(from, to), b: max(from, to))
            if seen.insert(edge).inserted { edges.append(edge) }
        }
        self.init(nodes: unique, edges: edges)
    }

    /// How many edges each node has.
    public var degrees: [Int] {
        var degrees = [Int](repeating: 0, count: nodes.count)
        for edge in edges {
            degrees[edge.a] += 1
            degrees[edge.b] += 1
        }
        return degrees
    }

    /// The node `id` and the nodes it shares an edge with; empty when there is no such node.
    public func neighbourhood(of id: String) -> RoamGraph {
        guard let centre = nodes.firstIndex(where: { $0.id == id }) else { return RoamGraph() }
        var kept = [centre]
        for edge in edges where edge.a == centre || edge.b == centre { kept.append(edge.a == centre ? edge.b : edge.a) }
        kept.sort()
        let position = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
        return RoamGraph(nodes: kept.map { nodes[$0] }, edges: edges.compactMap { edge in
            guard let a = position[edge.a], let b = position[edge.b] else { return nil }
            return Edge(a: a, b: b)
        })
    }

    /// The node the caret is in: the innermost heading with an ID around `offset`, else the
    /// file's ID; with `denote`, the identifier in the file's name.
    public static func current(tree: OrgTree, at offset: Int, path: String, denote: Bool) -> String? {
        if denote { return Denote.identifier(ofFile: path) }
        let model = DocumentModel(tree: tree)
        let inner = model.headings.filter { $0.id != nil && $0.sectionRange.contains(offset) }.max { $0.sectionRange.lowerBound < $1.sectionRange.lowerBound }
        return inner?.id ?? model.property("ID", of: nil)?.value
    }

    /// A place for each node, by Fruchterman and Reingold's force-directed method: nodes push
    /// each other apart, edges pull theirs together, and all are held around the origin. The
    /// same graph gives the same picture. About one unit lies between neighbours. Nodes more
    /// than `reach` units apart don't push, so parts with no link between them settle beside
    /// each other instead of far away.
    static let reach = 4.0

    public func layout(iterations: Int? = nil) -> [CGPoint] {
        let count = nodes.count
        guard count > 1 else { return [CGPoint](repeating: .zero, count: count) }
        // Started on a spiral, which has no two nodes in one place.
        var x = [Double](repeating: 0, count: count), y = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let radius = (Double(i) + 0.5).squareRoot(), angle = Double(i) * 2.399963229728653
            x[i] = radius * cos(angle)
            y[i] = radius * sin(angle)
        }
        // Each round compares every pair, so large graphs get fewer rounds.
        let rounds = iterations ?? max(30, min(300, 40_000_000 / (count * count)))
        var temperature = Double(count).squareRoot()
        let cooling = temperature / Double(rounds + 1)
        var dx = [Double](repeating: 0, count: count), dy = [Double](repeating: 0, count: count)
        for _ in 0..<rounds {
            for i in 0..<count {
                // Gravity, so that parts with no edge between them stay in view.
                dx[i] = -x[i] * 0.05
                dy[i] = -y[i] * 0.05
            }
            for i in 0..<count {
                for j in (i + 1)..<count {
                    let ex = x[i] - x[j], ey = y[i] - y[j]
                    let squared = max(ex * ex + ey * ey, 1e-4)
                    if squared > Self.reach * Self.reach { continue }
                    let fx = ex / squared, fy = ey / squared
                    dx[i] += fx
                    dy[i] += fy
                    dx[j] -= fx
                    dy[j] -= fy
                }
            }
            for edge in edges {
                let ex = x[edge.a] - x[edge.b], ey = y[edge.a] - y[edge.b]
                let distance = (ex * ex + ey * ey).squareRoot()
                let fx = ex * distance, fy = ey * distance
                dx[edge.a] -= fx
                dy[edge.a] -= fy
                dx[edge.b] += fx
                dy[edge.b] += fy
            }
            for i in 0..<count {
                let length = max((dx[i] * dx[i] + dy[i] * dy[i]).squareRoot(), 1e-9)
                let step = min(length, temperature)
                x[i] += dx[i] / length * step
                y[i] += dy[i] / length * step
            }
            temperature -= cooling
        }
        return (0..<count).map { CGPoint(x: x[$0], y: y[$0]) }
    }
}

extension WorkspaceModel {
    /// The graph of the workspace's nodes, with unsaved buffers' in place of their files'.
    public func roamGraph(overlay: [String: FileRecord] = [:], denote: Bool = OrgPreferences.usesDenote()) -> RoamGraph {
        RoamGraph(nodes: nodes(overlay: overlay, denote: denote), links: (try? index.links(overlay: overlay)) ?? [],
                  sections: denote ? [:] : (try? index.nodeSections(overlay: overlay)) ?? [:], denote: denote)
    }
}
