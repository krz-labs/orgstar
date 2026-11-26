#if os(macOS)
import AppKit
import OrgCore

/// Keyboard macros as Emacs's kmacro has them, in every preset: keys are recorded as they reach
/// `handleChord`, as the Doom preset's `q` records them, and replayed through it. A prompt
/// opened while replaying reads its answer from the macro's keys; a command that fails stops
/// the macro.
extension OrgEditor {
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
                // The rest of the macro doesn't answer it: it is the person's to answer.
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
                // `kmacro-end-and-call-macro`: e runs it again, as C-x e's last key.
                if Self.kmacro.isRecording { try endMacro(byKey: byKey) }
                let key = commandKeys.flatMap { $0.count > 1 ? $0.last : nil }
                callLastMacro(count: macroCount, repeatKey: key)
            case "macro.start-or-insert-counter":
                if Self.kmacro.isRecording || kmacroDepth > 0 {
                    textView.insertText(Self.kmacro.insertCounter(), replacementRange: textView.selectedRange())
                } else {
                    try startMacro()
                }
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
        // A macro that starts one while replaying does nothing, as in Emacs.
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
            let before = (document.revision, textView.selectedRange())
            macroKeys = keys
            while !macroKeys.isEmpty, macroError == nil {
                let key = macroKeys.removeFirst()
                if !handleChord(key) { typeUnhandled(key) }
            }
            if macroError != nil {
                failed = true
                break
            }
            if count == 0, before == (document.revision, textView.selectedRange()) { break }
        }
        return !failed
    }

    /// A replayed key that `handleChord` left to the text system, which gets it as an event.
    /// ⌘ keys go to the menus.
    private func typeUnhandled(_ key: KeyChord) {
        if modal { return insertTyped(key) }
        guard let event = Self.event(for: key, window: textView.window) else { return }
        if key.modifiers.contains(.command) {
            if NSApp.mainMenu?.performKeyEquivalent(with: event) != true { fail("\(key) is undefined") }
        } else {
            textView.interpretKeyEvents([event])
        }
    }

    /// A key-down event for `key`, the reverse of `KeyEvents.chord`.
    static func event(for key: KeyChord, window: NSWindow?) -> NSEvent? {
        let functionKeys: [String: Int] = [
            "<delete>": NSDeleteFunctionKey, "<left>": NSLeftArrowFunctionKey, "<right>": NSRightArrowFunctionKey,
            "<up>": NSUpArrowFunctionKey, "<down>": NSDownArrowFunctionKey, "<home>": NSHomeFunctionKey,
            "<end>": NSEndFunctionKey, "<prior>": NSPageUpFunctionKey, "<next>": NSPageDownFunctionKey,
        ]
        let named = ["TAB": "\t", "RET": "\r", "SPC": " ", "ESC": "\u{1b}", "DEL": "\u{7f}"]
        let characters: String
        if let text = named[key.key] {
            characters = text
        } else if let code = functionKeys[key.key] ?? key.key.firstMatch(of: /^<f(\d+)>$/).flatMap({ Int($0.1) }).map({ NSF1FunctionKey + $0 - 1 }),
                  let scalar = Unicode.Scalar(code) {
            characters = String(Character(scalar))
        } else if key.key.count == 1 {
            characters = key.key
        } else {
            return nil
        }
        var flags: NSEvent.ModifierFlags = []
        if key.modifiers.contains(.control) { flags.insert(.control) }
        if key.modifiers.contains(.meta) { flags.insert(.option) }
        if key.modifiers.contains(.shift) || (key.key.count == 1 && key.key.uppercased() == key.key && key.key.lowercased() != key.key) { flags.insert(.shift) }
        if key.modifiers.contains(.command) { flags.insert(.command) }
        let code = KeyEvents.named.first { $0.value == key.key }?.key ?? 0
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        )
    }

    /// While replaying, C-f, C-b, C-n and C-p that can't move are errors, as in Emacs.
    func checkMovement(_ id: String, from before: NSRange) {
        let after = textView.selectedRange()
        let ns = textView.string as NSString
        let lineStart = { (offset: Int) in ns.lineRange(for: NSRange(location: offset, length: 0)).location }
        switch id {
        case "edit.forward-char" where after == before: fail("End of buffer")
        case "edit.backward-char" where after == before: fail("Beginning of buffer")
        case "edit.next-line" where NSMaxRange(after) == ns.length && (after == before || lineStart(NSMaxRange(before)) == lineStart(ns.length)):
            fail("End of buffer")
        case "edit.previous-line" where after.location == 0 && (after == before || lineStart(before.location) == 0):
            fail("Beginning of buffer")
        default: break
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

    /// Runs a named macro picked by name.
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
