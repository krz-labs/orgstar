#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import OrgIndex
import OrgPresentation
import QuickLook
import SwiftUI
import UIKit

/// What to read: a file, and where in it.
enum ReaderRoute: Hashable {
    case file(String)
    case offset(String, Int)
    /// A search result, found again if the file changed since it was indexed.
    case heading(HeadingLocation)
}

/// Editing a file, from the reader.
struct EditorRoute: Hashable {
    let path: String
    let offset: Int?
}

/// A file to read: headings that fold and unfold with a tap, as TAB cycles them, text styled as
/// in the editor, and links to follow.
struct ReaderScreen: View {
    let route: ReaderRoute
    let workspace: WorkspaceModel
    let session: DocumentSession
    @State private var fold = FoldState()
    @State private var folded: [Range<Int>] = []
    /// Drawers and blocks the file opens with folded, which fold and unfold from their first line.
    @State private var foldable: [Range<Int>] = []
    @State private var loadedPath: String?
    /// The file's display: indentation, leading stars, inline images, truncation.
    @State private var startup: StartupDisplay?
    /// Headings' padded tags, by the heading's start.
    @State private var tagGaps: [Int: TagGap] = [:]
    /// The view's width, which images in a line's text are no wider than.
    @State private var width: CGFloat = 0
    @State private var showingOutline = false
    @State private var message: String?
    /// A file a link opened, shown in Quick Look.
    @State private var previewed: URL?
    /// The pane the reader shows its file in, closed with the reader.
    @State private var holder = PaneHolder()
    /// The system find bar over the file's text, shown each time `findRequest` changes.
    @State private var find = ReaderFind()
    @State private var findRequest = 0
    /// Find's results, true for the one shown, and the offset to scroll to.
    @State private var found: [Range<Int>: Bool] = [:]
    @State private var findTarget: Int?
    @Environment(\.openURL) private var openURL
    @Environment(MobileModel.self) private var model

    private var pane: EditorPane? { holder.pane }
    private var outline: [OutlineEntry] { pane?.outline ?? [] }
    /// The file the reader's pane shows.
    private var shownPath: String? { pane?.path }
    private var document: DocumentState? { shownPath.flatMap(session.document(of:)) }

    /// The file this reader shows.
    private var path: String {
        switch route {
        case .file(let path), .offset(let path, _): path
        case .heading(let location): location.path
        }
    }

    /// The pane shows this reader's file; the session opens files by their resolved paths.
    private var showsOwnFile: Bool {
        guard let current = shownPath else { return false }
        return current == path || current == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    var body: some View {
        let _ = pane?.editVersion
        // Read again when settings or the Dynamic Type size change.
        let _ = model.settingsVersion
        let theme = MobileTheme(model.theme)
        let truncated = startup?.truncated ?? false
        ScrollViewReader { proxy in
            ScrollView(truncated ? [.vertical, .horizontal] : .vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let tree = document?.tree, showsOwnFile {
                        let length = (tree.text as NSString).length
                        let preambleEnd = min(outline.first?.start ?? length, length)
                        if preambleEnd > 0 { textView(tree, 0..<preambleEnd, theme) }
                        ForEach(Array(outline.enumerated()), id: \.element.start) { index, entry in
                            // While another file opens, rows can update with the last file's
                            // entries for a moment; those don't fit this text.
                            if index < outline.count, outline[index] == entry, entry.end <= length, isShown(index) {
                                heading(tree, entry, theme).id(entry.start)
                                if !fold.folds.contains(entry.start), !fold.bodyFolds.contains(entry.start) {
                                    let body = bodyRange(index, tree)
                                    if !body.isEmpty { textView(tree, body, theme).padding(.leading, bodyIndent(entry, theme)) }
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: truncated ? nil : .infinity, alignment: .leading)
            }
            // Narrower than the view while truncated, the text still starts at the top left.
            .defaultScrollAnchor(truncated ? .topLeading : nil)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(theme.swiftColor("background") ?? Color(uiColor: .systemBackground))
            .onChange(of: pane?.revealRequest?.id) {
                guard let offset = pane?.revealRequest?.offset else { return }
                reveal(offset, proxy)
            }
            .onChange(of: findTarget) {
                guard let offset = findTarget else { return }
                findTarget = nil
                showFound(offset, proxy)
            }
        }
        .navigationTitle(((shownPath ?? "") as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Find", systemImage: "magnifyingglass") {
                    find.text = (document?.tree.text ?? "") as NSString
                    findRequest += 1
                }
                .disabled(document == nil)
                Button("Outline", systemImage: "list.bullet.indent") { showingOutline = true }.disabled(outline.isEmpty)
                if let path = shownPath {
                    if let tree = document?.tree { ExportMenu(path: path, tree: tree) { message = $0 } }
                    NavigationLink(value: EditorRoute(path: path, offset: nil)) { Label("Edit", systemImage: "pencil") }
                }
            }
        }
        .quickLookPreview($previewed)
        .sheet(isPresented: $showingOutline) { outlineSheet }
        .message($message)
        .environment(\.openURL, OpenURLAction { url in follow(url) })
        .background { FindHost(find: find, request: findRequest) }
        .onAppear(perform: open)
        .onChange(of: pane?.path) { loadFolds() }
        .onChange(of: pane?.editVersion) { loadFolds() }
        .onChange(of: model.settingsVersion) { loadFolds() }
        .onReceive(NotificationCenter.default.publisher(for: OrgExport.refused)) { message = $0.object as? String }
    }

    // MARK: - Content

    private func indent(_ entry: OutlineEntry) -> CGFloat { CGFloat(entry.level - 1) * 14 }

    private var indented: Bool { startup?.indented ?? true }

    /// The text as the editor's display settings show it.
    private var display: ReadingText.Display {
        ReadingText.Display(showMarkup: model.showMarkup, options: session.options, highlighter: MobileEditor.highlighter)
    }

    /// org-indent: a heading's text and its body start past its stars, at level + 1 columns,
    /// the fold mark standing where the last star and its space would. Without it nothing is
    /// indented and the stars show.
    private func headingIndent(_ entry: OutlineEntry, _ theme: MobileTheme) -> CGFloat {
        indented ? CGFloat(entry.level - 1) * theme.column : 0
    }

    private func bodyIndent(_ entry: OutlineEntry, _ theme: MobileTheme) -> CGFloat {
        indented ? CGFloat(entry.level + 1) * theme.column : 0
    }

    /// Hidden under a folded ancestor.
    private func isShown(_ index: Int) -> Bool {
        var parent = outline[index].parent
        while let p = parent {
            if fold.folds.contains(outline[p].start) { return false }
            parent = outline[p].parent
        }
        return true
    }

    /// From after the heading line to the first child, or the section's end.
    private func bodyRange(_ index: Int, _ tree: OrgTree) -> Range<Int> {
        let entry = outline[index]
        let ns = tree.text as NSString
        let lineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: entry.start, length: 0)))
        let firstChild = outline[(index + 1)...].first { $0.parent == index }?.start ?? entry.end
        return min(lineEnd, firstChild)..<firstChild
    }

    private func heading(_ tree: OrgTree, _ entry: OutlineEntry, _ theme: MobileTheme) -> some View {
        let ns = tree.text as NSString
        let line = ns.lineRange(for: NSRange(location: entry.start, length: 0))
        let start = indented ? min(entry.start + entry.level + 1, NSMaxRange(line)) : entry.start
        let tags = tagGaps[entry.start].flatMap { $0.tags.upperBound <= NSMaxRange(line) ? $0 : nil }
        func styled(_ range: Range<Int>) -> AttributedString {
            attributed(ReadingText.segments(tree, in: range, display: display), heading: entry.level, theme)
        }
        let hasContent = entry.end > NSMaxRange(line)
        let foldedMark = fold.folds.contains(entry.start) && hasContent
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Image(systemName: foldedMark ? "chevron.right" : "chevron.down")
                .font(.caption.weight(.semibold)).foregroundStyle(theme.swiftColor("markup") ?? Color(uiColor: .tertiaryLabel))
                .opacity(hasContent ? 1 : 0)
                .frame(width: 2 * theme.column, alignment: .leading)
            if let tags, tags.gap.lowerBound >= start {
                headingWithTags(title: styled(start..<tags.gap.lowerBound), gap: styled(tags.gap),
                                tags: styled(tags.tags.lowerBound..<NSMaxRange(line)).trimmingTrailingNewlines(), theme)
            } else {
                lineText(Text(styled(start..<NSMaxRange(line)).trimmingTrailingNewlines()), theme)
            }
        }
        .padding(.leading, headingIndent(entry, theme))
        .padding(.top, entry.level == 1 ? 6 : 0)
        .contentShape(Rectangle())
        .onTapGesture { fold = Presentation.cycle(entry.start, in: tree, fold) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(foldedMark ? "Unfolds the heading" : "Folds the heading")
    }

    /// A heading whose tags are padded: as written when the line fits, the tags at the right
    /// edge when they fit after one space, else the tags on a line of their own at the right.
    private func headingWithTags(title: AttributedString, gap: AttributedString, tags: AttributedString, _ theme: MobileTheme) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(title + gap + tags).fixedSize()
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(title).fixedSize()
                Spacer(minLength: theme.column)
                Text(tags).fixedSize()
            }
            VStack(alignment: .trailing, spacing: 0) {
                lineText(Text(title), theme)
                Text(tags).fixedSize()
            }
        }
        .lineSpacing(CGFloat(max(0, theme.spec.lineSpacing)))
    }

    private func textView(_ tree: OrgTree, _ range: Range<Int>, _ theme: MobileTheme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(parts(tree, range), id: \.range.lowerBound) { part in
                if let image = part.image {
                    Image(uiImage: image.picture).resizable().scaledToFit()
                        .frame(maxWidth: image.width.map { CGFloat($0) } ?? image.picture.size.width, alignment: .leading)
                        .accessibilityLabel((image.path as NSString).lastPathComponent)
                } else {
                    lineText(text(tree, part, theme), theme)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// A part's text, with each image in it standing where its link is.
    private func text(_ tree: OrgTree, _ part: Part, _ theme: MobileTheme) -> Text {
        func styled(_ range: Range<Int>) -> AttributedString {
            attributed(ReadingText.segments(tree, in: range, folded: folded, open: foldable.filter { !folded.contains($0) }, display: display), heading: nil, theme)
        }
        var text = Text("")
        var start = part.range.lowerBound
        for image in part.inText {
            text = Text("\(text)\(Text(styled(start..<image.range.lowerBound)))\(Image(uiImage: image.picture))")
            start = image.range.upperBound
        }
        return Text("\(text)\(Text(styled(start..<part.range.upperBound).trimmingTrailingNewlines()))")
    }

    /// Wrapped to the view's width, or on one line each, scrolling sideways, while truncated.
    private func lineText(_ text: Text, _ theme: MobileTheme) -> some View {
        text
            .lineSpacing(CGFloat(max(0, theme.spec.lineSpacing)))
            .fixedSize(horizontal: startup?.truncated ?? false, vertical: false)
            .frame(maxWidth: startup?.truncated == true ? nil : .infinity, alignment: .leading)
    }

    private struct Part {
        let range: Range<Int>
        /// The image of a link that is all its line holds.
        var image: (picture: UIImage, path: String, width: Int?)?
        /// Images in the text, at their size, and the links they stand for.
        var inText: [(range: Range<Int>, picture: UIImage)] = []
    }

    /// Text, and with inline images on, image links shown as their images: a link that is all
    /// its line holds as a part of its own, others in their part's text.
    private func parts(_ tree: OrgTree, _ range: Range<Int>) -> [Part] {
        guard startup?.inlineImages == true, let path = shownPath else { return [Part(range: range)] }
        // Read so that the view draws again when a remote image arrives.
        _ = RemoteImages.shared.version
        let remote = RemoteImages.Mode(rawValue: session.options.remoteInlineImages) ?? .skip
        let base = URL(fileURLWithPath: path).deletingLastPathComponent()
        let ns = tree.text as NSString
        let maxWidth = width > 0 ? max(80, width - 72) : .greatestFiniteMagnitude
        var parts: [Part] = []
        var pending = Part(range: range.lowerBound..<range.lowerBound)
        let links = InlineImages.links(tree, in: range, remote: remote != .skip, attachment: { DocumentSession.attachmentPath($0, at: $1, tree: tree, path: path) })
        for placement in Presentation.imagePlacements(links, in: ns) {
            let link = placement.link
            guard link.range.lowerBound >= pending.range.lowerBound, link.range.upperBound <= range.upperBound,
                  folded.allSatisfy({ !$0.contains(link.range.lowerBound) }),
                  let picture = MobileEditor.loadImage(link.image.path, relativeTo: base, remote: remote) else { continue }
            guard placement.ownLine else {
                let size = Presentation.imageSize(natural: picture.size, width: link.image.width, maxWidth: maxWidth)
                let sized = picture.cgImage.map { UIImage(cgImage: $0, scale: picture.size.width * picture.scale / max(1, size.width), orientation: picture.imageOrientation) }
                pending.inText.append((link.range, sized ?? picture))
                continue
            }
            let line = ns.lineRange(for: NSRange(location: link.range.lowerBound, length: 0))
            if pending.range.lowerBound < line.location {
                parts.append(Part(range: pending.range.lowerBound..<line.location, inText: pending.inText))
            }
            let end = min(NSMaxRange(line), range.upperBound)
            parts.append(Part(range: line.location..<end, image: (picture, link.image.path, link.image.width)))
            pending = Part(range: end..<end)
        }
        if pending.range.lowerBound < range.upperBound { parts.append(Part(range: pending.range.lowerBound..<range.upperBound, inText: pending.inText)) }
        return parts
    }

    /// Segments as styled text in the theme's font and colors, as the editor styles them;
    /// links get `orgstar-link:` URLs to follow.
    private func attributed(_ segments: [ReadingText.Segment], heading level: Int?, _ theme: MobileTheme) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            var font = level.map(theme.headingFont) ?? theme.body
            if theme.mixedPitch, segment.roles.contains(where: Presentation.isFixedPitch) { font = theme.fixedPitch(font) }
            var color = level.flatMap { theme.color("heading-\(min(max($0, 1), 8))") } ?? theme.foreground
            func fg(_ key: String) { if let c = theme.color(key) { color = c } }
            // Outer roles first, so inner ones win.
            for role in segment.roles.sorted(by: { Self.depth($0) < Self.depth($1) }) {
                switch role {
                case .todo, .done:
                    font = MobileTheme.adding(.traitBold, to: font)
                    if let c = theme.keywordColor(segment.text, done: role == .done) { color = c }
                case .priority: fg("priority")
                case .tags: fg("tags")
                case .bold: font = MobileTheme.adding(.traitBold, to: font)
                case .italic: font = MobileTheme.adding(.traitItalic, to: font)
                case .underline: part.underlineStyle = .single
                case .strikeThrough: part.strikethroughStyle = .single
                case .verbatim, .code, .inlineSource:
                    if let background = theme.color("inline-background") { part.backgroundColor = Color(uiColor: background) }
                    fg(role == .verbatim ? "verbatim" : "code")
                case .markup, .linkMarkup: fg("markup")
                case .leadingStars:
                    // As the editor hides them; shown in the heading's color unless hidden.
                    if !Presentation.skipsLeadingStars(role, indented: indented, hideStars: startup?.hideStars ?? false) { color = .clear }
                case .syntax(let category): if let key = category.themeKey { fg(key) }
                case .timestamp: fg("timestamp")
                case .comment: fg("comment")
                case .keyword: fg("keyword")
                case .metadata: fg("metadata")
                case .blockDelimiter: fg("block-delimiter")
                case .footnote, .cookie, .target, .macro, .latex: fg("special")
                case .table, .rule: fg("table")
                case .link:
                    part.underlineStyle = .single
                    fg("link")
                case .heading, .block: break
                }
            }
            if segment.link != nil {
                // Found again by position when followed.
                part.link = URL(string: "orgstar-link:\(segment.offset)")
            }
            if let start = segment.toggles { part.link = URL(string: "orgstar-fold:\(start)") }
            if let superscript = segment.superscript {
                // Raised or lowered as the editor draws `org-pretty-entities` scripts.
                part.baselineOffset = (superscript ? 0.3 : -0.3) * font.pointSize
                font = font.withSize(font.pointSize * 0.7)
            }
            part.font = Font(font as CTFont)
            part.foregroundColor = Color(uiColor: color)
            if !found.isEmpty { markFound(&part, segment) }
            result += part
        }
        return result
    }

    /// Find's results in a segment's text: exactly where the segment shows the file as written,
    /// otherwise the whole segment.
    private func markFound(_ part: inout AttributedString, _ segment: ReadingText.Segment) {
        let length = (segment.text as NSString).length
        let span = segment.offset..<(segment.offset + length)
        let source = (document?.tree.text ?? "") as NSString
        let asWritten = span.upperBound <= source.length && source.substring(with: NSRange(span)) == segment.text
        for (range, shown) in found where range.overlaps(span) || (span.isEmpty && range.contains(span.lowerBound)) {
            let color = Color(uiColor: shown ? .systemYellow : .systemYellow.withAlphaComponent(0.35))
            guard asWritten else {
                part.backgroundColor = color
                continue
            }
            let text = segment.text
            func index(_ offset: Int) -> AttributedString.Index {
                let utf16 = text.utf16.index(text.startIndex, offsetBy: min(max(0, offset - span.lowerBound), length))
                return part.index(part.startIndex, offsetByCharacters: text.distance(from: text.startIndex, to: utf16))
            }
            let lower = index(range.lowerBound), upper = index(range.upperBound)
            if lower < upper { part[lower..<upper].backgroundColor = color }
        }
    }

    /// Unfolds the way to a find result, its heading and a drawer it's in, and scrolls to its heading.
    private func showFound(_ offset: Int, _ proxy: ScrollViewProxy) {
        folded.removeAll { $0.contains(offset) }
        // Before the first heading, the text shows already.
        guard let index = outline.lastIndex(where: { $0.start <= offset }) else { return }
        fold.folds.remove(outline[index].start)
        fold.bodyFolds.remove(outline[index].start)
        reveal(offset, proxy)
    }

    /// How deep a role's text usually nests: elements, then objects, then their parts.
    private static func depth(_ role: StyleRole) -> Int {
        switch role {
        case .heading: 0
        case .metadata, .keyword, .comment, .block, .table, .rule: 1
        case .blockDelimiter, .link, .bold, .italic, .underline, .strikeThrough, .timestamp, .footnote, .target, .macro, .latex: 2
        default: 3
        }
    }

    // MARK: - Actions

    private func open() {
        find.onChange = { found = $0 }
        find.onShow = { findTarget = $0 }
        let pane = holder.pane ?? {
            let made = session.makePane()
            holder.pane = made
            holder.release = { [weak session] in session?.closePane(made) }
            return made
        }()
        // What the reader opens and follows goes to its pane.
        session.focused = pane
        if loadedPath == nil {
            switch route {
            case .file(let path): session.open(path, in: pane)
            case .offset(let path, let offset):
                session.open(path, in: pane)
                session.reveal(offset, in: pane)
            case .heading(let location): session.show(location)
            }
        }
        loadFolds()
    }

    /// The file's startup display, as the editor opens it; its heading folds are kept while
    /// the same file is open.
    private func loadFolds() {
        guard let tree = document?.tree, showsOwnFile else { return }
        let display = Presentation.startupDisplay(tree, options: session.options)
        startup = display
        let text = tree.text as NSString
        tagGaps = Dictionary(Presentation.tagGaps(tree).map { (text.lineRange(for: NSRange(location: $0.gap.lowerBound, length: 0)).location, $0) }) { a, _ in a }
        folded = display.wrappers.map(\.hidden)
        foldable = folded
        guard loadedPath != shownPath else { return }
        loadedPath = shownPath
        fold = display.folds
    }

    /// Unfolds the way to the heading containing `offset` and scrolls to it.
    private func reveal(_ offset: Int, _ proxy: ScrollViewProxy) {
        guard let index = outline.lastIndex(where: { $0.start <= offset }) else { return }
        var parent = outline[index].parent
        while let p = parent {
            fold.folds.remove(outline[p].start)
            parent = outline[p].parent
        }
        let start = outline[index].start
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(start, anchor: .top) } }
    }

    private func follow(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == "orgstar-fold", let start = Int(url.absoluteString.dropFirst("orgstar-fold:".count)) {
            if folded.contains(where: { $0.lowerBound == start }) {
                folded.removeAll { $0.lowerBound == start }
            } else if let range = foldable.first(where: { $0.lowerBound == start }) {
                folded.append(range)
            }
            return .handled
        }
        guard url.scheme == "orgstar-link", let offset = Int(url.absoluteString.dropFirst("orgstar-link:".count)),
              let tree = document?.tree, let link = Links.link(at: offset, text: tree.text, tree: tree)?.link else {
            return .systemAction
        }
        if let pane { session.focused = pane }
        switch session.follow(link, workspace: workspace, isText: { _ in false }) {
        case .shown:
            message = nil
            // A link to another file shows it on its own screen; this pane keeps its file.
            if let pane, let target = pane.path, target != path, !showsOwnFile {
                let caret = session.caret(of: target) ?? 0
                session.open(path, in: pane)
                model.openRequest = .offset(target, caret)
            }
        case .openExternally(let target): if target.isFileURL { previewed = target } else { openURL(target) }
        case .message(let text): message = text
        case .choose(let question, let paths): message = question + paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        case .elisp: message = "Open the file in the editor to run elisp links."
        }
        return .handled
    }

    private var outlineSheet: some View {
        NavigationStack {
            List(outline, id: \.start) { entry in
                Button {
                    showingOutline = false
                    if let pane { session.reveal(entry.start, in: pane) }
                } label: {
                    Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                        .padding(.leading, indent(entry))
                        .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Outline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingOutline = false } } }
        }
    }
}

/// The reader's find, for the system find bar: it searches the file as written and tells the
/// reader which results to mark and which one to show.
@MainActor
final class ReaderFind: NSObject, @preconcurrency UITextSearching, UIFindInteractionDelegate {
    /// The file's text, set when the find bar opens.
    nonisolated(unsafe) var text: NSString = ""
    /// Each result marked, true for the one shown.
    var onChange: ([Range<Int>: Bool]) -> Void = { _ in }
    /// The result to show, by its offset.
    var onShow: (Int) -> Void = { _ in }
    private var marked: [Range<Int>: Bool] = [:]

    final class Position: UITextPosition {
        let offset: Int
        init(_ offset: Int) { self.offset = offset }
    }

    final class TextRange: UITextRange {
        let range: Range<Int>
        init(_ range: Range<Int>) { self.range = range }
        override var start: UITextPosition { Position(range.lowerBound) }
        override var end: UITextPosition { Position(range.upperBound) }
        override var isEmpty: Bool { range.isEmpty }
    }

    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        UITextSearchingFindSession(searchableObject: self)
    }

    var selectedTextRange: UITextRange? { nil }

    func compare(_ foundRange: UITextRange, toRange: UITextRange, document: AnyHashable??) -> ComparisonResult {
        let a = (foundRange as? TextRange)?.range.lowerBound ?? 0, b = (toRange as? TextRange)?.range.lowerBound ?? 0
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    /// May be called off the main thread; reads only `text`, an immutable string.
    nonisolated func performTextSearch(queryString: String, options: UITextSearchOptions, resultAggregator: UITextSearchAggregator<AnyHashable?>) {
        for found in EditorFind.matches(of: queryString, in: text, options: options) {
            resultAggregator.foundRange(TextRange(found), searchString: queryString, document: nil)
        }
        resultAggregator.finishedSearching()
    }

    func decorate(foundTextRange: UITextRange, document: AnyHashable??, usingStyle style: UITextSearchFoundTextStyle) {
        guard let range = (foundTextRange as? TextRange)?.range else { return }
        switch style {
        case .normal: marked[range] = nil
        case .highlighted:
            marked[range] = true
            onShow(range.lowerBound)
        default: marked[range] = false
        }
        onChange(marked)
    }

    func clearAllDecoratedFoundText() {
        marked = [:]
        onChange(marked)
    }

    func scrollRangeToVisible(_ range: UITextRange, inDocument: AnyHashable??) {
        if let range = (range as? TextRange)?.range { onShow(range.lowerBound) }
    }
}

/// Holds the find interaction for a SwiftUI screen, and shows its find bar when `request` changes.
private struct FindHost: UIViewRepresentable {
    let find: ReaderFind
    let request: Int

    /// The find bar shows for the first responder's interaction.
    final class Host: UIView {
        override var canBecomeFirstResponder: Bool { true }
    }

    func makeUIView(context: Context) -> Host {
        let view = Host()
        view.addInteraction(UIFindInteraction(sessionDelegate: find))
        return view
    }

    func updateUIView(_ view: Host, context: Context) {
        guard request != context.coordinator.shown else { return }
        context.coordinator.shown = request
        view.becomeFirstResponder()
        view.interactions.lazy.compactMap { $0 as? UIFindInteraction }.first?.presentFindNavigator(showingReplace: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown = 0
    }
}

private extension AttributedString {
    /// Without the final newline, which `Text` would show as an empty line.
    func trimmingTrailingNewlines() -> AttributedString {
        var copy = self
        while let last = copy.characters.last, last.isNewline { copy.characters.removeLast() }
        return copy
    }
}
#endif
