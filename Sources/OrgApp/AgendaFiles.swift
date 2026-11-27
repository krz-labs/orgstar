import Foundation
import OrgConfig

extension WorkspaceModel {
    /// `(org-agenda-files)`: `list` resolved, or when it is empty the org files at the top of
    /// each folder (or below it, with `includeSubfolders`), by path, as Emacs lists a
    /// directory.
    public func agendaFilePaths(list: [String] = OrgPreferences.agendaFiles(), includeSubfolders: Bool = OrgPreferences.agendaSubfolders()) -> [String] {
        if !list.isEmpty { return AgendaFiles.resolve(list, base: rootPaths.first) }
        return files
            // Dotfiles stay out, as `org-agenda-file-regexp` leaves them out.
            .filter { $0.kind == .org && !$0.name.hasPrefix(".") && (includeSubfolders || !$0.relativePath.contains("/")) }
            .map(\.path)
            .sorted()
    }
}
