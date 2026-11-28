import AppKit
import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI

extension AgendaView {
    /// The day or week as a timeline, with the TODO entries without a date beside it. A click
    /// selects an entry and a double click opens it; dragging a block or its edges changes its
    /// time, and an entry dropped on the timeline gets the time it is dropped at.
    var timelineView: some View {
        let groups = agenda.groups(showAllDates: true, filter: filter)
        let first = agenda.days.first?.day ?? agenda.today
        let timeline = Timeline(groups: groups, first: first, count: max(agenda.days.count, 1), today: agenda.today,
                                defaultLength: timelineLength, calendar: .current)
        let todos = rows(agenda.unscheduled)
        let style = AgendaTimelineStyle(
            today: todayColor, foreground: theme.color("foreground") ?? .primary,
            selection: theme.color("selection") ?? Color.accentColor.opacity(0.25)
        ) { [theme] row in
            row.event.map { event in theme.dynamic(.systemPurple) { [theme] in theme.eventColor(event, dark: $0) } }
                ?? theme.dynamic { [theme] in theme.categoryColor(row.category, dark: $0) }
        }
        return AgendaTimelineView(
            timeline: timeline, todos: todos, style: style, step: timelineSnap, secondZone: TimeZone(identifier: timelineSecondZone), now: now,
            isSelected: { row, day in selection == timelineLine(row, day: day, groups: groups, todos: todos).id },
            tap: { row, day in
                selection = timelineLine(row, day: day, groups: groups, todos: todos).id
                focused = true
            },
            open: { row, day in
                if todos.contains(where: { $0.id == row.id }) {
                    if let item = row.item, let path = item.path, let offset = item.headingOffset {
                        commands.jump(path: path, offset: offset)
                        openWindow(id: "main")
                    }
                } else {
                    open(timelineLine(row, day: day, groups: groups, todos: todos))
                }
            },
            move: { row, from, to, start, end in retime(row, from: from, to: to, start: start, end: end) },
            drop: { payloads, day, start in
                let drops = AgendaTimelineDrop.resolve(payloads, groups: groups, todos: todos, start: start, step: timelineSnap)
                for drop in drops { apply(drop, on: day) }
                return !drops.isEmpty
            },
            showDay: { setSpan(.day, around: $0) },
            menu: { row, day in
                if todos.contains(where: { $0.id == row.id }) {
                    Button("Open") {
                        if let item = row.item, let path = item.path, let offset = item.headingOffset { commands.jump(path: path, offset: offset) }
                    }
                } else {
                    menu(timelineLine(row, day: day, groups: groups, todos: todos))
                }
            }
        )
    }

    /// The line `row` is on `day`, with the selection id the list gives it; a TODO entry's is
    /// `todo:` and its place.
    private func timelineLine(_ row: AgendaRow, day: Int, groups: [AgendaDayGroup], todos: [AgendaRow]) -> Line {
        if let index = todos.firstIndex(where: { $0.id == row.id }) { return Line(id: "todo:\(index)", row: row, day: day) }
        let group = groups.first { $0.day == day }
        if let group, let index = group.overdue.firstIndex(where: { $0.id == row.id }) {
            return Line(id: "\(day):o\(index)", row: row, day: day)
        }
        return Line(id: "\(day):\(group?.rows.firstIndex { $0.id == row.id } ?? -1)", row: row, day: day)
    }

    private func apply(_ drop: AgendaTimelineDrop, on day: Int) {
        switch drop {
        case .move(let row, let from, let start?, let end):
            retime(row, from: from, to: day, start: start, end: end)
        case .move(let row, let from, nil, _):
            if let item = row.item { reschedule(item, from: from, to: day) }
        case .schedule(let item, let start):
            schedule(item, on: day, at: start)
        }
    }

    /// Gives `row`'s entry, shown on `from`, the time `start` to `end` on `day`, asking for a
    /// note when the log settings want one.
    func retime(_ row: AgendaRow, from: Int, to day: Int, start: Int, end: Int?, answers: [String: String] = [:]) {
        report(session.retime(row, shownOn: from, to: day, start: start, end: end, answers: answers)) { answer in
            retime(row, from: from, to: day, start: start, end: end, answers: answers.merging(answer) { $1 })
        }
    }

    /// Schedules a TODO entry without a date on `day` at `start`.
    func schedule(_ item: AgendaItem, on day: Int, at start: Int, answers: [String: String] = [:]) {
        report(session.schedule(item, on: day, at: start, answers: answers)) { answer in
            schedule(item, on: day, at: start, answers: answers.merging(answer) { $1 })
        }
    }

    /// Shows what a timeline change did; a prompt asks and `again` runs with the answer.
    private func report(_ step: CommandStep?, again: @escaping ([String: String]) -> Void) {
        switch step {
        case nil: return
        case .prompt(let request)?:
            ask(request) { again([request.key: $0]) }
        case .failed(let text)?:
            message = text
            tick += 1
        case .external?:
            message = "Not available from the agenda"
        case .commit?:
            message = nil
            tick += 1
        }
    }
}
