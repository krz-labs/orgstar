import Contacts
import Foundation
import OrgCore
import OrgPresentation

/// What the agenda reads from a contact: `CNContact`, or a value made in tests.
public protocol ContactRecord {
    var recordID: String { get }
    var recordName: String { get }
    var recordBirthday: DateComponents? { get }
    /// The contact's other dates with their labels, as shown.
    var recordDates: [(label: String, date: DateComponents)] { get }
}

extension CNContact: ContactRecord {
    public var recordID: String { identifier }
    public var recordName: String {
        CNContactFormatter.string(from: self, style: .fullName) ?? (organizationName.isEmpty ? "" : organizationName)
    }
    public var recordBirthday: DateComponents? { isKeyAvailable(CNContactBirthdayKey) ? birthday : nil }
    public var recordDates: [(label: String, date: DateComponents)] {
        guard isKeyAvailable(CNContactDatesKey) else { return [] }
        return dates.map { value in
            let label: String
            switch value.label {
            case CNLabelDateAnniversary: label = String(localized: "Anniversary", comment: "A date on a contact, in the agenda")
            case nil, "": label = String(localized: "Date", comment: "A date without a label on a contact, in the agenda")
            case let raw?: label = CNLabeledValue<NSDateComponents>.localizedString(forLabel: raw)
            }
            return (label, value.value as DateComponents)
        }
    }
}

/// A birthday or another date on a contact, every year from its year (when known).
public struct ContactDate: Sendable, Equatable {
    public let contactID: String
    public let name: String
    /// `Birthday`, `Anniversary` or the date's own label.
    public let label: String
    public let month: Int
    public let day: Int
    public let year: Int?
    /// Tells a contact's dates apart: 0 for the birthday, then 1, 2, … for the others.
    public let index: Int
}

/// Read-only birthdays and other dates from Contacts for the agenda (`agenda-contact-dates` in
/// config.toml). The contacts' dates are read once, off the main thread, and again after
/// Contacts changes.
public final class ContactDates: @unchecked Sendable {
    private let store = CNContactStore()
    private let lock = NSLock()
    private var cached: [ContactDate]?
    private var observer: NSObjectProtocol?

    public init() {
        observer = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.invalidate()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public static var isAuthorized: Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: true
        default: false
        }
    }

    /// Asks for access once; later calls answer with what the person chose.
    public func requestAccess() async -> Bool {
        if Self.isAuthorized { return true }
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }

    /// Drops the dates read, so the next read asks Contacts again.
    public func invalidate() {
        lock.withLock { cached = nil }
    }

    /// Every contact's dates. Reads Contacts the first time and after a change, so call it off
    /// the main thread. None without access.
    public func dates() -> [ContactDate] {
        guard Self.isAuthorized else { return [] }
        if let cached = lock.withLock({ cached }) { return cached }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor, CNContactDatesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var found: [ContactDate] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            found += Self.dates(contact)
        }
        lock.withLock { cached = found }
        return found
    }

    /// The occurrences on the days `first..<first + days` (as `Days` numbers them).
    public func events(first: Int, days: Int, calendar: Calendar = .current) -> [AgendaEvent] {
        Self.events(dates(), first: first, days: days, calendar: calendar)
    }

    /// A contact's birthday and labeled dates; those without a month and day are left out.
    public static func dates(_ record: some ContactRecord) -> [ContactDate] {
        let birthday = record.recordBirthday.map { (String(localized: "Birthday", comment: "A contact's birthday, in the agenda"), $0) }
        return ([birthday].compactMap { $0 } + record.recordDates).enumerated().compactMap { index, labeled in
            let (label, date) = labeled
            guard let month = date.month, let day = date.day, (1...12).contains(month), (1...31).contains(day) else { return nil }
            if let calendar = date.calendar, calendar.identifier != .gregorian { return nil }
            // Contacts stores 1604 for a date saved without its year.
            let year = date.year.flatMap { $0 == 1604 ? nil : $0 }
            return ContactDate(contactID: record.recordID, name: record.recordName, label: label, month: month, day: day, year: year,
                               index: birthday == nil ? index + 1 : index)
        }
    }

    /// The dates' occurrences on the days `first..<first + days`, all day, by day. As
    /// `org-anniversary` shows them: 29 February is 1 March in other years, and with a year the
    /// title gives the years since, as `%d` does; with a year, nothing shows before it.
    public static func events(_ dates: [ContactDate], first: Int, days: Int, calendar: Calendar = .current) -> [AgendaEvent] {
        guard days > 0 else { return [] }
        let last = first + days - 1
        var events: [(day: Int, event: AgendaEvent)] = []
        for year in Days.date(first).year...Days.date(last).year {
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            for date in dates {
                if let born = date.year, born > year { continue }
                let (month, day) = date.month == 2 && date.day == 29 && !leap ? (3, 1) : (date.month, date.day)
                let absolute = Days.absolute(year: year, month: month, day: day)
                guard (first...last).contains(absolute), Days.date(absolute).month == month else { continue }
                let title = date.year.map { year > $0 ? String(localized: "\(date.name) (\(year - $0))", comment: "A contact's name and the years since a date of theirs, in the agenda") : date.name } ?? date.name
                let start = calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                events.append((absolute, AgendaEvent(
                    id: "\(date.contactID)\u{1f}\(date.index)\u{1f}\(absolute)", title: title, calendarID: date.contactID, calendarTitle: date.label,
                    color: nil, start: start, end: end, isAllDay: true, isContact: true
                )))
            }
        }
        return events.enumerated().sorted { ($0.element.day, $0.offset) < ($1.element.day, $1.offset) }.map(\.element.event)
    }
}
