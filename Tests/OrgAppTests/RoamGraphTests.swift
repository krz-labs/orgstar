import CoreGraphics
import Foundation
import OrgCore
@testable import OrgIndex
import Testing
@testable import OrgApp

struct RoamGraphTests {
    private func store(_ files: [String: String]) throws -> IndexStore {
        let store = try IndexStore()
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            try store.write(FileRecord(path: path, root: "/notes", kind: .org, bytes: Array(text.utf8), mtime: 1, settings: IndexSettings()))
        }
        return store
    }

    private func graph(_ store: IndexStore, denote: Bool = false) throws -> RoamGraph {
        RoamGraph(nodes: denote ? try store.denoteNodes() : try store.nodes(), links: try store.links(),
                  sections: try store.nodeSections(), denote: denote)
    }

    private func pairs(_ graph: RoamGraph) -> Set<[String]> {
        Set(graph.edges.map { [graph.nodes[$0.a].title, graph.nodes[$0.b].title].sorted() })
    }

    @Test func linksJoinTheNodesTheyAreWrittenInAndName() throws {
        let store = try store([
            "/notes/a.org": ":PROPERTIES:\n:ID: a\n:END:\n#+TITLE: Alpha\nSee [[id:b]] and [[id:missing]] and [[https://x.org]].\n",
            "/notes/b.org": ":PROPERTIES:\n:ID: b\n:END:\n#+TITLE: Beta\nBack to [[id:a]], and [[id:b][myself]].\n"
                + "* Outer\n:PROPERTIES:\n:ID: outer\n:END:\n** Plain\n[[id:c]]\n** Inner\n:PROPERTIES:\n:ID: inner\n:END:\n[[id:a]]\n* After\n[[id:c]]\n",
            "/notes/c.org": ":PROPERTIES:\n:ID: c\n:END:\n#+TITLE: Gamma\n",
            "/notes/loose.org": "No ID here, so [[id:a]] is written in no node.\n",
        ])
        let graph = try graph(store)
        #expect(Set(graph.nodes.map(\.title)) == ["Alpha", "Beta", "Gamma", "Outer", "Inner"])
        // Both directions between Alpha and Beta are one edge. The link under Plain belongs to
        // Outer, the heading with an ID around it; the one under After to the file, Beta.
        #expect(pairs(graph) == [["Alpha", "Beta"], ["Gamma", "Outer"], ["Alpha", "Inner"], ["Beta", "Gamma"]])
        #expect(graph.degrees.reduce(0, +) == 8)
    }

    @Test func denoteLinksJoinNotesByIdentifier() throws {
        let store = try store([
            "/notes/20240101T100000--first__a.org": "#+title: First\n[[denote:20240102T100000][second]] and [[id:x]]\n* H\n[[denote:20240102T100000::*There]]\n",
            "/notes/20240102T100000--second.org": "#+title: Second\n",
            "/notes/plain.org": "[[denote:20240101T100000]]\n",
        ])
        let graph = try graph(store, denote: true)
        #expect(graph.nodes.map(\.title) == ["First", "Second"])
        #expect(pairs(graph) == [["First", "Second"]])
    }

    @Test func neighbourhoodKeepsANodeAndItsNeighbours() {
        func node(_ id: String) -> IndexStore.Node { IndexStore.Node(id: id, title: id, location: .file("/n/\(id).org", contentHash: "")) }
        func link(_ from: String, _ to: String) -> (source: HeadingLocation, target: String) { (.file("/n/\(from).org", contentHash: ""), "id:" + to) }
        let graph = RoamGraph(nodes: ["a", "b", "c", "d", "e"].map(node), links: [link("a", "b"), link("b", "c"), link("c", "d"), link("a", "c")])
        let near = graph.neighbourhood(of: "b")
        #expect(near.nodes.map(\.id) == ["a", "b", "c"])
        #expect(Set(near.edges.map { [near.nodes[$0.a].id, near.nodes[$0.b].id] }) == [["a", "b"], ["b", "c"], ["a", "c"]])
        #expect(graph.neighbourhood(of: "e").nodes.map(\.id) == ["e"])
        #expect(graph.neighbourhood(of: "nope").nodes.isEmpty)
    }

    @Test func currentNodeIsTheInnermostHeadingWithAnIDElseTheFile() {
        let text = ":PROPERTIES:\n:ID: file\n:END:\nTop.\n* Outer\n:PROPERTIES:\n:ID: outer\n:END:\n** Plain\nHere.\n* Other\nThere.\n"
        let tree = OrgParser.parse(text)
        let ns = text as NSString
        #expect(RoamGraph.current(tree: tree, at: ns.range(of: "Here.").location, path: "/n/a.org", denote: false) == "outer")
        #expect(RoamGraph.current(tree: tree, at: ns.range(of: "There.").location, path: "/n/a.org", denote: false) == "file")
        #expect(RoamGraph.current(tree: tree, at: 0, path: "/n/20240101T100000--a.org", denote: true) == "20240101T100000")
    }

    @Test func layoutSeparatesNodesAndKeepsNeighboursClose() {
        func node(_ id: Int) -> IndexStore.Node { IndexStore.Node(id: "\(id)", title: "\(id)", location: .file("/n/\(id).org", contentHash: "")) }
        func link(_ from: Int, _ to: Int) -> (source: HeadingLocation, target: String) { (.file("/n/\(from).org", contentHash: ""), "id:\(to)") }
        // Two chains of ten with nothing between them, and five nodes with no links.
        let links = (0..<9).map { link($0, $0 + 1) } + (10..<19).map { link($0, $0 + 1) }
        let graph = RoamGraph(nodes: (0..<25).map(node), links: links)
        let points = graph.layout()
        #expect(points == graph.layout())
        func distance(_ a: Int, _ b: Int) -> Double { Double(hypot(points[a].x - points[b].x, points[a].y - points[b].y)) }
        var nearest = Double.infinity
        for a in 0..<25 { for b in (a + 1)..<25 { nearest = min(nearest, distance(a, b)) } }
        #expect(nearest > 0.2)
        let linked = graph.edges.map { distance($0.a, $0.b) }.reduce(0, +) / Double(graph.edges.count)
        #expect(linked < distance(0, 9))
        #expect(points.allSatisfy { abs($0.x) < 40 && abs($0.y) < 40 && $0.x.isFinite && $0.y.isFinite })
        #expect(RoamGraph().layout().isEmpty)
    }
}
