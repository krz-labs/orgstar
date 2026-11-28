import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI

/// The sidebar's agenda: the agenda, or one of the named views, as a narrow list beside the
/// editor. A click on an entry shows it in the editor. It follows the Agenda window's span and
/// files, and shows Calendar events and Reminders only once the Agenda window has asked for them.
struct AgendaSidebar: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    /// Changes every hour, so that the day rolls over.
    let hour: Int
    @Binding var showsAgenda: Bool
    @State private var agenda: AgendaModel
    @State private var views = AgendaViewLoader.builtIn
    @AppStorage("sidebarAgendaView") private var viewName = AgendaViewLoader.builtIn[0].name
    @AppStorage("agendaSpan") private var span = 10
    @AppStorage("agendaStartOffset") private var startOffset = 0
    @AppStorage("agendaStartOnWeekday") private var startOnWeekday = "1"
    @AppStorage("agendaSubfolders") private var includeSubfolders = false
    @AppStorage("agendaFiles") private var agendaFileList = ""
    @Environment(\.orgTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.textScale) private var scale

    init(workspace: WorkspaceModel, session: DocumentSession, commands: AppCommands, hour: Int, showsAgenda: Binding<Bool>) {
        self.workspace = workspace
        self.session = session
        self.commands = commands
        self.hour = hour
        _showsAgenda = showsAgenda
        _agenda = State(initialValue: AgendaModel(workspace: workspace))
    }

    private struct Key: Equatable {
        var view: String
        var mode: AgendaMode?
        var settings: [String]
        var hidden: Set<String>
        var files: Int
        var changed: Int?
        var edits: Int
        var hour: Int
    }

    private var view: AgendaViewDefinition { views.first { $0.name == viewName } ?? AgendaViewLoader.builtIn[0] }

    /// A section of rows under a header: a day, or a list or block's title.
    private struct Group: Identifiable {
        let id: String
        let header: String
        var isToday = false
        var rows: [AgendaRow]
    }

    private var groups: [Group] {
        func days(_ groups: [AgendaDayGroup], prefix: String) -> [Group] {
            groups.map { day in
                // Org pads the day's name with spaces.
                Group(id: "\(prefix)\(day.day)", header: day.header.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                      isToday: day.isToday, rows: day.overdue + day.rows)
            }
        }
        func list(_ items: [AgendaItem]) -> [AgendaRow] {
            items.compactMap { AgendaRow(item: $0, day: agenda.today, today: agenda.today) }
        }
        switch agenda.mode {
        case .agenda:
            return days(agenda.groups(), prefix: "")
        case .blocks:
            return agenda.blocks.enumerated().flatMap { index, block in
                block.isAgenda
                    ? days(agenda.groups(block, showAllDates: false, filter: AgendaFilter()), prefix: "b\(index):")
                    : [Group(id: "b\(index)", header: block.header, rows: list(block.list))]
            }
        default:
            return [Group(id: "list", header: agenda.viewSettings[agenda.mode]?.header ?? agenda.mode.title, rows: list(agenda.list))]
        }
    }

    var body: some View {
        let groups = groups
        List {
            if groups.allSatisfy(\.rows.isEmpty) {
                Text("Nothing scheduled").font(.scaled(.body, scale)).foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                if !group.rows.isEmpty {
                    Section {
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in line(row) }
                    } header: {
                        Text(group.header).font(.scaled(.subheadline, scale).weight(.semibold)).foregroundStyle((group.isToday ? theme.color("agenda-today") : theme.color("sidebar-header")) ?? .secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .themedListBackground(theme.color("sidebar-background", in: colorScheme))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarBar(showsAgenda: $showsAgenda) {
                Menu {
                    ForEach(views) { view in Button(view.name) { viewName = view.name } }
                    Divider()
                    Button("Open Agenda Window") { openWindow(id: "agenda") }
                } label: {
                    Text(view.name)
                }
                .fixedSize()
                .help("The agenda view shown here; add views in views.toml")
            }
        }
        .task(id: Key(
            view: viewName, mode: views.first { $0.name == viewName }?.mode, settings: ["\(span)", "\(startOffset)", startOnWeekday, "\(includeSubfolders)", agendaFileList],
            hidden: HiddenFolders.shared.all, files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion, hour: hour
        )) { await refresh() }
    }

    @ViewBuilder
    private func line(_ row: AgendaRow) -> some View {
        let label = HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !row.gutter.isEmpty {
                Text(row.gutter)
                    .font(.scaled(.caption, scale))
                    .monospacedDigit()
                    .foregroundStyle(theme.dynamic(.secondaryLabelColor) { [theme] in theme.statusColor(row.status, dark: $0) })
                    .frame(width: 52 * scale, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let todo = row.todo {
                        Text(todo)
                            .font(.scaled(.caption, scale).bold())
                            .foregroundStyle(theme.dynamic(row.isDone ? .systemGreen : .systemRed) { [theme] in theme.todoColor(todo, isDone: row.isDone, dark: $0) })
                    }
                    Text(row.title.isEmpty ? "(untitled)" : row.title)
                        .font(.scaled(.body, scale))
                        .lineLimit(2)
                        .strikethrough(row.isDone)
                        .foregroundStyle(row.isDone ? .secondary : theme.color("sidebar-foreground") ?? .primary)
                }
                if !row.category.isEmpty {
                    Text(row.category).font(.scaled(.caption2, scale)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .opacity(row.isBlocked ? 0.5 : 1)
        if let item = row.item, let path = item.path, let offset = item.headingOffset ?? item.markerOffset {
            Button {
                commands.jump(path: path, offset: offset)
            } label: {
                label.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help((path as NSString).lastPathComponent)
        } else {
            label
        }
    }

    private func refresh() async {
        let loaded = AgendaViewLoader.load()
        views = loaded.views
        agenda.viewSettings = AgendaViewLoader.settings(loaded.views)
        agenda.mode = view.mode
        agenda.span = span
        agenda.startOffset = startOffset
        agenda.startOnWeekday = Int(startOnWeekday)
        agenda.includeSubfolders = includeSubfolders
        agenda.excludeArchives = OrgPreferences.agendaExcludeArchives()
        agenda.hiddenFolders = HiddenFolders.shared.all
        agenda.agendaFiles = OrgPreferences.agendaFiles()
        agenda.options = OrgPreferences.agendaOptions(agenda.options)
        let pro = ProAccess.shared.isUnlocked
        agenda.calendarEvents = pro && OrgPreferences.calendarEvents() && CalendarEvents.isAuthorized ? CalendarAccess.events : nil
        agenda.calendarNames = OrgPreferences.calendarEventCalendars()
        agenda.reminderLists = pro && OrgPreferences.agendaReminders() && ReminderLists.isAuthorized ? CalendarAccess.reminders : nil
        agenda.reminderListNames = OrgPreferences.agendaReminderLists()
        agenda.contactDates = pro && OrgPreferences.agendaContactDates() && ContactDates.isAuthorized ? CalendarAccess.contacts : nil
        await agenda.refresh(open: session.openTexts)
    }
}
