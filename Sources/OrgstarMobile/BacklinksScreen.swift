#if os(iOS)
import OrgApp
import OrgCore
import OrgIndex
import SwiftUI

/// Headings that link to the heading at the caret, and to the file, as the Mac's backlinks
/// pane lists them.
struct BacklinksScreen: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let path: String
    let caret: Int
    let open: (HeadingLocation) -> Void
    @State private var heading: (title: String, links: [HeadingLocation])?
    @State private var toFile: [HeadingLocation] = []
    /// Why the index couldn't be read, shown in place of the lists.
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Text(failure).foregroundStyle(.secondary)
                } else {
                    if let heading {
                        Section("Links to \(heading.title.isEmpty ? "(untitled)" : heading.title)") { rows(heading.links) }
                    }
                    Section("Links to this file") { rows(toFile) }
                }
            }
            .navigationTitle("Backlinks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private func rows(_ locations: [HeadingLocation]) -> some View {
        if locations.isEmpty {
            Text("None").foregroundStyle(.secondary)
        }
        ForEach(locations, id: \.self) { location in
            Button {
                dismiss()
                open(location)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.title.isEmpty ? "(untitled)" : location.title).lineLimit(1).foregroundStyle(.primary)
                    if let snippet = location.snippet {
                        Text(snippet.attributed).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Text((location.path as NSString).lastPathComponent).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func refresh() async {
        let overlay = workspace.overlay(session.openDocuments)
        guard let document = session.openDocuments.first(where: { $0.path == path })?.document else { return }
        do {
            let found = try await Self.backlinks(in: workspace, path: path, tree: document.tree, caret: caret, overlay: overlay)
            guard !Task.isCancelled else { return }
            (toFile, heading) = found
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }

    @concurrent
    private nonisolated static func backlinks(
        in workspace: WorkspaceModel, path: String, tree: OrgTree, caret: Int, overlay: [String: FileRecord]
    ) async throws -> (toFile: [HeadingLocation], heading: (title: String, links: [HeadingLocation])?) {
        let model = DocumentModel(tree: tree)
        let toFile = try workspace.backlinks(to: Backlinks.Target(path: path, id: model.property("ID", of: nil)?.value), overlay: overlay)
        guard let info = model.headings.last(where: { $0.headingRange.lowerBound <= caret }) else { return (toFile, nil) }
        let customID = info.properties.last { $0.key.uppercased() == "CUSTOM_ID" }?.value
        let target = Backlinks.Target(path: path, title: info.title, id: info.id, customID: customID)
        return (toFile, (info.title, try workspace.backlinks(to: target, excluding: info.headingRange.lowerBound, overlay: overlay)))
    }
}
#endif
