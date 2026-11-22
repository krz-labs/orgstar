import Foundation
import Testing
@testable import OrgApp
import OrgCore

struct ExportSettingsTests {
    static func defaults() -> UserDefaults { UserDefaults(suiteName: "orgstar-export-\(UUID().uuidString)")! }

    static let file = "#+TITLE: Whole\n#+OPTIONS: toc:nil\nIntro.\n* One\nFirst.\n** Sub\nSub body.\n* Two\nSecond.\n"
    static var caret: Int { (file as NSString).range(of: "First.").location }

    /// What the Mac's export writes for a format, scope and body-only choice.
    static func export(_ format: String, subtree: Bool, bodyOnly: Bool) throws -> String {
        let text = subtree ? try #require(ExportScope.subtree(file, at: caret)) : file
        switch format {
        case "markdown": return MarkdownExport.document(text, bodyOnly: bodyOnly)
        case "latex": return try LaTeXExport.document(text, bodyOnly: bodyOnly, author: "A", file: true)
        case "text": return try ASCIIExport.document(text, bodyOnly: bodyOnly, author: "A", file: true)
        default: return HTMLExport.page(text, fallbackTitle: "t", bodyOnly: bodyOnly)
        }
    }

    @Test func settingsAreKeptPerFile() {
        let defaults = Self.defaults()
        #expect(ExportSettings.saved(for: "/notes/a.org", defaults: defaults) == ExportSettings())
        var a = ExportSettings()
        (a.format, a.subtree, a.bodyOnly, a.openAfter) = ("markdown", true, true, true)
        a.save(for: "/notes/a.org", defaults: defaults)
        var b = ExportSettings()
        b.format = "latex"
        b.save(for: "/notes/b.org", defaults: defaults)
        #expect(ExportSettings.saved(for: "/notes/a.org", defaults: defaults) == a)
        #expect(ExportSettings.saved(for: "/notes/b.org", defaults: defaults) == b)
        #expect(ExportSettings.saved(for: "/notes/c.org", defaults: defaults) == ExportSettings())
    }

    /// A file without settings starts with the format and open-after choice last exported
    /// with, and exports the whole file as a whole document.
    @Test func aFileWithoutSettingsGetsTheLastUsedFormat() {
        let defaults = Self.defaults()
        var a = ExportSettings()
        (a.format, a.subtree, a.bodyOnly, a.openAfter) = ("markdown", true, true, true)
        a.save(for: "/notes/a.org", lastUsed: true, defaults: defaults)
        var fresh = ExportSettings()
        (fresh.format, fresh.openAfter) = ("markdown", true)
        #expect(ExportSettings.saved(for: "/notes/c.org", defaults: defaults) == fresh)
        var b = ExportSettings()
        b.format = "odt"
        b.save(for: "/notes/b.org", defaults: defaults)
        #expect(ExportSettings.saved(for: "/notes/c.org", defaults: defaults) == fresh)
    }

    /// A single-format command exports what the dialog does with the same scope and body-only
    /// choice.
    @Test(arguments: ["html", "html-open", "markdown", "latex", "text"])
    func commandsFollowTheFilesSettings(_ format: String) throws {
        let defaults = Self.defaults()
        let whole = try Self.export(format, subtree: false, bodyOnly: false)
        let fresh = try #require(ExportSettings.saved(for: "/notes/a.org", defaults: defaults).commandOptions(format))
        #expect(try Self.export(format, subtree: fresh.subtree, bodyOnly: fresh.bodyOnly) == whole)
        for (subtree, bodyOnly) in [(true, false), (false, true), (true, true)] {
            var settings = ExportSettings()
            (settings.subtree, settings.bodyOnly) = (subtree, bodyOnly)
            settings.save(for: "/notes/a.org", defaults: defaults)
            let options = try #require(ExportSettings.saved(for: "/notes/a.org", defaults: defaults).commandOptions(format))
            let dialog = try Self.export(format, subtree: subtree, bodyOnly: bodyOnly)
            #expect(try Self.export(format, subtree: options.subtree, bodyOnly: options.bodyOnly) == dialog)
            #expect(dialog != whole)
            #expect(dialog.contains("Second.") == !subtree)
        }
    }

    @Test func theMessageSaysWhatWasExported() {
        #expect(ExportSettings.exported("a.html", subtree: false, bodyOnly: false) == "Exported to a.html")
        #expect(ExportSettings.exported("a.html", subtree: true, bodyOnly: false) == "Exported the subtree to a.html")
        #expect(ExportSettings.exported("a.html", subtree: false, bodyOnly: true) == "Exported the body to a.html")
        #expect(ExportSettings.exported("a.html", subtree: true, bodyOnly: true) == "Exported the subtree's body to a.html")
    }

    /// Body only is refused for the formats the dialog disables it for; the agenda files'
    /// calendars follow neither choice.
    @Test func bodyOnlyIsRefusedForWholeDocumentFormats() throws {
        var settings = ExportSettings()
        (settings.subtree, settings.bodyOnly) = (true, true)
        for format in ["pdf", "print-pdf", "odt", "docx", "rtf", "plain-text", "icalendar"] {
            #expect(!ExportSettings.allowsBodyOnly(format))
            #expect(settings.commandOptions(format) == nil)
        }
        for format in ["icalendar-agenda", "icalendar-combined"] {
            let options = try #require(settings.commandOptions(format))
            #expect(options == (false, false))
        }
        settings.bodyOnly = false
        let options = try #require(settings.commandOptions("print-pdf"))
        #expect(options == (true, false))
    }
}
