import Foundation
import OrgCore
import OrgDocument
import OrgMathJax
import PDFKit
import Testing
@testable import OrgApp

/// What Print… sends to the printer: the page PDF export makes of the file, the subtree or the
/// selection, and the agenda as shown.
@MainActor
struct PrintingTests {
    init() { PDFExport.mathJaxURL = OrgMathJax.script }

    static let text = "#+TITLE: Notes\n* One\nFirst body.\n** Inner\nInner body.\n* Two\nSecond body.\n"

    func page(_ scope: PrintScope, text: String = Self.text) -> String? {
        Printing.page(text, path: "/notes/a.org", scope: scope, settings: .default, codeStyle: nil, language: "en")
    }

    func offset(of needle: String, in text: String = Self.text) -> Int { (text as NSString).range(of: needle).location }

    @Test func eachScope() throws {
        let file = try #require(page(.file))
        #expect(file.contains("<title>Notes</title>") && file.contains("First body.") && file.contains("Second body."))
        #expect(file == HTMLExport.page(Self.text, fallbackTitle: "a", settings: .default, path: "/notes/a.org", language: "en"))

        // As Export Subtree: the heading is the title, its children promoted.
        let subtree = try #require(page(.subtree(offset(of: "First body."))))
        #expect(subtree.contains("<title>One</title>") && subtree.contains("Inner body."))
        #expect(!subtree.contains("Second body."))
        #expect(page(.subtree(0)) == nil)

        // The selection with the file's keywords.
        let start = offset(of: "Second body.")
        let selection = try #require(page(.selection(start..<(start + 6))))
        #expect(selection.contains("<title>Notes</title>") && selection.contains("Second"))
        #expect(!selection.contains("Second body.") && !selection.contains("First body."))
        #expect(page(.selection(start..<start)) == nil)
    }

    @Test func regionKeepsTheFileKeywordsOnce() {
        #expect(ExportScope.region(Self.text, 0..<15) == "#+TITLE: Notes\n")
        let start = offset(of: "* Two")
        #expect(ExportScope.region(Self.text, start..<(start + 5)) == "#+TITLE: Notes\n* Two")
        #expect(ExportScope.region("* A\nbody\n", 4..<8) == "body")
    }

    /// The pages the print panel gets: PDF export's layout, with page numbers. The print
    /// operation itself isn't run here: it stops the test process's main run loop.
    @Test func printsThePDFExportPages() async throws {
        let html = try #require(page(.subtree(offset(of: "First body."))))
        let document = try #require(PDFDocument(data: try await Printing.pages(html: html, directory: nil)))
        let text = document.string ?? ""
        #expect(text.contains("One") && text.contains("Inner body."))
        #expect(!text.contains("Second body."))
        #expect(document.page(at: 0)?.annotations.first { $0.type == "FreeText" }?.contents == "1")
        #expect(Printing.title(html) == "One")
    }

    /// Printing a file needs orgstar+ as PDF export does, since the print panel saves PDFs; the
    /// agenda prints without it.
    @Test func gating() {
        for id in Printing.commands { #expect(ProFeature.required(byCommand: id) == .export) }
        #expect(ProFeature.required(byCommand: "app.print-agenda") == nil)
        let access = ProAccess(defaults: TestDefaults("orgstar-printing"))
        #expect(!access.allows(ProFeature.required(byCommand: "app.print")!))
        #expect(access.paywall == .export)
    }

    /// An entry encrypted on disk prints as its message, as PDF export exports it, until it's
    /// decrypted in the editor.
    @Test func encryptedEntriesPrintOnlyOnceDecrypted() throws {
        let secret = "Account 12345"
        let plain = "* Plain\nOpen text.\n* Bank :crypt:\n\(secret)\n* Last\n"
        let encrypted = try #require(try OrgCrypt.encrypt(plain, at: offset(of: "* Bank", in: plain), passphrase: "pw"))
        let notes = try Folder()
        let file = try notes.write("a.org", encrypted)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".recovery")))
        session.saveMode = .explicit
        session.encryptsTaggedEntries = true
        session.passphrases = FakeKeychain.passphrases(.undecided).passphrases
        session.open(file.path)
        let text = try #require(session.document?.text)
        let bank = offset(of: "* Bank", in: text)
        for scope in [PrintScope.file, .subtree(bank), .selection(0..<(text as NSString).length)] {
            let html = try #require(page(scope, text: text))
            #expect(!html.contains(secret))
            #expect(html.contains("Bank"))
        }

        let buffer = StateBuffer(try #require(session.document))
        session.attach(buffer)
        let decrypted = try OrgCrypt.decryptInPlace(text, at: bank, passphrase: "pw")
        try buffer.update { try $0.apply([TextEdit(range: 0..<($0.text as NSString).length, replacement: decrypted)], baseRevision: $0.revision) }
        session.bufferChanged()
        let shown = try #require(session.document?.text)
        #expect(try #require(page(.file, text: shown)).contains(secret))
        #expect(try #require(page(.subtree(offset(of: "* Bank", in: shown)), text: shown)).contains(secret))
    }

    // MARK: - Agenda

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 8))!

    func agenda(_ mode: AgendaMode) async throws -> (AgendaModel, Folder) {
        let notes = try Folder()
        try notes.write("work.org", """
            * TODO Call the bank :phone:
            SCHEDULED: <2026-11-26 Thu 09:00>
            * TODO [#A] Send the report
            DEADLINE: <2026-11-20 Fri>
            * DONE Filed
            CLOSED: [2026-11-25 Wed 10:00]
            * TODO Read <b>this</b>
            SCHEDULED: <2026-11-27 Fri>

            """)
        let workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        let agenda = AgendaModel(workspace: workspace)
        agenda.mode = mode
        await agenda.refresh(open: [:], now: Self.now, calendar: Self.calendar)
        return (agenda, notes)
    }

    func page(_ agenda: AgendaModel, filter: AgendaFilter = AgendaFilter(), overdueShown: Bool = true, showAllDates: Bool = false) -> String {
        AgendaPrint.page(title: "Agenda", subtitle: "work", parts: agenda.printParts(showAllDates: showAllDates, filter: filter, overdueShown: overdueShown),
                         today: agenda.today, calendar: Self.calendar, locale: Locale(identifier: "en_US"))
    }

    @Test func agendaDaysAsShown() async throws {
        let (agenda, notes) = try await agenda(.agenda(span: 2, startOffset: nil))
        _ = notes
        let html = page(agenda)
        #expect(html.contains("<title>Agenda</title>") && html.contains("<p class=\"subtitle\">work</p>"))
        #expect(html.contains("Today · Thursday, November 26, 2026") && html.contains("Tomorrow · Friday, November 27, 2026"))
        #expect(html.contains("<span class=\"todo\">TODO</span> <span class=\"title\">Call the bank</span>"))
        #expect(html.contains("09:00") && html.contains("work · :phone:"))
        #expect(html.contains("<p class=\"overdue\">Overdue 1</p>") && html.contains("[#A] <span class=\"title\">Send the report</span>"))
        // Escaped, not markup.
        #expect(html.contains("Read &lt;b&gt;this&lt;/b&gt;"))
        // Folded overdue entries stay folded; a filter leaves out what it hides.
        let folded = page(agenda, overdueShown: false)
        #expect(folded.contains("Overdue 1") && !folded.contains("Send the report"))
        var filter = AgendaFilter()
        filter.tags = ["-phone"]
        #expect(!page(agenda, filter: filter).contains("Call the bank"))
    }

    @Test func agendaListsAndEmptyDays() async throws {
        let (list, notes) = try await agenda(.todo(keywords: nil))
        _ = notes
        let html = page(list)
        #expect(html.contains("Call the bank") && html.contains("Send the report") && !html.contains("Filed"))
        #expect(!html.contains("class=\"gutter\""))
        var none = AgendaFilter()
        none.tags = ["+nothing"]
        #expect(page(list, filter: none).contains("No entries"))

        let (days, more) = try await agenda(.agenda(span: 1, startOffset: 3))
        _ = more
        #expect(!page(days).contains("<h3"))
        #expect(page(days, showAllDates: true).contains("Sunday, November 29, 2026</h3>\n<p class=\"empty\">Nothing scheduled</p>"))
    }

    /// The agenda's page goes through the same pages as a file's.
    @Test func agendaPrintsAsPages() async throws {
        let (agenda, notes) = try await agenda(.agenda(span: 2, startOffset: nil))
        _ = notes
        let text = try #require(PDFDocument(data: try await Printing.pages(html: page(agenda), directory: nil))).string ?? ""
        #expect(text.contains("Call the bank") && text.contains("Send the report"))
    }
}
