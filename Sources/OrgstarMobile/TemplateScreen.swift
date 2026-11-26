#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// A folder New File from Template… creates its file in.
struct TemplateFolder: Identifiable {
    let path: String
    var id: String { path }
}

/// New File from Template…: a template from `snippets.toml` and a name. The file is created in
/// the folder as New File creates one, and opens in the editor with the template expanded.
struct TemplateScreen: View {
    let folder: String
    let workspace: WorkspaceModel
    let created: (String) -> Void
    @State private var template = ""
    @State private var name = ""
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let templates = SnippetLibrary.shared.templates
        NavigationStack {
            Form {
                if templates.isEmpty {
                    Text("No templates yet. A snippet in snippets.toml with file = true is one.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Template", selection: $template) {
                        ForEach(templates, id: \.trigger) { Text($0.name).tag($0.trigger) }
                    }
                    Section {
                        TextField("Name", text: $name)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } footer: {
                        Text("A name without an extension gets .org.")
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .navigationTitle((folder as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(templates.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { if template.isEmpty { template = templates.first?.trigger ?? "" } }
        }
    }

    private func create() {
        guard let chosen = SnippetLibrary.shared.templates.first(where: { $0.trigger == template }) else { return }
        Task {
            do {
                let path = try await SnippetLibrary.shared.createFile(named: name, in: folder, from: chosen, workspace: workspace)
                dismiss()
                created(path)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// The template sheet for `folder`, and the editor the new file opens in.
private struct NewFromTemplate: ViewModifier {
    @Binding var folder: TemplateFolder?
    let workspace: WorkspaceModel
    let session: DocumentSession
    @State private var editing: EditorRoute?

    func body(content: Content) -> some View {
        content
            .sheet(item: $folder) { folder in
                TemplateScreen(folder: folder.path, workspace: workspace) { editing = EditorRoute(path: $0, offset: nil) }
            }
            .navigationDestination(item: $editing) { route in
                EditorSplitScreen(path: route.path, offset: nil, workspace: workspace, session: session)
            }
    }
}

extension View {
    func newFromTemplate(_ folder: Binding<TemplateFolder?>, workspace: WorkspaceModel, session: DocumentSession) -> some View {
        modifier(NewFromTemplate(folder: folder, workspace: workspace, session: session))
    }
}
#endif
