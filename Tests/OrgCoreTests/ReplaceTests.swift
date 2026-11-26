import Foundation
import Testing
@testable import OrgCore

/// Replace in Files' matching and case rules, and the structural renames of tags and TODO
/// keywords, against Emacs where Org has the behaviour.
struct ReplaceTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    func replaced(_ text: String, _ query: TextReplace, skipping: [Range<Int>] = []) throws -> String {
        ProposedChange.apply(try query.changes(in: text, skipping: skipping), to: text)
    }

    /// An Emacs Lisp string literal.
    static func lisp(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @Test func plainText() throws {
        let query = TextReplace(pattern: "a.b", replacement: "$1\\1")
        #expect(try replaced("a.b axb\n", query) == "$1\\1 axb\n")
    }

    @Test func regexpWithGroups() throws {
        let query = TextReplace(pattern: "(\\w+)@(\\w+)", replacement: "\\2 at $1 (\\&)", isRegexp: true, caseFold: false)
        #expect(try replaced("me@home\n", query) == "home at me (me@home)\n")
    }

    @Test func linesAnchor() throws {
        let query = TextReplace(pattern: "^- ", replacement: "+ ", isRegexp: true)
        #expect(try replaced("- a\n- b\nx - c\n", query) == "+ a\n+ b\nx - c\n")
    }

    @Test func caseRules() throws {
        // case-fold-search off: only the exact case matches, and nothing is casified.
        #expect(try replaced("foo Foo", TextReplace(pattern: "foo", replacement: "bar", caseFold: false)) == "bar Foo")
        // An upper-case letter in the pattern turns folding off.
        #expect(try replaced("foo Foo", TextReplace(pattern: "Foo", replacement: "bar")) == "foo bar")
        // case-replace off: matches fold, the replacement stays as written.
        #expect(try replaced("foo Foo FOO", TextReplace(pattern: "foo", replacement: "bar", caseReplace: false)) == "bar bar bar")
        // A letter after a backslash isn't upper case for folding.
        #expect(TextReplace(pattern: "\\Wfoo", replacement: "", isRegexp: true).foldsCase)
        #expect(!TextReplace(pattern: "\\WFoo", replacement: "", isRegexp: true).foldsCase)
    }

    @Test func invalidPatterns() {
        #expect(throws: TextReplace.InvalidPattern.empty) { try TextReplace(pattern: "", replacement: "x").regex() }
        #expect(throws: TextReplace.InvalidPattern.invalid) { try TextReplace(pattern: "(", replacement: "x", isRegexp: true).regex() }
    }

    @Test func changesDescribeTheirLines() throws {
        let changes = try TextReplace(pattern: "cat", replacement: "dog").changes(in: "a\nthe cat sat\non a cat\n")
        #expect(changes.map(\.line) == [2, 3])
        #expect(changes[0].lineText == "the cat sat")
        #expect(changes[0].changed == 4..<7)
        #expect(changes[1].replacement == "dog")
    }

    @Test func encryptedEntriesAreSkipped() throws {
        let text = """
        * Secrets :crypt:
        -----BEGIN PGP MESSAGE-----

        jA0ECQMCsecret
        -----END PGP MESSAGE-----
        * Open
        secret
        ** Child :crypt:
        -----BEGIN PGP MESSAGE-----
        secret
        -----END PGP MESSAGE-----
        * Not tagged
        -----BEGIN PGP MESSAGE-----
        secret
        -----END PGP MESSAGE-----

        """
        let ranges = EncryptedText.ranges(in: text)
        #expect(ranges.count == 2)
        let changes = try TextReplace(pattern: "secret", replacement: "x").changes(in: text, skipping: ranges)
        // The tagged heading's title isn't encrypted.
        #expect(changes.map(\.line) == [1, 7, 14])
        #expect(EncryptedText.isEncryptedFile("/a/notes.org.gpg"))
        #expect(!EncryptedText.isEncryptedFile("/a/notes.org"))
    }

    /// The same replacements through `perform-replace` with `case-fold-search` and
    /// `case-replace` on: (text, Emacs pattern, ICU pattern, replacement, regexp).
    static let replaceCases: [(String, String, String, String, Bool)] = [
        ("foo Foo FOO fOo\n", "foo", "foo", "bar", false),
        ("Foo foo\n", "Foo", "Foo", "bar", false),
        ("a A x\n", "a", "a", "bc", false),
        ("foo Foo FOO\n", "foo", "foo", "Bar baz", false),
        ("1foo 1Foo\n", "1foo", "1foo", "bar", false),
        ("Foo bar\nFoo Bar\n", "foo bar", "foo bar", "qux quux", false),
        ("foo-bar Foo-Bar FOO-BAR\n", "foo-\\(bar\\)", "foo-(bar)", "x-\\1", true),
        ("John Smith\njane doe\n", "\\([a-z]+\\) \\([a-z]+\\)", "([a-z]+) ([a-z]+)", "\\2, \\1", true),
        ("* TODO a\n* b\n", "^\\* ", "^\\* ", "- ", true),
        ("Émile émile ÉMILE\n", "émile", "émile", "zoé", false),
    ]

    @Test(.enabled(if: oracle)) func replaceMatchesEmacs() throws {
        for (text, emacsPattern, pattern, replacement, regexp) in Self.replaceCases {
            let form = "(progn (goto-char (point-min)) (let ((case-fold-search t) (case-replace t)) (perform-replace \(Self.lisp(emacsPattern)) \(Self.lisp(replacement)) nil \(regexp ? "t" : "nil") nil)) (list (buffer-string)))"
            let emacs = try EmacsOracle.evaluate(text, form)
            let ours = try replaced(text, TextReplace(pattern: pattern, replacement: replacement, isRegexp: regexp))
            #expect([ours] == emacs, "\(emacsPattern) -> \(replacement) in \(text)")
        }
    }

    // MARK: - Tags

    static let tagged = """
    #+TAGS: work(w) home { @office : work errand } urgent
    #+FILETAGS: :work:notes:
    * Plan                                                                 :work:
    ** TODO Call the boss                                           :work:urgent:
    * A heading whose title is long enough to push its tags past the tag column :work:
    * Unaligned :home:work:
    * See [[https://example.com][the site]]                               :work:
    * Coffee ☕ break :work:
    * Untagged
    Body text says work and :work: and is left alone.
    #+begin_example
    #+TAGS: work
    #+end_example

    """

    func renameTag(_ text: String, _ old: String, _ new: String) -> String {
        let tree = OrgParser.parse(text)
        return ProposedChange.apply(TagRename.changes(in: text, tree: tree, from: old, to: new, options: .org), to: text)
    }

    @Test func tagRenameChangesOnlyTags() {
        let renamed = renameTag(Self.tagged, "work", "office")
        #expect(renamed.contains("#+TAGS: office(w) home { @office : office errand } urgent\n"))
        #expect(renamed.contains("#+FILETAGS: :office:notes:\n"))
        #expect(renamed.contains("Body text says work and :work: and is left alone."))
        #expect(renamed.contains("#+begin_example\n#+TAGS: work\n"))
        #expect(renamed.components(separatedBy: ":work:").count == 2)
        // The list shows whole tag lists and words, not the realigning spaces.
        let changes = TagRename.changes(in: Self.tagged, tree: OrgParser.parse(Self.tagged), from: "work", to: "office", options: .org)
        let shown = changes.map { ($0.lineText as NSString).substring(with: NSRange($0.changed)) + " -> " + $0.replacement }
        #expect(shown[0] == "work(w) home { @office : work -> office(w) home { @office : office")
        #expect(shown[1] == ":work:notes: -> :office:notes:")
        #expect(shown[3] == ":work:urgent: -> :office:urgent:")
    }

    @Test func tagRenameMerges() {
        let renamed = renameTag(Self.tagged, "work", "home")
        #expect(renamed.contains("#+TAGS: home { @office : errand } urgent\n"))
        #expect(renamed.contains("#+FILETAGS: :home:notes:\n"))
        #expect(renamed.contains("* Unaligned") && renamed.contains(":home:\n* See"))
        #expect(TagRename.renamedTagAlist("a(a) b\nc", from: "a", to: "c") == "c(a) b\nc")
        #expect(TagRename.renamedTagAlist("a b c", from: "b", to: "a") == "a c")
        #expect(TagRename.renamedTagAlist("x y", from: "a", to: "b") == nil)
        #expect(TagRename.renamedFileTagsValue(" a b", from: "b", to: "a") == " a")
        #expect(TagRename.renamedFileTagsValue(" :b:a:", from: "b", to: "a") == " :a:")
    }

    /// Org's `org-set-tags` on every heading with the tag, as Rename Tag aligns them.
    @Test(.enabled(if: oracle)) func tagRenameAlignsAsOrg() throws {
        let headings = Self.tagged.components(separatedBy: "\n").filter { $0.hasPrefix("*") }.joined(separator: "\n") + "\n"
        for (old, new) in [("work", "office"), ("work", "home"), ("work", "a-very-long-tag-name".replacingOccurrences(of: "-", with: "_")), ("urgent", "u")] {
            let form = """
            (progn (setq org-tags-column -77) (font-lock-ensure)
              (org-map-entries (lambda () (let ((tags (org-get-tags nil t)))
                (when (member \(Self.lisp(old)) tags)
                  (org-set-tags (delete-dups (mapcar (lambda (tg) (if (equal tg \(Self.lisp(old))) \(Self.lisp(new)) tg)) tags)))))))
              (list (buffer-string)))
            """
            let emacs = try EmacsOracle.evaluate(headings, form)
            #expect([renameTag(headings, old, new)] == emacs, "\(old) -> \(new)")
        }
    }

    // MARK: - TODO keywords

    /// A heading line with its tags ending at column 77, as `org-tags-column` -77 puts them.
    static func aligned(_ title: String, _ tags: String) -> String {
        title + String(repeating: " ", count: max(1, 77 - title.count - tags.count)) + tags
    }

    static let keyworded = """
    #+TODO: TODO NEXT(n!) | DONE(d)
    #+TYP_TODO: Fred Sara | FINISHED
    \(aligned("* NEXT Call the boss", ":work:"))
    \(aligned("** NEXT A longer title so that the tags move", ":work:urgent:"))
    * TODO Write
    NEXT time, NEXT is body text.
    * DONE Filed
    \(aligned("* Sara Review", ":team:"))

    """

    func renameKeyword(_ text: String, _ old: String, _ new: String) -> String {
        let tree = OrgParser.parse(text)
        return ProposedChange.apply(KeywordRename.changes(in: text, tree: tree, from: old, to: new, headings: true, options: .org), to: text)
    }

    @Test func keywordRenameChangesOnlyKeywords() {
        let renamed = renameKeyword(Self.keyworded, "NEXT", "WAITING")
        #expect(renamed.contains("#+TODO: TODO WAITING(n!) | DONE(d)\n"))
        #expect(renamed.contains("NEXT time, NEXT is body text."))
        #expect(renamed.contains("* WAITING Call the boss"))
        #expect(OrgParser.parse(renamed).settings.todoKeywordNames.contains("WAITING"))
    }

    @Test func keywordRenameMergesAndRefuses() {
        let merged = renameKeyword(Self.keyworded, "NEXT", "TODO")
        #expect(merged.contains("#+TODO: TODO | DONE(d)\n"))
        #expect(merged.contains("* TODO Call the boss"))
        let settings = OrgParser.parse(Self.keyworded).settings
        #expect(KeywordRename.crossesStates(settings, from: "NEXT", to: "DONE"))
        #expect(KeywordRename.crossesStates(settings, from: "FINISHED", to: "Sara"))
        #expect(!KeywordRename.crossesStates(settings, from: "NEXT", to: "TODO"))
        #expect(!KeywordRename.crossesStates(settings, from: "NEXT", to: "LATER"))
        #expect(!KeywordRename.isValidName("A B") && !KeywordRename.isValidName("A(b)") && !KeywordRename.isValidName("|"))
        #expect(KeywordRename.renamedTodoKeywords("TODO NEXT | DONE\nA B", from: "NEXT", to: "WAIT") == "TODO WAIT | DONE\nA B")
    }

    @Test func keywordSources() {
        let tree = OrgParser.parse(Self.keyworded)
        #expect(KeywordRename.source(of: "NEXT", in: tree) == .file)
        #expect(KeywordRename.source(of: "LATER", in: tree) == .none)
        var defaults = OrgSettings.default.withTodoKeywords("TODO LATER | DONE")!
        #expect(KeywordRename.source(of: "LATER", in: OrgParser.parse("* LATER x\n", defaults: defaults)) == .defaults)
        defaults.setupKeywords = "#+TODO: TODO SOON | DONE\n"
        #expect(KeywordRename.source(of: "SOON", in: OrgParser.parse("* SOON x\n", defaults: defaults)) == .setupFile)
        // Without headings, only the keyword lines change.
        let lines = KeywordRename.changes(in: Self.keyworded, tree: tree, from: "NEXT", to: "WAITING", headings: false, options: .org)
        #expect(lines.map(\.line) == [1])
    }

    /// After a rename, Org reads the headings with the new keyword, and its tags stay where
    /// `org-align-tags` puts them.
    @Test(.enabled(if: oracle)) func keywordRenameParsesInOrg() throws {
        for (old, new) in [("NEXT", "WAITING"), ("NEXT", "N"), ("Sara", "Alexandra"), ("TODO", "NEXT")] {
            let renamed = renameKeyword(Self.keyworded, old, new)
            let form = """
            (progn (setq org-tags-column -77) (font-lock-ensure)
              (let ((states (org-map-entries (lambda () (or (org-get-todo-state) "")))))
                (org-align-tags t)
                (cons (buffer-string) states)))
            """
            let emacs = try EmacsOracle.evaluate(renamed, form)
            #expect(emacs.first == renamed, "\(old) -> \(new): alignment")
            let tree = OrgParser.parse(renamed)
            let ours = tree.root.descendants().filter { $0.kind == .heading }.map { $0.tokens.first { $0.kind == .todoKeyword }?.text ?? "" }
            #expect(Array(emacs.dropFirst()) == ours, "\(old) -> \(new): keywords")
            #expect(ours.contains(new))
        }
    }
}
