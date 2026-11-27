import Foundation

/// reveal.js export, as org-re-reveal (3.x) writes a deck: a title slide, a slide for each
/// heading down to `H`, those below `#+REVEAL_HLEVEL` (1) as vertical slides under the one
/// above, speaker notes from `#+BEGIN_NOTES` blocks, fragments from `#+ATTR_REVEAL: :frag`, and
/// everything inside a slide as HTML export writes it.
///
/// Without `#+REVEAL_ROOT` the deck is one file with reveal.js, its theme and plugins in the
/// page, read from `library` (reveal.js 6.0.2's `dist` files), and local images as `data:`
/// URIs. With it, the deck links to reveal.js there, as org-re-reveal does, laid out as
/// reveal.js 6 lays out its `dist` folder.
public enum RevealExport {
    /// The folder with reveal.js, `reveal.css`, `reset.css`, `theme/` and `plugin/`, which the
    /// apps set from `OrgMathJax.reveal`.
    nonisolated(unsafe) public static var library: URL?
    /// MathJax's `tex-svg-full.js`, put in a deck with math that inlines reveal.js.
    nonisolated(unsafe) public static var mathJax: URL?

    /// `org-re-reveal-plugins`, less markdown, which org text never needs.
    public static let defaultPlugins = ["notes", "search", "zoom"]
    /// The plugins in `library`; a deck that inlines reveal.js leaves out others.
    public static let bundledPlugins: Set<String> = ["notes", "search", "zoom", "math"]
    /// The themes in `library`.
    public static let themes = ["beige", "black", "black-contrast", "blood", "dracula", "league", "moon", "night", "serif", "simple", "sky", "solarized", "white", "white-contrast"]
    /// Themes with light text on a dark background, which take the dark code colors.
    static let darkThemes: Set<String> = ["black", "black-contrast", "blood", "dracula", "league", "moon", "night"]
    static let pluginNames = [
        "markdown": "RevealMarkdown", "notes": "RevealNotes", "search": "RevealSearch", "zoom": "RevealZoom",
        "highlight": "RevealHighlight", "math": "RevealMath.MathJax3",
    ]

    /// The `#+REVEAL_…` keywords of `text`, after its setup files', each with its values in order.
    static func keywords(_ text: String) -> [String: [String]] {
        var keywords: [String: [String]] = [:]
        for m in text.matches(of: #/(?mi)^[ \t]*#\+(REVEAL_[A-Z_]+|SUBTITLE|EMAIL):[ \t]*(.*?)[ \t]*$/#) {
            keywords[m.1.uppercased(), default: []].append(String(m.2))
        }
        return keywords
    }

    /// The deck. `path` is the file's, for includes, images and `#+REVEAL_EXTRA_CSS`.
    public static func document(
        _ text: String, fallbackTitle: String, settings: OrgSettings = .default, path: String? = nil, now: Date = Date(),
        codeStyle: HTMLCodeStyle? = nil, language: String = "en", library: URL? = RevealExport.library, mathJax: URL? = RevealExport.mathJax
    ) -> String {
        let directory = path.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        let expanded = ExportPreprocess.macros(ExportPreprocess.includes(text, directory: directory), path: path, now: now, setup: settings.setupKeywords)
        let text = ExportPreprocess.attachments(expanded, path: path, settings: settings)
        let options = ExportOptions.parse(settings.setupKeywords + text)
        let keywords = Self.keywords(settings.setupKeywords + "\n" + text)
        func keyword(_ key: String) -> String? { keywords[key]?.last }
        func flag(_ item: String, _ fallback: Bool) -> Bool { options.items[item].map { $0 != "nil" } ?? fallback }

        let root = keyword("REVEAL_ROOT").flatMap { $0.isEmpty ? nil : $0 }
        let inline = root == nil && library.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("reveal.js").path) } == true
        let base = root.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? "./reveal.js/"
        let theme = keyword("REVEAL_THEME").flatMap { $0.isEmpty ? nil : $0 } ?? "black"
        let plugins = keyword("REVEAL_PLUGINS").map { $0.split(whereSeparator: { "() \t".contains($0) }).map { String($0).lowercased() } } ?? defaultPlugins
        let hlevel = keyword("REVEAL_HLEVEL").flatMap { Int($0) } ?? 1

        let meta = HTMLExport.metadata(text, settings: settings)
        let title = meta.title ?? fallbackTitle
        let minLevel = DocumentModel(tree: OrgParser.parse(text, defaults: settings)).headings.map(\.level).min() ?? 1
        let slides = RevealSlides(hlevel: hlevel, headlineLevels: options.headlineLevels, minLevel: minLevel, fragmentStyle: keyword("REVEAL_DEFAULT_FRAG_STYLE"))
        let renderer = HTMLRenderer(settings: settings, options: options)
        renderer.codeStyle = codeStyle
        renderer.language = meta.language ?? language
        renderer.reveal = slides
        renderer.inTitle = true
        let titleHTML = renderer.inlineString(title)
        let subtitleHTML = keyword("SUBTITLE").map(renderer.inlineString) ?? ""
        renderer.inTitle = false
        renderer.citations = CiteProcessor(text: text, directory: directory, global: settings.citeGlobalBibliography)
        var body = renderer.document(renderer.citations == nil ? text : renderer.citations!.inliningNotes(CiteProcessor.removingNocite(text)))
        let footnotes = renderer.footnoteSection()
        if !footnotes.isEmpty { body += "<section>\n\(footnotes)</section>\n" }
        var contents = renderer.tableOfContents()
        if !contents.isEmpty { contents = "<section id=\"table-of-contents-section\">\n\(contents)</section>\n" }
        // reveal.js goes to a slide by `#/id`.
        var slidesHTML = contents + body
        for id in slides.headingIDs {
            slidesHTML = slidesHTML.replacingOccurrences(of: "href=\"#\(HTMLRenderer.escape(id))\"", with: "href=\"#/slide-\(HTMLRenderer.escape(id))\"")
        }

        // The title slide: org-re-reveal's `auto` template, a template of `%` specs, or none.
        var titleSlide = ""
        let template = keywords["REVEAL_TITLE_SLIDE"].map { $0.joined(separator: "\n") } ?? "auto"
        if flag("reveal_title_slide", true), template != "nil", !template.isEmpty {
            let escape = HTMLRenderer.escape
            let author = options.author ? meta.author.map(escape) ?? "" : ""
            let date = options.date ? meta.date.map(escape) ?? "" : ""
            let email = flag("email", false) ? keyword("EMAIL").map(escape) ?? "" : ""
            var content: String
            if template == "auto" {
                content = options.title && !title.isEmpty ? "<h1 class=\"title\">\(titleHTML)</h1>" : ""
                if !subtitleHTML.isEmpty { content += "<h2 class=\"subtitle\">\(subtitleHTML)</h2>" }
                if !author.isEmpty { content += "<h2 class=\"author\">\(author)</h2>" }
                if !email.isEmpty { content += "<h2 class=\"email\">\(email)</h2>" }
                if !date.isEmpty { content += "<h2 class=\"date\">\(date)</h2>" }
                if let misc = keyword("REVEAL_MISCINFO"), !misc.isEmpty { content += "<p class=\"misc\">\(misc)</p>" }
            } else {
                let specs: [Character: String] = [
                    "t": titleHTML, "s": subtitleHTML, "a": author, "e": email, "d": date,
                    "A": keyword("REVEAL_ACADEMIC_TITLE") ?? "", "m": keyword("REVEAL_MISCINFO") ?? "", "%": "%",
                ]
                content = ""
                var chars = template.makeIterator()
                while let c = chars.next() {
                    guard c == "%", let spec = chars.next() else {
                        content.append(c)
                        continue
                    }
                    content += specs[spec] ?? "%" + String(spec)
                }
            }
            let background = slides.attributes([
                ("data-background", keyword("REVEAL_TITLE_SLIDE_BACKGROUND")),
                ("data-background-size", keyword("REVEAL_TITLE_SLIDE_BACKGROUND_SIZE")),
                ("data-background-position", keyword("REVEAL_TITLE_SLIDE_BACKGROUND_POSITION")),
                ("data-background-repeat", keyword("REVEAL_TITLE_SLIDE_BACKGROUND_REPEAT")),
                ("data-background-transition", keyword("REVEAL_TITLE_SLIDE_BACKGROUND_TRANSITION")),
            ])
            titleSlide = "<section id=\"sec-title-slide\"\(background)>\n\(content)\n</section>\n"
        }

        // The page around the slides.
        func file(_ name: String) -> String? {
            guard let library else { return nil }
            return try? String(contentsOf: library.appendingPathComponent(name), encoding: .utf8)
        }
        func style(_ css: String, id: String? = nil) -> String {
            "<style\(id.map { " id=\"\($0)\"" } ?? "")>\n\(css.replacingOccurrences(of: "</style", with: "<\\/style"))\n</style>\n"
        }
        func script(_ js: String) -> String {
            "<script>\n\(js.replacingOccurrences(of: "</script", with: "<\\/script"))\n</script>\n"
        }
        var head = ""
        if inline, let reset = file("reset.css"), let css = file("reveal.css") {
            head += style(reset) + style(css)
        } else {
            head += "<link rel=\"stylesheet\" href=\"\(base)dist/reset.css\"/>\n<link rel=\"stylesheet\" href=\"\(base)dist/reveal.css\"/>\n"
        }
        // A theme by name, or a stylesheet of one's own.
        if theme.hasSuffix(".css") || theme.contains("/") {
            head += "<link rel=\"stylesheet\" href=\"\(HTMLRenderer.escape(theme))\" id=\"theme\"/>\n"
        } else if inline {
            if let css = file("theme/\(themes.contains(theme) ? theme : "black").css") { head += style(css, id: "theme") }
        } else {
            head += "<link rel=\"stylesheet\" href=\"\(base)dist/theme/\(HTMLRenderer.escape(theme)).css\" id=\"theme\"/>\n"
        }
        if !inline, plugins.contains("highlight") {
            head += "<link rel=\"stylesheet\" href=\"\(base)dist/plugin/highlight/monokai.css\"/>\n"
        }
        for extra in keywords["REVEAL_EXTRA_CSS"] ?? [] where !extra.isEmpty {
            let url = extra.hasPrefix("/") || extra.contains(":") ? nil : directory?.appendingPathComponent(extra)
            if inline, let url, let css = try? String(contentsOf: url, encoding: .utf8) {
                head += style(css)
            } else {
                head += "<link rel=\"stylesheet\" href=\"\(HTMLRenderer.escape(extra))\"/>\n"
            }
        }
        if let codeStyle { head += style(Self.codeCSS(codeStyle.css, dark: darkThemes.contains(theme))) }
        head += options.htmlHead.map { $0 + "\n" }.joined()
        head += (keywords["REVEAL_HEAD_PREAMBLE"] ?? []).map { $0 + "\n" }.joined()
        if renderer.hasMath, !plugins.contains("math") {
            head += "<script>window.MathJax = { tex: { inlineMath: [['\\\\(', '\\\\)']], displayMath: [['\\\\[', '\\\\]'], ['$$', '$$']] } };</script>\n"
            if inline, let mathJax, let js = try? String(contentsOf: mathJax, encoding: .utf8) {
                head += "<script id=\"MathJax-script\">\n\(js.replacingOccurrences(of: "</script", with: "<\\/script"))\n</script>\n"
            } else {
                head += HTMLExport.mathJaxScript + "\n"
            }
        }

        var scripts = ""
        if inline, let js = file("reveal.js") {
            scripts += script(js)
        } else {
            scripts += "<script src=\"\(base)dist/reveal.js\"></script>\n"
        }
        var used: [String] = []
        for plugin in plugins where pluginNames[plugin] != nil && !used.contains(plugin) {
            if inline {
                guard bundledPlugins.contains(plugin), let js = file("plugin/\(plugin).js") else { continue }
                scripts += script(js)
            } else {
                scripts += "<script src=\"\(base)dist/plugin/\(plugin).js\"></script>\n"
            }
            used.append(plugin)
        }
        // `org-re-reveal`'s defaults, then `#+REVEAL_INIT_OPTIONS`, which win.
        func bool(_ item: String, _ fallback: Bool) -> String { flag(item, fallback) ? "true" : "false" }
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
        let slideNumber = options.items["reveal_slide_number"].map { $0 == "nil" ? "false" : $0 == "t" ? "'c'" : quoted($0) } ?? "'c'"
        var initialize = [
            "controls: \(bool("reveal_control", true))", "progress: \(bool("reveal_progress", true))", "history: \(bool("reveal_history", false))",
            "center: \(bool("reveal_center", true))", "slideNumber: \(slideNumber)", "rollingLinks: \(bool("reveal_rolling_links", false))",
            "keyboard: \(bool("reveal_keyboard", true))", "mouseWheel: \(bool("reveal_mousewheel", false))",
            "fragmentInURL: \(bool("reveal_fragmentinurl", false))", "hashOneBasedIndex: \(bool("reveal_hashonebasedindex", false))",
            "pdfSeparateFragments: \(bool("reveal_pdfseparatefragments", true))", "overview: \(bool("reveal_overview", true))",
        ]
        for (key, option) in [("REVEAL_MARGIN", "margin"), ("REVEAL_MIN_SCALE", "minScale"), ("REVEAL_MAX_SCALE", "maxScale")] {
            if let value = keyword(key), Double(value) != nil { initialize.append("\(option): \(value)") }
        }
        initialize.append("transition: \(quoted(keyword("REVEAL_TRANS").flatMap { $0.isEmpty ? nil : $0 } ?? "convex"))")
        initialize.append("transitionSpeed: \(quoted(keyword("REVEAL_SPEED").flatMap { $0.isEmpty ? nil : $0 } ?? "default"))")
        for line in keywords["REVEAL_INIT_OPTIONS"] ?? [] {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: ", \t"))
            if !trimmed.isEmpty { initialize.append(trimmed) }
        }
        initialize.append("plugins: [ \(used.compactMap { pluginNames[$0] }.joined(separator: ", ")) ]")
        scripts += script("Reveal.initialize({\n" + initialize.joined(separator: ",\n") + "\n});")

        var page = """
            <!DOCTYPE html>
            <html lang="\(HTMLRenderer.escape(renderer.language))">
            <head>
            <meta charset="utf-8"/>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no"/>
            <title>\(HTMLRenderer.escape(title))</title>
            \(options.author ? meta.author.map { "<meta name=\"author\" content=\"\(HTMLRenderer.escape($0))\"/>\n" } ?? "" : "")\(head)</head>
            <body>
            \((keywords["REVEAL_PREAMBLE"] ?? []).map { $0 + "\n" }.joined())<div class="reveal">
            <div class="slides">
            \(titleSlide)\(slidesHTML)</div>
            \((keywords["REVEAL_POSTAMBLE"] ?? []).map { $0 + "\n" }.joined())</div>
            \(scripts)</body>
            </html>

            """
        if inline { page = inliningImages(page, directory: directory) }
        return page
    }

    /// The light rules of an `HTMLCodeStyle`'s stylesheet, or its dark ones, for a theme's
    /// background rather than the system's appearance.
    static func codeCSS(_ css: String, dark: Bool) -> String {
        let marker = "@media (prefers-color-scheme: dark) { "
        guard let range = css.range(of: marker) else { return css }
        if !dark { return String(css[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        let rest = css[range.upperBound...]
        guard let end = rest.range(of: " }", options: .backwards) else { return css }
        return String(rest[..<end.lowerBound])
    }

    static let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp", "bmp": "image/bmp", "avif": "image/avif"]

    /// `html` with the local images that `<img src>` and slide backgrounds name as `data:` URIs.
    /// Files that can't be read keep their link.
    static func inliningImages(_ html: String, directory: URL?) -> String {
        html.replacing(#/(<img\b[^>]*?\bsrc="|\bdata-background(?:-image)?=")([^"]*)(")/#) { match in
            let (whole, before, src, after) = match.output
            let path = String(src).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            guard let type = imageTypes[(path as NSString).pathExtension.lowercased()] else { return String(whole) }
            let url: URL?
            if path.hasPrefix("file://") {
                url = URL(string: path)
            } else if path.hasPrefix("/") {
                url = URL(fileURLWithPath: path)
            } else if path.hasPrefix("~/") {
                url = URL(fileURLWithPath: OrgPaths.expandingTilde(path))
            } else if !path.contains(":") {
                url = directory?.appendingPathComponent(path)
            } else {
                url = nil
            }
            guard let url, let data = try? Data(contentsOf: url) else { return String(whole) }
            return before + "data:\(type);base64,\(data.base64EncodedString())" + after
        }
    }
}

/// The slides of a deck as `HTMLRenderer` writes them: each heading down to `H` opens a
/// `<section>`, closing the one before, and a heading down to `hlevel` also opens a `<section>`
/// that holds it and the vertical slides after it, as `org-re-reveal-headline` writes them.
final class RevealSlides {
    let hlevel: Int
    let headlineLevels: Int
    let minLevel: Int
    /// `#+REVEAL_DEFAULT_FRAG_STYLE`, for `:frag t`.
    let fragmentStyle: String?
    private var slideOpen = false
    private var groupOpen = false
    /// The open slide's attributes but its id, for `#+REVEAL: split`.
    private var slideAttributes = ""
    /// The headings' ids that slides are named after, as `slide-<id>`.
    private(set) var headingIDs: [String] = []

    init(hlevel: Int, headlineLevels: Int, minLevel: Int, fragmentStyle: String?) {
        self.hlevel = hlevel
        self.headlineLevels = headlineLevels
        self.minLevel = minLevel
        self.fragmentStyle = fragmentStyle
    }

    /// ` key="value"` for each value given.
    func attributes(_ pairs: [(String, String?)]) -> String {
        pairs.compactMap { key, value in value.flatMap { $0.isEmpty ? nil : " \(key)=\"\(HTMLRenderer.escape($0))\"" } }.joined()
    }

    /// The section under `heading` as a slide, with its text, then the slides of its children;
    /// nil for a heading below `H`, which HTML export writes. `all` is false for an archived
    /// heading, which shows only its title.
    func section(_ node: SyntaxNode, heading: SyntaxNode, all: Bool, renderer: HTMLRenderer) -> String? {
        let stars = heading.tokens.first { $0.kind == .stars }?.text.count ?? 1
        let level = stars - minLevel + 1
        guard level <= headlineLevels else { return nil }
        var properties: [String: String] = [:]
        for drawer in node.children where drawer.kind == .propertyDrawer {
            for property in drawer.children where property.kind == .nodeProperty {
                if let m = property.text.trimmingCharacters(in: .whitespacesAndNewlines).firstMatch(of: /^:([^:\s]+):[ \t]*(.*)$/) { properties[m.1.uppercased()] = String(m.2) }
            }
        }
        var out = ""
        if slideOpen { out += "</section>\n" }
        if level <= hlevel {
            if groupOpen { out += "</section>\n" }
            out += "<section>\n"
            groupOpen = true
        }
        let headingHTML = renderer.heading(heading)
        let id = headingHTML.firstMatch(of: /id="([^"]*)"/).map { String($0.1) } ?? ""
        headingIDs.append(id.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&"))
        slideAttributes = attributes([
            ("class", properties["HTML_CONTAINER_CLASS"]),
            ("data-transition", properties["REVEAL_DATA_TRANSITION"]),
            ("data-state", properties["REVEAL_DATA_STATE"]),
            ("data-background", properties["REVEAL_BACKGROUND"]),
            ("data-background-size", properties["REVEAL_BACKGROUND_SIZE"]),
            ("data-background-position", properties["REVEAL_BACKGROUND_POSITION"]),
            ("data-background-repeat", properties["REVEAL_BACKGROUND_REPEAT"]),
            ("data-background-transition", properties["REVEAL_BACKGROUND_TRANS"]),
            ("data-background-opacity", properties["REVEAL_BACKGROUND_OPACITY"]),
            ("data-background-iframe", properties["REVEAL_BACKGROUND_IFRAME"]),
            ("data-background-video", properties["REVEAL_BACKGROUND_VIDEO"]),
        ]) + (properties["REVEAL_EXTRA_ATTR"].map { $0.isEmpty ? "" : " " + $0 } ?? "")
        out += "<section id=\"slide-\(id)\"\(slideAttributes)>\n" + headingHTML
        slideOpen = true
        if all {
            for child in node.children where child.kind != .heading { out += renderer.element(child) }
        }
        return out
    }

    /// Text before the first heading, on a slide of its own.
    func preamble(_ html: String) -> String {
        html.allSatisfy(\.isWhitespace) ? "" : "<section>\n\(html)</section>\n"
    }

    /// What closes the slides still open at the end.
    func close() -> String {
        defer { (slideOpen, groupOpen) = (false, false) }
        return (slideOpen ? "</section>\n" : "") + (groupOpen ? "</section>\n" : "")
    }

    /// `#+REVEAL_HTML: …` as written, `#+REVEAL: split` a new slide with the same attributes;
    /// other keywords nothing.
    func keyword(_ text: String) -> String {
        guard let m = text.trimmingCharacters(in: .whitespacesAndNewlines).firstMatch(of: /^#\+([A-Za-z_]+):[ \t]*(.*)$/) else { return "" }
        switch m.1.uppercased() {
        case "REVEAL_HTML": return String(m.2) + "\n"
        case "REVEAL" where m.2.lowercased().hasPrefix("split") && slideOpen: return "</section>\n<section\(slideAttributes)>\n"
        default: return ""
        }
    }

    /// `:frag` and `:frag_idx` from an `#+ATTR_REVEAL` line: their value, or the values of a
    /// parenthesized list.
    static func values(_ key: String, in attributes: String) -> [String]? {
        guard let m = attributes.firstMatch(of: try! Regex(":\(key)[ \\t]+(\\([^)]*\\)|\\S+)")) else { return nil }
        let value = String(m.output[1].substring ?? "")
        if value.hasPrefix("(") { return value.dropFirst().dropLast().split(whereSeparator: \.isWhitespace).map(String.init) }
        return [value]
    }

    /// The classes for a `:frag` style: `t` the default style, `none` none.
    func fragmentClass(_ style: String) -> String? {
        switch style {
        case "t": fragmentStyle.map { "fragment \($0)" } ?? "fragment"
        case "none", "nil": nil
        default: "fragment \(style)"
        }
    }

    /// `html`, an element's, as a fragment: its first tag gets the classes and index. In a
    /// list, a parenthesized `:frag` makes each item a fragment, the last style and index
    /// standing for items past the end of their lists.
    func fragment(_ html: String, attributes: String, list: Bool) -> String {
        guard let styles = Self.values("frag", in: attributes), !styles.isEmpty else { return html }
        let indexes = Self.values("frag_idx", in: attributes) ?? []
        let perItem = list && attributes.firstMatch(of: /:frag[ \t]+\(/) != nil
        guard perItem else { return Self.adding(fragmentClass(styles[0]), index: indexes.first, to: html, at: html.startIndex) }
        var out = html
        var depth = 0
        var item = 0
        var at = out.startIndex
        while let tag = out[at...].firstMatch(of: /<(\/?)(ul|ol|li)\b/) {
            if tag.output.1.isEmpty, tag.output.2 == "li", depth == 1 {
                let style = styles[min(item, styles.count - 1)]
                let index = indexes.isEmpty ? nil : indexes[min(item, indexes.count - 1)]
                let before = out.distance(from: out.startIndex, to: tag.range.lowerBound)
                out = Self.adding(fragmentClass(style), index: index, to: out, at: tag.range.lowerBound)
                at = out.index(out.startIndex, offsetBy: before + 3)
                item += 1
                continue
            }
            if tag.output.2 != "li" { depth += tag.output.1.isEmpty ? 1 : -1 }
            at = tag.range.upperBound
        }
        return out
    }

    /// `html` with the classes and `data-fragment-index` added to the tag at `position`.
    static func adding(_ classes: String?, index: String?, to html: String, at position: String.Index) -> String {
        guard classes != nil || (index != nil && index != "-") else { return html }
        guard let open = html[position...].firstMatch(of: /<([a-zA-Z0-9]+)([^>]*)>/) else { return html }
        var attributes = String(open.output.2)
        if let classes {
            if let existing = attributes.firstMatch(of: /\bclass="([^"]*)"/) {
                attributes.replaceSubrange(existing.range, with: "class=\"\(existing.output.1) \(classes)\"")
            } else {
                attributes += " class=\"\(classes)\""
            }
        }
        if let index, index != "-" { attributes += " data-fragment-index=\"\(HTMLRenderer.escape(index))\"" }
        var out = html
        out.replaceSubrange(open.range, with: "<\(open.output.1)\(attributes)>")
        return out
    }
}
