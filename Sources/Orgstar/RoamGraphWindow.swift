import OrgApp
import OrgCore
import OrgIndex
import SwiftUI

/// Window ▸ Graph: the workspace's nodes and links; a click on a node shows it in the main window.
struct RoamGraphWindow: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    @Environment(\.openWindow) private var openWindow

    private var current: String? {
        guard let path = session.path, let tree = session.document?.tree else { return nil }
        return RoamGraph.current(tree: tree, at: commands.selection.location, path: path, denote: OrgPreferences.usesDenote())
    }

    var body: some View {
        RoamGraphView(
            load: { workspace.roamGraph(overlay: workspace.overlay(session.openDocuments)) },
            current: current,
            version: session.editVersion &+ workspace.files.count &+ (workspace.changedFile?.version ?? 0)
        ) { location in
            if !commands.mainWindowOpen { openWindow(id: "main") }
            commands.jump(path: location.path, offset: location.start)
        }
        .frame(minWidth: 420, minHeight: 320)
        .navigationTitle("Node Graph")
    }
}
