import OrgApp
import OrgCore
import OrgIndex
import OrgPresentation
import SwiftUI

/// Headings that link to the heading at the caret, and to the file.
struct BacklinksPane: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    let open: (HeadingLocation) -> Void
    @State private var toHeading: [HeadingLocation] = []
    @State private var toFile: [HeadingLocation] = []
    /// Why the index couldn't be read, shown in place of the lists.
    @State private var failure: String?
    @Environment(\.orgTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// The heading at the caret.
    private var heading: OutlineEntry? { session.outline.last { $0.start <= commands.selection.location } }

    private struct Key: Equatable {
        var path: String?
        var heading: Int?
        var title: String?
        var index: Int
    }

    var body: some View {
        Group {
            if failure == nil, toHeading.isEmpty, toFile.isEmpty {
                // Nothing links here: a single line, leaving the column to the outline.
                HStack {
                    Text("Links to this file").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("None").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(theme.color("sidebar-background", in: colorScheme) ?? .clear)
            } else {
                List {
                    if let failure {
                        Text(failure).foregroundStyle(.secondary)
                    } else {
                        if let heading {
                            Section("Links to \(heading.title.isEmpty ? "(untitled)" : heading.title)") { rows(toHeading) }
                        }
                        Section("Links to this file") { rows(toFile) }
                    }
                }
                .themedListBackground(theme.color("sidebar-background", in: colorScheme))
                .frame(height: 200)
            }
        }
        .task(id: Key(path: session.path, heading: heading?.start, title: heading?.title, index: workspace.indexVersion)) { await refresh() }
    }

    @ViewBuilder
    private func rows(_ locations: [HeadingLocation]) -> some View {
        if locations.isEmpty {
            Text("None").foregroundStyle(.secondary)
        }
        ForEach(locations, id: \.self) { location in
            Button {
                open(location)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.title.isEmpty ? "(untitled)" : location.title).lineLimit(1)
                    if let snippet = location.snippet {
                        Text(snippet.attributed).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Text((location.path as NSString).lastPathComponent).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func refresh() async {
        guard let path = session.path else {
            toHeading = []
            toFile = []
            failure = nil
            return
        }
        let overlay = workspace.overlay(session.openDocuments)
        do {
            let found = try await Self.backlinks(in: workspace, path: path, tree: session.document?.tree, heading: heading?.start, overlay: overlay)
            guard !Task.isCancelled else { return }
            (toFile, toHeading) = found
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            (toFile, toHeading) = ([], [])
            failure = error.localizedDescription
        }
    }

    @concurrent
    private nonisolated static func backlinks(
        in workspace: WorkspaceModel, path: String, tree: OrgTree?, heading: Int?, overlay: [String: FileRecord]
    ) async throws -> (toFile: [HeadingLocation], toHeading: [HeadingLocation]) {
        let model = tree.map { DocumentModel(tree: $0) }
        // The file's own ID, as an org-roam file node.
        let toFile = try workspace.backlinks(to: Backlinks.Target(path: path, id: model?.property("ID", of: nil)?.value), overlay: overlay)
        guard let heading, let info = model?.headings.first(where: { $0.headingRange.lowerBound == heading }) else { return (toFile, []) }
        let customID = info.properties.last { $0.key.uppercased() == "CUSTOM_ID" }?.value
        let target = Backlinks.Target(path: path, title: info.title, id: info.id, customID: customID)
        return (toFile, try workspace.backlinks(to: target, excluding: heading, overlay: overlay))
    }
}
