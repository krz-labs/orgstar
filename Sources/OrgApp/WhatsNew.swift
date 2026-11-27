import SwiftUI

/// What changed in one version.
public struct ReleaseNotes: Identifiable, Sendable {
    public struct Item: Identifiable, Sendable {
        public let systemImage: String
        public let title: LocalizedStringResource
        public let text: LocalizedStringResource

        public var id: String { title.key }

        public init(_ systemImage: String, _ title: LocalizedStringResource, _ text: LocalizedStringResource) {
            self.systemImage = systemImage
            self.title = title
            self.text = text
        }
    }

    /// The `CFBundleShortVersionString` the notes are for.
    public let version: String
    public let items: [Item]

    public var id: String { version }

    public init(version: String, items: [Item]) {
        self.version = version
        self.items = items
    }
}

/// The notes shown once after an update to a version that has some.
public enum WhatsNew {
    static let seenKey = "whatsNew.seenVersion"

    public static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Newest first. A version without an entry shows nothing.
    public static let releases: [ReleaseNotes] = [
        ReleaseNotes(version: "1.4.0", items: [
            .init("rectangle.on.rectangle.angled", "Presentations",
                  "Present a file one heading at a time, full screen, or export it as a reveal.js deck."),
            .init("rectangle.stack", "Flashcards",
                  "Make and review flashcards in org-fc's format; a widget counts the cards that are due."),
            .init("printer", "Printing", "Print the file, a subtree, the selection or the agenda."),
            .init("doc.plaintext", "Markdown and plain text",
                  "Markdown and text files open with highlighting, heading folds and an outline, and search finds them."),
            .init("note.text", "Denote in Markdown and text",
                  "Denote notes in Markdown and plain text, with their front matter, renaming, links and backlinks."),
            .init("quote.opening", "Citations",
                  "Insert citations from your bibliography, complete keys after @, follow a citation to its entry, and open Zotero links."),
            .init("point.3.connected.trianglepath.dotted", "More org-roam",
                  "Aliases, refs, excluded nodes, tags in the node chooser, and capture templates for new nodes and daily notes."),
        ] + python14 + mac14),
        ReleaseNotes(version: "1.3.0", items: [
            .init("text.cursor", "Completion as you type",
                  "A completion list opens by itself in every preset, matches loosely, and offers words from your files, id links by title, property values and Denote notes."),
            .init("text.badge.plus", "Snippets and templates",
                  "Snippets with tab stops, and templates for new files."),
            .init("magnifyingglass", "Replace across files",
                  "Replace text in every file of your folders, or rename a tag or TODO keyword everywhere at once."),
            .init("clock.arrow.circlepath", "File history",
                  "A file's recovery versions and git commits in one list."),
            .init("checklist", "Lint",
                  "Lint File and Lint All Folders check your files with org-lint's rules."),
            .init("lock.doc", "Encrypted files",
                  "Open and save .org.gpg files, encrypt entries tagged crypt whenever the file is saved, and, if you turn it on, unlock saved passphrases with Face ID or Touch ID."),
            .init("laptopcomputer.and.iphone", "Handoff",
                  "Continue the open file at the same place on your Mac, iPhone or iPad."),
        ] + ios13 + mac13 + [
            .init("speedometer", "Faster",
                  "Files open, parse and are styled faster, and typing in long files stays smooth."),
        ]),
        ReleaseNotes(version: "1.2.0", items: ios + [
            .init("square.and.arrow.up", "LaTeX, OpenDocument and plain text export",
                  "Export and publish to LaTeX, ODT and ASCII without Emacs."),
            .init("play.rectangle", "Code blocks that run in orgstar",
                  "Emacs Lisp, JavaScript, calc and sqlite blocks run without any other program installed."),
            .init("tablecells", "More table formulas",
                  "More Calc and Lisp formulas, date arithmetic and org-sbe are worked out without Emacs."),
            .init("chart.xyaxis.line", "Plots",
                  "Radar plots, more of gnuplot's set options, and SVG files without gnuplot."),
            .init("point.3.connected.trianglepath.dotted", "Diagrams",
                  "dot and mermaid blocks draw SVG and PNG pictures without Graphviz or mermaid installed."),
            .init("circle.hexagongrid", "Node graph",
                  "Show Node Graph draws your org-roam or Denote notes and the links between them."),
            .init("function", "Math in PDFs",
                  "PDF export typesets math without a network connection."),
        ] + mac),
    ]

    /// Only the App Store builds run python blocks in Pyodide.
    private static var python14: [ReleaseNotes.Item] {
        #if canImport(WebKit)
        guard PythonBlocks.folder != nil else { return [] }
        return [.init("chevron.left.forwardslash.chevron.right", "Python built in",
                      "python blocks run in orgstar itself, with Python's standard library and no python3 to install.")]
        #else
        return []
        #endif
    }

    #if os(iOS)
    private static let ios = [
        ReleaseNotes.Item("iphone", "More from the Mac app",
                          "Archive subtrees, publish projects, show calendars in the agenda, copy rich text, and resolve idle clock time."),
        ReleaseNotes.Item("doc.viewfinder", "Scan documents",
                          "More ▸ Attachments ▸ Scan Document… saves the pages as a PDF and links it at the caret."),
    ]
    private static let mac: [ReleaseNotes.Item] = []
    private static let ios13 = [
        ReleaseNotes.Item("command", "One Commands list",
                          "Every screen has the same Commands list, and you can choose the keys on the bar above the keyboard."),
        ReleaseNotes.Item("ipad", "iPad", "A sidebar layout, the menu bar and keyboard shortcuts."),
        ReleaseNotes.Item("arrow.triangle.branch", "Working Copy", "Sync a folder that is a git repository through Working Copy."),
    ]
    private static let mac13: [ReleaseNotes.Item] = []
    private static let mac14: [ReleaseNotes.Item] = []
    #else
    private static let ios: [ReleaseNotes.Item] = []
    private static let ios13: [ReleaseNotes.Item] = []
    private static let mac13 = [
        ReleaseNotes.Item("record.circle", "Keyboard macros",
                          "Record and replay keyboard macros in the Emacs and Mac presets; named ones are kept across restarts."),
        ReleaseNotes.Item("command", "Command palette", "Recent commands come first, and the ones you use most rank higher."),
    ]
    private static let mac14 = [
        ReleaseNotes.Item("square.and.arrow.down", "Import Markdown and Obsidian",
                          "File ▸ Import converts Markdown files or an Obsidian vault to org files."),
        ReleaseNotes.Item("textformat.size", "Larger text",
                          "Settings ▸ Appearance ▸ Size now enlarges the agenda and the sidebars as well as the editor."),
    ]
    private static let mac = [
        ReleaseNotes.Item("sidebar.left", "Agenda in the sidebar",
                          "The calendar button under the sidebar shows your agenda, or a view from views.toml, beside the editor."),
        ReleaseNotes.Item("menubar.rectangle", "orgstar in the menu bar",
                          "Settings ▸ General ▸ Keep orgstar in the menu bar adds capture, the agenda and today's entries to the menu bar."),
    ]
    #endif

    /// The notes to show at launch, the first time `version` runs after another version did: the
    /// newest notes for a version after the one seen last, up to `version`, so an update that
    /// skips a version still shows its notes. Records `version` as seen. `firstLaunch` is a new
    /// install, which shows none.
    public static func pending(
        version: String = appVersion, firstLaunch: Bool, defaults: UserDefaults = .standard, releases: [ReleaseNotes] = releases
    ) -> ReleaseNotes? {
        let seen = defaults.string(forKey: seenKey)
        defaults.set(version, forKey: seenKey)
        guard seen != version, !firstLaunch else { return nil }
        func newer(_ a: String, than b: String) -> Bool { a.compare(b, options: .numeric) == .orderedDescending }
        return releases.first { notes in !newer(notes.version, than: version) && seen.map { newer(notes.version, than: $0) } ?? true }
    }
}

/// A version's notes, as a sheet.
public struct WhatsNewView: View {
    let notes: ReleaseNotes
    @Environment(\.dismiss) private var dismiss

    public init(notes: ReleaseNotes) {
        self.notes = notes
    }

    public var body: some View {
        VStack(spacing: 24) {
            Text("What's New in orgstar \(notes.version)").font(.title2.bold()).multilineTextAlignment(.center)
            #if os(macOS)
            items
            #else
            ScrollView { items }
            #endif
            Button { dismiss() } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 460)
        #endif
    }

    private var items: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(notes.items) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.systemImage).font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.headline)
                        Text(item.text).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
