#if canImport(WebKit)
import Foundation
import OrgCore
import WebKit

/// dot and mermaid blocks drawn in a web view, for builds that can't start `dot` or `mmdc`: dot
/// with Viz.js (Graphviz as WebAssembly), mermaid with mermaid.js. They write SVG and PNG; other
/// formats and most of `:cmdline` are refused. Mermaid labels are SVG text rather than HTML, so
/// the SVG shows outside a browser and can be drawn into the PNG.
public enum DiagramBlocks {
    /// `viz-global.js` and `mermaid.min.js`, which the app sets from `OrgMathJax`.
    nonisolated(unsafe) public static var vizURL: URL?
    nonisolated(unsafe) public static var mermaidURL: URL?

    /// The width of `mmdc`'s page, which a wider mermaid diagram is scaled down to.
    static let pageWidth = 800

    /// Draws `job` into its `:file` when it is a dot or mermaid block, in `directory` or its
    /// `:dir`; nil for other jobs.
    @MainActor
    public static func run(_ job: BabelJob, directory: URL) async throws -> BabelOutput? {
        guard let diagram = job.diagram else { return nil }
        let folder = job.directory.map { URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL } ?? directory
        let target = diagram.file.hasPrefix("/") ? URL(fileURLWithPath: diagram.file) : folder.appendingPathComponent(diagram.file)
        let data = try await draw(language: job.language, source: diagram.source, cmdline: diagram.cmdline, format: target.pathExtension)
        do {
            try data.write(to: target)
        } catch {
            throw Babel.Failure.message(error.localizedDescription)
        }
        return BabelOutput(stdout: "")
    }

    /// What `:cmdline` asks for.
    struct Options: Equatable {
        /// dot's `-K`.
        var engine = "dot"
        /// mmdc's `-t` and `-b`.
        var theme = "default"
        var background = "white"

        /// `-Kengine` for dot; `-t theme` and `-b color` for mermaid, in their long forms too.
        /// Nil for anything else.
        init?(language: String, cmdline: String?) {
            var words = (cmdline ?? "").split(whereSeparator: \.isWhitespace).map(String.init)[...]
            while let word = words.popFirst() {
                if language == "dot", word.hasPrefix("-K"), word.count > 2 {
                    engine = String(word.dropFirst(2))
                } else if language == "mermaid", ["-t", "--theme"].contains(word), let value = words.popFirst() {
                    theme = value
                } else if language == "mermaid", ["-b", "--backgroundColor"].contains(word), let value = words.popFirst() {
                    background = value
                } else {
                    return nil
                }
            }
        }
    }

    /// The picture as SVG text or PNG data; `format` is the file's extension, PNG when empty.
    @MainActor
    static func draw(language: String, source: String, cmdline: String?, format: String) async throws -> Data {
        let format = format.isEmpty ? "png" : format.lowercased()
        guard ["svg", "png"].contains(format) else {
            throw Babel.Failure.message(String(localized: "\(language) blocks draw only SVG and PNG files in this version of orgstar."))
        }
        guard let options = Options(language: language, cmdline: cmdline) else {
            throw Babel.Failure.message(String(localized: "\(language) blocks with this :cmdline don't run in this version of orgstar."))
        }
        guard let library = language == "dot" ? vizURL : mermaidURL, let script = try? String(contentsOf: library, encoding: .utf8) else {
            throw Babel.Failure.message("The \(language) library is missing from the app.")
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: pageWidth, height: 600), configuration: configuration)
        let loader = Loader()
        webView.navigationDelegate = loader
        // Viz.js resolves its own name against the page's address; nothing is fetched.
        webView.loadHTMLString("<!doctype html><html><body style=\"margin:0\"></body></html>", baseURL: URL(string: "https://localhost/"))
        try await loader.loaded()
        do {
            let result = try await webView.callAsyncJavaScript(
                (language == "dot" ? dot : mermaid) + raster,
                arguments: ["source": source, "format": format, "engine": options.engine, "theme": options.theme, "background": options.background],
                contentWorld: .page
            )
            guard let text = result as? String else { throw Babel.Failure.message("The \(language) block drew nothing.") }
            if format == "svg" { return Data(text.utf8) }
            guard let png = Data(base64Encoded: text) else { throw Babel.Failure.message("The \(language) block drew nothing.") }
            return png
        } catch let error as NSError where error.domain == WKErrorDomain {
            throw Babel.Failure.message((error.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription)
        }
    }

    /// Leaves the SVG in `svg`.
    private static let dot = """
        const viz = await Viz.instance();
        const result = viz.render(source, { format: "svg", engine: engine });
        if (result.status !== "success") {
            throw new Error(result.errors.map(error => error.message).join("\\n") || "dot failed");
        }
        const svg = result.output;

        """

    private static let mermaid = """
        mermaid.initialize({ startOnLoad: false, theme: theme, htmlLabels: false, flowchart: { htmlLabels: false } });
        await mermaid.parse(source);
        const svg = (await mermaid.render("my-svg", source)).svg;

        """

    /// Returns `svg`, or for PNG its picture at the size it has on the page, as base64.
    private static let raster = """
        if (format === "svg") { return svg; }
        const holder = document.createElement("div");
        holder.innerHTML = svg;
        document.body.replaceChildren(holder);
        const element = holder.querySelector("svg");
        const box = element.getBoundingClientRect();
        const width = Math.max(1, Math.ceil(box.width)), height = Math.max(1, Math.ceil(box.height));
        element.setAttribute("width", width);
        element.setAttribute("height", height);
        element.removeAttribute("style");
        const image = new Image();
        image.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(new XMLSerializer().serializeToString(element));
        await image.decode();
        const canvas = document.createElement("canvas");
        canvas.width = width;
        canvas.height = height;
        const context = canvas.getContext("2d");
        if (background !== "transparent") {
            context.fillStyle = background;
            context.fillRect(0, 0, width, height);
        }
        context.drawImage(image, 0, 0, width, height);
        return canvas.toDataURL("image/png").split(",")[1];
        """

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?

        func loaded() async throws {
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        private func finish(_ result: Result<Void, Error>) {
            if let continuation {
                continuation.resume(with: result)
                self.continuation = nil
            } else {
                self.result = result
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    }
}
#endif
