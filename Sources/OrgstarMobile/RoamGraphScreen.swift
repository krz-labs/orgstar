#if os(iOS)
import OrgApp
import OrgCore
import OrgIndex
import SwiftUI

/// The workspace's nodes and links, as the Mac's Graph window draws them; a tap on a node
/// opens it.
struct RoamGraphScreen: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let path: String
    let caret: Int
    let open: (HeadingLocation) -> Void
    @Environment(\.dismiss) private var dismiss

    private var current: String? {
        session.document(of: path).flatMap { RoamGraph.current(tree: $0.tree, at: caret, path: path, denote: OrgPreferences.usesDenote()) }
    }

    var body: some View {
        NavigationStack {
            RoamGraphView(load: { workspace.roamGraph(overlay: workspace.overlay(session.openDocuments)) }, current: current, version: 0) { location in
                dismiss()
                open(location)
            }
            .navigationTitle("Node Graph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
