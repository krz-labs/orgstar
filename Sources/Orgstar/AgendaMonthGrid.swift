import AppKit
import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI

extension AgendaView {
    /// The month as a grid of weeks. A click selects an entry, a double click opens it, and
    /// dragging it to another day moves its deadline, schedule or timestamp there; a day's
    /// number shows that day.
    var monthGridView: some View {
        let groups = agenda.groups(showAllDates: true, filter: filter)
        let first = agenda.days.first?.day ?? agenda.today
        let last = agenda.days.last?.day ?? first
        let weekStart = agenda.startOnWeekday ?? 1
        let grid = MonthGrid(groups: groups, first: first, last: last, today: agenda.today, weekStart: weekStart)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(grid.weeks.first ?? [], id: \.day) { cell in
                    Text(Self.format(cell.day, "EEE"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            Divider()
            GeometryReader { geometry in
                let height = geometry.size.height / CGFloat(max(grid.weeks.count, 1))
                VStack(spacing: 0) {
                    ForEach(grid.weeks, id: \.first!.day) { week in
                        HStack(spacing: 0) {
                            ForEach(week) { cell in
                                monthCell(cell, groups: groups, height: height)
                                    .frame(width: geometry.size.width / 7, height: height, alignment: .topLeading)
                                    .overlay(alignment: .trailing) { Divider() }
                            }
                        }
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
            }
        }
    }

    private static let gridLineHeight: CGFloat = 17

    private func monthCell(_ cell: MonthGrid.Cell, groups: [AgendaDayGroup], height: CGFloat) -> some View {
        // The day number takes a line; a last line says how many more there are.
        let fits = max(Int((height - 28) / Self.gridLineHeight), 1)
        let shown = cell.rows.count > fits ? fits - 1 : cell.rows.count
        let group = groups.first { $0.day == cell.day }
        return VStack(alignment: .leading, spacing: 1) {
            Button {
                setSpan(.day, around: cell.day)
            } label: {
                Text(Days.date(cell.day).day, format: .number)
                    .font(.callout.weight(cell.isToday ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(cell.isToday ? Color.white : cell.inMonth ? theme.color("agenda-date") ?? .primary : .secondary.opacity(0.6))
                    .padding(.horizontal, 5)
                    .background { if cell.isToday { Capsule().fill(todayColor) } }
            }
            .buttonStyle(.plain)
            .help("Show this day")
            ForEach(Array(cell.rows.prefix(shown).enumerated()), id: \.offset) { _, row in
                gridEntry(row, line: gridLine(row, in: group, day: cell.day))
            }
            if shown < cell.rows.count {
                Button(String(localized: "\(cell.rows.count - shown) more", comment: "Month grid: entries of a day that don't fit")) {
                    setSpan(.day, around: cell.day)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dropDay == cell.day ? todayColor.opacity(0.15) : cell.inMonth ? Color.clear : Color.primary.opacity(0.03))
        .contentShape(Rectangle())
        .modifier(AgendaDropTarget(day: cell.day, target: $dropDay, drop: drop(_:on:)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.format(cell.day, "EEEE d MMMM"))
    }

    /// The line `row` is on `day`, with the selection id the list gives it.
    private func gridLine(_ row: AgendaRow, in group: AgendaDayGroup?, day: Int) -> Line {
        if let group, let index = group.overdue.firstIndex(where: { $0.id == row.id }) {
            return Line(id: "\(day):o\(index)", row: row, day: day)
        }
        return Line(id: "\(day):\(group?.rows.firstIndex { $0.id == row.id } ?? -1)", row: row, day: day)
    }

    private func gridEntry(_ row: AgendaRow, line: Line) -> some View {
        let selected = selection == line.id
        let dot = row.event.map { event in theme.dynamic(.systemPurple) { [theme] in theme.eventColor(event, dark: $0) } }
            ?? theme.dynamic { [theme] in theme.categoryColor(row.category, dark: $0) }
        let status = theme.dynamic(.labelColor) { [theme] in theme.statusColor(row.status, dark: $0) }
        return HStack(spacing: 4) {
            Circle().fill(dot).frame(width: 6, height: 6)
            if let start = row.start {
                Text(String(format: "%02d:%02d", start / 100 % 24, start % 100)).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(row.title.isEmpty ? " " : row.title)
                .strikethrough(row.isDone)
                .foregroundStyle(row.isDone ? AnyShapeStyle(.secondary) : row.status == .overdue || row.status == .dueSoon ? AnyShapeStyle(status)
                    : AnyShapeStyle(theme.color("foreground") ?? .primary))
        }
        .font(.caption)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: Self.gridLineHeight - 1, alignment: .leading)
        .padding(.horizontal, 4)
        .opacity(row.isBlocked ? 0.5 : 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? theme.color("selection") ?? Color.accentColor.opacity(0.25) : hovered == line.id ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = line.id } else if hovered == line.id { hovered = nil }
        }
        .onTapGesture(count: 2) { open(line) }
        .simultaneousGesture(TapGesture().onEnded {
            selection = line.id
            focused = true
        })
        .contextMenu { menu(line) }
        .modifier(AgendaDragSource(drag: AgendaDrag(row, day: line.day)))
        .help(row.category.isEmpty ? row.title : "\(row.category): \(row.title)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Lets an agenda row be dragged to another day, when it can move.
struct AgendaDragSource: ViewModifier {
    let drag: AgendaDrag?

    func body(content: Content) -> some View {
        if let drag { content.draggable(drag.payload) } else { content }
    }
}

/// Takes agenda rows dropped on `day`, and sets `target` while one is over it.
struct AgendaDropTarget: ViewModifier {
    let day: Int?
    @Binding var target: Int?
    let drop: ([String], Int) -> Bool

    func body(content: Content) -> some View {
        if let day {
            content.dropDestination(for: String.self) { payloads, _ in
                target = nil
                return drop(payloads, day)
            } isTargeted: { inside in
                if inside { target = day } else if target == day { target = nil }
            }
        } else {
            content
        }
    }
}
