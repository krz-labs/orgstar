import Foundation

/// TAB after a trigger, where TAB means nothing else, and any key bound to it: `yas-expand`.
public struct ExpandSnippet: OrgCommand {
    public init() {}
    public var id: String { "org.snippet.expand" }
    public var title: String { "Expand Snippet" }
    public func applies(in context: EditContext) -> Bool {
        context.selection.allSatisfy(\.isEmpty) && Snippets.trigger(before: context.caret, in: context.text, snippets: context.options.snippets) != nil
    }
    public func run(in context: EditContext) -> CommandStep {
        guard context.selection.allSatisfy(\.isEmpty),
              let found = Snippets.trigger(before: context.caret, in: context.text, snippets: context.options.snippets) else {
            return .failed("No snippet to expand")
        }
        return Snippets.step(found.snippet, replacing: found.range, in: context)
    }
}

/// Insert Snippet…: one chosen by name replaces the selection, which `%i` inserts
/// (`yas-insert-snippet`).
public struct InsertSnippet: OrgCommand {
    public init() {}
    public var id: String { "org.snippet.insert" }
    public var title: String { "Insert Snippet…" }
    public func applies(in context: EditContext) -> Bool { context.options.snippets.contains { !$0.file } }
    public func run(in context: EditContext) -> CommandStep {
        let snippets = context.options.snippets.filter { !$0.file }
        guard !snippets.isEmpty else { return .failed("No snippets in \(Snippets.fileName)") }
        guard let answer = context.answers["snippet"] else {
            return .prompt(Prompt(key: "snippet", message: "Choose snippet: ", choices: snippets.map(Snippets.label)))
        }
        guard let snippet = snippets.first(where: { Snippets.label($0) == answer || $0.trigger == answer }) else {
            return .failed("No snippet \(answer)")
        }
        let selected = context.selection.first ?? context.caret..<context.caret
        return Snippets.step(snippet, replacing: selected, in: context)
    }
}

/// A snippet or file template by trigger, at the caret: the command `Snippet.commandID` names.
public struct ExpandNamedSnippet: OrgCommand {
    public let trigger: String
    /// The snippet itself, for a template expanded before the editor has the snippets.
    let snippet: Snippet?
    public init(trigger: String) {
        self.trigger = trigger
        snippet = nil
    }
    public init(snippet: Snippet) {
        trigger = snippet.trigger
        self.snippet = snippet
    }
    public var id: String { Snippets.commandPrefix + trigger }
    public var title: String { "Expand Snippet" }
    public func applies(in context: EditContext) -> Bool { snippet != nil || context.options.snippets.contains { $0.trigger == trigger } }
    public func run(in context: EditContext) -> CommandStep {
        guard let snippet = snippet ?? context.options.snippets.first(where: { $0.trigger == trigger }) else { return .failed("No snippet \(trigger)") }
        let selected = context.selection.first ?? context.caret..<context.caret
        return Snippets.step(snippet, replacing: selected, in: context)
    }
}

extension Snippets {
    /// How Insert Snippet… lists a snippet.
    public static func label(_ snippet: Snippet) -> String {
        snippet.name == snippet.trigger ? snippet.trigger : "\(snippet.name) (\(snippet.trigger))"
    }

    /// The command for an id of the form `Snippet.commandID`.
    public static func command(_ id: String) -> (any OrgCommand)? {
        trigger(ofCommand: id).map(ExpandNamedSnippet.init)
    }

    /// Asks the body's prompts one at a time, then replaces `range` with the expansion and
    /// starts a session on its fields.
    static func step(_ snippet: Snippet, replacing range: Range<Int>, in context: EditContext) -> CommandStep {
        let ns = context.text as NSString
        var capture = CaptureContext(now: context.now, calendar: context.calendar,
                                     initial: range.isEmpty ? "" : ns.substring(with: NSRange(location: range.lowerBound, length: range.count)),
                                     file: context.options.filePath ?? "")
        capture.tagsColumn = context.options.tagsColumn
        let questions = questions(snippet, context: capture)
        var answers: [String] = []
        for (index, question) in questions.enumerated() {
            let key = "snippet-\(index)"
            guard let answer = context.answers[key] else { return .prompt(prompt(question, key: key)) }
            answers.append(answer)
        }
        let lineStart = ns.lineRange(for: NSRange(location: range.lowerBound, length: 0)).location
        let indentation = String(ns.substring(with: NSRange(location: lineStart, length: range.lowerBound - lineStart)).prefix { $0 == " " || $0 == "\t" })
        switch expand(snippet, context: capture, answers: answers, indentation: indentation) {
        case .failure(.message(let message)):
            return .failed(message)
        case .success(let expansion):
            let session = SnippetSession(expansion, at: range.lowerBound)
            let exit = (expansion.exit.lowerBound + range.lowerBound)..<(expansion.exit.upperBound + range.lowerBound)
            return .commit(EditResult(
                baseRevision: context.revision, edits: [TextEdit(range: range, replacement: expansion.text)],
                selection: [session?.selection ?? exit], effects: session.map { [.snippet($0)] } ?? []
            ))
        }
    }

    static func prompt(_ question: Capture.Question, key: String) -> Prompt {
        switch question.kind {
        case .date(_, let inactive):
            return Prompt(key: key, message: question.prompt + ": ", date: .init(defaultDate: nil, inactive: inactive))
        case .tags:
            return Prompt(key: key, message: question.prompt + ": ", choices: question.choices, requireMatch: false, completionSeparator: ":")
        case .text, .clipboard, .property:
            return Prompt(key: key, message: question.prompt + (question.defaultValue.isEmpty ? ": " : " (\(question.defaultValue)): "),
                          choices: question.choices, requireMatch: false)
        }
    }
}
