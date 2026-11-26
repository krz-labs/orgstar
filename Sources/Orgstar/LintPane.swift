import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI

/// Lint File's panel under the editor: the problems in the open file, by line. Choosing a row
/// moves the caret there. The list follows the file as it changes.
struct LintPane: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    /// Raised each time Lint File runs, so running it again lints again.
    let run: Int
    let close: () -> Void
    @State private var findings: [LintFinding]?
    @State private var linted: Key?
    @State private var selection: LintFinding.ID?
    @Environment(\.orgTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private struct Key: Equatable {
        var path: String?
        var revision: Int?
        var run: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Lint File").font(.subheadline.weight(.semibold))
                if let path = session.path { Text((path as NSString).lastPathComponent).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if let findings { Text(FileLint.summary(findings)).foregroundStyle(.secondary) } else { ProgressView().controlSize(.small) }
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Close the Lint File panel")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            Table(findings ?? [], selection: $selection) {
                TableColumn("Line") { finding in Text(verbatim: "\(finding.line)").monospacedDigit() }
                    .width(48)
                TableColumn("Severity") { finding in
                    Label(FileLint.severity(finding), systemImage: finding.trust == .high ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(finding.trust == .high ? Color.red : Color.orange)
                        .labelStyle(.titleAndIcon)
                }
                .width(96)
                TableColumn("Problem") { finding in Text(finding.message).lineLimit(1).help(finding.message) }
                    .width(min: 200, ideal: 360)
                TableColumn("Checker") { finding in Text(verbatim: finding.checker.rawValue).foregroundStyle(.secondary).lineLimit(1) }
                    .width(min: 120, ideal: 210, max: 260)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if findings?.isEmpty == true { Text("No problems found").foregroundStyle(.secondary) }
            }
        }
        .background(theme.color("sidebar-background", in: colorScheme) ?? .clear)
        .onChange(of: selection) { _, id in
            guard let id, let finding = findings?.first(where: { $0.id == id }) else { return }
            session.reveal(finding.offset)
        }
        .task(id: Key(path: session.path, revision: session.document?.revision, run: run)) { await refresh() }
    }

    private func refresh() async {
        let key = Key(path: session.path, revision: session.document?.revision, run: run)
        // Typing relints after a pause; a new file or another run of the command at once.
        if let linted, linted.path == key.path, linted.run == key.run {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
        }
        guard let document = session.document, FileLint.applies(to: session.path) else {
            findings = []
            return
        }
        let environment = FileLint.environment(index: workspace.index, overlay: workspace.overlay(session.openDocuments))
        let found = await FileLint.lint(document.text, tree: document.tree, path: session.path, environment: environment)
        guard !Task.isCancelled else { return }
        findings = found
        linted = key
        if let selection, !found.contains(where: { $0.id == selection }) { self.selection = nil }
    }
}
