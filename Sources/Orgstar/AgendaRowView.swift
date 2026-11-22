import AppKit
import OrgApp
import OrgDocument
import OrgCore
import OrgPresentation
import SwiftUI

/// One agenda line: the time or status over an icon; above the title the category, progress and
/// tags, with the TODO keyword and priority at the end; a habit's graph under the title.
struct AgendaRowView: View {
    let row: AgendaRow
    /// The agenda day the row is on, for habit graphs.
    var day: Int
    var showsGutter = true
    var selected = false
    var hovered = false
    /// Marked for a bulk action.
    var marked = false
    @Environment(\.orgTheme) private var theme
    @ScaledMetric(relativeTo: .callout) private var gutterWidth = AgendaRowView.gutterWidth
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @ScaledMetric(relativeTo: .caption) private var badgeSize: CGFloat = 18

    static let gutterWidth: CGFloat = 92

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsGutter { gutter }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 8) {
                    metaLine
                    Spacer(minLength: 0)
                    marks
                }
                Text(row.title.isEmpty ? " " : row.title)
                    .font(.body)
                    .strikethrough(row.isDone)
                    .foregroundStyle(row.isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.color("foreground") ?? .primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let habit = row.item?.habit {
                    HabitGraph(cells: habit.graph(today: day), theme: theme).padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        // `org-agenda-dim-blocked-tasks`.
        .opacity(row.isBlocked ? 0.5 : 1)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? theme.color("selection") ?? Color.accentColor.opacity(0.2) : hovered ? Color.primary.opacity(0.05) : .clear)
                .padding(.horizontal, 6)
        }
        .overlay(alignment: .leading) {
            if marked {
                Capsule().fill(theme.color("agenda-today") ?? .accentColor).frame(width: 3).padding(.vertical, 8).padding(.leading, 8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Increase Contrast: keyword and priority badges are filled with their colour, tags outlined in full.
    private var highContrast: Bool { contrast == .increased }

    private var background: Color { theme.color("agenda-background") ?? Color(nsColor: .textBackgroundColor) }

    private var statusColor: Color {
        theme.dynamic(.secondaryLabelColor) { [theme, row] in theme.statusColor(row.status, dark: $0) }
    }

    /// The start over the end for timed rows, else the status; the icon under them.
    private var gutter: some View {
        VStack(alignment: .leading, spacing: 2) {
            let lines = row.gutterLines
            Text(lines[0])
                .font(.callout.weight(row.status == .overdue || row.status == .dueSoon ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(statusColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if lines.count > 1 {
                Text(lines[1]).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let symbol = row.symbol {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .imageScale(row.icon == .event ? .small : .medium)
                    .foregroundStyle(iconColor)
            }
        }
        .frame(width: gutterWidth, alignment: .leading)
    }

    private var iconColor: Color {
        if let event = row.event { return theme.dynamic(.systemPurple) { [theme] in theme.eventColor(event, dark: $0) } }
        return row.status == .normal ? Color.secondary.opacity(0.8) : statusColor
    }

    /// The category, the prefix's detail, progress and tags, wrapping to more lines as needed.
    private var metaLine: some View {
        FlowLayout(spacing: 5, lineSpacing: 3) {
            if !row.category.isEmpty {
                HStack(spacing: 5) {
                    Circle()
                        .fill(row.event.map { event in theme.dynamic(.systemPurple) { [theme] in theme.eventColor(event, dark: $0) } }
                            ?? theme.dynamic { [theme, row] in theme.categoryColor(row.category, dark: $0) })
                        .frame(width: 6, height: 6)
                    Text(row.category)
                        .font(.subheadline)
                        .foregroundStyle(theme.color("agenda-category") ?? .secondary)
                        .lineLimit(1)
                }
            }
            if let detail = row.prefixDetail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach([row.progress, row.detail].compactMap { $0 }, id: \.self) { progress in
                Text(progress)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
            }
            ForEach(row.tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.color("tags") ?? .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().strokeBorder((theme.color("tags") ?? .secondary).opacity(highContrast ? 1 : 0.35), lineWidth: highContrast ? 1 : 0.5))
            }
        }
    }

    /// The TODO keyword and the priority, at the end of the category's line.
    private var marks: some View {
        HStack(spacing: 6) {
            if let todo = row.todo {
                let color = theme.dynamic(row.isDone ? .systemGreen : .systemRed) { [theme, row] in theme.todoColor(todo, isDone: row.isDone, dark: $0) }
                HStack(spacing: 2) {
                    // Done or not without telling green from red.
                    if withoutColor, row.isDone { Image(systemName: "checkmark") }
                    Text(todo)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(highContrast ? background : color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(highContrast ? color : color.opacity(0.14)))
                .overlay { if withoutColor, !highContrast { Capsule().strokeBorder(color, lineWidth: 1) } }
            }
            priorityBadge
        }
        .fixedSize()
    }

    @ViewBuilder
    private var priorityBadge: some View {
        if let priority = row.priority {
            let color = theme.dynamic(.systemOrange) { [theme] in theme.priorityColor(priority, dark: $0) }
            Text(priority)
                .font(.caption.weight(.bold))
                .foregroundStyle(highContrast ? background : color)
                .frame(width: badgeSize, height: badgeSize)
                .background(Circle().fill(highContrast ? color : color.opacity(0.14)))
                .overlay(Circle().strokeBorder(color.opacity(highContrast ? 1 : 0.6), lineWidth: 1))
                .help("Priority \(priority)")
        } else {
            Color.clear.frame(width: badgeSize, height: badgeSize)
        }
    }
}

/// org-habit's consistency graph: a cell per day, `*` where the habit was done, `!` today.
struct HabitGraph: View {
    let cells: [Habit.Cell]
    var theme: ThemeSpec = .default

    var body: some View {
        HStack(spacing: 1) {
            ForEach(cells, id: \.day) { cell in
                Text(String(cell.glyph))
                    .font(.caption2.monospaced().weight(.bold))
                    .frame(width: 8, height: 14)
                    .background(color(cell.face))
                    .help(Self.label(cell))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Done \(cells.filter { $0.glyph == "*" }.count) of the last \(Habit.precedingDays) days")
    }

    /// Due-state colors, lighter for days to come, as org-habit's faces.
    func color(_ face: Habit.Face) -> Color {
        func themed(_ key: String, _ fallback: Color) -> Color { theme.color(key) ?? fallback }
        switch face {
        case .clear: return themed("habit-clear", .blue).opacity(0.7)
        case .clearFuture: return themed("habit-clear", .blue).opacity(0.35)
        case .ready: return themed("habit-ready", .green).opacity(0.75)
        case .readyFuture: return themed("habit-ready", .green).opacity(0.35)
        case .alert: return themed("habit-alert", .yellow).opacity(0.85)
        case .alertFuture: return themed("habit-alert", .yellow).opacity(0.4)
        case .overdue: return themed("habit-overdue", .red).opacity(0.75)
        case .overdueFuture: return themed("habit-overdue", .red).opacity(0.35)
        }
    }

    static func label(_ cell: Habit.Cell) -> String {
        let date = Days.date(cell.day)
        return String(format: "%04d-%02d-%02d", date.year, date.month, date.day) + (cell.glyph == "*" ? " DONE" : "")
    }
}
