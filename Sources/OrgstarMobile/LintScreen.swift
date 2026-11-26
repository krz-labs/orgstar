#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// Lint File: the problems in the open file, by line, as the Mac's panel lists them. Tapping
/// one closes the list and moves the caret to its line.
struct LintScreen: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let path: String
    let reveal: (Int) -> Void
    @State private var findings: [LintFinding]?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let findings {
                    Section {
                        ForEach(findings) { finding in
                            Button {
                                dismiss()
                                reveal(finding.offset)
                            } label: {
                                row(finding)
                            }
                        }
                    } header: {
                        Text(FileLint.summary(findings))
                    }
                }
            }
            .overlay {
                if findings == nil {
                    ProgressView()
                } else if findings?.isEmpty == true {
                    ContentUnavailableView("No problems found", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Lint File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await refresh() }
    }

    private func row(_ finding: LintFinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: finding.trust == .high ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(finding.trust == .high ? Color.red : Color.orange)
                .accessibilityLabel(FileLint.severity(finding))
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.message).foregroundStyle(.primary)
                Text("Line \(finding.line) · \(finding.checker.rawValue)", comment: "Lint File: a problem's line and checker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() async {
        guard let document = session.openDocuments.first(where: { $0.path == path })?.document else {
            findings = []
            return
        }
        let environment = FileLint.environment(index: workspace.index, overlay: workspace.overlay(session.openDocuments))
        let found = await FileLint.lint(document.text, tree: document.tree, path: path, environment: environment)
        guard !Task.isCancelled else { return }
        findings = found
    }
}
#endif
