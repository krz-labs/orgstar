#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// Settings ▸ Key Bar: the key bar's buttons, added from the Commands list, removed and
/// reordered, for narrow and wide editors. Changes are written to `[key-bar]` in config.toml.
struct KeyBarSettings: View {
    let model: MobileModel
    @State private var width: KeyBarLayout.Width = UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
    @State private var adding = false

    private var stored: [String]? {
        let _ = model.settingsVersion
        return KeyBarLayout.stored(width, in: .standard)
    }

    var body: some View {
        let ids = stored ?? width.defaultIDs
        List {
            Section {
                Picker("Layout", selection: $width) {
                    Text(verbatim: "iPhone").tag(KeyBarLayout.Width.iphone)
                    Text(verbatim: "iPad").tag(KeyBarLayout.Width.ipad)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("The iPhone buttons show where the editor is narrow, the iPad buttons where it is wide.")
            }
            Section {
                ForEach(ids, id: \.self) { row($0) }
                    .onMove { from, to in
                        var list = ids
                        list.move(fromOffsets: from, toOffset: to)
                        model.setKeyBar(list, width)
                    }
                    .onDelete { offsets in
                        var list = ids
                        list.remove(atOffsets: offsets)
                        model.setKeyBar(list, width)
                    }
            } header: {
                Text("Buttons")
            } footer: {
                Text("Buttons that don't fit go under More. While a snippet's fields are filled in, Previous Snippet Field and Next Snippet Field take the places of Promote and Demote.")
            }
            Section {
                Button("Add Button…") { adding = true }
                Button("Reset to Default") { model.setKeyBar(nil, width) }
                    .disabled(stored == nil)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Key Bar")
        .sheet(isPresented: $adding) {
            CommandList(rows: candidates(besides: ids), title: String(localized: "Add Button"), recordsUse: false) { id in
                model.setKeyBar(ids + [id], width)
            }
        }
    }

    private func row(_ id: String) -> some View {
        let item = KeyBar.item(id)
        return HStack(spacing: 12) {
            Group {
                if let symbol = item?.symbol {
                    Image(systemName: symbol).font(.body)
                } else {
                    Text(item?.text ?? "?").font(.caption2.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.5)
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(.tint)
            // As on the bar, the tile stops growing where its symbols do.
            .dynamicTypeSize(...KeyBar.largestSymbolSize)
            .frame(width: 56, height: 40)
            .background(.fill.tertiary, in: .rect(cornerRadius: 8))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.label ?? id)
                if item == nil {
                    Text("Not a command here; the key bar skips it.").font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    /// The bar's own buttons, then the editor's commands, named macros and snippets, without
    /// those already on the bar or a command one of the bar's own buttons runs.
    private func candidates(besides ids: [String]) -> [CommandRow] {
        let own = KeyBar.items.values.compactMap { item -> String? in
            if case .command(let id) = item.action { return id }
            return nil
        }
        let commands = KeyBar.items.keys.map { $0 } + CommandPalette.commands(macros: NamedMacros.shared).map(\.id)
            + SnippetLibrary.shared.snippets.filter { !$0.file }.map(\.commandID)
        return commands.filter { !ids.contains($0) && !own.contains($0) }.compactMap { id in
            KeyBar.item(id).map { CommandRow(id: id, title: $0.label) }
        }
    }
}
#endif
