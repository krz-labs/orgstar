import Foundation
import OrgCore
import OrgPresentation
import Testing
@testable import OrgApp

struct ContactDatesTests {
    struct Record: ContactRecord {
        var recordID = "c1"
        var recordName = "Ada Lovelace"
        var recordBirthday: DateComponents? = DateComponents(year: 1990, month: 12, day: 10)
        var recordDates: [(label: String, date: DateComponents)] = []
    }

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Int { Days.absolute(year: year, month: month, day: day) }

    static func events(_ record: Record, from first: Int, days: Int) -> [AgendaEvent] {
        ContactDates.events(ContactDates.dates(record), first: first, days: days, calendar: utc)
    }

    @Test func settingIsOffByDefault() {
        let defaults = TestDefaults("orgstar-contact-dates")
        #expect(!OrgPreferences.agendaContactDates(defaults))
        let problems = UserConfig.apply("""
            [orgstar]
            agenda-contact-dates = true
            """, to: defaults)
        #expect(problems.isEmpty)
        #expect(OrgPreferences.agendaContactDates(defaults))
        #expect(UserConfig.settings.contains { $0.key == "agenda-contact-dates" && $0.fallback == .bool(false) })
    }

    @Test func birthdayWithYearGivesTheAge() throws {
        let events = Self.events(Record(), from: Self.day(2026, 12, 1), days: 14)
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.isContact && event.isAllDay && !event.isReminder)
        #expect(event.title == "Ada Lovelace (36)" && event.calendarTitle == "Birthday" && event.calendarID == "c1")
        #expect(event.days(calendar: Self.utc) == Self.day(2026, 12, 10)...Self.day(2026, 12, 10))
        let row = AgendaRow(event: event, day: Self.day(2026, 12, 10), calendar: Self.utc)
        #expect(row.gutter == "All day" && row.icon == .contact && row.category == "Birthday" && row.id.hasPrefix("contact\u{1f}"))
    }

    @Test func birthdayWithoutYearHasNoAge() throws {
        var record = Record()
        record.recordBirthday = DateComponents(month: 12, day: 10)
        #expect(Self.events(record, from: Self.day(2026, 12, 10), days: 1).map(\.title) == ["Ada Lovelace"])
        // Contacts keeps 1604 as the year of a date saved without one.
        record.recordBirthday = DateComponents(year: 1604, month: 12, day: 10)
        #expect(Self.events(record, from: Self.day(2026, 12, 10), days: 1).map(\.title) == ["Ada Lovelace"])
    }

    @Test func nothingBeforeTheYearAndNoAgeInIt() {
        var record = Record()
        record.recordBirthday = DateComponents(year: 2026, month: 12, day: 10)
        #expect(Self.events(record, from: Self.day(2026, 12, 10), days: 1).map(\.title) == ["Ada Lovelace"])
        record.recordBirthday = DateComponents(year: 2027, month: 12, day: 10)
        #expect(Self.events(record, from: Self.day(2026, 12, 10), days: 1).isEmpty)
    }

    @Test func february29IsMarch1InOtherYears() {
        var record = Record()
        record.recordBirthday = DateComponents(year: 2000, month: 2, day: 29)
        let common = Self.events(record, from: Self.day(2027, 2, 27), days: 4)
        #expect(common.map { Days.absolute($0.start, calendar: Self.utc) } == [Self.day(2027, 3, 1)])
        #expect(common.map(\.title) == ["Ada Lovelace (27)"])
        let leap = Self.events(record, from: Self.day(2028, 2, 27), days: 4)
        #expect(leap.map { Days.absolute($0.start, calendar: Self.utc) } == [Self.day(2028, 2, 29)])
        // 2100 isn't a leap year.
        #expect(Self.events(record, from: Self.day(2100, 2, 28), days: 2).map { Days.absolute($0.start, calendar: Self.utc) } == [Self.day(2100, 3, 1)])
    }

    @Test func labeledDatesShowWithTheirLabels() {
        var record = Record()
        record.recordDates = [
            ("Anniversary", DateComponents(year: 2015, month: 6, day: 20)),
            ("First met", DateComponents(month: 6, day: 21)),
            ("No day", DateComponents(year: 2015, month: 6)),
        ]
        let events = Self.events(record, from: Self.day(2026, 6, 19), days: 5)
        #expect(events.map(\.calendarTitle) == ["Anniversary", "First met"])
        #expect(events.map(\.title) == ["Ada Lovelace (11)", "Ada Lovelace"])
        #expect(Set(events.map(\.id)).count == 2)
        // No birthday: the labeled dates still show.
        record.recordBirthday = nil
        #expect(Self.events(record, from: Self.day(2026, 6, 19), days: 5).count == 2)
    }

    @Test func dayRangesAcrossYearsGiveEachOccurrence() {
        var record = Record()
        record.recordBirthday = DateComponents(year: 1990, month: 1, day: 2)
        let events = Self.events(record, from: Self.day(2026, 12, 20), days: 20)
        #expect(events.map(\.title) == ["Ada Lovelace (37)"])
        #expect(events.map { Days.absolute($0.start, calendar: Self.utc) } == [Self.day(2027, 1, 2)])
        // A span over more than a year has an occurrence for each year, in order.
        let long = Self.events(record, from: Self.day(2026, 1, 1), days: 800)
        #expect(long.map(\.title) == ["Ada Lovelace (36)", "Ada Lovelace (37)", "Ada Lovelace (38)"])
        #expect(Set(long.map(\.id)).count == 3)
        // Days just outside the range don't count.
        #expect(Self.events(record, from: Self.day(2026, 1, 3), days: 364).isEmpty)
        #expect(Self.events(record, from: Self.day(2026, 1, 1), days: 0).isEmpty)
    }

    @Test func eventsOfSeveralContactsGoByDay() {
        var a = Record()
        a.recordBirthday = DateComponents(month: 3, day: 5)
        var b = Record()
        b.recordID = "c2"
        b.recordName = "Grace Hopper"
        b.recordBirthday = DateComponents(month: 3, day: 2)
        let events = ContactDates.events(ContactDates.dates(a) + ContactDates.dates(b), first: Self.day(2026, 3, 1), days: 7, calendar: Self.utc)
        #expect(events.map(\.title) == ["Grace Hopper", "Ada Lovelace"])
    }

    @Test func groupsPutContactDatesWithTheAllDayEvents() {
        let day = Self.day(2026, 12, 10)
        let events = Self.events(Record(), from: day, days: 1)
        let groups = AgendaRows.groups(Agenda.list([], start: day, days: 1, today: day, now: (10, 0)), events: events, today: day, calendar: Self.utc)
        #expect(groups.first?.rows.map(\.title) == ["Ada Lovelace (36)"])
    }
}
