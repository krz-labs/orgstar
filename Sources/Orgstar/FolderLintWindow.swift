import OrgApp
import OrgCore
import SwiftUI

/// Lint All Folders: the problems in every indexed Org file, grouped by file. Choosing a row
/// opens the file in the main window at that line.
struct FolderLintWindow: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    @State private var selection: String?
    @Environment(\.openWindow) private var openWindow

    private var lint: FolderLint { commands.folderLint }

    var body: some View {
        let names = FileLint.names(workspace.files)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                if lint.isRunning {
                    ProgressView(value: Double(lint.checked), total: Double(max(1, lint.total)))
                        .frame(width: 120)
                }
                Text(lint.summary).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if lint.isRunning {
                    Button("Stop") { lint.stop() }
                } else {
                    Button("Check Again") { lint.run(workspace: workspace, session: session) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            List(selection: $selection) {
                ForEach(lint.files ?? []) { file in
                    Section {
                        ForEach(file.findings) { finding in
                            row(finding).tag(Self.tag(file.path, finding))
                        }
                    } header: {
                        HStack {
                            Text(verbatim: names[file.path] ?? file.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(verbatim: "\(file.findings.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .help(file.path)
                    }
                }
            }
            .overlay {
                if lint.files?.isEmpty == true { Text("No problems found").foregroundStyle(.secondary) }
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .navigationTitle("Lint All Folders")
        .onAppear { if lint.files == nil, !lint.isRunning { lint.run(workspace: workspace, session: session) } }
        .onChange(of: selection) { _, tag in
            guard let tag, let (path, finding) = find(tag) else { return }
            if !commands.mainWindowOpen { openWindow(id: "main") }
            commands.jump(path: path, offset: finding.offset)
        }
    }

    private func row(_ finding: LintFinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(finding.line)").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            Image(systemName: finding.trust == .high ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(finding.trust == .high ? Color.red : Color.orange)
                .help(FileLint.severity(finding))
                .accessibilityLabel(FileLint.severity(finding))
            Text(finding.message).lineLimit(1).help(finding.message)
            Spacer()
            Text(verbatim: finding.checker.rawValue).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private static func tag(_ path: String, _ finding: LintFinding) -> String { path + "\n" + finding.id }

    private func find(_ tag: String) -> (String, LintFinding)? {
        for file in lint.files ?? [] {
            if let finding = file.findings.first(where: { Self.tag(file.path, $0) == tag }) { return (file.path, finding) }
        }
        return nil
    }
}
