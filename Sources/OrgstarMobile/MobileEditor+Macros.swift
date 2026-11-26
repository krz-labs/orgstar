#if os(iOS)
import OrgCore
import UIKit

/// Keyboard macros with a hardware keyboard, as on the Mac: keys are recorded as they reach
/// `handleChord` and replayed through it; a prompt opened while replaying reads its answer from
/// the macro's keys, and a command that fails stops the macro. Keys the text system types are
/// typed by the editor while replaying.
extension MobileEditor {
    /// The macro being recorded and the last one, shared by every editor as Emacs's are.
    static var kmacro = MacroRecorder()

    /// Shows `message`; while a macro replays, it is an error that stops it.
    func fail(_ message: String) {
        onMessage?(message)
        if kmacroDepth > 0, macroError == nil { macroError = message }
    }

    /// Asks through `onPrompt`, recording the answer while a macro records. While one replays,
    /// the answer comes from its keys.
    func ask(_ prompt: Prompt, reply: @escaping (String?) -> Void) {
        if kmacroDepth > 0 {
            guard let (answer, used) = MacroRecorder.reply(from: macroKeys) else {
                macroKeys = []
                onPrompt?(prompt, reply)
                return
            }
            macroKeys.removeFirst(used)
            switch answer {
            case .answer(let text): reply(text)
            case .quit:
                macroError = "Quit"
                reply(nil)
            }
            return
        }
        let records = Self.kmacro.isRecording
        onPrompt?(prompt) { answer in
            if records { Self.kmacro.record(answer: answer) }
            reply(answer)
        }
    }

    /// The count a macro command runs with: the prefix argument of the keys that ran it, or 1.
    private var macroCount: Int { commandKeys == nil ? 1 : dispatcher.argument ?? 1 }

    func macroCommand(_ id: String) {
        let byKey = commandKeys != nil
        do {
            switch id {
            case "macro.start":
                try startMacro()
            case "macro.end":
                try endMacro(byKey: byKey)
            case "macro.call":
                if Self.kmacro.isRecording { try endMacro(byKey: byKey) }
                callLastMacro(count: macroCount, repeatKey: commandKeys.flatMap { $0.count > 1 ? $0.last : nil })
            case "macro.start-or-insert-counter":
                if Self.kmacro.isRecording || kmacroDepth > 0 { textView.insertText(Self.kmacro.insertCounter()) } else { try startMacro() }
            case "macro.end-or-call":
                if Self.kmacro.isRecording { try endMacro(byKey: byKey) } else { callLastMacro(count: macroCount, repeatKey: nil) }
            case "macro.name":
                nameLastMacro()
            case "macro.run":
                runNamedMacro(count: macroCount)
            default:
                let name = String(id.dropFirst(NamedMacros.commandPrefix.count))
                guard id.hasPrefix(NamedMacros.commandPrefix), let keys = namedMacros.keys(name) else {
                    return fail("No macro named \(name)")
                }
                playMacro(keys, count: macroCount)
            }
        } catch let failure as MacroRecorder.Failure {
            fail(failure.message)
        } catch {
            fail("\(error)")
        }
    }

    private func startMacro() throws {
        guard kmacroDepth == 0 else { return }
        try Self.kmacro.start()
        onMessage?("Defining keyboard macro…")
    }

    private func endMacro(byKey: Bool) throws {
        guard kmacroDepth == 0 else { return }
        onMessage?(try Self.kmacro.end(byKey: byKey))
    }

    func callLastMacro(count: Int, repeatKey: KeyChord?) {
        let completed: Bool
        do {
            completed = playMacro(try Self.kmacro.lastMacro(), count: count)
        } catch let failure as MacroRecorder.Failure {
            return fail(failure.message)
        } catch {
            return
        }
        guard completed, kmacroDepth == 0, let repeatKey else { return }
        macroRepeatKey = repeatKey
        onMessage?("(Type \(repeatKey) to repeat macro)")
    }

    /// Feeds `keys` through `handleChord` `count` times, or with 0 until a command fails or a
    /// round changes nothing. False when a command failed.
    @discardableResult
    func playMacro(_ keys: [KeyChord], count: Int) -> Bool {
        guard kmacroDepth < 20 else {
            fail("Keyboard macros nest too deeply")
            return false
        }
        let outer = macroKeys
        kmacroDepth += 1
        defer {
            kmacroDepth -= 1
            macroKeys = outer
            if kmacroDepth == 0 { macroError = nil }
        }
        var rounds = 0
        var failed = false
        while count == 0 ? rounds < 100_000 : rounds < count {
            rounds += 1
            let before = (document.revision, textView.selectedRange)
            macroKeys = keys
            while !macroKeys.isEmpty, macroError == nil {
                let key = macroKeys.removeFirst()
                if !handleChord(key) { typeUnhandled(key) }
            }
            if macroError != nil {
                failed = true
                break
            }
            if count == 0, before == (document.revision, textView.selectedRange) { break }
        }
        return !failed
    }

    /// A replayed key that `handleChord` left to the text system: typed here.
    private func typeUnhandled(_ key: KeyChord) {
        if modal { return insertTyped(key) }
        if let command = keymap.candidates(for: [key]).first?.command, command.hasPrefix("edit.") {
            return replayEdit(command)
        }
        let ns = textView.textStorage.string as NSString
        let selected = textView.selectedRange
        switch (key.key, key.modifiers) {
        case ("DEL", []): textView.deleteBackward()
        case ("<delete>", []):
            if selected.length > 0 { textView.insertText("") } else if selected.location < ns.length {
                replace(ns.rangeOfComposedCharacterSequence(at: selected.location), with: "")
            }
        case ("<left>", []): replayEdit("edit.backward-char")
        case ("<right>", []): replayEdit("edit.forward-char")
        case ("<up>", []): replayEdit("edit.previous-line")
        case ("<down>", []): replayEdit("edit.next-line")
        default:
            let text = key.key == "SPC" ? " " : key.key == "RET" ? "\n" : key.key == "TAB" ? "\t" : key.key
            guard key.modifiers.isEmpty || key.modifiers == [.shift], text.count == 1 else { return fail("\(key) is undefined") }
            textView.insertText(text)
        }
    }

    private func replace(_ range: NSRange, with text: String) {
        textView.selectedRange = range
        textView.insertText(text)
    }

    private func setCaret(to offset: Int) {
        textView.selectedRange = NSRange(location: offset, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    /// The text system's editing keys (C-f, C-n, C-k and the like), which it has while typing.
    /// Moves that can't move are errors, as in Emacs.
    private func replayEdit(_ id: String) {
        let ns = textView.textStorage.string as NSString
        let caret = textView.selectedRange.location
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        var lineEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &lineEnd, for: line)
        let column = caret - line.location
        switch id {
        case "edit.forward-char":
            guard caret < ns.length else { return fail("End of buffer") }
            setCaret(to: NSMaxRange(ns.rangeOfComposedCharacterSequence(at: caret)))
        case "edit.backward-char":
            guard caret > 0 else { return fail("Beginning of buffer") }
            setCaret(to: ns.rangeOfComposedCharacterSequence(at: caret - 1).location)
        case "edit.next-line":
            guard NSMaxRange(line) < ns.length || (NSMaxRange(line) == ns.length && lineEnd < NSMaxRange(line)) else {
                setCaret(to: ns.length)
                return fail("End of buffer")
            }
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
            var nextEnd = 0
            ns.getLineStart(nil, end: nil, contentsEnd: &nextEnd, for: next)
            setCaret(to: min(next.location + column, nextEnd))
        case "edit.previous-line":
            guard line.location > 0 else {
                setCaret(to: 0)
                return fail("Beginning of buffer")
            }
            let previous = ns.lineRange(for: NSRange(location: line.location - 1, length: 0))
            setCaret(to: min(previous.location + column, line.location - 1))
        case "edit.beginning-of-line": setCaret(to: line.location)
        case "edit.end-of-line": setCaret(to: lineEnd)
        case "edit.beginning-of-buffer": setCaret(to: 0)
        case "edit.end-of-buffer": setCaret(to: ns.length)
        case "edit.forward-word", "edit.backward-word":
            let forward = id == "edit.forward-word"
            guard let start = textView.selectedTextRange?.end,
                  let position = textView.tokenizer.position(from: start, toBoundary: .word, inDirection: .storage(forward ? .forward : .backward))
            else { return }
            setCaret(to: textView.offset(from: textView.beginningOfDocument, to: position))
        case "edit.delete-char":
            guard caret < ns.length else { return fail("End of buffer") }
            replace(ns.rangeOfComposedCharacterSequence(at: caret), with: "")
        case "edit.kill-line":
            guard caret < ns.length else { return fail("End of buffer") }
            replace(NSRange(location: caret, length: caret < lineEnd ? lineEnd - caret : NSMaxRange(line) - caret), with: "")
        default:
            fail(Self.unavailable(command: id))
        }
    }

    /// `kmacro-name-last-macro`, with the name saved in `macros.toml`.
    private func nameLastMacro() {
        guard let keys = Self.kmacro.last else { return fail("No keyboard macro defined") }
        ask(Prompt(key: "macro-name", message: "Name for last kbd macro:")) { [weak self] answer in
            guard let self, let answer else { return }
            let name = answer.trimmingCharacters(in: .whitespaces)
            guard NamedMacros.isValidName(name) else {
                return self.fail(name.isEmpty ? "No command name given" : "A macro name has letters, digits, - and _ only")
            }
            do {
                try self.namedMacros.name(name, keys)
                self.onMessage?("Macro \(name) saved in \(NamedMacros.fileName)")
            } catch {
                self.fail("\(NamedMacros.fileName) wasn't written: \(error.localizedDescription)")
            }
        }
    }

    private func runNamedMacro(count: Int) {
        let names = namedMacros.names
        guard !names.isEmpty else { return fail("No named macros") }
        ask(Prompt(key: "macro", message: "Run macro:", choices: names)) { [weak self] answer in
            guard let self, let answer else { return }
            guard let keys = self.namedMacros.keys(answer) else { return self.fail("No macro named \(answer)") }
            self.playMacro(keys, count: count)
        }
    }
}
#endif
