import Foundation
import Testing
@testable import OrgCore

/// The list that opens by itself (#139), fuzzy matching (#140), word completion (#141) and
/// completion from the index (#143).
struct CompletionListTests {
    func context(_ text: String, _ caret: Int? = nil, options: EditingOptions = .org) -> EditContext {
        let caret = caret ?? text.utf16.count
        return EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], options: options)
    }

    var fuzzy: EditingOptions {
        var options = EditingOptions.org
        options.completion.fuzzy = true
        return options
    }

    // MARK: - #139

    @Test func autoOpensOnlyWhenSetAndInInsertState() {
        let off = CompletionOptions()
        #expect(CompletionAuto.delay(off, modal: false, insertState: false, isOrg: true) == nil)
        #expect(CompletionAuto.delay(off, modal: true, insertState: true, isOrg: true) == nil)
        let on = CompletionOptions(auto: true, delay: 0.25, prefix: 3)
        #expect(CompletionAuto.delay(on, modal: false, insertState: false, isOrg: true) == 0.25)
        #expect(CompletionAuto.delay(on, modal: true, insertState: true, isOrg: true) == 0.25)
        #expect(CompletionAuto.delay(on, modal: true, insertState: false, isOrg: true) == nil)
        // Outside org files only words are offered.
        #expect(CompletionAuto.delay(on, modal: false, insertState: false, isOrg: false) == nil)
        #expect(CompletionAuto.delay(CompletionOptions(auto: true, words: true), modal: false, insertState: false, isOrg: false) == 0.4)
    }

    @Test func autoOpensOnceEnoughIsTyped() {
        let options = CompletionOptions(auto: true, prefix: 3)
        #expect(!CompletionAuto.opens(OrgCompletion.at(context("#+TI")), options))
        #expect(CompletionAuto.opens(OrgCompletion.at(context("#+TIT")), options))
        #expect(!CompletionAuto.opens(OrgCompletion.at(context("#+XYZQ")), options))
        #expect(!CompletionAuto.opens(nil, options))
        // An index query opens it before anything is found.
        #expect(CompletionAuto.opens(OrgCompletion.at(context("[[id:abc")), options))
    }

    // MARK: - #140

    @Test func fuzzyMatchesLettersInOrderBestFirst() {
        #expect(OrgCompletion.at(context("#+STARTUP: lgd"))?.candidates == [])
        let found = OrgCompletion.at(context("#+STARTUP: lgd", options: fuzzy))!.candidates
        #expect(found.first == "logdone" && found.contains("lognotedone") && found.contains("nologdone"))
        #expect(found.firstIndex(of: "logdone")! < found.firstIndex(of: "nologdone")!)
        // Word starts and runs rank first; the prefix match beats one inside a word.
        #expect(OrgCompletion.matching(["nofold", "fold", "fnadjust"], "fo", fuzzy: true) == ["fold", "nofold"])
        // Keywords in the case typed.
        #expect(OrgCompletion.at(context("#+ttl", options: fuzzy))!.candidates.allSatisfy { $0 == $0.lowercased() })
        #expect(OrgCompletion.at(context("#+ttl", options: fuzzy))!.candidates.contains("title: "))
        // Prefix matching stays as it was.
        #expect(OrgCompletion.at(context("#+STARTUP: in"))?.candidates == ["indent", "inlineimages"])
    }

    @Test func fuzzyMatchesSnippetTriggers() {
        var options = fuzzy
        options.snippets = [Snippet(trigger: "meeting", name: "Meeting", body: "x"), Snippet(trigger: "todo", name: "Todo", body: "y")]
        #expect(OrgCompletion.at(context("mtg", options: options))?.candidates == ["meeting"])
    }

    @Test func listKeysAndTheCommonPart() {
        var list = CompletionList(OrgCompletion.at(context("#+STARTUP: entities"))!)
        #expect(list.key(KeyChord("TAB")) == .common("entitiesp"))
        #expect(list.key(KeyChord("n", .control)) == .shown && list.selected == "entitiesplain")
        #expect(list.key(KeyChord("p", .control)) == .shown && list.selected == nil)
        #expect(list.key(KeyChord("p", .control)) == .shown && list.selected == "entitiespretty")
        #expect(list.key(KeyChord("RET")) == .insert("entitiespretty"))
        #expect(list.key(KeyChord("g", .control)) == .close)
        #expect(list.key(KeyChord("ESC")) == .closeAndPass)
        // The chosen candidate stays chosen when more arrive.
        list.update(OrgCompletion.at(context("#+STARTUP: e"))!)
        #expect(list.selected == "entitiespretty")
        // Fuzzy candidates that don't start alike don't shorten what's typed.
        let spread = OrgCompletion.at(context("#+STARTUP: nd", options: fuzzy))!
        var fuzzyList = CompletionList(spread)
        #expect(fuzzyList.key(KeyChord("TAB")) == .shown)
    }

    // MARK: - #141

    @Test func dabbrevSearchesBackThenForward() {
        let text = "fa fb\nf fc fd"
        let caret = 7
        #expect(DabbrevExpansion(context(text, caret))?.expansions == ["fb", "fa", "fc", "fd"])
        #expect(Dabbrev.completion(context(text, caret))?.candidates == ["fb", "fa", "fc", "fd"])
        // Other buffers after this one, from their start; each word once, ignoring case.
        let more = Dabbrev.completion(context("Foo\nf"), others: ["fun FOO fix"])!
        #expect(more.candidates == ["foo", "fun", "fix"] && more.range == 4..<5 && more.query == .words("f"))
        // Org's word characters.
        #expect(DabbrevExpansion(context("fo_x fo-y fo.z fo'w fo/v fo2\nfo"))?.expansions == ["fo2", "fo/v", "fo'w", "fo-y", "fo_x"])
        #expect(DabbrevExpansion(context("*bold*\nb"))?.expansions == [])
        #expect(DabbrevExpansion(context("x ")) == nil)
    }

    @Test func dabbrevCyclesAndRestores() {
        var expansion = DabbrevExpansion(context("help hello\nhe"))!
        #expect(expansion.advance() == (TextEdit(range: 11..<13, replacement: "hello"), false))
        #expect(expansion.advance() == (TextEdit(range: 11..<16, replacement: "help"), false))
        expansion.add(["helmet", "Hello"])
        #expect(expansion.advance() == (TextEdit(range: 11..<15, replacement: "helmet"), false))
        #expect(expansion.advance() == (TextEdit(range: 11..<17, replacement: "he"), true))
        #expect(expansion.failure == "No further dynamic expansion for `he' found")
    }

    @Test func dabbrevCase() {
        #expect(Dabbrev.substitute("Hello", for: "he", replacing: "he") == "hello")
        #expect(Dabbrev.substitute("hello", for: "HE", replacing: "HE") == "HELLO")
        #expect(Dabbrev.substitute("HeLp", for: "He", replacing: "He") == "HeLp")
        #expect(Dabbrev.substitute("hex", for: "He", replacing: "Hello") == "Hex")
        #expect(Dabbrev.substitute("fooBar", for: "foo", replacing: "foo") == "fooBar")
        #expect(Dabbrev.substitute("alpine", for: "Al", replacing: "Al") == "Alpine")
        #expect(Dabbrev.substitute("12ab", for: "12", replacing: "12") == "12ab")
    }

    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    /// `dabbrev-expand` repeated in a buffer alone: each expansion, then the message.
    static let dabbrevCases: [String] = [
        "fa fb\nf| fc fd", "Hello help\nhe|", "Hello HELP hex\nHE|", "Hello HeLp hex\nHe|", "fooBar\nfoo|", "alpha alpine\nAl|",
        "Foo foo FOO\nf|", "fo_x fo-y fo.z fo'w fo/v fo2\nfo|", "12ab 12cd\n12|", "*bold* =code= ~x~\nb|", "abc ab\nab|",
        "naïve naïf\nna|", "* Heading one\n:PROPERTIES:\n:CATEGORY: head\n:END:\nHe|", "The THEME theory\nth|", "x A Apple\nA|",
    ]

    @Test(.enabled(if: oracle && EmacsOracle.isAvailable))
    func dabbrevMatchesEmacs() throws {
        let form = """
            (progn (require 'dabbrev) (let ((dabbrev-check-other-buffers nil) (dabbrev-check-all-buffers nil) (start nil) (out nil) (done nil))
              (save-excursion (setq start (progn (skip-syntax-backward "w_") (point))))
              (setq last-command nil)
              (while (and (not done) (< (length out) 12))
                (condition-case e
                    (progn (setq this-command 'dabbrev-expand) (dabbrev-expand nil) (setq last-command 'dabbrev-expand)
                           (push (buffer-substring-no-properties start (point)) out))
                  (error (push (error-message-string e) out) (setq done t))))
              (erase-buffer)
              (insert (mapconcat #'identity (nreverse out) "\\n"))))
            """
        let cases = Self.dabbrevCases.map { marked -> (String, Int) in
            let caret = (marked as NSString).range(of: "|").location
            return (marked.replacingOccurrences(of: "|", with: ""), caret)
        }
        let results = try EmacsOracle.run(cases.map { EmacsOracle.Case(text: $0.0, point: EmacsOracle.point($0.1, in: $0.0) , form: form) })
        for ((text, caret), result) in zip(cases, results) {
            var expansion = DabbrevExpansion(context(text, caret))!
            var ours: [String] = []
            while true {
                let (edit, exhausted) = expansion.advance()
                if exhausted {
                    ours.append(expansion.failure)
                    break
                }
                ours.append(edit.replacement)
            }
            #expect(ours.joined(separator: "\n") == result.text, "\(text.debugDescription)")
        }
    }

    // MARK: - #143

    @Test func idLinksCompleteHeadingsFromTheBufferThenTheIndex() {
        var options = fuzzy
        options.filePath = "/notes/here.org"
        let text = "* Alpha\n:PROPERTIES:\n:ID: a1\n:END:\n* Beta\nSee [[id:al]]"
        let completion = OrgCompletion.at(context(text, text.utf16.count - 2, options: options))!
        #expect(completion.kind == .idLink && completion.typed == "al" && completion.query == .linkTargets)
        #expect(completion.candidates == ["Alpha"])
        #expect(completion.link == 46..<55)
        let other = CompletionItem(title: "All hands", id: nil, path: "/notes/other.org", start: 10, heading: true)
        let twin = CompletionItem(title: "Alpha", id: "a2", path: "/notes/other.org", start: 40, heading: true)
        let filled = OrgCompletion.filled(completion, with: CompletionResult(items: [other, twin]), fuzzy: true)
        #expect(Set(filled.candidates) == ["Alpha (here.org)", "Alpha (other.org)", "All hands"])
        #expect(filled.item("All hands") == other && filled.label("All hands") == "All hands  other.org")
        // A heading here without an ID gets one, and the link moves with the drawer.
        let beta = CompletionItem(title: "Beta", id: nil, path: "/notes/here.org", start: 35, heading: true)
        let edits = CompletionFlow.createID(beta, in: context(text, options: options), newID: "b1")!
        let link = CompletionFlow.linkEdit(completion, beta, id: "b1", after: edits)
        var result = text
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { result = edit.apply(to: result) }
        result = link.apply(to: result)
        #expect(result == "* Alpha\n:PROPERTIES:\n:ID: a1\n:END:\n* Beta\n:PROPERTIES:\n:ID:       b1\n:END:\nSee [[id:b1][Beta]]")
    }

    @Test func denoteLinksAskTheIndex() {
        let completion = OrgCompletion.at(context("[[denote:"))!
        #expect(completion.kind == .denoteLink && completion.candidates.isEmpty && completion.query == .denoteNotes)
        let note = CompletionItem(title: "Reading list", id: "20260101T090000", path: "/n/20260101T090000--reading-list.org", start: 0, heading: false)
        let filled = OrgCompletion.filled(completion, with: CompletionResult(items: [note]), fuzzy: false)
        #expect(filled.candidates == ["Reading list"] && filled.link(note, id: note.id!) == "[[denote:20260101T090000][Reading list]]")
    }

    @Test func propertyValuesFromTheBufferAllowedFirst() {
        let text = "#+PROPERTY: Status_ALL todo \"in progress\" done\n* A\n:PROPERTIES:\n:Status: waiting\n:END:\n* B\n:PROPERTIES:\n:Status: i\n:END:\n"
        let caret = (text as NSString).range(of: ":Status: i").location + 10
        let completion = OrgCompletion.at(context(text, caret))!
        #expect(completion.kind == .propertyValue && completion.query == .propertyValues("Status"))
        #expect(completion.candidates == ["in progress"])
        let all = OrgCompletion.at(context(text, caret - 1))!
        #expect(all.candidates == ["todo", "in progress", "done", "waiting"])
        let filled = OrgCompletion.filled(all, with: CompletionResult(strings: ["blocked", "done"]), fuzzy: false)
        #expect(filled.candidates == ["todo", "in progress", "done", "waiting", "blocked"])
        // Names still complete as before.
        #expect(OrgCompletion.at(context("* H\n:PROPERTIES:\n:A: 1\n:CU\n:END:\n", 26))?.kind == .property)
    }
}
