import OrgApp
import OrgCore
import SwiftUI

/// Edit ▸ Find ▸ Replace in Files…, Org ▸ TODO and Tags ▸ Rename Tag… and Rename TODO Keyword…:
/// what to look for and where, then every change by file and line to untick, then apply.
struct ReplaceInFilesSheet: View {
    let kind: ReplaceKind
    let workspace: WorkspaceModel
    let session: DocumentSession
    /// Called with what was done, after applying.
    let done: (String) -> Void
    @State private var model: ReplaceInFiles
    @State private var find = ""
    @State private var replacement = ""
    @AppStorage("replaceRegexp") private var regexp = false
    @AppStorage("replaceCaseFold") private var caseFold = true
    @AppStorage("replaceCaseReplace") private var caseReplace = true
    @State private var includeConfig = true
    /// A root's path, or empty for every folder.
    @State private var scope = ""
    @Environment(\.orgTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    init(kind: ReplaceKind, workspace: WorkspaceModel, session: DocumentSession, initial: String = "", done: @escaping (String) -> Void) {
        self.kind = kind
        self.workspace = workspace
        self.session = session
        self.done = done
        _model = State(initialValue: ReplaceInFiles(session: session, workspace: workspace))
        _find = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title).font(.headline)
            form
            Divider()
            results
            HStack {
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { model.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(kind.applyTitle) {
                    done(model.apply())
                    dismiss()
                }
                .disabled(model.isSearching || (model.tickedCount == 0 && !(model.configChange != nil && model.changesConfig)))
            }
        }
        .padding()
        .frame(minWidth: 640, idealWidth: 760, minHeight: 460, idealHeight: 560)
        // Which headings a keyword rename changes depends on it, so the search runs again.
        .onChange(of: includeConfig) { if model.mode != nil, !find.isEmpty { search() } }
        #if !APPSTORE
        .onAppear {
            // Scripted runs answer the two fields and search, for the snapshot.
            let answers = DevelopmentHooks.answers
            guard answers.count >= 2 else { return }
            find = answers[0]
            replacement = answers[1]
            search()
        }
        #endif
    }

    @ViewBuilder
    private var form: some View {
        Form {
            switch kind {
            case .replace:
                TextField("Find:", text: $find, prompt: regexp ? Text("Regular expression") : Text("Text"))
                TextField("Replace with:", text: $replacement, prompt: regexp ? Text("\\1 or $1 for a group") : Text("Text"))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Regular expression", isOn: $regexp)
                    Toggle("Ignore case when the search is lower case", isOn: $caseFold)
                        .help("case-fold-search: a search with an upper-case letter matches case exactly")
                    Toggle("Keep each match's case", isOn: $caseReplace)
                        .help("case-replace: FOO becomes BAR and Foo becomes Bar")
                        .disabled(!caseFold)
                }
            case .renameTag:
                LabeledContent("Tag:") { nameField($find, suggestions: knownTags) }
                TextField("New name:", text: $replacement)
                Toggle("Also rename it in org-tag-alist in config.toml", isOn: $includeConfig)
            case .renameKeyword:
                LabeledContent("Keyword:") { nameField($find, suggestions: knownKeywords) }
                TextField("New name:", text: $replacement)
                Toggle("Also rename it in org-todo-keywords in config.toml", isOn: $includeConfig)
            }
            HStack {
                Picker("In:", selection: $scope) {
                    Text("All Folders").tag("")
                    ForEach(workspace.rootPaths, id: \.self) { root in
                        Text(verbatim: (root as NSString).lastPathComponent).tag(root)
                    }
                }
                .fixedSize()
                Spacer()
                if model.isSearching {
                    ProgressView(value: Double(model.progress.done), total: Double(max(1, model.progress.total)))
                        .frame(width: 160)
                    Button("Stop") { model.cancel() }
                } else {
                    Button("Find") { search() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(find.isEmpty || (kind != .replace && replacement.isEmpty))
                }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let problem = model.problem {
            ContentUnavailableView(problem, systemImage: "exclamationmark.triangle")
                .frame(maxHeight: .infinity)
        } else if model.files.isEmpty && !(model.configChange != nil && model.changesConfig) {
            if model.mode == nil || model.isSearching {
                Color.clear.frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView(String(localized: "No Matches", comment: "Replace in Files: the search found nothing"), systemImage: "magnifyingglass")
                    .frame(maxHeight: .infinity)
            }
        } else {
            ReplacePreview(model: model, removed: theme.color("todo") ?? .red, added: theme.color("done") ?? .green)
                .frame(maxHeight: .infinity)
        }
    }

    private var summary: String {
        if model.isSearching {
            return String(localized: "Searched \(model.progress.done) of \(model.progress.total) files", comment: "Replace in Files: progress")
        }
        guard model.mode != nil, model.problem == nil else { return "" }
        let base = String(localized: "\(model.tickedCount) of \(model.changeCount) changes; files: \(model.files.count)", comment: "Replace in Files: what applying does")
        return model.wasCancelled ? base + " · " + String(localized: "Stopped", comment: "Replace in Files: the search was stopped") : base
    }

    private func nameField(_ text: Binding<String>, suggestions: [String]) -> some View {
        HStack(spacing: 4) {
            TextField("", text: text).labelsHidden()
            Menu {
                ForEach(suggestions, id: \.self) { name in Button(name) { text.wrappedValue = name } }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(suggestions.isEmpty)
            .accessibilityLabel(Text("Choose", comment: "Rename: menu of the existing names"))
        }
    }

    private var knownTags: [String] { ((try? workspace.index.tags()) ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    private var knownKeywords: [String] {
        var names: [String] = []
        let sequences = session.defaults.todoSequences + (session.document?.tree.settings.todoSequences ?? [])
        for name in sequences.flatMap({ ($0.active + $0.done).map(\.name) }) where !names.contains(name) { names.append(name) }
        return names
    }

    private func search() {
        let mode: ReplaceInFiles.Mode = switch kind {
        case .replace: .replace(TextReplace(pattern: find, replacement: replacement, isRegexp: regexp, caseFold: caseFold, caseReplace: caseReplace))
        case .renameTag: .renameTag(from: find.trimmingCharacters(in: .whitespaces), to: replacement.trimmingCharacters(in: .whitespaces))
        case .renameKeyword: .renameKeyword(from: find.trimmingCharacters(in: .whitespaces), to: replacement.trimmingCharacters(in: .whitespaces))
        }
        model.start(mode, scope: scope.isEmpty ? nil : scope, includeConfig: includeConfig)
    }
}
