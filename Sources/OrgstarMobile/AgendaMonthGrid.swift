#if os(iOS)
import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI

/// The month as a grid of weeks, each day with the start of its entries. Tapping a day picks
/// it, and its entries show under the grid; an entry dragged (a long press, then a move) to
/// another day moves its deadline, schedule or timestamp there.
struct AgendaMonthGrid: View {
    let grid: MonthGrid
    @Binding var picked: Int
    let theme: ThemeSpec
    let dark: Bool
    let drop: ([String], Int) -> Bool
    @State private var target: Int?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .caption2) private var lineHeight: CGFloat = 14

    private var compact: Bool { sizeClass == .compact }
    /// Entries a day shows before `+n`.
    private var fits: Int { compact ? 3 : 5 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(grid.weeks.first ?? []) { cell in
                    Text(date(cell.day).formatted(.dateTime.weekday(compact ? .narrow : .abbreviated)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            ForEach(grid.weeks, id: \.first!.day) { week in
                Divider()
                HStack(spacing: 0) {
                    ForEach(week) { cell in self.cell(cell) }
                }
            }
        }
    }

    private var todayColor: Color { theme.color("agenda-today", dark: dark)?.swiftUI ?? .accentColor }

    private func background(_ cell: MonthGrid.Cell) -> Color {
        if target == cell.day { return todayColor.opacity(0.2) }
        if cell.day == picked { return todayColor.opacity(0.08) }
        return cell.inMonth ? .clear : Color.primary.opacity(0.03)
    }

    private func number(_ cell: MonthGrid.Cell) -> some View {
        let isPicked = cell.day == picked
        let color: Color = cell.isToday ? .white : isPicked ? todayColor : cell.inMonth ? .primary : Color.secondary.opacity(0.5)
        return Text(Days.date(cell.day).day, format: .number)
            .font(.footnote.weight(cell.isToday || isPicked ? .bold : .regular).monospacedDigit())
            .foregroundStyle(color)
            .frame(minWidth: 22, minHeight: 22)
            .background { if cell.isToday { Circle().fill(todayColor) } }
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
    }

    private func cell(_ cell: MonthGrid.Cell) -> some View {
        let shown = cell.rows.count > fits ? fits - 1 : cell.rows.count
        let isPicked = cell.day == picked
        let label = date(cell.day).formatted(.dateTime.weekday(.wide).day().month(.wide))
        let titles = cell.rows.map(\.title).joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 1) {
            number(cell)
            ForEach(Array(cell.rows.prefix(shown).enumerated()), id: \.offset) { _, row in
                entry(row, day: cell.day)
            }
            if shown < cell.rows.count {
                Text(verbatim: "+\(cell.rows.count - shown)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity, minHeight: 26 + CGFloat(fits) * lineHeight, alignment: .top)
        .background(background(cell))
        .contentShape(Rectangle())
        .onTapGesture { picked = cell.day }
        .dropDestination(for: String.self) { payloads, _ in
            target = nil
            picked = cell.day
            return drop(payloads, cell.day)
        } isTargeted: { inside in
            if inside { target = cell.day } else if target == cell.day { target = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(titles)
        .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
    }

    private func entry(_ row: AgendaRow, day: Int) -> some View {
        let color = row.event.flatMap { theme.eventColor($0, dark: dark)?.swiftUI } ?? (row.isEvent ? .purple : theme.categoryColor(row.category, dark: dark).swiftUI)
        let overdue: Color = theme.statusColor(.overdue, dark: dark)?.swiftUI ?? .red
        let foreground: Color = row.isDone ? .secondary : row.status == .overdue ? overdue : .primary
        let label = Text(row.title.isEmpty ? " " : row.title)
            .font(.caption2)
            .lineLimit(1)
            .strikethrough(row.isDone)
            .foregroundStyle(foreground)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: lineHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.18)))
            .opacity(row.isBlocked ? 0.5 : 1)
        return Group {
            if let drag = AgendaDrag(row, day: day) { label.draggable(drag.payload) } else { label }
        }
    }

    private func date(_ day: Int) -> Date {
        let d = Days.date(day)
        return Calendar.current.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) ?? Date()
    }
}

/// An agenda row that drags to another day when it can move.
struct RowDrag: ViewModifier {
    let drag: AgendaDrag?

    func body(content: Content) -> some View {
        if let drag { content.draggable(drag.payload) } else { content }
    }
}
#endif
