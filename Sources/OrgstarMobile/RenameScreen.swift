#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// Rename Tag… and Rename TODO Keyword… from Commands: the old and new name and where, then
/// every change by file and line to untick, then Rename.
struct RenameScreen: View {
    let kind: ReplaceKind
    let workspace: WorkspaceModel
    let session: DocumentSession
    let done: (String) -> Void
    @State private var model: ReplaceInFiles?
    @State private var old: String
    @State private var new = ""
    @State private var includeConfig = true
    /// A root's path, or empty for every folder.
    @State private var scope = ""
    @Environment(MobileModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    init(kind: ReplaceKind, workspace: WorkspaceModel, session: DocumentSession, initial: String, done: @escaping (String) -> Void) {
        self.kind = kind
        self.workspace = workspace
        self.session = session
        self.done = done
        _old = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section {
                        HStack {
                            TextField(kind == .renameTag ? LocalizedStringKey("Tag") : LocalizedStringKey("Keyword"), text: $old)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Menu {
                                ForEach(suggestions, id: \.self) { name in Button(name) { old = name } }
                            } label: {
                                Image(systemName: "chevron.down.circle")
                            }
                            .disabled(suggestions.isEmpty)
                            .accessibilityLabel(Text("Choose", comment: "Rename: menu of the existing names"))
                        }
                        TextField("New name", text: $new)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Picker("In", selection: $scope) {
                            Text("All Folders").tag("")
                            ForEach(workspace.rootPaths, id: \.self) { root in
                                Text(verbatim: (root as NSString).lastPathComponent).tag(root)
                            }
                        }
                        Toggle(kind == .renameTag ? LocalizedStringKey("Also rename it in org-tag-alist in config.toml")
                                                  : LocalizedStringKey("Also rename it in org-todo-keywords in config.toml"), isOn: $includeConfig)
                    }
                    Section {
                        if let model, model.isSearching {
                            HStack {
                                ProgressView(value: Double(model.progress.done), total: Double(max(1, model.progress.total)))
                                Button("Stop") { model.cancel() }
                            }
                        } else {
                            Button("Find") { search() }
                                .disabled(old.isEmpty || new.isEmpty)
                        }
                        if let model, let text = summary(model) {
                            Text(text).foregroundStyle(model.problem == nil ? .secondary : .primary)
                        }
                    }
                }
                .frame(maxHeight: model?.files.isEmpty == false ? 330 : .infinity)
                if let model, !model.files.isEmpty || (model.configChange != nil && model.changesConfig) {
                    ReplacePreview(model: model)
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(kind.applyTitle) {
                        if let model { done(model.apply()) }
                        dismiss()
                    }
                    .disabled(model.map { $0.isSearching || ($0.tickedCount == 0 && !($0.configChange != nil && $0.changesConfig)) } ?? true)
                }
            }
            .onChange(of: includeConfig) { if model?.mode != nil { search() } }
        }
    }

    private var suggestions: [String] {
        switch kind {
        case .renameTag: ((try? workspace.index.tags()) ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        default:
            session.defaults.todoSequences.flatMap { ($0.active + $0.done).map(\.name) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        }
    }

    private func summary(_ model: ReplaceInFiles) -> String? {
        if let problem = model.problem { return problem }
        guard model.mode != nil, !model.isSearching else { return nil }
        if model.files.isEmpty, model.configChange == nil { return String(localized: "No Matches", comment: "Replace in Files: the search found nothing") }
        return String(localized: "\(model.tickedCount) of \(model.changeCount) changes; files: \(model.files.count)", comment: "Replace in Files: what applying does")
    }

    private func search() {
        let model = self.model ?? ReplaceInFiles(session: session, workspace: workspace, config: config)
        self.model = model
        let from = old.trimmingCharacters(in: .whitespaces), to = new.trimmingCharacters(in: .whitespaces)
        model.start(kind == .renameTag ? .renameTag(from: from, to: to) : .renameKeyword(from: from, to: to), scope: scope.isEmpty ? nil : scope, includeConfig: includeConfig)
    }

    /// config.toml through the app's settings, which write the synced folder's file.
    private var config: ReplaceInFiles.Config {
        var config = ReplaceInFiles.Config.standard
        let app = app
        config.set = { key, value in app.set(key, to: .string(value)) }
        return config
    }
}
#endif
