#if os(iOS)
import OrgApp
import SwiftUI
import UIKit

/// Syncing folders through Working Copy: saves every file, opens Working Copy's commit, pull
/// and push chain, and takes its answer from `orgstar://working-copy/…`.
@MainActor
@Observable
final class WorkingCopySync {
    /// What the last sync, or its start, came to, for the app's message line.
    var message: String?
    /// Folders waiting for the one being synced, by root.
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var running: String?
    /// When a sync last started: coming back from Working Copy makes the app active again,
    /// which mustn't start another.
    @ObservationIgnored private var started: Date?
    @ObservationIgnored let folders = WorkingCopy.Folders()

    /// The folder `path` is in, when it is set up.
    func root(containing path: String, roots: [String]) -> String? {
        let set = folders.all
        return roots.filter { set[$0] != nil && (path == $0 || path.hasPrefix($0 + "/")) }.max { $0.count < $1.count }
    }

    /// Syncs `root`, after the folders already waiting.
    func sync(_ root: String, session: DocumentSession) {
        guard running != root, !queue.contains(root) else { return }
        queue.append(root)
        if running == nil { next(session: session) }
    }

    /// The app became active: the folders that sync on opening, unless a sync started a moment
    /// ago and this is the return from Working Copy.
    func appOpened(roots: [String], session: DocumentSession) {
        if let started, Date().timeIntervalSince(started) < 120 { return }
        let set = folders.all
        for root in roots where set[root]?.syncOnOpen == true { sync(root, session: session) }
    }

    private func next(session: DocumentSession) {
        guard running == nil, !queue.isEmpty else { return }
        let root = queue.removeFirst()
        let name = (root as NSString).lastPathComponent
        guard let folder = folders.folder(root) else { return next(session: session) }
        // Working Copy commits what is on disk.
        let unsaved = session.dirtyPaths.filter { !session.save($0) }.sorted()
        if let failed = unsaved.first {
            message = String(localized: "\(name) wasn't synced: \((failed as NSString).lastPathComponent) couldn't be saved.", comment: "Working Copy sync")
            queue.removeAll()
            return
        }
        guard let key = WorkingCopy.Key.stored() else {
            message = String(localized: "\(name) wasn't synced: set Working Copy's URL key in Settings ▸ Working Copy.", comment: "Working Copy sync")
            queue.removeAll()
            return
        }
        running = root
        started = Date()
        UIApplication.shared.open(WorkingCopy.syncURL(repo: folder.repository, key: key)) { [weak self] opened in
            guard let self, !opened else { return }
            self.running = nil
            self.queue.removeAll()
            self.message = String(localized: "\(name) wasn't synced: Working Copy isn't installed or couldn't be opened.", comment: "Working Copy sync")
        }
    }

    /// Working Copy's answer.
    func finished(_ callback: WorkingCopy.Callback, workspace: WorkspaceModel, session: DocumentSession) {
        running = nil
        switch callback {
        case .success(let repo):
            let name = folders.root(of: repo).map { ($0 as NSString).lastPathComponent } ?? repo
            message = String(localized: "Synced \(name) with Working Copy", comment: "Working Copy sync")
            Task { await workspace.refresh() }
            next(session: session)
        case .failure(let repo, let reason):
            let name = folders.root(of: repo).map { ($0 as NSString).lastPathComponent } ?? repo
            message = reason.map { String(localized: "\(name) wasn't synced: \($0)", comment: "Working Copy sync; Working Copy's error follows") }
                ?? String(localized: "\(name) wasn't synced: Working Copy reported an error.", comment: "Working Copy sync")
            queue.removeAll()
        }
    }
}

/// Settings ▸ Working Copy: the URL key, and for each folder whether it syncs.
struct WorkingCopyScreen: View {
    let workspace: WorkspaceModel
    @State private var key = WorkingCopy.Key.stored() ?? ""
    @State private var keyStored = WorkingCopy.Key.stored() != nil

    var body: some View {
        Form {
            Section {
                SecureField("URL key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(storeKey)
                Button(keyStored ? "Replace Key" : "Save Key", action: storeKey).disabled(key.isEmpty)
                if keyStored {
                    Button("Remove Key", role: .destructive) {
                        WorkingCopy.Key.store(nil)
                        key = ""
                        keyStored = false
                    }
                }
            } footer: {
                Text("Working Copy runs orgstar's sync only with the URL key from Working Copy's settings. orgstar keeps it in the Keychain on this device.")
            }
            ForEach(workspace.rootPaths, id: \.self) { root in
                WorkingCopyFolderSection(root: root)
            }
        }
        .navigationTitle("Working Copy")
    }

    private func storeKey() {
        guard !key.isEmpty else { return }
        keyStored = WorkingCopy.Key.store(key)
    }
}

/// Whether a folder syncs with Working Copy, the repository's name there, and whether it syncs
/// when orgstar opens.
struct WorkingCopyFolderSection: View {
    let root: String
    @State private var folder: WorkingCopy.Folder?

    init(root: String) {
        self.root = root
        _folder = State(initialValue: WorkingCopy.Folders().folder(root))
    }

    var body: some View {
        let name = (root as NSString).lastPathComponent
        Section {
            Toggle("Sync with Working Copy", isOn: Binding {
                folder != nil
            } set: { on in
                save(on ? WorkingCopy.Folder(repository: name) : nil)
            })
            if let folder {
                LabeledContent("Repository") {
                    TextField(name, text: Binding { folder.repository } set: { value in
                        save(WorkingCopy.Folder(repository: value.isEmpty ? name : value, syncOnOpen: folder.syncOnOpen))
                    })
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                Toggle("Sync when orgstar opens", isOn: Binding { folder.syncOnOpen } set: { on in
                    save(WorkingCopy.Folder(repository: folder.repository, syncOnOpen: on))
                })
            }
        } header: {
            Text(verbatim: name)
        } footer: {
            if folder != nil {
                Text("Sync saves every file, then Working Copy commits every changed file in the repository, pulls and pushes. The repository is its name in Working Copy's list.")
            } else if WorkingCopy.isRepository(root) {
                Text("This folder is a git repository.")
            }
        }
    }

    private func save(_ new: WorkingCopy.Folder?) {
        folder = new
        WorkingCopy.Folders().set(new, for: root)
    }
}

/// A folder's Working Copy settings on their own, from its menu in Folders.
struct WorkingCopyFolderScreen: View {
    let root: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { WorkingCopyFolderSection(root: root) }
                .navigationTitle("Working Copy")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
