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

    #if os(iOS)
    private static let ios = [
        ReleaseNotes.Item("iphone", "More from the Mac app",
                          "Archive subtrees, publish projects, show calendars in the agenda, copy rich text, and resolve idle clock time."),
        ReleaseNotes.Item("doc.viewfinder", "Scan documents",
                          "More ▸ Attachments ▸ Scan Document… saves the pages as a PDF and links it at the caret."),
    ]
    private static let mac: [ReleaseNotes.Item] = []
    #else
    private static let ios: [ReleaseNotes.Item] = []
    private static let mac = [
        ReleaseNotes.Item("sidebar.left", "Agenda in the sidebar",
                          "The Agenda button at the top of the sidebar shows your agenda, or a view from views.toml, beside the editor."),
        ReleaseNotes.Item("menubar.rectangle", "orgstar in the menu bar",
                          "Settings ▸ General ▸ Keep orgstar in the menu bar adds capture, the agenda and today's entries to the menu bar."),
    ]
    #endif

    /// The notes to show at launch: those for `version`, the first time it runs after another
    /// version did. Records `version` as seen. `firstLaunch` is a new install, which shows none.
    public static func pending(
        version: String = appVersion, firstLaunch: Bool, defaults: UserDefaults = .standard, releases: [ReleaseNotes] = releases
    ) -> ReleaseNotes? {
        let seen = defaults.string(forKey: seenKey)
        defaults.set(version, forKey: seenKey)
        guard seen != version, !firstLaunch else { return nil }
        return releases.first { $0.version == version }
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
