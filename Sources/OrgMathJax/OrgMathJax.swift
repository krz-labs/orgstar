import Foundation

/// Scripts that run in a web view. Only the apps link it, so extensions don't carry the files.
public enum OrgMathJax {
    /// MathJax 3.2.2's `tex-svg-full.js`, for PDF export.
    public static var script: URL? { Bundle.module.url(forResource: "tex-svg-full", withExtension: "js", subdirectory: "MathJax") }
    /// Viz.js 3.31.0's `viz-global.js` and mermaid 12.3.0's `mermaid.min.js`, for dot and mermaid blocks.
    public static var viz: URL? { Bundle.module.url(forResource: "viz-global", withExtension: "js", subdirectory: "Diagrams") }
    public static var mermaid: URL? { Bundle.module.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Diagrams") }
}
