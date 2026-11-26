#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// Lint All Folders: the problems in every indexed Org file, grouped by file. Tapping one closes
/// the list and opens its file at that line. Closing the list stops a run.
struct FolderLintScreen: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let open: (String, Int) -> Void
    @State private var lint = FolderLint()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let names = FileLint.names(workspace.files)
        return NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(lint.summary).foregroundStyle(.secondary)
                        if lint.isRunning { ProgressView(value: Double(lint.checked), total: Double(max(1, lint.total))) }
                    }
                }
                ForEach(lint.files ?? []) { file in
                    Section {
                        ForEach(file.findings) { finding in
                            Button {
                                dismiss()
                                open(file.path, finding.offset)
                            } label: {
                                row(finding)
                            }
                        }
                    } header: {
                        Text(verbatim: names[file.path] ?? file.path)
                    }
                }
            }
            .overlay {
                if lint.files?.isEmpty == true { ContentUnavailableView("No problems found", systemImage: "checkmark.circle") }
            }
            .navigationTitle("Lint All Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    if lint.isRunning {
                        Button("Stop") { lint.stop() }
                    } else {
                        Button("Check Again") { lint.run(workspace: workspace, session: session) }
                    }
                }
            }
        }
        .onAppear { lint.run(workspace: workspace, session: session) }
        .onDisappear { lint.stop() }
    }

    private func row(_ finding: LintFinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: finding.trust == .high ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(finding.trust == .high ? Color.red : Color.orange)
                .accessibilityLabel(FileLint.severity(finding))
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.message).foregroundStyle(Color.primary)
                Text("Line \(finding.line) · \(finding.checker.rawValue)", comment: "Lint File: a problem's line and checker")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}
#endif
