import Foundation
import ImageIO
import OrgCore
import OrgMathJax
import Testing
@testable import OrgApp

@MainActor
struct DiagramBlocksTests {
    init() {
        DiagramBlocks.vizURL = OrgMathJax.viz
        DiagramBlocks.mermaidURL = OrgMathJax.mermaid
    }

    private func size(_ png: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    @Test func drawsDotAsSVG() async throws {
        let data = try await DiagramBlocks.draw(language: "dot", source: "digraph { alpha -> beta }", cmdline: nil, format: "svg")
        let svg = try #require(String(data: data, encoding: .utf8))
        #expect(svg.contains("<svg") && svg.contains("alpha") && svg.contains("beta"))
    }

    @Test func drawsDotAsPNGWhenTheFileHasNoExtension() async throws {
        let data = try await DiagramBlocks.draw(language: "dot", source: "digraph { alpha -> beta }", cmdline: "-Kneato", format: "")
        let size = try size(data)
        #expect(size.width > 20 && size.height > 20)
    }

    @Test func reportsDotErrors() async throws {
        do {
            _ = try await DiagramBlocks.draw(language: "dot", source: "digraph { alpha -> }", cmdline: nil, format: "svg")
            Issue.record("drew a graph with a syntax error")
        } catch Babel.Failure.message(let message) {
            #expect(message.contains("syntax error"))
        }
    }

    @Test func drawsMermaidAsSVGWithoutHTMLLabels() async throws {
        let data = try await DiagramBlocks.draw(language: "mermaid", source: "graph TD\n  Alpha --> Beta", cmdline: "-t dark", format: "svg")
        let svg = try #require(String(data: data, encoding: .utf8))
        #expect(svg.contains("<svg") && svg.contains("Alpha") && !svg.contains("foreignObject"))
    }

    @Test func drawsMermaidAsPNG() async throws {
        let data = try await DiagramBlocks.draw(language: "mermaid", source: "sequenceDiagram\n  Alice->>Bob: Hello", cmdline: nil, format: "png")
        let size = try size(data)
        #expect(size.width > 50 && size.width <= DiagramBlocks.pageWidth && size.height > 50)
    }

    @Test func reportsMermaidErrors() async throws {
        do {
            _ = try await DiagramBlocks.draw(language: "mermaid", source: "graph TD\n  A -->", cmdline: nil, format: "svg")
            Issue.record("drew a diagram with a syntax error")
        } catch Babel.Failure.message(let message) {
            #expect(message.contains("Parse error"))
        }
    }

    @Test func refusesOtherFormatsAndCommandLines() async throws {
        await #expect(throws: Babel.Failure.self) {
            _ = try await DiagramBlocks.draw(language: "dot", source: "digraph { a }", cmdline: nil, format: "pdf")
        }
        #expect(DiagramBlocks.Options(language: "dot", cmdline: "-Kcirco")?.engine == "circo")
        #expect(DiagramBlocks.Options(language: "dot", cmdline: "-Gdpi=300") == nil)
        #expect(DiagramBlocks.Options(language: "mermaid", cmdline: "--theme forest -b transparent")?.background == "transparent")
        #expect(DiagramBlocks.Options(language: "mermaid", cmdline: "-w 1200") == nil)
    }

    @Test func writesTheFileADotBlockNames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-diagram-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = "#+begin_src dot :file graph.svg\ndigraph { alpha -> beta }\n#+end_src\n"
        let job = try Babel.plan(EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])).get()
        #expect(job.diagram?.file == "graph.svg")
        let output = try #require(try await DiagramBlocks.run(job, directory: folder))
        #expect(output.status == 0)
        #expect(try String(contentsOf: folder.appendingPathComponent("graph.svg"), encoding: .utf8).contains("alpha"))
    }
}
