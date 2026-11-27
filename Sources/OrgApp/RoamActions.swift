import Foundation
import OrgCore
import OrgIndex

/// The `app.dailies.` and `app.node.` commands: org-roam's daily notes, and finding and
/// linking ID nodes, or with Denote set, denote-journal's entries and Denote's notes, with
/// the platform's questions and file opening.
@MainActor
public struct RoamActions {
    public var session: DocumentSession
    /// The sidebar folders, the first being `org-roam-directory` unless it's set.
    public var roots: () -> [String]
    /// Headings and files with IDs.
    public var nodes: () throws -> [IndexStore.Node]
    public var show: (String) -> Void
    public var ask: (Prompt, @escaping (String?) -> Void) -> Void
    /// Opens a file with the caret at an offset.
    public var open: (_ path: String, _ offset: Int) -> Void
    /// Puts a link at the caret, in place of the selection, which describes it; without one,
    /// the title does.
    public var insertLink: (_ link: String, _ title: String) -> Void
    /// The index reads new files.
    public var refresh: () -> Void
    /// In the Mac sandbox, asks for access to folders outside the sidebar's that new notes go
    /// in. False when one is still out of reach.
    public var reachFolders: ([String]) -> Bool = { _ in true }
    /// Shows the capture window for an org-roam capture. Without it, the first template is
    /// filed at once and its file opened there.
    public var capture: ((RoamCapture) -> Void)?
    /// org-roam's capture templates, from capture.toml.
    public var templates: (RoamTemplate.Set) -> (templates: [RoamTemplate], problems: [String]) = { RoamTemplate.load($0) }

    public init(
        session: DocumentSession, roots: @escaping () -> [String], nodes: @escaping () throws -> [IndexStore.Node], show: @escaping (String) -> Void,
        ask: @escaping (Prompt, @escaping (String?) -> Void) -> Void, open: @escaping (String, Int) -> Void,
        insertLink: @escaping (String, String) -> Void, refresh: @escaping () -> Void
    ) {
        self.session = session
        self.roots = roots
        self.nodes = nodes
        self.show = show
        self.ask = ask
        self.open = open
        self.insertLink = insertLink
        self.refresh = refresh
    }

    private var dailies: Dailies? { Dailies.configured(roots: roots()) }
    private var denote: Bool { OrgPreferences.usesDenote() }
    private var linkType: String { denote ? "denote:" : "id:" }

    /// A date prompt's answer, read by `org-read-date`. Without a time, the time of day stays
    /// now's, as `org-read-date` with `to-time` keeps it.
    nonisolated static func date(_ answer: String, now: Date = Date()) -> Date? {
        let read = ReadDate.read(answer, default: nil, now: now, calendar: .current)
        guard let chosen = Calendar.current.date(from: read.components(.current)) else { return nil }
        let time = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        return Calendar.current.date(bySettingHour: read.timeGiven ? read.hour : time.hour!, minute: read.timeGiven ? read.minute : time.minute!,
                                     second: read.timeGiven ? 0 : time.second!, of: chosen) ?? chosen
    }

    private func day(_ offset: Int, from now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
    }

    public func run(_ id: String) {
        switch id {
        case "app.dailies.today": goto(day(0))
        case "app.dailies.yesterday": goto(day(-1))
        case "app.dailies.tomorrow": goto(day(1))
        case "app.dailies.capture-today": capture(day(0))
        case "app.dailies.capture-yesterday": capture(day(-1))
        case "app.dailies.capture-tomorrow": capture(day(1))
        case "app.dailies.date", "app.dailies.capture-date":
            let goto = id == "app.dailies.date"
            ask(Prompt(key: "date", message: goto ? "Find daily-note: " : "Capture to daily-note: ", date: Prompt.DateRead(defaultDate: nil))) { answer in
                guard let answer, let date = Self.date(answer) else { return }
                if goto { self.goto(date) } else { capture(date) }
            }
        case "app.dailies.next", "app.dailies.previous":
            guard let dailies else { return show("No folder for daily notes") }
            guard let path = session.path else { return show("Not in a daily-note") }
            do {
                let note = try dailies.neighbor(of: path, by: id == "app.dailies.next" ? 1 : -1)
                open(note, 0)
            } catch {
                show("\(error)")
            }
        case "app.node.rename-from-front-matter":
            renameFromFrontMatter()
        case "app.node.rename":
            renameNote()
        case _ where id.hasPrefix("app.node.sequence-"):
            runSequence(String(id.dropFirst("app.node.sequence-".count)))
        case "app.node.rename-folder-from-front-matter":
            renameFolderFromFrontMatter()
        case "app.node.find":
            chooseNode("Node: ") { choice in
                switch choice {
                case .existing(let node, _): open(node.location.path, node.location.start)
                case .created(let path, let offset, _, _): open(path, offset)
                }
            }
        case "app.node.find-ref":
            findRef()
        case "app.node.silo-find", "app.node.silo-create":
            // denote-silo: a folder of `denote-silo-directories` in place of `denote-directory`.
            let silos = DenoteNote.silos(roots: roots())
            guard !silos.isEmpty else { return show("No folder for new notes") }
            ask(Prompt(key: "silo", message: "Select a silo: ", choices: silos.map(DenoteNote.abbreviated))) { answer in
                guard let answer, let silo = silos.first(where: { DenoteNote.abbreviated($0) == answer }) else { return }
                let opened: (NodeChoice) -> Void = { choice in
                    switch choice {
                    case .existing(let node, _): open(node.location.path, node.location.start)
                    case .created(let path, _, _, _): open(path, (session.text(of: path).map { ($0 as NSString).length }) ?? 0)
                    }
                }
                guard id == "app.node.silo-create" else { return chooseNode("Node: ", silo: silo, opened) }
                ask(Prompt(key: "title", message: "New file TITLE: ", requireMatch: false)) { title in
                    guard let title = title?.trimmingCharacters(in: .whitespaces) else { return }
                    do { createDenote(title, known: try nodes(), silo: silo, opened) } catch { show(error.localizedDescription) }
                }
            }
        case "app.node.insert":
            // An `id:` link is org syntax; only Denote's links go in its Markdown and text notes.
            if !denote, let path = session.path, !DocumentSession.isOrgPath(path) { return show("Not an org file") }
            chooseNode("Node: ") { choice in
                switch choice {
                case .existing(let node, let title): insertLink(linkType + node.id, title)
                case .created(_, _, let id, let title): insertLink(linkType + id, title)
                }
            }
        default:
            show("Unknown command \(id)")
        }
    }

    /// The daily-note templates: `[[roam-dailies-template]]`, or one from the
    /// `org-roam-dailies-…` settings; for a Denote journal, one for the day's entry.
    private func dailyTemplates(_ dailies: Dailies, _ day: Date) -> [RoamTemplate] {
        if dailies.journal != nil {
            return [RoamTemplate(key: "d", name: "default", kind: .entry, template: dailies.entry, file: dailies.path(for: day), head: dailies.newText(day, id: ""))]
        }
        let (templates, problems) = self.templates(.dailies)
        if let problem = problems.first { show(problem) }
        return templates
    }

    /// `org-roam-dailies-goto-*`: the day's file, made if missing. With templates aimed at
    /// different files, asks which.
    func goto(_ day: Date) {
        guard let dailies else { return show("No folder for daily notes") }
        guard reachFolders([dailies.directory]) else { return }
        let templates = dailyTemplates(dailies, day)
        func go(_ template: RoamTemplate) {
            var dailies = dailies
            if dailies.journal == nil {
                dailies.file = template.file
                dailies.head = template.head
            }
            do {
                let (path, created) = try dailies.ensure(day)
                if created { refresh() }
                open(path, (session.text(of: path).map { ($0 as NSString).length }) ?? 0)
            } catch {
                show("Can't make the daily note: \(error.localizedDescription)")
            }
        }
        guard Set(templates.map(\.file)).count > 1 else { return go(templates[0]) }
        chooseTemplate(templates) { go($0) }
    }

    /// `org-capture`'s template menu, for a command that files nothing.
    private func chooseTemplate(_ templates: [RoamTemplate], _ then: @escaping (RoamTemplate) -> Void) {
        let labels = templates.map { "[\($0.key)] \($0.name)" }
        ask(Prompt(key: "template", message: "Template: ", choices: labels)) { answer in
            guard let answer, let index = labels.firstIndex(of: answer) else { return }
            then(templates[index])
        }
    }

    /// `org-roam-dailies-capture-*`: the capture window with the daily-note templates; the
    /// entry goes at the end of the day's file, made with its head when it's new.
    func capture(_ day: Date) {
        guard let dailies else { return show("No folder for daily notes") }
        guard reachFolders([dailies.directory]) else { return }
        start(RoamCapture(dailyTemplates(dailies, day), title: "", directory: dailies.directory, now: day, ids: dailies.journal == nil,
                          session: session, refresh: refresh) { _, _, _ in })
    }

    /// Shows the capture window, or without one, files the first template at once and opens
    /// what it filed.
    func start(_ roam: RoamCapture) {
        if let capture { return capture(roam) }
        switch roam.fileFirst() {
        case .success(let entry): open(entry.path, entry.offset)
        case .failure(let error): show(error.message)
        }
    }

    enum NodeChoice {
        /// A node, by the title or alias chosen.
        case existing(IndexStore.Node, title: String)
        /// A new node, with where its text went.
        case created(path: String, offset: Int, id: String, title: String)
    }

    /// `org-roam-node-read--completions`: a candidate for each node's title and each of its
    /// aliases, with its file's name when names repeat, and its tags after it as Doom's
    /// `org-roam-node-display-template` shows them.
    nonisolated static func candidates(_ nodes: [IndexStore.Node]) -> [(label: String, node: IndexStore.Node, title: String)] {
        let names = nodes.flatMap { node in ([node.title] + node.aliases).map { (node: node, name: $0) } }
        let counts = Dictionary(names.map { ($0.name, 1) }, uniquingKeysWith: +)
        return names.map { node, name in
            var label = counts[name, default: 0] > 1 ? "\(name) (\((node.location.path as NSString).lastPathComponent))" : name
            if !node.tags.isEmpty { label += "  " + node.tags.map { "#" + $0 }.joined(separator: " ") }
            return (label, node, name)
        }
    }

    /// `org-roam-node-read`: a node by its title or an alias. A title no node has goes to the
    /// capture window with `[[roam-template]]`'s templates, as `org-roam-capture-` does, and
    /// once filed makes the node; with Denote, `denote` asks for its keywords and makes the note.
    private func chooseNode(_ message: String, silo: String? = nil, _ then: @escaping (NodeChoice) -> Void) {
        let known: [IndexStore.Node]
        do { known = try nodes() } catch { return show(error.localizedDescription) }
        let all = silo.map { silo in known.filter { $0.location.path.hasPrefix(silo.hasSuffix("/") ? silo : silo + "/") } } ?? known
        let candidates = Self.candidates(all)
        ask(Prompt(key: "node", message: message, choices: candidates.map(\.label), requireMatch: false)) { answer in
            guard let answer else { return }
            if let chosen = candidates.first(where: { $0.label == answer }) ?? candidates.first(where: { $0.title == answer }) {
                return then(.existing(chosen.node, title: chosen.title))
            }
            let title = answer.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            if denote || silo != nil { return createDenote(title, known: all, silo: silo, then) }
            guard let folder = RoamNode.directory(roots: roots()) else { return show("No folder for new nodes") }
            guard reachFolders([folder]) else { return }
            let (templates, problems) = self.templates(.node)
            if let problem = problems.first { show(problem) }
            start(RoamCapture(templates, title: title, directory: folder, session: session, refresh: refresh) { path, offset, id in
                then(.created(path: path, offset: offset, id: id, title: title))
            })
        }
    }

    /// `org-roam-ref-find`: a node by one of its `ROAM_REFS`, shown with its title.
    private func findRef() {
        let known: [IndexStore.Node]
        do { known = try nodes() } catch { return show(error.localizedDescription) }
        let refs = known.flatMap { node in node.refs.map { (label: "\($0)  \(node.title)", node: node) } }
        guard !refs.isEmpty else { return show("No node has refs") }
        ask(Prompt(key: "ref", message: "Ref: ", choices: refs.map(\.label))) { answer in
            guard let answer, let chosen = refs.first(where: { $0.label == answer }) else { return }
            open(chosen.node.location.path, chosen.node.location.start)
        }
    }

    /// org-roam-protocol's `roam-ref`: the node with the ref, else the capture window with
    /// `[[roam-ref-template]]`'s templates (only the one keyed `template` when given) for a new
    /// node with the ref in its `ROAM_REFS`; and `roam-node`: the node with the ID.
    public func follow(_ request: OrgProtocol.Request) {
        let known: [IndexStore.Node]
        do { known = try nodes() } catch { return show(error.localizedDescription) }
        switch request {
        case .roamNode(let id):
            guard let node = known.first(where: { $0.id == id }) else { return show("No node has the ID \(id)") }
            open(node.location.path, node.location.start)
        case .roamRef(let ref, let title, let body, let key):
            if let node = known.first(where: { $0.refs.contains(ref) }) { return open(node.location.path, node.location.start) }
            guard let folder = RoamNode.directory(roots: roots()) else { return show("No folder for new nodes") }
            guard reachFolders([folder]) else { return }
            let (all, problems) = self.templates(.ref)
            if let problem = problems.first { show(problem) }
            let templates = key.map { key in all.filter { $0.key == key } } ?? all
            guard !templates.isEmpty else { return show("No roam-ref template \"\(key ?? "")\"") }
            let quoted = ref.contains(where: \.isWhitespace) ? "\"" + ref.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : ref
            start(RoamCapture(templates, title: title ?? ref, directory: folder, fields: ["ref": ref, "body": body ?? ""], properties: [("ROAM_REFS", quoted)],
                              session: session, refresh: refresh) { path, offset, _ in open(path, offset) })
        default:
            break
        }
    }

    /// What a new Denote note's questions give.
    struct DenoteAnswers {
        var keywords: [String] = []
        var folder: String?
        var date: Date?
        var template = ""
        var signature = ""
    }

    /// `denote`: after the title, the questions `denote-prompts` lists, in its order, then the
    /// note in `denote-directory` or the folder chosen under it.
    /// In a silo, its folder takes the place of `denote-directory`.
    /// With `signature`, as `denote-use-signature` sets it: that signature, not asked for.
    func createDenote(_ title: String, known: [IndexStore.Node], silo: String? = nil, signature: String? = nil, _ then: @escaping (NodeChoice) -> Void) {
        let folders = silo.map { [$0] } ?? DenoteNote.directories(roots: roots())
        guard !folders.isEmpty else { return show("No folder for new notes") }
        var answers = DenoteAnswers()
        if let signature { answers.signature = signature }
        createDenote(title, roots: folders, prompts: OrgPreferences.denotePrompts().filter { signature == nil || $0 != "signature" },
                     templates: UserConfig.denoteTemplates(.standard), keywords: Denote.keywords(known.flatMap { Denote.name(ofFile: $0.location.path).keywords }),
                     answers: answers, then)
    }

    /// The note goes in the first of `roots`, or the folder the `subdirectory` question picks
    /// among them and their folders.
    func createDenote(
        _ title: String, roots: [String], prompts: [String], templates: [(key: String, text: String)], keywords: [String],
        answers: DenoteAnswers = DenoteAnswers(), _ then: @escaping (NodeChoice) -> Void
    ) {
        let root = roots[0]
        func next(_ answers: DenoteAnswers) {
            createDenote(title, roots: roots, prompts: Array(prompts.dropFirst()), templates: templates, keywords: keywords, answers: answers, then)
        }
        var answers = answers
        switch prompts.first {
        case nil:
            guard reachFolders([answers.folder ?? root]) else { return }
            do {
                let note = try DenoteNote.create(title: title, keywords: answers.keywords, in: answers.folder ?? root, roots: roots,
                                                 now: answers.date ?? Date(), signature: answers.signature, template: answers.template,
                                                 type: OrgPreferences.denoteFileType())
                refresh()
                show("Created \((note.path as NSString).lastPathComponent)")
                then(.created(path: note.path, offset: (session.text(of: note.path).map { ($0 as NSString).length }) ?? 0, id: note.id, title: title))
            } catch {
                show("Can't make the note: \(error)")
            }
        case "keywords":
            // Separated by commas or spaces; the keywords already in file names are offered.
            ask(Prompt(key: "keywords", message: "New file KEYWORDS: ", choices: keywords, requireMatch: false)) { answer in
                guard let answer else { return }
                answers.keywords = answer.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
                next(answers)
            }
        case "subdirectory":
            let folders = DenoteNote.folderChoices(roots)
            guard folders.count > 1 else { return next(answers) }
            ask(Prompt(key: "subdirectory", message: "Select SUBDIRECTORY: ", choices: folders.map(\.label))) { answer in
                guard let answer else { return }
                answers.folder = folders.first { $0.label == answer }?.path ?? root
                next(answers)
            }
        case "date":
            ask(Prompt(key: "date", message: "DATE and TIME for note: ", date: Prompt.DateRead(defaultDate: nil))) { answer in
                guard let answer else { return }
                answers.date = Self.date(answer)
                next(answers)
            }
        case "template":
            guard !templates.isEmpty else { return next(answers) }
            ask(Prompt(key: "template", message: "Select TEMPLATE key: ", choices: templates.map(\.key))) { answer in
                guard let answer else { return }
                answers.template = templates.first { $0.key == answer }?.text ?? ""
                next(answers)
            }
        case "signature":
            ask(Prompt(key: "signature", message: "New file SIGNATURE: ", requireMatch: false)) { answer in
                guard let answer else { return }
                answers.signature = answer
                next(answers)
            }
        default:
            // The title is asked first anyway; Org is the only file type; the rest have no equal.
            next(answers)
        }
    }

    /// `denote-rename-file-using-front-matter`: the open file renamed from its title,
    /// keywords and signature, keeping its identifier, and its front matter rewritten from them.
    func renameFromFrontMatter() {
        guard let path = session.path else { return show("No file is open") }
        guard let text = session.text(of: path) else { return show("Can't read \((path as NSString).lastPathComponent)") }
        guard let (target, rewritten) = Denote.renamed(path, text: text) else { return show("Not a Denote note: no front matter or identifier") }
        guard target != path || rewritten != text else { return show("Nothing to rename") }
        if rewritten != text, case .failed(let message) = session.perform(ReplaceText(old: text, new: rewritten), path: path, at: 0, expect: nil) { return show(message) }
        guard target != path else { return show("Front matter rewritten") }
        rename(path, to: target)
    }

    /// Saves `path`, moves it to `target` and opens it there.
    func rename(_ path: String, to target: String) {
        guard !FileManager.default.fileExists(atPath: target) else { return show("\((target as NSString).lastPathComponent) is already there") }
        do {
            try move(path, to: target)
            refresh()
            open(target, 0)
            show("Renamed to \((target as NSString).lastPathComponent)")
        } catch {
            show("Can't rename: \(error)")
        }
    }

    /// Moves a file, saving it first and closing it when it's open.
    func move(_ path: String, to target: String) throws {
        if session.openPaths.contains(path) {
            guard session.save(path) else { throw Dailies.Failure("Can't save \((path as NSString).lastPathComponent)") }
        }
        try FileManager.default.moveItem(atPath: path, toPath: target)
        if session.openPaths.contains(path) { session.kill(path) }
    }

    /// `denote-rename-file`: the open file's title, keywords, signature and date, as
    /// `denote-prompts` asks for them, each starting with the current value, then the file
    /// renamed in its folder and its front matter rewritten. A file without an identifier
    /// gets one from its modification time; one without front matter gets it at the top.
    func renameNote() {
        guard let path = session.path else { return show("No file is open") }
        guard let text = session.text(of: path) else { return show("Can't read \((path as NSString).lastPathComponent)") }
        let name = Denote.name(ofFile: path), type = Denote.FileType(path: path, text: text) ?? .org, front = Denote.frontMatter(of: text, type: type)
        var title = front.title ?? name.title?.replacingOccurrences(of: "-", with: " ") ?? ""
        var keywords = front.keywords ?? name.keywords
        var signature = name.signature ?? front.signature ?? ""
        var date: Date?
        let file = (path as NSString).lastPathComponent
        func ask(_ prompts: ArraySlice<String>) {
            switch prompts.first {
            case nil: finish()
            case "title":
                self.ask(Prompt(key: "title", message: "Rename \(file) with TITLE (empty to remove): ", initial: title, requireMatch: false)) { answer in
                    guard let answer else { return }
                    title = answer
                    ask(prompts.dropFirst())
                }
            case "keywords":
                self.ask(Prompt(key: "keywords", message: "Rename \(file) with KEYWORDS (empty to remove): ", initial: keywords.joined(separator: ","), requireMatch: false)) { answer in
                    guard let answer else { return }
                    keywords = answer.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
                    ask(prompts.dropFirst())
                }
            case "signature":
                self.ask(Prompt(key: "signature", message: "Rename \(file) with SIGNATURE (empty to remove): ", initial: signature, requireMatch: false)) { answer in
                    guard let answer else { return }
                    signature = answer
                    ask(prompts.dropFirst())
                }
            case "date":
                self.ask(Prompt(key: "date", message: "Rename \(file) with DATE: ", date: Prompt.DateRead(defaultDate: Denote.date(of: text, type: type)))) { answer in
                    guard let answer else { return }
                    date = answer.isEmpty ? nil : Self.date(answer)
                    ask(prompts.dropFirst())
                }
            default: ask(prompts.dropFirst())
            }
        }
        func finish() {
            let (target, rewritten) = DenoteNote.renaming(path, text: text, title: title, keywords: keywords, signature: signature, date: date,
                                                          roots: DenoteNote.directories(roots: roots()), preferred: OrgPreferences.denoteFileType())
            guard target != path || rewritten != text else { return show("Nothing to rename") }
            if rewritten != text, case .failed(let message) = session.perform(ReplaceText(old: text, new: rewritten), path: path, at: 0, expect: nil) { return show(message) }
            guard target != path else { return show("Front matter rewritten") }
            rename(path, to: target)
        }
        ask(ArraySlice(OrgPreferences.denotePrompts()))
    }

    /// `denote-dired-rename-marked-files-using-front-matter`, with every Denote note in a
    /// folder of `denote-directory` marked: each renamed from its front matter, which is
    /// rewritten from the values read.
    func renameFolderFromFrontMatter() {
        let folders = DenoteNote.folderChoices(DenoteNote.directories(roots: roots()))
        guard !folders.isEmpty else { return show("No folder for notes") }
        ask(Prompt(key: "folder", message: "Rename notes in: ", choices: folders.map(\.label))) { answer in
            guard let answer, let folder = folders.first(where: { $0.label == answer })?.path else { return }
            let shown = session.path
            var renamed = 0, problems: [String] = []
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() where Denote.identifier(ofFile: name) != nil {
                let path = (folder as NSString).appendingPathComponent(name)
                guard let text = session.text(of: path) ?? (try? String(contentsOfFile: path, encoding: .utf8)),
                      let (target, rewritten) = Denote.renamed(path, text: text), target != path || rewritten != text else { continue }
                guard target == path || !FileManager.default.fileExists(atPath: target) else { problems.append("\((target as NSString).lastPathComponent) is already there"); continue }
                do {
                    if rewritten != text {
                        if session.openPaths.contains(path) {
                            if case .failed(let message) = session.perform(ReplaceText(old: text, new: rewritten), path: path, at: 0, expect: nil) { throw Dailies.Failure(message) }
                        } else {
                            try rewritten.write(toFile: path, atomically: true, encoding: .utf8)
                        }
                    }
                    guard target != path else { continue }
                    try move(path, to: target)
                    renamed += 1
                    if shown == path { open(target, 0) }
                } catch {
                    problems.append("\(error)")
                }
            }
            refresh()
            show(([renamed == 1 ? "Renamed 1 note" : "Renamed \(renamed) notes"] + problems).joined(separator: "; "))
        }
    }
}
