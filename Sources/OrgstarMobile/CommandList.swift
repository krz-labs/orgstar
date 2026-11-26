#if os(iOS)
import GameController
import OrgApp
import SwiftUI

/// A command in the Commands list.
struct CommandRow: Identifiable {
    let id: String
    let title: String
    /// Its keys in the current keymap, shown while a hardware keyboard is attached.
    var keys: String? = nil
    /// Why it doesn't apply here; nil when it runs. The row is listed greyed with this.
    var reason: String? = nil
}

/// Commands, on every screen: with an empty query the recent ones, then every command by
/// subject; a query matches as the Mac's palette does.
struct CommandList: View {
    let rows: [CommandRow]
    var title = String(localized: "Commands")
    /// Choosing a command counts as running it, for Recent and the ranking.
    var recordsUse = true
    /// Called with the chosen command before the list closes.
    let choose: (String) -> Void
    @State private var query = ""
    @State private var keyboard = GCKeyboard.coalesced != nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let ranked = CommandRanking.rank(rows, query: query, id: \.id, titles: { [$0.title] })
        NavigationStack {
            List {
                if query.allSatisfy(\.isWhitespace) {
                    if !ranked.recent.isEmpty {
                        Section("Recent") { ForEach(ranked.recent) { row($0) } }
                    }
                    ForEach(sections(ranked.rest), id: \.group) { section in
                        Section {
                            ForEach(section.rows) { row($0) }
                        } header: {
                            if let group = section.group { Text(CommandGroups.commandList[group].title) }
                        }
                    }
                } else {
                    // Those that run here first, each part in rank order.
                    ForEach(ranked.rest.filter { $0.reason == nil } + ranked.rest.filter { $0.reason != nil }) { row($0) }
                }
            }
            .overlay {
                if !query.allSatisfy(\.isWhitespace), ranked.rest.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in keyboard = GCKeyboard.coalesced != nil }
    }

    /// The rows by `CommandGroups.commandList`, those in no group first, in the list's order.
    private func sections(_ rows: [CommandRow]) -> [(group: Int?, rows: [CommandRow])] {
        let grouped = Dictionary(grouping: rows) { CommandGroups.group(of: $0.id, in: CommandGroups.commandList) }
        return ([nil] + CommandGroups.commandList.indices.map(Optional.some)).compactMap { group in
            grouped[group].map { (group, $0) }
        }
    }

    private func row(_ command: CommandRow) -> some View {
        Button {
            if recordsUse { CommandUsage.shared.record(command.id) }
            choose(command.id)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                    if let reason = command.reason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if keyboard, let keys = command.keys {
                    Text(keys).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
        .disabled(command.reason != nil)
    }
}
#endif
