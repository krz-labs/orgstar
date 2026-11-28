import Foundation
import Testing
@testable import OrgCore

/// org-ql queries, checked against org-ql's documented semantics and its source
/// (org-ql.el, org-ql-search.el): org-ql isn't installed for an Emacs oracle. The heading
/// links of the dynamic block come from Org itself and are checked against Emacs.
struct OrgQLTests {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-11-28 12:00 UTC, a Saturday.
    static let now = Date(timeIntervalSince1970: 1_795_867_200)
    static let today = Days.absolute(now, calendar: utc)

    static let text = """
    #+TODO: TODO NEXT WAIT | DONE CANCELLED
    #+FILETAGS: :file:
    * TODO [#A] Pay rent :home:
    DEADLINE: <2026-11-30 Mon>
    * NEXT Write report :work:
    SCHEDULED: <2026-11-28 Sat 10:00>
    :PROPERTIES:
    :CLIENT: Acme
    :STYLE: habit
    :END:
    ** WAIT Call Bob :phone:
    DEADLINE: <2026-12-20 Sun -30d>
    Met him on [2026-11-20 Fri].
    *** Deep [#C] note
    * DONE Paid the bills
    CLOSED: [2026-11-27 Fri 18:00]
    * Meeting <2026-12-05 Sat 14:00>
    * CANCELLED [#B] Old plan :work:
    SCHEDULED: <2026-11-01 Sun>
    * Notes on Rent
    """

    static let source = AgendaSource(path: "/notes/inbox.org", text: text)

    /// The titles of the headings `query` matches.
    static func titles(_ query: String, sort: [String] = [], sources: [AgendaSource] = [source]) throws -> [String] {
        let parsed = try OrgQL.parse(query)
        return OrgQL.select(sources, query: parsed, sort: sort, context: OrgQL.Context(today: today)).map { $0.source.headings[$0.index].title }
    }

    // MARK: - Reading

    @Test func plainQueriesReadAsOrgQLReadsThem() throws {
        let cases: [(String, OrgQL.Query)] = [
            ("todo:", .todo([])),
            ("todo:NEXT,WAIT", .todo(["NEXT", "WAIT"])),
            ("todo:NEXT tags:work", .and([.todo(["NEXT"]), .tags(.both, ["work"])])),
            ("!todo:DONE", .not(.todo(["DONE"]))),
            ("  done:  habit: ", .and([.done, .habit])),
            ("tags-all:a,b", .and([.tags(.both, ["a"]), .tags(.both, ["b"])])),
            ("tags&:a ltags:b itags:c", .and([.and([.tags(.both, ["a"])]), .tags(.local, ["b"]), .tags(.inherited, ["c"])])),
            ("priority:A,B", .priority(nil, ["A", "B"])),
            ("deadline:to=7", .planning(.deadline, OrgQL.DateRange(to: .days(7)))),
            ("deadline:auto", .deadlineWarning),
            ("scheduled:7", .planning(.scheduled, OrgQL.DateRange(to: .days(7)))),
            ("ts:on=today", .ts(.both, OrgQL.DateRange(from: .days(0), to: .days(0)))),
            ("ts-a:from=-7,to=2026-12-01", .ts(.active, OrgQL.DateRange(from: .days(-7), to: .date(day: Days.absolute(year: 2026, month: 12, day: 1), seconds: nil)))),
            ("ts-i:from=\"2026-11-01 10:30\"", .ts(.inactive, OrgQL.DateRange(from: .date(day: Days.absolute(year: 2026, month: 11, day: 1), seconds: 37800)))),
            ("heading:\"pay rent\",report", .heading(["pay rent", "report"])),
            ("h:rent", .heading(["rent"])),
            ("property:CLIENT", .property("CLIENT", value: nil, inherit: nil)),
            ("property:CLIENT,Acme", .property("CLIENT", value: "Acme", inherit: nil)),
            ("level:2", .level(2, 2)),
            ("level:3,1", .level(1, 3)),
            ("level:<,3", .level(Int.min, 2)),
            ("path:inbox", .path(["inbox"])),
            ("todo: \"\" tags:x", .and([.todo([]), .tags(.both, ["x"])])),
        ]
        for (text, expected) in cases {
            #expect(try OrgQL.parse(text) == expected, "\(text)")
        }
    }

    @Test func sexpQueriesReadAsOrgQLReadsThem() throws {
        let cases: [(String, OrgQL.Query)] = [
            ("(todo)", .todo([])),
            ("(and (todo \"NEXT\") (tags \"work\") (deadline :to 7))",
             .and([.todo(["NEXT"]), .tags(.both, ["work"]), .planning(.deadline, OrgQL.DateRange(to: .days(7)))])),
            ("(or (done) (not (habit)))", .or([.done, .not(.habit)])),
            ("(priority '>= \"B\")", .priority(.greaterOrEqual, ["B"])),
            ("(priority > \"B\")", .priority(.greater, ["B"])),
            ("(deadline auto)", .deadlineWarning),
            ("(deadline 3)", .planning(.deadline, OrgQL.DateRange(to: .days(3)))),
            ("(scheduled :from -2 :to today)", .planning(.scheduled, OrgQL.DateRange(from: .days(-2), to: .days(0)))),
            ("(ts :type inactive :on \"2026-11-20\")",
             .ts(.inactive, OrgQL.DateRange(from: .date(day: Days.absolute(year: 2026, month: 11, day: 20), seconds: nil), to: .date(day: Days.absolute(year: 2026, month: 11, day: 20), seconds: nil)))),
            ("(ts :with-time t)", .ts(.both, OrgQL.DateRange(withTime: true))),
            ("(property \"CLIENT\" \"Acme\" :inherit t)", .property("CLIENT", value: "Acme", inherit: true)),
            ("(property :CLIENT)", .property("CLIENT", value: nil, inherit: nil)),
            ("(level '> 1)", .level(2, Int.max)),
            ("(level 1 2)", .level(1, 2)),
            ("(heading \"rent\" \"pay\")", .heading(["rent", "pay"])),
            ("(and)", .and([])),
        ]
        for (text, expected) in cases {
            #expect(try OrgQL.parse(text) == expected, "\(text)")
        }
    }

    @Test func badQueriesSayWhatIsWrong() {
        let cases: [(String, String)] = [
            ("(category \"work\")", "org-ql's category predicate isn't supported"),
            ("regexp:foo", "org-ql's regexp predicate isn't supported"),
            ("todo:NEXT rent", "Words without a predicate search with org-ql's rifle predicate, which isn't supported: rent. Use heading:rent to search headings."),
            ("(frobnicate)", "Unknown predicate frobnicate"),
            ("(todo NEXT)", "todo takes strings, not NEXT"),
            ("(done \"x\")", "done takes no arguments"),
            ("(not (todo) (done))", "not takes one query"),
            ("(deadline :until 3)", "deadline takes :from, :to, :on and :with-time, not :until"),
            ("ts:from=soon", "ts: can't read \"soon\" as a date or a number of days"),
            ("(ts :type maybe)", "ts: :type takes active, inactive or both"),
            ("(level \"x\")", "level takes a number, two numbers, or a comparator and a number"),
            ("(todo", "Can't read the query: line 1: unclosed list"),
            ("(todo) (done)", "Text after the query: (done)"),
            ("", "The query is empty"),
            ("path:\"[\"", "Invalid regexp ["),
        ]
        for (text, message) in cases {
            #expect(throws: OrgQL.QueryError(message), "\(text)") { try OrgQL.parse(text) }
        }
        #expect(throws: OrgQL.QueryError("Unknown sort key size")) { try OrgQL.sortKeys(["date", "size"]) }
    }

    // MARK: - Predicates

    @Test func todoAndDone() throws {
        #expect(try Self.titles("(todo)") == ["Pay rent", "Write report", "Call Bob"])
        #expect(try Self.titles("todo:WAIT,TODO") == ["Pay rent", "Call Bob"])
        #expect(try Self.titles("todo:CANCELLED") == ["Old plan"])
        #expect(try Self.titles("todo:next") == [])
        #expect(try Self.titles("done:") == ["Paid the bills", "Old plan"])
    }

    @Test func tagsLocalAndInherited() throws {
        #expect(try Self.titles("tags:work") == ["Write report", "Call Bob", "Deep [#C] note", "Old plan"])
        #expect(try Self.titles("tags-local:work") == ["Write report", "Old plan"])
        #expect(try Self.titles("tags-inherited:work") == ["Call Bob", "Deep [#C] note"])
        #expect(try Self.titles("tags-all:work,phone") == ["Call Bob", "Deep [#C] note"])
        #expect(try Self.titles("tags:phone,home") == ["Pay rent", "Call Bob", "Deep [#C] note"])
        #expect(try Self.titles("tags:Work") == [])
        // File tags are inherited by every heading.
        #expect(try Self.titles("tags-local:") == ["Pay rent", "Write report", "Call Bob", "Old plan"])
        #expect(try Self.titles("tags:").count == 8)
        #expect(try Self.titles("tags-inherited:file").count == 8)
    }

    @Test func priorities() throws {
        #expect(try Self.titles("priority:") == ["Pay rent", "Old plan"])
        #expect(try Self.titles("priority:B,C") == ["Old plan"])
        #expect(try Self.titles("(priority '> \"B\")") == ["Pay rent"])
        #expect(try Self.titles("(priority '>= \"B\")") == ["Pay rent", "Old plan"])
        #expect(try Self.titles("(priority '< \"A\")") == ["Old plan"])
    }

    @Test func deadlinesAndScheduled() throws {
        #expect(try Self.titles("deadline:") == ["Pay rent", "Call Bob"])
        #expect(try Self.titles("deadline:to=2") == ["Pay rent"])
        #expect(try Self.titles("deadline:to=1") == [])
        #expect(try Self.titles("(deadline :from 3)") == ["Call Bob"])
        #expect(try Self.titles("(deadline :on \"2026-11-30\")") == ["Pay rent"])
        // Call Bob warns 30 days ahead; Pay rent is within the default 14.
        #expect(try Self.titles("deadline:auto") == ["Pay rent", "Call Bob"])
        #expect(OrgQL.select([Self.source], query: .deadlineWarning, context: OrgQL.Context(today: Self.today, deadlineWarningDays: 1)).count == 1)
        #expect(try Self.titles("scheduled:on=today") == ["Write report"])
        #expect(try Self.titles("(scheduled :to -1)") == ["Old plan"])
        #expect(try Self.titles("(scheduled :from \"2026-11-28 10:01\")") == [])
        #expect(try Self.titles("(scheduled :to \"2026-11-28 10:00\")") == ["Write report", "Old plan"])
        #expect(try Self.titles("(scheduled :with-time t)") == ["Write report"])
        #expect(try Self.titles("(scheduled :with-time nil)") == ["Old plan"])
    }

    @Test func timestampsInTheEntry() throws {
        // Every timestamp from the heading line to the next heading, planning lines included.
        #expect(try Self.titles("ts:") == ["Pay rent", "Write report", "Call Bob", "Paid the bills", "Meeting", "Old plan"].map { $0 == "Meeting" ? "Meeting <2026-12-05 Sat 14:00>" : $0 })
        #expect(try Self.titles("ts-i:") == ["Call Bob", "Paid the bills"])
        #expect(try Self.titles("ts-a:from=5") == ["Call Bob", "Meeting <2026-12-05 Sat 14:00>"])
        #expect(try Self.titles("ts:from=-8,to=-1") == ["Call Bob", "Paid the bills"])
        #expect(try Self.titles("(ts :type inactive :on -1)") == ["Paid the bills"])
        #expect(try Self.titles("(ts :type active :on -1)") == [])
    }

    @Test func closedAndClocked() throws {
        #expect(try OrgQL.parse("closed:from=-7") == .planning(.closed, OrgQL.DateRange(from: .days(-7))))
        #expect(try OrgQL.parse("(clocked :on today)") == .clocked(OrgQL.DateRange(from: .days(0), to: .days(0))))
        #expect(throws: OrgQL.QueryError("closed takes :from, :to, :on and :with-time, not 7")) { try OrgQL.parse("(closed 7)") }
        #expect(try Self.titles("closed:") == ["Paid the bills"])
        #expect(try Self.titles("(closed :on -1)") == ["Paid the bills"])
        #expect(try Self.titles("(closed :to -2)") == [])
        #expect(try Self.titles("(closed :from \"2026-11-27 18:01\")") == [])

        let clocks = AgendaSource(path: "/c.org", text: """
            * Overnight
            :LOGBOOK:
            CLOCK: [2026-11-20 Fri 23:00]--[2026-11-21 Sat 01:00] =>  2:00
            :END:
            * Running
            CLOCK: [2026-11-28 Sat 08:00]
            * Child clocks aren't the parent's
            ** Child
            CLOCK: [2026-11-25 Wed 10:00]--[2026-11-25 Wed 11:00] =>  1:00
            * Never
            """)
        #expect(try Self.titles("clocked:", sources: [clocks]) == ["Overnight", "Running", "Child"])
        #expect(try Self.titles("(clocked :on \"2026-11-21\")", sources: [clocks]) == ["Overnight"])
        // A clock overlapping the range counts: Overnight ended on day -7.
        #expect(try Self.titles("(clocked :from -7)", sources: [clocks]) == ["Overnight", "Running", "Child"])
        #expect(try Self.titles("(clocked :from -6)", sources: [clocks]) == ["Running", "Child"])
        #expect(try Self.titles("(clocked :to -8)", sources: [clocks]) == ["Overnight"])
    }

    @Test func headingsPropertiesLevelsPathsAndHabits() throws {
        #expect(try Self.titles("heading:rent") == ["Pay rent", "Notes on Rent"])
        #expect(try Self.titles("heading:pay,rent") == ["Pay rent"])
        // The keyword and tags aren't part of the heading; the priority cookie is.
        #expect(try Self.titles("heading:TODO") == [])
        #expect(try Self.titles("heading:work") == [])
        #expect(try Self.titles("heading:\"#B\"") == ["Old plan"])
        #expect(try Self.titles("property:CLIENT") == ["Write report"])
        #expect(try Self.titles("property:client,Acme") == ["Write report"])
        #expect(try Self.titles("property:CLIENT,acme") == [])
        #expect(try Self.titles("(property \"CLIENT\" \"Acme\" :inherit t)") == ["Write report", "Call Bob", "Deep [#C] note"])
        #expect(try Self.titles("(property \"CLIENT\" :inherit nil)") == ["Write report"])
        #expect(try Self.titles("level:2") == ["Call Bob"])
        #expect(try Self.titles("level:2,3") == ["Call Bob", "Deep [#C] note"])
        #expect(try Self.titles("(level '> 1)") == ["Call Bob", "Deep [#C] note"])
        #expect(try Self.titles("path:inbox").count == 8)
        #expect(try Self.titles("path:\"^/work/\"") == [])
        #expect(try Self.titles("habit:") == ["Write report"])
    }

    @Test func combinations() throws {
        #expect(try Self.titles("(and (todo) (tags \"work\") (deadline :to 30))") == ["Call Bob"])
        #expect(try Self.titles("todo: tags:work deadline:to=30") == ["Call Bob"])
        #expect(try Self.titles("(or (priority \"A\") (level 3))") == ["Pay rent", "Deep [#C] note"])
        #expect(try Self.titles("(not (or (todo) (done)))") == ["Deep [#C] note", "Meeting <2026-12-05 Sat 14:00>", "Notes on Rent"])
        #expect(try Self.titles("tags:work !done:") == ["Write report", "Call Bob", "Deep [#C] note"])
        #expect(try Self.titles("(or)") == [])
    }

    @Test func sortingAsOrgQLSorts() throws {
        let byDate = try Self.titles("ts-a:", sort: ["date"])
        #expect(byDate == ["Old plan", "Write report", "Pay rent", "Call Bob", "Meeting <2026-12-05 Sat 14:00>"])
        #expect(try Self.titles("ts-a:", sort: ["scheduled"]) == ["Old plan", "Write report", "Pay rent", "Call Bob", "Meeting <2026-12-05 Sat 14:00>"])
        #expect(try Self.titles("ts:", sort: ["closed"]).first == "Paid the bills")
        #expect(try Self.titles("tags:", sort: ["priority"]).prefix(3) == ["Pay rent", "Old plan", "Write report"])
        // The keyword's position in #+TODO, then entries without one.
        #expect(try Self.titles("tags:", sort: ["todo"]) == ["Pay rent", "Write report", "Call Bob", "Paid the bills", "Old plan", "Deep [#C] note", "Meeting <2026-12-05 Sat 14:00>", "Notes on Rent"])
        // The last key decides first; earlier keys order the ties.
        #expect(try Self.titles("todo:TODO,CANCELLED,NEXT", sort: ["date", "priority"]) == ["Pay rent", "Old plan", "Write report"])
        #expect(try Self.titles("(todo)", sort: ["reverse"]) == ["Call Bob", "Write report", "Pay rent"])
    }

    @Test func archivedAndCommentedHeadingsMatchToo() throws {
        let source = AgendaSource(path: "/a.org", text: "* TODO Kept :ARCHIVE:\n* COMMENT TODO Hidden\n* TODO Shown\n")
        #expect(try Self.titles("todo:", sources: [source]) == ["Kept", "Shown"])
        #expect(try Self.titles("heading:hidden", sources: [source]) == ["COMMENT TODO Hidden"])
    }

    @Test func agendaListsMatchesInFileOrder() throws {
        let other = AgendaSource(path: "/notes/work.org", text: "#+TODO: NEXT | DONE\n* NEXT [#B] Other file\n")
        let items = try #require(Agenda.query([Self.source, other], query: "todo:NEXT,TODO", today: Self.today))
        #expect(items.map(\.text) == ["TODO [#A] Pay rent", "NEXT Write report", "NEXT [#B] Other file"])
        #expect(items.map(\.category) == ["inbox", "inbox", "work"])
        #expect(Agenda.query([Self.source], query: "(category)", today: Self.today) == nil)
        let sorted = try #require(Agenda.query([Self.source, other], query: "todo:NEXT,TODO", sort: ["priority"], today: Self.today))
        #expect(sorted.map(\.text) == ["TODO [#A] Pay rent", "NEXT [#B] Other file", "NEXT Write report"])
    }

    // MARK: - Dynamic block

    static func update(_ text: String) -> (text: String, failure: String?) {
        let caret = (text as NSString).range(of: "#+BEGIN:").location
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], now: now, calendar: utc)
        switch UpdateDynamicBlock().run(in: context) {
        case .commit(let result):
            var new = text
            for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
            return (new, nil)
        case .failed(let message): return (text, message)
        default: return (text, "unexpected")
        }
    }

    @Test func dynamicBlockWritesOrgQLsDefaultTable() {
        let text = """
        #+BEGIN: org-ql :query "todo:"
        #+END:
        * TODO [#A] Pay [[https://example.com][the]] rent [1/2] :home:
        * TODO Write  report
        * DONE Paid
        """
        #expect(Self.update(text).text == """
        #+BEGIN: org-ql :query "todo:"
        | Heading       | Todo | P |
        |---------------+------+---|
        | [[*Pay \\[\\[https://example.com\\]\\[the\\]\\] rent][*Pay the rent]] | TODO | A |
        | [[*Write report][*Write report]] | TODO |   |
        #+END:
        * TODO [#A] Pay [[https://example.com][the]] rent [1/2] :home:
        * TODO Write  report
        * DONE Paid
        """)
    }

    @Test func dynamicBlockTakesColumnsSortTakeAndFormat() {
        let text = """
        #+BEGIN: org-ql :query (and (todo) (not (habit))) :columns (todo (priority "P") deadline scheduled ((property client) "Client") heading) :sort (deadline priority) :take 2 :ts-format "%Y-%m-%d %H:%M"
        old contents
        #+END:
        * TODO [#B] Second
        DEADLINE: <2026-12-02 Wed> SCHEDULED: <2026-11-29 Sun 09:30>
        :PROPERTIES:
        :CLIENT: Acme
        :END:
        * TODO [#A] First
        DEADLINE: <2026-12-02 Wed>
        * TODO Third
        """
        #expect(Self.update(text).text == """
        #+BEGIN: org-ql :query (and (todo) (not (habit))) :columns (todo (priority "P") deadline scheduled ((property client) "Client") heading) :sort (deadline priority) :take 2 :ts-format "%Y-%m-%d %H:%M"
        | Todo | P | Deadline         | Scheduled        | Client | Heading |
        |------+---+------------------+------------------+--------+---------|
        | TODO | A | 2026-12-02 00:00 |                  |        | [[*First][*First]]  |
        | TODO | B | 2026-12-02 00:00 | 2026-11-29 09:30 | Acme   | [[*Second][*Second]] |
        #+END:
        * TODO [#B] Second
        DEADLINE: <2026-12-02 Wed> SCHEDULED: <2026-11-29 Sun 09:30>
        :PROPERTIES:
        :CLIENT: Acme
        :END:
        * TODO [#A] First
        DEADLINE: <2026-12-02 Wed>
        * TODO Third
        """)
    }

    @Test func dynamicBlockRefusesWhatItCantDo() {
        let block = { (params: String) in Self.update("#+BEGIN: org-ql \(params)\n#+END:\n* TODO a\n").failure }
        #expect(block(":columns (heading)") == "An org-ql block needs a :query")
        #expect(block(":query \"rifle:x\"") == "org-ql's rifle predicate isn't supported")
        #expect(block(":query (todo) :columns (tags)") == "The org-ql column tags isn't supported")
        #expect(block(":query (todo) :sort size") == "Unknown sort key size")
        #expect(block(":query (todo) :take -1 :ts-format \"%Q\"") == nil)
    }

    /// Org's `org-link-heading-search-string`, `org-link-make-string` and
    /// `org-link-display-format`, which org-ql's heading column calls, against Emacs.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil && EmacsOracle.isAvailable)) func headingLinksMatchOrg() throws {
        let titles = ["Foo bar", "Task [2/3] here [50%]", "See [[https://x.org][link]] now", "A  b\tc", "Ends with ]", "Back\\slash [x]"]
        let form = "(mapcar (lambda (h) (let ((n (org-link-heading-search-string h))) (org-link-make-string n (org-link-display-format n)))) (list \(titles.map { Sexp.string($0).description }.joined(separator: " "))))"
        let expected = try EmacsOracle.evaluate("", form)
        let ours = titles.map { title -> String in
            let search = "*" + Links.normalize(title, context: false)
            return Links.makeString(search, Links.displayFormat(search))
        }
        #expect(ours == expected)
    }

    /// The block's rows as org-ql inserts them, aligned by Emacs's `org-table-align`, against
    /// the updated block.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil && EmacsOracle.isAvailable)) func dynamicBlockAlignsAsOrgDoes() throws {
        let text = """
        #+BEGIN: org-ql :query "todo:" :columns (heading todo (priority "P") deadline ((property effort) "E")) :ts-format "%d %b"
        #+END:
        * TODO [#A] Pay [[https://example.com][the]] rent [1/2] :home:
        DEADLINE: <2026-12-02 Wed>
        :PROPERTIES:
        :EFFORT: 1:00
        :END:
        * TODO Write  report
        * TODO Ünïcode 😀 tïtle
        """
        let buffer = EmacsBuffer(text, point: 0, settings: OrgParser.parse(text).settings)
        buffer.now = Self.now
        buffer.calendar = Self.utc
        let raw = try buffer.orgQLBlock(paramText:":query \"todo:\" :columns (heading todo (priority \"P\") deadline ((property effort) \"E\")) :ts-format \"%d %b\"")
        let form = "(progn (insert \(Sexp.string(raw).description)) (font-lock-ensure) (goto-char (point-min)) (org-table-align) (list (string-trim-right (buffer-substring-no-properties (point-min) (point-max)))))"
        let expected = try EmacsOracle.evaluate("", form)
        let updated = Self.update(text).text.components(separatedBy: "\n")
        #expect([updated[1...5].joined(separator: "\n")] == expected)
    }
}
