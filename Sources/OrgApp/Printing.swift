import Foundation
import OrgCore
import OrgPresentation
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What Print… prints of an org file.
public enum PrintScope: Sendable, Equatable {
    case file
    /// The subtree containing this offset, as Export Subtree exports it.
    case subtree(Int)
    /// The selected text, with the file's keywords.
    case selection(Range<Int>)
}

/// Printing: the page PDF export makes, with its margins, font and page numbers, through the
/// system's print panel. A file's text comes from its buffer, as PDF export takes it, so an
/// entry encrypted on disk prints as its message unless it was decrypted in the editor. The
/// agenda prints as `AgendaPrint` lays it out.
@MainActor
public enum Printing {
    /// The commands that print an org file: `app.print`, `app.print-subtree`, `app.print-selection`.
    public static let commands = ["app.print", "app.print-subtree", "app.print-selection"]

    /// When set, jobs are saved to this PDF file without the panel, for checking from scripts.
    nonisolated(unsafe) public static var saveTo: URL?

    /// The page PDF export makes of `scope` of `text`, the buffer of the org file at `path`; nil
    /// before the first heading for a subtree, and for an empty selection.
    public static func page(_ text: String, path: String, scope: PrintScope, settings: OrgSettings, codeStyle: HTMLCodeStyle?, language: String) -> String? {
        let printed: String
        switch scope {
        case .file:
            printed = text
        case .subtree(let caret):
            guard let subtree = ExportScope.subtree(text, at: caret, settings: settings) else { return nil }
            printed = subtree
        case .selection(let range):
            guard !range.isEmpty else { return nil }
            printed = ExportScope.region(text, range, settings: settings)
        }
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return HTMLExport.page(printed, fallbackTitle: base, settings: settings, path: path, codeStyle: codeStyle, language: language)
    }

    /// The job's name: the page's title.
    nonisolated static func title(_ html: String) -> String {
        guard let match = html.firstMatch(of: /<title>([^<]*)<\/title>/) else { return "" }
        return String(match.1).replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// `html` laid out in pages as PDF export lays it out, then shown in the print panel.
    /// `directory` is where relative image links are read from.
    public static func show(html: String, directory: URL?) async throws {
        try await present(try await pages(html: html, directory: directory), title: title(html), saveTo: saveTo)
    }

    /// `html` as the pages PDF export makes, with the PDF settings.
    static func pages(html: String, directory: URL?) async throws -> Data {
        try await PDFExport.pdf(html: html, directory: directory, options: OrgPreferences.pdfOptions())
    }

    #if os(macOS)
    /// The pages in the print panel, a sheet on the key window, with its paper size, orientation
    /// and preview; or, with `saveTo`, saved there without the panel. The pages already have
    /// their margins; the printer's own scales them to fit.
    static func present(_ data: Data, title: String, saveTo: URL?) async throws {
        guard let document = PDFDocument(data: data) else { throw PDFExport.Failure(description: "The pages couldn't be made.") }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        if let saveTo {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = saveTo
        }
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
            throw PDFExport.Failure(description: "The pages couldn't be printed.")
        }
        operation.jobTitle = title
        operation.showsPrintPanel = saveTo == nil
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        // A sheet on the key window; saved without a panel, on a window never shown, as PDF
        // export renders its pages.
        let window = (saveTo == nil ? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) : nil)
            ?? NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
        let done = Done()
        await withCheckedContinuation { continuation in
            done.continuation = continuation
            operation.runModal(for: window, delegate: done, didRun: #selector(Done.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    private final class Done: NSObject {
        var continuation: CheckedContinuation<Void, Never>?

        @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            continuation?.resume()
            continuation = nil
        }
    }
    #else
    /// The pages in the system's print sheet.
    static func present(_ data: Data, title: String, saveTo: URL?) async throws {
        let info = UIPrintInfo.printInfo()
        info.jobName = title
        info.outputType = .general
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true)
    }
    #endif
}

/// The agenda as shown, as a page to print: the title, then each day's header with its overdue
/// entries, rows and time grid, or the entries of a list view, or each block's.
public enum AgendaPrint {
    public enum Part: Equatable, Sendable {
        /// A block's title.
        case heading(String)
        /// A day; `overdueShown` false leaves today's overdue entries folded, as the view can.
        case day(AgendaDayGroup, overdueShown: Bool)
        /// The entries of a TODO list, match or search.
        case entries([AgendaRow])
    }

    /// The page for `parts` under `title`, with `subtitle` (the folders shown, the filter) below it.
    public static func page(title: String, subtitle: String? = nil, parts: [Part], today: Int, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var body = "<h1 class=\"title\">\(escape(title))</h1>\n"
        if let subtitle, !subtitle.isEmpty { body += "<p class=\"subtitle\">\(escape(subtitle))</p>\n" }
        for part in parts {
            switch part {
            case .heading(let text):
                body += "<h2>\(escape(text))</h2>\n"
            case .day(let group, let overdueShown):
                body += "<h3\(group.isToday ? " class=\"today\"" : "")>\(escape(dayHeader(group, today: today, calendar: calendar, locale: locale)))</h3>\n"
                if group.isToday, !group.overdue.isEmpty {
                    body += "<p class=\"overdue\">\(escape(String(localized: "Overdue", bundle: .main))) \(group.overdue.count)</p>\n"
                    if overdueShown { body += table(group.overdue) }
                }
                if group.rows.isEmpty {
                    body += "<p class=\"empty\">\(escape(String(localized: "Nothing scheduled", bundle: .main)))</p>\n"
                } else {
                    // A page isn't live: no current-time line.
                    body += table(group.lines(now: 0).compactMap { line -> Line? in
                        switch line {
                        case .row(let index): .row(group.rows[index])
                        case .grid(let time): .grid(time)
                        case .now: nil
                        }
                    })
                }
            case .entries(let rows):
                body += rows.isEmpty ? "<p class=\"empty\">\(escape(String(localized: "No entries", bundle: .main)))</p>\n" : table(rows, gutter: false)
            }
        }
        return """
            <!DOCTYPE html>
            <html lang="\(escape(locale.language.languageCode?.identifier ?? "en"))">
            <head>
            <meta charset="utf-8">
            <title>\(escape(title))</title>
            <style>
            body { font-family: -apple-system, sans-serif; line-height: 1.35; }
            h1.title { font-size: 16pt; margin: 0 0 2pt; }
            p.subtitle { color: #666; margin: 0 0 8pt; }
            h2 { font-size: 13pt; margin: 14pt 0 4pt; }
            h3 { font-size: 11pt; margin: 12pt 0 4pt; padding-bottom: 2pt; border-bottom: 0.5pt solid #bbb; }
            h3.today { font-weight: 800; }
            p.overdue { color: #b00; font-weight: 600; margin: 4pt 0; }
            p.empty { color: #666; margin: 4pt 0; }
            table { border-collapse: collapse; width: 100%; }
            td { vertical-align: top; padding: 2pt 6pt 2pt 0; }
            td.gutter { width: 80pt; white-space: nowrap; color: #444; font-variant-numeric: tabular-nums; }
            tr.overdue td.gutter { color: #b00; }
            tr.done .title { color: #777; text-decoration: line-through; }
            tr.grid td { color: #999; font-size: 9pt; border-top: 0.5pt dashed #ccc; padding-top: 1pt; padding-bottom: 1pt; }
            .meta { color: #666; font-size: 9pt; }
            .todo { font-weight: 700; }
            </style>
            </head>
            <body>
            \(body)</body>
            </html>

            """
    }

    private enum Line {
        case row(AgendaRow)
        case grid(Int)
    }

    private static func table(_ rows: [AgendaRow], gutter: Bool = true) -> String {
        table(rows.map(Line.row), gutter: gutter)
    }

    private static func table(_ lines: [Line], gutter: Bool = true) -> String {
        var html = "<table>\n"
        for line in lines {
            switch line {
            case .grid(let time):
                html += "<tr class=\"grid\"><td class=\"gutter\">\(String(format: "%02d:%02d", time / 100, time % 100))</td><td></td></tr>\n"
            case .row(let row):
                let classes = [row.status == .overdue ? "overdue" : nil, row.isDone ? "done" : nil].compactMap { $0 }
                html += "<tr\(classes.isEmpty ? "" : " class=\"\(classes.joined(separator: " "))\"")>"
                if gutter { html += "<td class=\"gutter\">\(row.gutterLines.map(escape).joined(separator: "<br>"))</td>" }
                html += "<td>\(entry(row))</td></tr>\n"
            }
        }
        return html + "</table>\n"
    }

    /// The category, detail, progress and tags over the TODO keyword, priority and title, as
    /// the view's rows have them.
    private static func entry(_ row: AgendaRow) -> String {
        let meta = [row.category, row.prefixDetail, row.progress, row.detail].compactMap { $0 }.filter { !$0.isEmpty }
            + (row.tags.isEmpty ? [] : [":" + row.tags.joined(separator: ":") + ":"])
        var html = meta.isEmpty ? "" : "<div class=\"meta\">\(meta.map(escape).joined(separator: " · "))</div>"
        var title: [String] = []
        if let todo = row.todo { title.append("<span class=\"todo\">\(escape(todo))</span>") }
        if let priority = row.priority { title.append("[#\(escape(priority))]") }
        title.append("<span class=\"title\">\(escape(row.title))</span>")
        html += "<div>\(title.joined(separator: " "))</div>"
        return html
    }

    /// `Today · Thursday 26 November 2026`.
    static func dayHeader(_ group: AgendaDayGroup, today: Int, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMy")
        let date = formatter.string(from: group.date(calendar: calendar))
        return group.relativeName(today: today).map { $0 + " · " + date } ?? date
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension AgendaModel {
    /// What the view shows, as `AgendaPrint` lays it out: its days, its entries, or each block's
    /// title over its days or entries, with `filter` and empty days as the view has them.
    public func printParts(showAllDates: Bool, filter: AgendaFilter, overdueShown: Bool) -> [AgendaPrint.Part] {
        let rows = { (list: [AgendaItem]) in list.filter(filter.keeps).compactMap { AgendaRow(item: $0, day: self.today, today: self.today) } }
        switch mode {
        case .agenda:
            return groups(showAllDates: showAllDates, filter: filter).map { .day($0, overdueShown: overdueShown) }
        case .blocks:
            return blocks.flatMap { block -> [AgendaPrint.Part] in
                [.heading(block.header)] + (block.isAgenda
                    ? groups(block, showAllDates: showAllDates, filter: filter).map { .day($0, overdueShown: overdueShown) }
                    : [.entries(rows(block.list))])
            }
        default:
            return [.entries(rows(list))]
        }
    }
}
