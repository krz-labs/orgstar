import OrgCore
import OrgPresentation
import SwiftUI

/// The colors the timeline draws with, from each app's theme.
public struct AgendaTimelineStyle {
    public var today: Color
    public var foreground: Color
    public var selection: Color
    /// A row's tint: its calendar's color for an event, its category's otherwise.
    public var tint: (AgendaRow) -> Color

    public init(today: Color, foreground: Color, selection: Color, tint: @escaping (AgendaRow) -> Color) {
        self.today = today
        self.foreground = foreground
        self.selection = selection
        self.tint = tint
    }
}

/// What the timeline's callbacks are given for a drop on a day: dragged rows and TODO entries
/// as `AgendaDrag` and `AgendaTodoDrag` resolve them.
public enum AgendaTimelineDrop: Equatable {
    /// An agenda row moved to `day`, at `start` and to `end` when it has a time range; with no
    /// `start` (the all-day strip) it moves only its day.
    case move(AgendaRow, from: Int, start: Int?, end: Int?)
    /// A TODO entry without a date scheduled at `start`.
    case schedule(AgendaItem, start: Int)

    /// The drops `payloads` stand for on a day at `start` (minutes; nil for the all-day strip):
    /// rows found among `groups`, TODO entries among `todos`. A dragged row keeps the length of
    /// its time range; one without a range keeps having none.
    public static func resolve(_ payloads: [String], groups: [AgendaDayGroup], todos: [AgendaRow], start: Int?, step: Int) -> [AgendaTimelineDrop] {
        payloads.compactMap { payload in
            if let drag = AgendaDrag(payload: payload), let row = drag.row(in: groups) {
                guard let start else { return .move(row, from: drag.day, start: nil, end: nil) }
                guard let item = row.item, AgendaReschedule.canMoveTime(item) else { return nil }
                guard let from = row.start, let to = row.end else { return .move(row, from: drag.day, start: min(start, Timeline.latestEnd - 1), end: nil) }
                let length = (to / 100 * 60 + to % 100) - (from / 100 * 60 + from % 100)
                let moved = Timeline.moved(start: start, end: start + max(length, 1), by: 0, step: step)
                return .move(row, from: drag.day, start: moved.start, end: moved.end)
            }
            if let start, let drag = AgendaTodoDrag(payload: payload), let item = drag.row(in: todos)?.item {
                return .schedule(item, start: min(start, Timeline.latestEnd - 1))
            }
            return nil
        }
    }
}

/// The agenda's days by time of day: an hour scale (with a second time zone when one is set),
/// a column a day with its timed entries as blocks, an all-day strip above, and optionally the
/// TODO entries without a date beside it. Dragging a block moves its time (and day, between
/// columns); dragging its top or bottom edge changes its start or end. A row or TODO entry
/// dropped on a column gets that time; dropped on the all-day strip, a row moves to that day.
/// Calendar events, Contacts dates and ranges of days don't drag. On iOS a block moves after
/// a long press, so the scale still scrolls.
public struct AgendaTimelineView<RowMenu: View>: View {
    let timeline: Timeline
    let todos: [AgendaRow]?
    let style: AgendaTimelineStyle
    let step: Int
    let secondZone: TimeZone?
    let now: Date
    let calendar: Calendar
    let isSelected: (AgendaRow, Int) -> Bool
    let tap: (AgendaRow, Int) -> Void
    let open: (AgendaRow, Int) -> Void
    let move: (_ row: AgendaRow, _ from: Int, _ to: Int, _ start: Int, _ end: Int?) -> Void
    let drop: (_ payloads: [String], _ day: Int, _ start: Int?) -> Bool
    let showDay: ((Int) -> Void)?
    let menu: (AgendaRow, Int) -> RowMenu

    @State private var dragging: Dragging?
    @State private var target: Int?
    @State private var allDayHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .caption) private var hourHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .caption2) private var labelWidth: CGFloat = 44

    public init(
        timeline: Timeline, todos: [AgendaRow]?, style: AgendaTimelineStyle, step: Int, secondZone: TimeZone?, now: Date, calendar: Calendar = .current,
        isSelected: @escaping (AgendaRow, Int) -> Bool, tap: @escaping (AgendaRow, Int) -> Void, open: @escaping (AgendaRow, Int) -> Void,
        move: @escaping (AgendaRow, Int, Int, Int, Int?) -> Void, drop: @escaping ([String], Int, Int?) -> Bool, showDay: ((Int) -> Void)?,
        @ViewBuilder menu: @escaping (AgendaRow, Int) -> RowMenu
    ) {
        self.timeline = timeline
        self.todos = todos
        self.style = style
        self.step = step
        self.secondZone = secondZone
        self.now = now
        self.calendar = calendar
        self.isSelected = isSelected
        self.tap = tap
        self.open = open
        self.move = move
        self.drop = drop
        self.showDay = showDay
        self.menu = menu
    }

    /// A block being moved or resized: where it would land.
    private struct Dragging: Equatable {
        enum Edge { case top, bottom }
        /// The block's id and the index of the day it is on.
        let blockID: String
        let origin: Int
        let edge: Edge?
        var start: Int
        var end: Int
        var dayIndex: Int
    }

    private static var space: String { "agenda-timeline" }
    private var perMinute: CGFloat { hourHeight / 60 }
    private var scaleWidth: CGFloat { secondZone == nil ? labelWidth : labelWidth * 2 }
    private var days: [Timeline.Day] { timeline.days }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                allDayStrip
                Divider()
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            scale
                            GeometryReader { geometry in
                                columns(width: geometry.size.width / CGFloat(max(days.count, 1)))
                            }
                            .frame(height: hourHeight * 24)
                        }
                        .padding(.vertical, 8)
                    }
                    .onAppear { proxy.scrollTo("hour\(firstHour)", anchor: .top) }
                    // Other days, or their entries once read.
                    .onChange(of: [days.first?.day ?? 0, days.contains { !$0.blocks.isEmpty } ? 1 : 0]) {
                        proxy.scrollTo("hour\(firstHour)", anchor: .top)
                    }
                }
            }
            if let todos {
                Divider()
                todoList(todos)
            }
        }
    }

    /// The hour shown first: one before the earliest block, else before now on today, else 8.
    private var firstHour: Int {
        if let earliest = days.flatMap(\.blocks).map(\.start).min() { return max(min(earliest / 60 - 1, 16), 0) }
        if days.contains(where: \.isToday) { return max(min(Timeline.minutes(now, calendar: calendar) / 60 - 1, 16), 0) }
        return 8
    }

    // MARK: - Header and all-day strip

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                if let secondZone, let first = days.first {
                    Text(verbatim: Timeline.zoneName(calendar.timeZone, day: first.day)).frame(width: labelWidth)
                    Text(verbatim: Timeline.zoneName(secondZone, day: first.day)).frame(width: labelWidth)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: scaleWidth)
            ForEach(days) { day in
                let label = dayTitle(day.day)
                Group {
                    if let showDay, days.count > 1 {
                        Button { showDay(day.day) } label: { Text(label) }
                            .buttonStyle(.plain)
                            .help(Text("Show this day"))
                    } else {
                        Text(label)
                    }
                }
                .font(.callout.weight(day.isToday ? .bold : .medium))
                .foregroundStyle(day.isToday ? style.today : style.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }

    private func dayTitle(_ day: Int) -> String {
        let date = Days.date(day)
        let value = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) ?? now
        return days.count > 1 ? value.formatted(.dateTime.weekday(.abbreviated).day()) : value.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// The all-day strip, scrolling when it is taller than about four lines.
    private var allDayStrip: some View {
        ScrollView(.vertical) {
            allDayRows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { allDayHeight = $0 }
        }
        .frame(height: min(max(allDayHeight, 24), 100))
    }

    private var allDayRows: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day", comment: "Agenda timeline: the strip of entries without a time")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
                .padding(.top, 3)
                .frame(width: scaleWidth, alignment: .trailing)
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(day.allDay) { row in chip(row, day: day.day) }
                }
                .padding(2)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
                .background(target == day.day ? style.today.opacity(0.15) : .clear)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { payloads, _ in
                    target = nil
                    return drop(payloads, day.day, nil)
                } isTargeted: { inside in
                    if inside { target = day.day } else if target == day.day { target = nil }
                }
            }
        }
    }

    private func chip(_ row: AgendaRow, day: Int) -> some View {
        let tint = style.tint(row)
        let label = HStack(spacing: 4) {
            if let symbol = row.symbol { Image(systemName: symbol).font(.caption2).foregroundStyle(tint) }
            Text(row.title.isEmpty ? " " : row.title)
                .strikethrough(row.isDone)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(isSelected(row, day) ? style.selection : tint.opacity(0.15)))
        .opacity(row.isBlocked || row.isDone ? 0.6 : 1)
        .contentShape(Rectangle())
        return selectable(label, row: row, day: day)
            .modifier(DragPayload(payload: AgendaDrag(row, day: day)?.payload))
    }

    // MARK: - Scale and columns

    private var scale: some View {
        let zoneLabels = secondZone.flatMap { zone in days.first.map { Timeline.zoneLabels(day: $0.day, local: calendar.timeZone, other: zone) } }
        return VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 0) {
                    Text(verbatim: String(format: "%02d:00", hour)).frame(width: labelWidth, alignment: .trailing)
                    if let zoneLabels { Text(verbatim: zoneLabels[hour]).frame(width: labelWidth, alignment: .trailing).foregroundStyle(.tertiary) }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
                // The label sits on its hour's line.
                .offset(y: -7)
                .opacity(hour == 0 ? 0 : 1)
                .frame(width: scaleWidth, height: hourHeight, alignment: .topTrailing)
                .id("hour\(hour)")
            }
        }
    }

    private func columns(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    VStack(spacing: 0) {
                        Divider()
                        Spacer(minLength: 0)
                    }
                    .frame(height: hourHeight)
                }
            }
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                column(day, index: index, width: width)
                    .frame(width: width, height: hourHeight * 24, alignment: .topLeading)
                    // On the column, not its background, so that a drop on a block counts too.
                    .dropDestination(for: String.self) { payloads, location in
                        target = nil
                        let start = min(max(Timeline.snap(Int(location.y / perMinute), to: step), 0), Timeline.latestEnd - 1)
                        return drop(payloads, day.day, start)
                    } isTargeted: { inside in
                        if inside { target = day.day } else if target == day.day { target = nil }
                    }
                    .overlay(alignment: .leading) { Divider() }
                    .offset(x: CGFloat(index) * width)
            }
            if let dragging, dragging.origin < days.count, dragging.dayIndex < days.count,
               let block = days[dragging.origin].blocks.first(where: { $0.id == dragging.blockID }) {
                blockFace(block, start: dragging.start, end: dragging.end, column: 0, columns: 1, width: width, selected: true)
                    .offset(x: CGFloat(dragging.dayIndex) * width)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(.named(Self.space))
    }

    private func column(_ day: Timeline.Day, index: Int, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(target == day.day ? style.today.opacity(0.1) : day.isToday ? style.today.opacity(0.03) : Color.clear)
                .contentShape(Rectangle())
            ForEach(day.blocks) { block in
                blockView(block, day: day, index: index, width: width)
            }
            if day.isToday {
                let y = CGFloat(Timeline.minutes(now, calendar: calendar)) * perMinute
                HStack(spacing: 0) {
                    Circle().fill(style.today).frame(width: 7, height: 7)
                    Rectangle().fill(style.today).frame(height: 1.5)
                }
                .offset(x: -3, y: y - 3.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private func isDragged(_ block: Timeline.Block, index: Int) -> Bool {
        dragging.map { $0.blockID == block.id && $0.origin == index } ?? false
    }

    private func blockView(_ block: Timeline.Block, day: Timeline.Day, index: Int, width: CGFloat) -> some View {
        let face = blockFace(block, start: block.start, end: block.end, column: block.column, columns: block.columns, width: width, selected: isSelected(block.row, day.day))
            .opacity(isDragged(block, index: index) ? 0.35 : 1)
        return selectable(face, row: block.row, day: day.day)
            .overlay(alignment: .top) { if block.canMove { handle(block, index: index, edge: .top) } }
            .overlay(alignment: .bottom) { if block.canMove { handle(block, index: index, edge: .bottom) } }
            .modifier(MoveGesture(enabled: block.canMove, gesture: moveGesture(block, index: index, width: width)))
            .offset(x: width * CGFloat(block.column) / CGFloat(block.columns), y: CGFloat(block.start) * perMinute)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: "\(block.row.gutter) \(block.row.title)"))
    }

    private func blockFace(_ block: Timeline.Block, start: Int, end: Int, column: Int, columns: Int, width: CGFloat, selected: Bool) -> some View {
        let row = block.row
        let tint = style.tint(row)
        let height = max(CGFloat(end - start) * perMinute, 16)
        let time = start == block.start && end == block.end ? row.gutter
            : MoveTimestampTimeText.text(start, block.hasEnd || dragging?.edge != nil ? end : nil)
        return HStack(spacing: 0) {
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                if height >= 30, width / CGFloat(columns) >= 70 {
                    Text(verbatim: time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(row.title.isEmpty ? " " : row.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(style.foreground)
                    .strikethrough(row.isDone)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            Spacer(minLength: 0)
        }
        .frame(width: max(width / CGFloat(columns) - 2, 4), height: height, alignment: .topLeading)
        // Over the window's background, so the hour lines don't show through.
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? style.selection : tint.opacity(row.isEvent ? 0.12 : 0.2)))
        .background(RoundedRectangle(cornerRadius: 4).fill(.background))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(row.isBlocked || row.isDone ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    /// Taps select (and on iOS open), a double tap opens, and the row's menu is on a secondary
    /// click or a long press.
    private func selectable(_ content: some View, row: AgendaRow, day: Int) -> some View {
        content
            .onTapGesture(count: 2) { open(row, day) }
            .simultaneousGesture(TapGesture().onEnded { tap(row, day) })
            .contextMenu { menu(row, day) }
    }

    private func handle(_ block: Timeline.Block, index: Int, edge: Dragging.Edge) -> some View {
        Color.clear
            .frame(height: 8)
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(.frameResize(position: edge == .top ? .top : .bottom))
            #endif
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in update(block, index: index, edge: edge, translation: value.translation.height, x: value.location.x, width: 0) }
                    .onEnded { _ in finish(block, index: index) }
            )
            .accessibilityHidden(true)
    }

    private func moveGesture(_ block: Timeline.Block, index: Int, width: CGFloat) -> some Gesture {
        #if os(iOS)
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    update(block, index: index, edge: nil, translation: drag.translation.height, x: drag.location.x, width: width)
                }
            }
            .onEnded { value in
                if case .second(true, _) = value { finish(block, index: index) } else { dragging = nil }
            }
        #else
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in update(block, index: index, edge: nil, translation: value.translation.height, x: value.location.x, width: width) }
            .onEnded { _ in finish(block, index: index) }
        #endif
    }

    private func update(_ block: Timeline.Block, index: Int, edge: Dragging.Edge?, translation: CGFloat, x: CGFloat, width: CGFloat) {
        let delta = Int((translation / perMinute).rounded())
        let landing: (start: Int, end: Int)
        var dayIndex = index
        switch edge {
        case nil:
            landing = Timeline.moved(start: block.start, end: block.end, by: delta, step: step)
            if width > 0 { dayIndex = min(max(Int((x / width).rounded(.down)), 0), days.count - 1) }
        case .top?:
            landing = Timeline.resized(start: block.start, end: block.end, top: true, by: delta, step: step)
        case .bottom?:
            landing = Timeline.resized(start: block.start, end: block.end, top: false, by: delta, step: step)
        }
        dragging = Dragging(blockID: block.id, origin: index, edge: edge, start: landing.start, end: landing.end, dayIndex: dayIndex)
    }

    private func finish(_ block: Timeline.Block, index: Int) {
        guard let dragging, isDragged(block, index: index) else { return }
        self.dragging = nil
        let from = days[index].day
        let to = days[dragging.dayIndex].day
        // A move keeps an entry without a time range without one; a resize writes a range.
        let end = dragging.edge == nil && !block.hasEnd ? nil : dragging.end
        if from == to, dragging.start == block.start, end == (block.hasEnd ? block.end : nil) { return }
        move(block.row, from, to, dragging.start, end)
    }

    // MARK: - TODO list

    private func todoList(_ todos: [AgendaRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("To Schedule", comment: "Agenda timeline: the list of TODO entries without a date, to drag onto the timeline")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            if todos.isEmpty {
                Text("No TODO entries without a date.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(todos) { row in
                            todoRow(row)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 230)
    }

    private func todoRow(_ row: AgendaRow) -> some View {
        let tint = style.tint(row)
        let today = days.first(where: \.isToday)?.day ?? days.first?.day ?? 0
        let label = HStack(alignment: .top, spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title.isEmpty ? " " : row.title).font(.callout).foregroundStyle(style.foreground).lineLimit(2)
                HStack(spacing: 6) {
                    if let todo = row.todo { Text(verbatim: todo) }
                    if !row.category.isEmpty { Text(verbatim: row.category) }
                    if let effort = row.item?.effort { Label { Text(verbatim: effort) } icon: { Image(systemName: "hourglass") } }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected(row, today) ? style.selection : .clear)
        .contentShape(Rectangle())
        return selectable(label, row: row, day: today)
            .modifier(DragPayload(payload: AgendaTodoDrag(row)?.payload))
    }
}

/// `10:00` or `10:00–11:30`, from minutes, as the agenda's gutter writes times.
enum MoveTimestampTimeText {
    static func text(_ start: Int, _ end: Int?) -> String {
        func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60 % 24, minutes % 60) }
        return end.map { clock(start) + "–" + clock($0) } ?? clock(start)
    }
}

/// Makes a view draggable with `payload` as its text, when there is one.
private struct DragPayload: ViewModifier {
    let payload: String?

    func body(content: Content) -> some View {
        if let payload { content.draggable(payload) } else { content }
    }
}

/// Adds the gesture that moves a block, when it can move.
private struct MoveGesture<G: Gesture>: ViewModifier {
    let enabled: Bool
    let gesture: G

    func body(content: Content) -> some View {
        if enabled { content.gesture(gesture) } else { content }
    }
}
