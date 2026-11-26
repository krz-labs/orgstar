import OrgApp
import OrgCore
import SwiftUI

/// New File from Template…: a template from `snippets.toml`, a folder and a name. The file is
/// created as New File creates one and opens with the template expanded in it.
struct TemplateSheet: View {
    let workspace: WorkspaceModel
    /// The folder of the file shown, which the folder menu starts on.
    let folder: String?
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var template = ""
    @State private var chosenFolder = ""
    @State private var name = ""
    @State private var failure: String?

    var body: some View {
        let templates = SnippetLibrary.shared.templates
        let folders = SnippetLibrary.folders(in: workspace)
        VStack(alignment: .leading, spacing: 12) {
            Text("New File from Template").font(.headline)
            if templates.isEmpty {
                Text("No templates yet. A snippet in snippets.toml with file = true is one.")
                    .foregroundStyle(.secondary)
            } else if folders.isEmpty {
                Text("Add a folder first.").foregroundStyle(.secondary)
            } else {
                Form {
                    Picker("Template", selection: $template) {
                        ForEach(templates, id: \.trigger) { Text($0.name).tag($0.trigger) }
                    }
                    Picker("Folder", selection: $chosenFolder) {
                        ForEach(folders, id: \.path) { Text($0.title).tag($0.path) }
                    }
                    TextField("Name", text: $name)
                }
                Text("A name without an extension gets .org. Use folder/name to make folders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(templates.isEmpty || folders.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            template = templates.first?.trigger ?? ""
            chosenFolder = folders.first { $0.path == folder }?.path ?? folders.first?.path ?? ""
        }
    }

    private func create() {
        guard let chosen = SnippetLibrary.shared.templates.first(where: { $0.trigger == template }) else { return }
        Task {
            do {
                let path = try await SnippetLibrary.shared.createFile(named: name, in: chosenFolder, from: chosen, workspace: workspace)
                dismiss()
                open(path)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
