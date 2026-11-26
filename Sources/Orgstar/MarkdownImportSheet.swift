import AppKit
import OrgApp
import OrgCore
import SwiftUI
import UniformTypeIdentifiers

/// File ▸ Import ▸ Markdown Files… and Obsidian Vault…: the sources, a folder to write into,
/// and what the import will write, before anything is written.
struct MarkdownImportSheet: View {
    let kind: MarkdownImport.Kind
    let workspace: WorkspaceModel
    /// The folder of the file shown, which the folder menu starts on.
    let folder: String?
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [URL] = []
    @State private var destination = ""
    @State private var plan: MarkdownImport.Plan?
    @State private var planning = false
    @State private var importing = false
    @State private var failure: String?

    var body: some View {
        let folders = SnippetLibrary.folders(in: workspace)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == .obsidian ? "Import Obsidian Vault" : "Import Markdown Files").font(.headline)
                    Text(sources.isEmpty ? String(localized: "Nothing chosen yet.", comment: "Markdown import with no source chosen")
                         : sources.map { OrgPaths.abbreviatingWithTilde($0.path) }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                Spacer()
                Button("Choose…") { choose() }
            }
            if folders.isEmpty {
                Text("Add a folder first.").foregroundStyle(.secondary)
            } else {
                Picker("Import into", selection: $destination) {
                    ForEach(folders, id: \.path) { Text($0.title).tag($0.path) }
                }
            }
            preview
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("New files only: nothing in the folder or the source is changed.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || plan?.notes == 0 || planning || importing)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
        .onAppear {
            destination = folders.first { $0.path == folder }?.path ?? folders.first?.path ?? ""
            #if !APPSTORE
            // Scripted runs give the source, and optionally the folder, for the snapshot.
            let answers = DevelopmentHooks.answers
            if let source = answers.first {
                if answers.count > 1, let chosen = folders.first(where: { $0.path == answers[1] || $0.title == answers[1] }) { destination = chosen.path }
                sources = [URL(fileURLWithPath: source)]
                return
            }
            #endif
            DispatchQueue.main.async { choose() }
        }
        .task(id: PlanKey(sources: sources, destination: destination)) { await makePlan() }
    }

    private struct PlanKey: Equatable {
        let sources: [URL]
        let destination: String
    }

    @ViewBuilder
    private var preview: some View {
        if planning {
            ProgressView("Reading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let plan {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                    GridRow { Text("Files"); Text(plan.notes, format: .number).monospacedDigit() }
                    GridRow { Text("Headings"); Text(plan.headings, format: .number).monospacedDigit() }
                    GridRow { Text("Links"); Text(plan.links, format: .number).monospacedDigit() }
                    GridRow { Text("Attachments"); Text(plan.attachments, format: .number).monospacedDigit() }
                }
                if !plan.renamed.isEmpty {
                    Text("Already in the folder, so imported under another name:").font(.subheadline)
                    Text(plan.renamed.map { "\($0.from) → \($0.to)" }.joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
                if plan.problems.isEmpty {
                    Text("Everything can be converted.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Not converted, or converted with a loss (\(plan.problems.count)):").font(.subheadline)
                    List(Array(plan.problems.enumerated()), id: \.offset) { _, problem in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.describe(problem.reason))
                            Text(problem.file).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .listStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Spacer()
        }
    }

    static func describe(_ reason: MarkdownImport.Problem.Reason) -> String {
        switch reason {
        case .unreadable: String(localized: "Not UTF-8 text; not imported.", comment: "Markdown import problem")
        case .notConverted: String(localized: "Canvas and base files have no org equivalent; not imported.", comment: "Markdown import problem")
        case .converted(let issue):
            switch issue {
            case .unresolvedLink(let link): String(localized: "Link to \(link), which isn't among the files imported.", comment: "Markdown import problem")
            case .missingHeading(let link): String(localized: "Link to \(link): no such heading or block, so the link goes to the file.", comment: "Markdown import problem")
            case .frontMatter(let key): String(localized: "Front matter \(key) holds a nested map and was left out.", comment: "Markdown import problem")
            case .recurrence: String(localized: "A task's 🔁 recurrence is kept as text.", comment: "Markdown import problem")
            case .taskStatus(let status): String(localized: "Task status [\(status)] became an open checkbox.", comment: "Markdown import problem")
            case .nestedHeading(let text): String(localized: "Heading \(text) inside a list or quote became a bold line.", comment: "Markdown import problem")
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = kind == .markdown
        panel.allowsMultipleSelection = kind == .markdown
        if kind == .markdown { panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText, .folder] }
        panel.prompt = String(localized: "Choose", comment: "Open panel button")
        panel.message = kind == .obsidian ? String(localized: "Choose the vault's folder.", comment: "Open panel for importing an Obsidian vault")
            : String(localized: "Choose Markdown files, or folders of them.", comment: "Open panel for importing Markdown files")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            if sources.isEmpty { dismiss() }
            return
        }
        sources = panel.urls
    }

    private func makePlan() async {
        plan = nil
        failure = nil
        guard !sources.isEmpty, !destination.isEmpty else { return }
        planning = true
        defer { planning = false }
        let (kind, sources, destination) = (kind, sources, URL(fileURLWithPath: destination))
        do {
            let made = try await Task.detached { try MarkdownImport.plan(kind, sources: sources, into: destination) }.value
            guard !Task.isCancelled else { return }
            plan = made
        } catch {
            failure = error.localizedDescription
        }
    }

    private func runImport() {
        guard let plan else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let written = try await Task.detached { try MarkdownImport.write(plan) }.value
                await workspace.filesChanged(written.paths.map { URL(fileURLWithPath: $0) }, rescan: [])
                var message = String(localized: "Imported \(plan.notes) files and \(plan.attachments) attachments.", comment: "Message after a Markdown import")
                if !written.renamed.isEmpty {
                    message += " " + String(localized: "Taken since the preview, so renamed: \(written.renamed.map { "\($0.from) → \($0.to)" }.joined(separator: ", ")).",
                                            comment: "Message after a Markdown import")
                }
                dismiss()
                done(message)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Which import sheet is showing.
enum MarkdownImportKind: String, Identifiable {
    case markdown, obsidian

    var id: String { rawValue }
    var kind: MarkdownImport.Kind { self == .obsidian ? .obsidian : .markdown }
}
