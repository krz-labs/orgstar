import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI
import UniformTypeIdentifiers

/// Entries of the agenda files as a sortable table with property columns, or as a kanban
/// board by TODO keyword. Dragging a card to a column sets its keyword; edits go through the
/// open buffer or the file.
struct BoardView: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    @State private var agenda: AgendaModel
    @State private var entries: [BoardEntry] = []
    @State private var keywords: [String] = []
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\BoardRow.todoOrder), KeyPathComparator(\BoardRow.title)]
    @State private var message: String?
    /// A question an edit asks (a state note, a property).
    @State private var prompt: PromptRequest?
    @State private var tick = 0
    /// Whether the first load has finished, so an empty board says so.
    @State private var loaded = false
    /// The kanban card the arrow keys move from.
    @State private var current: String?
    @FocusState private var boardFocused: Bool
    @AppStorage("boardKanban") private var kanban = false
    @AppStorage("boardMatch") private var match = ""
    @AppStorage("boardColumns") private var columnText = "EFFORT"
    @AppStorage("agendaSubfolders") private var includeSubfolders = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.orgTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(workspace: WorkspaceModel, session: DocumentSession, commands: AppCommands) {
        self.workspace = workspace
        self.session = session
        self.commands = commands
        _agenda = State(initialValue: AgendaModel(workspace: workspace))
    }

    private var propertyColumns: [String] {
        columnText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
    }

    private var rows: [BoardRow] {
        entries.map { BoardRow(entry: $0, todoOrder: $0.todo.flatMap { keywords.firstIndex(of: $0) } ?? Int.max) }.sorted(using: sortOrder)
    }

    private struct RefreshKey: Hashable {
        var match: String
        var subfolders: Bool
        var files: Int
        var changed: Int?
        var edits: Int
        var path: String?
        var tick: Int
    }

    var body: some View {
        Group {
            if kanban { board } else { table }
        }
        .overlay {
            if loaded, entries.isEmpty {
                ContentUnavailableView(
                    "No Entries", systemImage: "rectangle.split.3x1",
                    description: Text(match.isEmpty ? "Headings with a TODO keyword in the agenda files show here." : "Nothing in the agenda files matches this.")
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if prompt != nil {
                PromptBar(request: $prompt)
            } else if let message {
                Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("View", selection: $kanban) {
                    Label("Table", systemImage: "tablecells").tag(false)
                    Label("Kanban", systemImage: "rectangle.split.3x1").tag(true)
                }
                .pickerStyle(.segmented)
                TextField("Match: +work/!TODO", text: $match)
                    .frame(minWidth: 200)
                if !kanban {
                    TextField("Property columns", text: $columnText)
                        .frame(minWidth: 140)
                        .help("Property names to show as columns, separated by commas")
                }
            }
        }
        .navigationTitle("Board")
        .task(id: RefreshKey(match: match, subfolders: includeSubfolders, files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion, path: session.path, tick: tick)) {
            agenda.includeSubfolders = includeSubfolders
            agenda.excludeArchives = OrgPreferences.agendaExcludeArchives()
            agenda.agendaFiles = OrgPreferences.agendaFiles()
            let open = session.openTexts
            let result = await agenda.board(open: open, match: match)
            entries = result.entries
            keywords = result.keywords
            loaded = true
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("TODO", value: \.todoOrder) { row in
                Text(row.entry.todo ?? "").foregroundStyle(keywordColor(row.entry.todo ?? "", done: row.entry.isDone)).bold()
            }
            .width(min: 50, ideal: 60, max: 90)
            TableColumn("P", value: \.priority) { row in Text(row.priority) }
                .width(min: 20, ideal: 24, max: 40)
            TableColumn("Title", value: \.title) { row in Text(row.title).lineLimit(1) }
                .width(min: 160, ideal: 320)
            TableColumn("Tags", value: \.tags) { row in Text(row.tags).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 60, ideal: 120)
            TableColumn("Scheduled", value: \.scheduled) { row in Text(row.scheduled).monospacedDigit() }
                .width(min: 80, ideal: 130)
            TableColumn("Deadline", value: \.deadline) { row in Text(row.deadline).monospacedDigit() }
                .width(min: 80, ideal: 130)
            TableColumnForEach(propertyColumns, id: \.self) { key in
                TableColumn(key.capitalized) { (row: BoardRow) in Text(row.entry.properties[key] ?? "") }
                    .width(min: 50, ideal: 80)
            }
            TableColumn("File", value: \.file) { row in Text(row.file).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 60, ideal: 120)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }) {
                Menu("Set TODO") {
                    ForEach(keywords, id: \.self) { keyword in Button(keyword) { setTodo(entry, keyword) } }
                    Divider()
                    Button(String(localized: "none.state", defaultValue: "None", comment: "No TODO state")) { setTodo(entry, nil) }
                }
                Button("Set Property…") { askProperty(entry) }
                Button("Open") { jump(entry) }
            }
        } primaryAction: { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }) { jump(entry) }
        }
    }

    // MARK: - Kanban

    private var board: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(keywords, id: \.self) { keyword in
                        column(keyword)
                    }
                }
                .padding(12)
            }
            .onChange(of: current) {
                if let current { proxy.scrollTo(current) }
            }
        }
        .background(theme.color("agenda-background", in: colorScheme) ?? .clear)
        .focusable()
        .focused($boardFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handle(press) }
    }

    /// The arrow keys move between cards, Shift-Left and Shift-Right move the card to the
    /// column before or after, Return opens it.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let columns = keywords.map { keyword in entries.filter { $0.todo == keyword } }
        let arrows: [KeyEquivalent] = [.upArrow, .downArrow, .leftArrow, .rightArrow]
        guard let c = columns.firstIndex(where: { $0.contains { $0.id == current } }),
              let r = columns[c].firstIndex(where: { $0.id == current }) else {
            guard arrows.contains(press.key), press.modifiers.isEmpty, let first = columns.lazy.compactMap(\.first).first else { return .ignored }
            current = first.id
            return .handled
        }
        let entry = columns[c][r]
        let step = press.key == .leftArrow ? -1 : 1
        if press.key == .return, press.modifiers.isEmpty {
            jump(entry)
        } else if press.modifiers == .shift, press.key == .leftArrow || press.key == .rightArrow {
            if keywords.indices.contains(c + step) { setTodo(entry, keywords[c + step]) }
        } else if press.modifiers.isEmpty, press.key == .upArrow || press.key == .downArrow {
            current = columns[c][min(max(r + (press.key == .upArrow ? -1 : 1), 0), columns[c].count - 1)].id
        } else if press.modifiers.isEmpty, press.key == .leftArrow || press.key == .rightArrow {
            // The nearest column with cards, at the same height.
            var k = c + step
            while columns.indices.contains(k), columns[k].isEmpty { k += step }
            if columns.indices.contains(k) { current = columns[k][min(r, columns[k].count - 1)].id }
        } else {
            return .ignored
        }
        return .handled
    }

    private func column(_ keyword: String) -> some View {
        let cards = entries.filter { $0.todo == keyword }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(keyword).font(.headline).foregroundStyle(keywordColor(keyword, done: cards.first?.isDone ?? false))
                Text("\(cards.count)").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cards) { entry in
                        card(entry)
                            .id(entry.id)
                            .draggable(entry.id)
                            .onTapGesture(count: 2) { jump(entry) }
                            .simultaneousGesture(TapGesture().onEnded {
                                current = entry.id
                                boardFocused = true
                            })
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(current == entry.id ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { jump(entry) }
                            .accessibilityActions {
                                // Dragging between columns, for VoiceOver.
                                ForEach(keywords.filter { $0 != keyword }, id: \.self) { other in
                                    Button("Move to \(other)") { setTodo(entry, other) }
                                }
                            }
                    }
                }
            }
        }
        .frame(width: 240, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids {
                if let entry = entries.first(where: { $0.id == id }), entry.todo != keyword { setTodo(entry, keyword) }
            }
            return true
        }
    }

    private func card(_ entry: BoardEntry) -> some View {
        let selected = current == entry.id
        return VStack(alignment: .leading, spacing: 4) {
            Text((entry.priority.map { "[#\($0)] " } ?? "") + entry.title).lineLimit(3)
                .foregroundStyle(theme.color("foreground") ?? .primary)
            HStack(spacing: 6) {
                Text(entry.category).font(.caption).foregroundStyle(secondary("agenda-category"))
                if !entry.tags.isEmpty {
                    Text(entry.tags.joined(separator: " ")).font(.caption).foregroundStyle(secondary("tags")).lineLimit(1)
                }
            }
            if let deadline = entry.deadline {
                // As the agenda colours a deadline: overdue when past, else due soon.
                let overdue = deadline.prefix(10) < Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
                Text("Deadline \(deadline)").font(.caption).foregroundStyle(theme.color(overdue ? "agenda-overdue" : "agenda-due-soon") ?? .red)
            } else if let scheduled = entry.scheduled {
                Text("Scheduled \(scheduled)").font(.caption).foregroundStyle(secondary("agenda-time"))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.color("block-background") ?? Color(nsColor: .controlBackgroundColor)))
        .overlay {
            // Increase Contrast: a full outline on every card and a heavier one on the selected card.
            if selected {
                RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("accent") ?? .accentColor, lineWidth: contrast == .increased ? 3 : 2)
            } else if contrast == .increased {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.6), lineWidth: 1)
            }
        }
    }

    /// A secondary text colour from the theme; the foreground under Increase Contrast.
    private func secondary(_ key: String) -> Color {
        contrast == .increased ? theme.color("foreground") ?? .primary : theme.color(key) ?? .secondary
    }

    /// A keyword's colour as the agenda draws it: its own, else its class's (NEXT, WAIT, …).
    private func keywordColor(_ keyword: String, done: Bool) -> Color {
        theme.dynamic(done ? .systemGreen : .systemRed) { [theme] in theme.todoColor(keyword, isDone: done, dark: $0) }
    }

    // MARK: - Editing

    private func perform(_ command: any OrgCommand, on entry: BoardEntry, answers: [String: String] = [:]) {
        switch session.perform(command, path: entry.path, at: entry.headingOffset, expect: (entry.headingOffset, entry.headingLine), answers: answers) {
        case .failed(let text): message = text
        case .prompt(let prompt):
            // A state note.
            self.prompt = PromptRequest(prompt: prompt) { answer in
                guard let answer else { return }
                perform(command, on: entry, answers: answers.merging([prompt.key: answer]) { $1 })
            }
        default: message = nil
        }
        tick += 1
    }

    private func setTodo(_ entry: BoardEntry, _ keyword: String?) {
        perform(SetTodo(keyword: keyword), on: entry)
    }

    private func askProperty(_ entry: BoardEntry) {
        prompt = PromptRequest(prompt: Prompt(key: "property", message: "Property (NAME value):")) { answer in
            guard let answer, let space = answer.firstIndex(of: " ") else { return }
            let key = String(answer[..<space])
            let value = String(answer[answer.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            perform(SetProperty(key: key, value: value), on: entry)
        }
    }

    private func jump(_ entry: BoardEntry) {
        commands.jump(path: entry.path, offset: entry.headingOffset)
        openWindow(id: "main")
    }
}

/// A table row with sortable values.
struct BoardRow: Identifiable {
    let entry: BoardEntry
    let todoOrder: Int
    var id: String { entry.id }
    var title: String { entry.title }
    var priority: String { entry.priority ?? "" }
    var tags: String { entry.tags.joined(separator: " ") }
    var scheduled: String { entry.scheduled ?? "" }
    var deadline: String { entry.deadline ?? "" }
    var file: String { (entry.path as NSString).lastPathComponent }
}
