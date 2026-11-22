import AppKit
import OrgApp
import OrgIndex
import OrgWorkspace
import SwiftUI

struct SearchResults: View {
    let results: Result<[HeadingLocation], any Error>
    let open: (HeadingLocation) -> Void

    var body: some View {
        let found = (try? results.get()) ?? []
        List(found, id: \.self) { location in
            Button {
                open(location)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.title.isEmpty ? String(localized: "(untitled)") : location.title).lineLimit(1)
                    if let snippet = location.snippet {
                        Text(snippet.attributed).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Text((location.path as NSString).lastPathComponent).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if case .failure(let error) = results {
                ContentUnavailableView(error.localizedDescription, systemImage: "exclamationmark.triangle")
            } else if found.isEmpty {
                ContentUnavailableView.search
            }
        }
    }
}

struct QuickOpenView: View {
    let workspace: WorkspaceModel
    let open: (FileEntry) -> Void
    @State private var query = ""
    /// The highlighted match, moved by ↑/↓ or C-p/C-n and opened by Return.
    @State private var selected = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let matches = workspace.quickOpen(query)
        let current = min(selected, matches.count - 1)
        VStack(spacing: 0) {
            TextField("Open file", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .onSubmit { if current >= 0 { open(matches[current]) } }
                .movesSelection($selected, current: current, count: matches.count)
                .onChange(of: query) { selected = 0 }
            Divider()
            ScrollViewReader { proxy in
                List(matches.indices, id: \.self) { index in
                    let entry = matches[index]
                    Button {
                        open(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text(entry.relativePath).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .selectedRow(index == current)
                }
                .onChange(of: current) { if current >= 0 { proxy.scrollTo(current) } }
            }
        }
        .frame(width: 520, height: 360)
        .onExitCommand { dismiss() }
    }
}

extension View {
    /// ↑/↓ and C-p/C-n move `selected` through `count` rows; `current` is the row shown as selected.
    func movesSelection(_ selected: Binding<Int>, current: Int, count: Int) -> some View {
        onKeyPress(phases: .down) { press in
            let control = press.modifiers == .control
            // Shift with an arrow is the date prompt's.
            let plain = press.modifiers.intersection([.shift, .control, .option, .command]).isEmpty
            let step = if press.key == .downArrow && plain || control && press.characters == "n" { 1 }
                else if press.key == .upArrow && plain || control && press.characters == "p" { -1 } else { 0 }
            guard step != 0, count > 0 else { return .ignored }
            selected.wrappedValue = max(0, min(current + step, count - 1))
            return .handled
        }
    }

    /// The highlight of the row arrow keys select in a list.
    func selectedRow(_ selected: Bool) -> some View {
        listRowBackground(selected ? Color.accentColor.opacity(0.25) : Color.clear)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
