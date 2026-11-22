import AppKit
import OrgApp
import SwiftUI

/// Export… (`app.export-dialog`): the format, where the file goes, and whether to open it after.
struct ExportSheet: View {
    let source: URL
    /// Whether the caret is in a subtree that can be exported alone.
    let inSubtree: Bool
    /// The default destination for an extension, with or without the subtree.
    let target: (_ ext: String, _ subtree: Bool) -> URL
    /// Without a chosen destination, the App Store build passes nil, and the export asks where
    /// to write when the default is outside the sandbox's reach.
    let export: (_ format: String, _ destination: URL?, _ open: Bool, _ subtree: Bool, _ bodyOnly: Bool) -> Void
    /// The file's settings, kept when it is exported.
    @State private var format: String
    @State private var openAfter: Bool
    @State private var bodyOnly: Bool
    @State private var subtree: Bool
    @AppStorage("pdfMargin") private var pdfMargin = 50
    @AppStorage("pdfFont") private var pdfFont = ""
    @AppStorage("pdfPageNumbers") private var pdfPageNumbers = true
    @State private var destination: URL?
    @Environment(\.dismiss) private var dismiss

    init(
        source: URL, inSubtree: Bool, target: @escaping (_ ext: String, _ subtree: Bool) -> URL,
        export: @escaping (_ format: String, _ destination: URL?, _ open: Bool, _ subtree: Bool, _ bodyOnly: Bool) -> Void
    ) {
        self.source = source
        self.inSubtree = inSubtree
        self.target = target
        self.export = export
        let saved = ExportSettings.saved(for: source.path)
        _format = State(initialValue: saved.format)
        _openAfter = State(initialValue: saved.openAfter)
        _bodyOnly = State(initialValue: saved.bodyOnly)
        _subtree = State(initialValue: saved.subtree)
    }

    #if APPSTORE
    static let formats: [(id: String, title: String, ext: String)] = [
        ("html", "HTML", "html"), ("markdown", "Markdown", "md"), ("print-pdf", "PDF", "pdf"), ("docx", "Word", "docx"),
        ("rtf", "Rich Text (RTF)", "rtf"), ("plain-text", "Plain text", "txt"), ("odt", "ODT", "odt"),
        ("icalendar", "iCalendar", "ics"), ("latex", "LaTeX", "tex"), ("text", "Plain text, ASCII", "txt"),
    ]
    #else
    static let formats: [(id: String, title: String, ext: String)] = [
        ("html", "HTML", "html"), ("markdown", "Markdown", "md"), ("print-pdf", "PDF", "pdf"), ("docx", "Word", "docx"),
        ("rtf", "Rich Text (RTF)", "rtf"), ("plain-text", "Plain text", "txt"), ("pdf", "PDF via LaTeX (Emacs)", "pdf"),
        ("odt", "ODT", "odt"), ("latex", "LaTeX", "tex"), ("text", "Plain text, ASCII", "txt"),
        ("icalendar", "iCalendar", "ics"),
    ]
    #endif

    private var ext: String { Self.formats.first { $0.id == format }?.ext ?? "html" }
    private var chosen: URL { destination ?? target(ext, subtree && inSubtree) }
    /// PDF and ODT are whole documents.
    private var allowsBodyOnly: Bool { ExportSettings.allowsBodyOnly(format) }

    var body: some View {
        Form {
            Picker("Format", selection: $format) {
                ForEach(Self.formats, id: \.id) { Text($0.title).tag($0.id) }
            }
            .onChange(of: format) { destination = destination.map { $0.deletingPathExtension().appendingPathExtension(ext) } }
            Picker("Scope", selection: Binding(get: { subtree && inSubtree }, set: { subtree = $0 })) {
                Text("Whole file").tag(false)
                Text("Subtree at the caret").tag(true)
            }
            .disabled(!inSubtree)
            Toggle("Body only", isOn: $bodyOnly)
                .disabled(!allowsBodyOnly)
                .help("Leave out the title and page wrapper, as Org's body-only export")
            if format == "print-pdf" {
                Stepper("Margins: \(pdfMargin) pt", value: $pdfMargin, in: 18...144, step: 6)
                Picker("Font", selection: $pdfFont) {
                    Text("The export's own").tag("")
                    Divider()
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Page numbers", isOn: $pdfPageNumbers)
            }
            LabeledContent("Destination") {
                HStack {
                    Text(chosen.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { choose() }
                }
            }
            Toggle("Open after export", isOn: $openAfter)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") {
                    var settings = ExportSettings()
                    (settings.format, settings.subtree, settings.bodyOnly, settings.openAfter) = (format, subtree, bodyOnly, openAfter)
                    settings.save(for: source.path, lastUsed: true)
                    #if APPSTORE
                    export(format, destination, openAfter, subtree && inSubtree, bodyOnly && allowsBodyOnly)
                    #else
                    export(format, chosen, openAfter, subtree && inSubtree, bodyOnly && allowsBodyOnly)
                    #endif
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520)
    }

    private func choose() {
        let panel = NSSavePanel()
        panel.directoryURL = chosen.deletingLastPathComponent()
        panel.nameFieldStringValue = chosen.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}
