import AppKit
import OrgApp
import OrgDocument
import OrgPresentation
#if !APPSTORE
import OrgPrograms
#endif
import SwiftUI

/// A diff in the theme's colours: removed lines in its TODO red, added ones in its DONE green.
struct ThemedDiff: View {
    let old: String
    let new: String
    @Environment(\.orgTheme) private var theme

    var body: some View {
        DiffView(
            old: old, new: new, removed: theme.color("todo") ?? .red, added: theme.color("done") ?? .green,
            foreground: theme.color("foreground"), background: theme.color("background")
        )
    }
}

/// The buffer and the file on disk changed differently: what differs, and how to settle it.
struct ConflictSheet: View {
    let session: DocumentSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conflicting Changes").font(.headline)
            Text((session.conflict ?? "") + " Lines marked - are on disk, + in your version. The version you don't keep is saved in the recovery folder.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let versions = session.conflictVersions() {
                ThemedDiff(old: versions.disk, new: versions.mine)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Disk Version") { session.useDiskVersion(); dismiss() }
                Button("Merge with Markers") { session.mergeConflictWithMarkers(); dismiss() }
                    .help("Both sets of changes in the buffer, conflicting lines between <<<<<<< and >>>>>>>")
                Button("Keep Mine") { session.keepMine(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 440)
    }
}

/// Syncthing's conflict copies of the open file: each against the file, and what to keep.
struct SyncConflictSheet: View {
    let session: DocumentSession
    let report: (String) -> Void
    @State private var copies: [URL] = []
    @State private var selected: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sync Conflict Copies").font(.headline)
            if copies.isEmpty {
                Text("No conflict copies of this file.").foregroundStyle(.secondary)
            } else {
                Picker("Copy", selection: $selected) {
                    ForEach(copies, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
                }
                Text("Lines marked - are in the file, + in the copy. The copy goes to the recovery folder when it's resolved.")
                    .foregroundStyle(.secondary)
                if let selected, let copy = session.recoveryText(selected), let mine = session.document?.text {
                    ThemedDiff(old: mine, new: copy)
                }
            }
            HStack {
                if copies.isEmpty {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                if let selected {
                    Button("Keep File") { resolve(selected, .keepFile) }
                    Button("Merge with Markers") { resolve(selected, .merge) }
                    Button("Use Copy") { resolve(selected, .useCopy) }
                }
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 440)
        .onAppear(perform: reload)
    }

    private func reload() {
        copies = session.syncConflictCopies()
        if selected.map({ !copies.contains($0) }) ?? true { selected = copies.first }
    }

    private func resolve(_ copy: URL, _ resolution: DocumentSession.CopyResolution) {
        if let message = session.resolve(copy: copy, resolution) { report(message) }
        reload()
        if copies.isEmpty { dismiss() }
    }
}

/// The open file's history, newest first, each version against the buffer: the versions kept
/// in the recovery folder and, in the download version where the folder is a git repository,
/// the commits that changed the file (`git log --follow`).
struct HistorySheet: View {
    let session: DocumentSession
    let report: (String) -> Void
    @State private var entries: [FileHistory.Entry] = []
    @State private var selected: FileHistory.Entry?
    /// The selected version's text, once read.
    @State private var text: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if entries.isEmpty {
                VStack {
                    ContentUnavailableView(
                        "No History", systemImage: "clock.arrow.circlepath",
                        description: Text("orgstar keeps a copy of this file here when it replaces a version, and a snapshot before a save at most once an hour.")
                    )
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
            } else {
                versionList
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .task {
            let recovery = session.recoveryVersions()
            entries = FileHistory.merged(recovery: recovery, commits: [])
            selected = entries.first
            #if !APPSTORE
            guard let path = session.path else { return }
            let commits = await GitHistory.commits(for: URL(fileURLWithPath: path))
            guard !commits.isEmpty else { return }
            entries = FileHistory.merged(recovery: recovery, commits: commits)
            if selected == nil { selected = entries.first }
            #endif
        }
        .task(id: selected) {
            text = nil
            if let selected { text = await load(selected) }
        }
    }

    /// The text of `entry`: a kept file, or the file in a commit.
    private func load(_ entry: FileHistory.Entry) async -> String? {
        switch entry {
        case .recovery(let url, _, _): return session.recoveryText(url)
        case .commit(let commit):
            #if APPSTORE
            return nil
            #else
            return await GitHistory.text(of: commit)
            #endif
        }
    }

    private var versionList: some View {
        HSplitView {
            List(entries, id: \.self, selection: $selected) { entry in
                row(entry).tag(entry)
            }
            .frame(minWidth: 220, idealWidth: 260)
            VStack(alignment: .leading, spacing: 10) {
                Text("History").font(.headline)
                Text("Lines marked - are in the buffer, + in the selected version.").foregroundStyle(.secondary)
                if let text, let mine = session.document?.text {
                    ThemedDiff(old: mine, new: text)
                } else {
                    Spacer()
                }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if case .recovery(let url, _, _) = selected {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Spacer()
                    if let text {
                        Button("Restore") {
                            if let message = session.restore(text: text) { report(message) } else { report("Restored; undo brings back what was there.") }
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func row(_ entry: FileHistory.Entry) -> some View {
        VStack(alignment: .leading) {
            Text(entry.date.formatted(date: .abbreviated, time: .standard))
            switch entry {
            case .recovery(_, _, let label):
                Text(Self.describe(label)).font(.caption).foregroundStyle(.secondary)
            case .commit(let commit):
                Text(verbatim: commit.subject).font(.caption).lineLimit(1)
                Text(verbatim: "\(commit.hash.prefix(7)) · \(commit.author)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    static func describe(_ label: String) -> String {
        switch label {
        case "local": "Your version, replaced"
        case "external": "Disk version, replaced"
        case "sync-conflict": "Sync conflict copy"
        case "snapshot": "Snapshot, before a save"
        default: label
        }
    }
}
