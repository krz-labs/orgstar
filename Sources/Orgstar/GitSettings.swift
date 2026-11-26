#if !APPSTORE
import OrgApp
import OrgPrograms
import SwiftUI

/// Settings ▸ Git: automatic commits for each sidebar folder that is a git repository.
struct GitSettingsForm: View {
    let workspace: WorkspaceModel?
    @State private var settings = GitFolderSettings.shared
    @State private var gitInstalled = true

    var body: some View {
        Form {
            Section {
                let roots = workspace?.rootPaths ?? []
                if roots.isEmpty {
                    Text("Add a folder to the sidebar to commit its changes automatically.", tableName: "DeveloperID").foregroundStyle(.secondary)
                }
                ForEach(roots, id: \.self) { root in
                    let name = (root as NSString).lastPathComponent
                    if GitBranch.current(for: (root as NSString).appendingPathComponent("x")) == nil {
                        LabeledContent {
                            Text("Not a git repository", tableName: "DeveloperID").foregroundStyle(.secondary)
                        } label: {
                            Text(verbatim: name).help(root)
                        }
                    } else {
                        Picker(selection: Binding(get: { settings.mode(for: root) }, set: { settings.set($0, for: root) })) {
                            Text("Off", tableName: "DeveloperID").tag(GitFolderSettings.Mode.off)
                            Text("Commit", tableName: "DeveloperID").tag(GitFolderSettings.Mode.commit)
                            Text("Commit, Pull and Push", tableName: "DeveloperID").tag(GitFolderSettings.Mode.sync)
                        } label: {
                            Text(verbatim: name).help(root)
                        }
                        .disabled(!gitInstalled)
                    }
                }
            } header: {
                Text("Commit changes automatically", tableName: "DeveloperID")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !gitInstalled {
                        Text("git isn't installed. Install the Xcode command line tools or git from Homebrew.", tableName: "DeveloperID").settingsFooter()
                    }
                    Text("A minute after the last save in a folder, and when orgstar quits, orgstar commits the files it saved there, and only those. Commit, Pull and Push pulls with --ff-only first and pushes after the commit. orgstar never merges or resolves a conflict, and doesn't commit while a merge, rebase or cherry-pick is in progress.", tableName: "DeveloperID").settingsFooter()
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 330)
        .task { gitInstalled = Git.find() != nil }
    }
}
#endif
