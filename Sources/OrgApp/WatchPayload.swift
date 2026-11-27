import Foundation
import OrgCore
import OrgPresentation
import OrgWatchData

extension WatchAgenda.Card {
    /// The first `limit` of `items` that are positions of normal and double cards, which the
    /// watch reviews, with their text cut to `length` characters.
    public static func review(_ items: [Flashcards.Item], limit: Int = 30, length: Int = 400) -> [WatchAgenda.Card] {
        func cut(_ text: String) -> String { text.count > length ? String(text.prefix(length)) + "…" : text }
        return items.lazy.filter { [.normal, .double].contains($0.card.cardType) }.compactMap { item -> WatchAgenda.Card? in
            guard let face = Flashcards.face(item.card, position: item.position) else { return nil }
            return WatchAgenda.Card(path: item.path, card: item.card.id, position: item.position, title: face.front.title.map(cut), front: cut(face.front.text),
                                    backTitle: cut(face.back.title ?? ""), back: cut(face.back.text))
        }.prefix(limit).map { $0 }
    }
}

extension WatchAgenda {
    /// Today's group of the agenda, for the watch, with the running clock and the entry
    /// Clock In Last would take.
    public init(groups: [AgendaDayGroup], today: Int, clock: ClockModel.Running?, lastClocked: String?, generated: Date, calendar: Calendar = .current) {
        let group = groups.first { $0.day == today }
        let midnight = group?.date(calendar: calendar) ?? calendar.startOfDay(for: generated)
        func entry(_ row: AgendaRow) -> Entry {
            func at(_ hhmm: Int?) -> Date? {
                hhmm.flatMap { calendar.date(byAdding: .minute, value: ($0 / 100) * 60 + $0 % 100, to: midnight) }
            }
            let item = row.item
            return Entry(
                id: row.id, title: row.title, gutter: row.gutter, category: row.category, todo: row.todo, status: row.status.rawValue,
                isDone: row.isDone, isEvent: row.isEvent, start: at(row.start), end: at(row.end), path: item?.path,
                offset: item?.headingOffset, headingLine: item?.headingLine, doneKeyword: item?.doneKeyword
            )
        }
        self.init(
            generated: generated, day: midnight, overdue: group?.overdue.map(entry) ?? [], rows: group?.rows.map(entry) ?? [],
            clock: clock.map { Clock(heading: $0.heading, startedAt: $0.startedAt) }, lastClocked: lastClocked
        )
    }
}
