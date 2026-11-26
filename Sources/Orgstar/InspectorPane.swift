import OrgApp
import OrgCore
import SwiftUI

/// The inspector beside the editor: column view and clocked time for the open file, kept
/// current as it changes.
struct InspectorPane: View {
    let session: DocumentSession
    let commands: AppCommands
    /// Whether the inspector is on screen; nothing is computed while it isn't.
    let shown: Bool
    @AppStorage("inspectorTab") private var tab = Tab.columns
    @AppStorage("inspectorColumnsScope") private var subtree = false
    @AppStorage("inspectorClockSpan") private var span = Span.week
    @State private var columns: ColumnView.View?
    @State private var clocked: [(start: Int, heading: String, minutes: Int)] = []
    /// The selected row's heading start, in each tab.
    @State private var selectedRow: Int?
    @State private var selectedClock: Int?

    /// A column view row, identified by its heading.
    private struct ColumnRow: Identifiable {
        let row: ColumnView.Row
        var id: Int { row.start }
    }

    enum Tab: String, CaseIterable {
        case columns = "Columns", clock = "Clock"

        var title: LocalizedStringKey {
            switch self {
            case .columns: "Columns"
            case .clock: "Clock"
            }
        }
    }

    enum Span: String, CaseIterable {
        case today = "Today", week = "This Week", all = "All"

        var title: LocalizedStringKey {
            switch self {
            case .today: "Today"
            case .week: "This Week"
            case .all: "All"
            }
        }
    }

    private struct Key: Equatable {
        var shown: Bool
        var path: String?
        var version: Int
        var caret: Int?
        var subtree: Bool
        var span: Span
    }

    /// The heading at the caret, for a subtree's columns and the current row.
    private var heading: Int? { session.outline.last { $0.start <= commands.selection.location }?.start }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case .columns: columnsView
            case .clock: clockView
            }
        }
        .task(id: Key(shown: shown, path: session.path, version: shown ? session.editVersion : 0, caret: shown && subtree ? heading : nil, subtree: subtree, span: span)) {
            if shown { await refresh() }
        }
    }

    @ViewBuilder
    private var columnsView: some View {
        Picker("Scope", selection: $subtree) {
            Text("File").tag(false)
            Text("Subtree").tag(true)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        if let columns, !columns.rows.isEmpty {
            // A table, so the arrow keys move through the rows; selecting one goes to it.
            Table(columns.rows.map(ColumnRow.init), selection: $selectedRow) {
                TableColumnForEach(columns.specs.indices, id: \.self) { i in
                    TableColumn(columns.specs[i].title) { (item: ColumnRow) in
                        let row = item.row
                        Text(columns.specs[i].property == "ITEM" ? String(repeating: "*", count: row.level) + " " + row.values[i] : row.values[i])
                            .lineLimit(1)
                            .fontWeight(row.start == heading ? .semibold : .regular)
                    }
                }
            }
            .font(.system(.callout, design: .monospaced))
            .onChange(of: selectedRow) { if let selectedRow { session.reveal(selectedRow) } }
            .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { starts in
                if let start = starts.first { session.reveal(start) }
            }
        } else {
            ContentUnavailableView("No Entries", systemImage: "tablecells")
        }
    }

    @ViewBuilder
    private var clockView: some View {
        Picker("Span", selection: $span) {
            ForEach(Span.allCases, id: \.self) { Text($0.title) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        if clocked.isEmpty {
            ContentUnavailableView("No Clocked Time", systemImage: "clock")
        } else {
            // A selectable list, so the arrow keys move through the headings; selecting one goes to it.
            List(selection: $selectedClock) {
                ForEach(clocked, id: \.start) { entry in
                    HStack {
                        Text(entry.heading.isEmpty ? String(localized: "(untitled)") : entry.heading).lineLimit(1)
                        Spacer()
                        Text(ClockReport.hours(entry.minutes)).monospacedDigit()
                    }
                    .fontWeight(entry.start == heading ? .semibold : .regular)
                    .accessibilityElement(children: .combine)
                    .tag(entry.start)
                }
                HStack {
                    Text("Total").bold()
                    Spacer()
                    Text(ClockReport.hours(clocked.reduce(0) { $0 + $1.minutes })).bold().monospacedDigit()
                }
            }
            .onChange(of: selectedClock) { if let selectedClock { session.reveal(selectedClock) } }
            .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { starts in
                if let start = starts.first { session.reveal(start) }
            }
        }
    }

    private func refresh() async {
        guard session.isOrg, let document = session.document else {
            columns = nil
            clocked = []
            return
        }
        let found = await Self.content(text: document.text, tree: document.tree, heading: heading, subtree: subtree, span: span)
        guard !Task.isCancelled else { return }
        (columns, clocked) = found
    }

    @concurrent
    private nonisolated static func content(
        text: String, tree: OrgTree, heading: Int?, subtree: Bool, span: Span
    ) async -> (columns: ColumnView.View?, clocked: [(start: Int, heading: String, minutes: Int)]) {
        let columns = (try? ColumnView.capture(text: text, tree: tree, at: heading ?? 0, global: !subtree || heading == nil))?.view
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // Weeks start on Monday, as org's do.
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let today = Date()
        let from: Date? = switch span {
        case .today: today
        case .week: calendar.dateInterval(of: .weekOfYear, for: today)?.start
        case .all: nil
        }
        return (columns, ClockReport.byHeading(ClockReport.entries(text), from: from.map(formatter.string), to: span == .all ? nil : formatter.string(from: today)))
    }
}
