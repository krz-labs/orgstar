#if os(iOS)
import OrgApp
import SwiftUI

/// The sidebar of a regular-width iPad window: the iPhone's tabs, search, and each added folder.
struct AppSidebar: View {
    let workspace: WorkspaceModel
    @Binding var selection: AppTab

    var body: some View {
        List(selection: Binding<AppTab?> { selection } set: { if let new = $0 { selection = new } }) {
            Section {
                Label("Agenda", systemImage: "calendar").tag(AppTab.agenda)
                Label("Search", systemImage: "magnifyingglass").tag(AppTab.search)
            }
            Section("Folders") {
                Label("All Folders", systemImage: "folder").tag(AppTab.folders)
                ForEach(workspace.rootPaths, id: \.self) { root in
                    Label((root as NSString).lastPathComponent, systemImage: "folder").tag(AppTab.folder(root))
                }
            }
            Section {
                Label("Settings", systemImage: "gearshape").tag(AppTab.settings)
            }
        }
        .navigationTitle(Text(verbatim: "orgstar"))
    }
}
#endif
