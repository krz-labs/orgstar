import Foundation

/// MathJax 3.2.2's `tex-svg-full.js`, for PDF export. Only the apps link it, so extensions don't
/// carry the file.
public enum OrgMathJax {
    public static var script: URL? { Bundle.module.url(forResource: "tex-svg-full", withExtension: "js", subdirectory: "MathJax") }
}
