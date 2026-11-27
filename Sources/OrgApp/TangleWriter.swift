import Foundation
import OrgConfig
import OrgCore

extension DocumentSession {
    /// The files `tangle` would write.
    public func tangleFiles(_ scope: Tangle.Scope) -> [String] {
        guard let path, let document, case .success(let output) = Tangle.run(text: document.text, path: path, scope: scope, tree: document.tree) else { return [] }
        return output.files.map(\.path)
    }

    /// Tangles the open file: its text as it is now, written beside it.
    public func tangle(_ scope: Tangle.Scope) -> String {
        guard let path, let document else { return "No file is open" }
        switch Tangle.run(text: document.text, path: path, scope: scope, tree: document.tree) {
        case .failure(.message(let message)):
            return message
        case .success(let output):
            do {
                try TangleWriter.write(output, source: path)
                return TangleWriter.message(output, source: path)
            } catch {
                return error.message
            }
        }
    }
}
