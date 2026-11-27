import OrgApp
import OrgCore
import OrgEditorAppKit
import OrgPresentation
import SwiftUI

struct KeyHint: Hashable {
    let key: String
    let title: String
}

/// The minibuffer line: a question, a pending prefix, or the last message until the next key
/// or click. After a short pause on a prefix, the keys that can follow it.
struct EchoArea: View {
    let commands: AppCommands
    @Environment(\.orgTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingHints = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingHints, commands.pendingKeys != nil, !commands.keyHints.isEmpty {
                Divider()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(commands.keyHints, id: \.self) { hint in
                        HStack(spacing: 8) {
                            Text(hint.key).font(.system(.body, design: .monospaced)).foregroundStyle(.tint)
                            Text(hint.title == "+prefix" ? String(localized: "+prefix", comment: "Key hint: the key starts a longer sequence") : hint.title)
                                .foregroundStyle(hint.title == "+prefix" ? .secondary : .primary).lineLimit(1)
                        }
                    }
                }
                .padding(10)
            }
            if let request = commands.prompt {
                PromptView(request: request, reply: commands.answer)
                    .id(request.id)
            } else if let text = commands.pendingKeys.map({ $0 + "-" }) ?? commands.message {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(theme.color("modeline-foreground") ?? .primary)
        .background { if let bg = theme.color("modeline-background", in: colorScheme) { bg } else { Rectangle().fill(.bar) } }
        .task(id: commands.pendingKeys) {
            showingHints = false
            guard commands.pendingKeys != nil else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { showingHints = true }
        }
    }
}

/// The evil state, as Doom's modeline shows it.
struct StateTag: View {
    let state: String
    @Environment(\.orgTheme) private var theme

    var body: some View {
        Text(label)
            .font(.system(.caption, design: .monospaced).bold())
            .foregroundStyle(labelColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("\(label.capitalized) state")
    }

    private var label: String {
        switch state {
        case "visual-line": "V-LINE"
        case "visual-block": "V-BLOCK"
        default: state.uppercased()
        }
    }

    private var slot: String {
        switch state {
        case "insert": "state-insert"
        case "replace": "state-replace"
        case "visual", "visual-line", "visual-block": "state-visual"
        default: "state-normal"
        }
    }

    private var color: Color {
        theme.color(slot) ?? ["state-insert": Color.green, "state-replace": .red, "state-visual": .orange][slot] ?? .blue
    }

    /// The theme's background on light fills, white on dark ones: whichever contrasts more.
    private var labelColor: Color {
        let (theme, slot) = (theme, slot)
        return theme.dynamic(.white) { dark in
            let colors = dark ? theme.dark : theme.light
            guard let fill = colors[slot], let background = colors["background"] else { return nil }
            let white = RGBA(red: 1, green: 1, blue: 1)
            return Self.contrast(background, fill) > Self.contrast(white, fill) ? background : white
        }
    }

    /// The WCAG contrast ratio of two opaque colors.
    nonisolated static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        func luminance(_ c: RGBA) -> Double {
            let linear = [c.red, c.green, c.blue].map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// A question a command asks: fast selection, or a text field with its choices, filtered as
/// it is typed, and a calendar for dates. The echo area shows it, and `PromptBar` in windows
/// without one.
struct PromptView: View {
    let request: PromptRequest
    /// Ends the prompt with an answer, or nil to cancel.
    let reply: (String?) -> Void
    @State private var answer = ""
    @FocusState private var answerFocused: Bool
    /// The highlighted choice, moved by ↑/↓ or C-p/C-n.
    @State private var selected = 0
    /// The highlight was moved, so Return answers with it even where any text is accepted.
    @State private var moved = false

    private var prompt: Prompt { request.prompt }

    var body: some View {
        if let fast = prompt.fast {
            Divider()
            FastSelectionView(selection: fast, message: prompt.message) { reply($0) }
        } else {
            let matches = filteredChoices(prompt.choices)
            let current = min(selected, matches.count - 1)
            if let detail = request.detail {
                Divider()
                Text(detail)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            if !prompt.choices.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(matches.indices, id: \.self) { index in
                                let choice = matches[index]
                                Button {
                                    if prompt.completionSeparator != nil { complete(choice) } else { reply(choice) }
                                } label: {
                                    Text(choice)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 4)
                                        .background(index == current ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 3))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .font(.system(.callout, design: .monospaced))
                                .accessibilityAddTraits(index == current ? .isSelected : [])
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 200)
                    .onChange(of: current) { if current >= 0 { proxy.scrollTo(current) } }
                }
            }
            if let read = prompt.date {
                Divider()
                DatePickerView(answer: answer, read: read) { reply($0) }
            }
            Divider()
            HStack(spacing: 6) {
                Text(prompt.message).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                TextField("", text: $answer)
                    .frame(minWidth: 240)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .focused($answerFocused)
                    .onSubmit {
                        if current >= 0, moved || prompt.requireMatch {
                            reply(matches[current])
                        } else if prompt.choices.isEmpty || !prompt.requireMatch {
                            reply(answer)
                        }
                    }
                    .onKeyPress(.tab) {
                        guard current >= 0 else { return .ignored }
                        complete(matches[current])
                        return .handled
                    }
                    .movesSelection(Binding(get: { selected }, set: { selected = $0; moved = true }), current: current, count: matches.count)
                    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                        guard let read = prompt.date, press.modifiers == .shift else { return .ignored }
                        let days = [KeyEquivalent.leftArrow: -1, .rightArrow: 1, .upArrow: -7, .downArrow: 7][press.key]!
                        answer = DatePickerView.shifted(answer, read, by: days)
                        return .handled
                    }
                    .onExitCommand { reply(nil) }
                    .onChange(of: answer) {
                        selected = 0
                        moved = false
                    }
                if !prompt.choices.isEmpty {
                    Text(verbatim: "\(max(current + 1, 0))/\(matches.count)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Choice \(max(current + 1, 0)) of \(matches.count)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .onAppear {
                answer = prompt.initial
                answerFocused = true
            }
        }
    }

    /// What completion matches: the text after the last separator, or all of it.
    private func completing(_ separator: Character?) -> Substring {
        guard let separator, let last = answer.lastIndex(of: separator) else { return answer[...] }
        return answer[answer.index(after: last)...]
    }

    /// Puts `choice` in place of what's being completed; with a separator, adds one after it.
    func complete(_ choice: String) {
        guard let separator = prompt.completionSeparator else {
            answer = choice
            return
        }
        let start = answer.lastIndex(of: separator).map { answer.index(after: $0) } ?? answer.startIndex
        answer = String(answer[..<start]) + (start == answer.startIndex ? String(separator) : "") + choice + String(separator)
    }

    /// Choices matching what's typed, best first.
    func filteredChoices(_ choices: [String]) -> [String] {
        let typed = String(completing(prompt.completionSeparator))
        guard !typed.isEmpty else { return choices }
        return choices.compactMap { choice in FuzzyMatch.score(typed, choice).map { (choice, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

/// A window's own question at its foot, styled as the echo area, for windows without one.
struct PromptBar: View {
    @Binding var request: PromptRequest?
    @Environment(\.orgTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let current = request {
            VStack(alignment: .leading, spacing: 0) {
                PromptView(request: current) { text in
                    request = nil
                    current.reply(text)
                }
                .id(current.id)
            }
            .foregroundStyle(theme.color("modeline-foreground") ?? .primary)
            .background { if let bg = theme.color("modeline-background", in: colorScheme) { bg } else { Rectangle().fill(.bar) } }
        }
    }
}

/// Messages: the echo area's recent messages, newest last (`view-echo-area-messages`).
struct MessagesView: View {
    let messages: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Messages").font(.headline).padding(12)
            Divider()
            if messages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "text.bubble")
            } else {
                ScrollView {
                    Text(messages.joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .defaultScrollAnchor(.bottom)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 360)
    }
}

/// Commands this build leaves out of the palette and menus; their keys say so when pressed.
#if APPSTORE
let hiddenCommandIDs = AppStoreCommands.hidden
#else
let hiddenCommandIDs: Set<String> = []
#endif

/// M-x and ⇧⌘P: every command by title, with its keys. An empty query lists the commands run
/// from here most recently, then the rest; matches rank commands used often a little higher.
struct PaletteView: View {
    let commands: AppCommands
    let run: (String) -> Void
    @State private var query = ""
    /// The highlighted match, moved by ↑/↓ or C-p/C-n and run by Return.
    @State private var selected = 0
    @Environment(\.dismiss) private var dismiss

    private var matches: (recent: [EditorCommand], rest: [EditorCommand]) {
        // A user command's `when` leaves it out where it doesn't apply.
        let context = commands.editor?.context()
        func offered(_ command: EditorCommand) -> Bool {
            guard case .text(let user as UserCommand) = command.action else { return true }
            return context.map(user.applies) ?? false
        }
        return CommandRanking.rank(EditorCommands.all.filter { $0.inPalette && !hiddenCommandIDs.contains($0.id) && offered($0) }, query: query,
                            id: \.id, titles: { [$0.localizedTitle, $0.title] })
    }

    var body: some View {
        let ranked = matches
        let matches = ranked.recent + ranked.rest
        let current = min(selected, matches.count - 1)
        VStack(spacing: 0) {
            TextField("Run command", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .onSubmit { if current >= 0 { choose(matches[current].id) } }
                .movesSelection($selected, current: current, count: matches.count)
                .onChange(of: query) { selected = 0 }
            Divider()
            ScrollViewReader { proxy in
                List {
                    if !ranked.recent.isEmpty {
                        Section("Recent") { rows(matches, 0..<ranked.recent.count, current) }
                        Section("All Commands") { rows(matches, ranked.recent.count..<matches.count, current) }
                    } else {
                        rows(matches, matches.indices, current)
                    }
                }
                .onChange(of: current) { if current >= 0 { proxy.scrollTo(current) } }
            }
        }
        .frame(width: 520, height: 360)
        .onExitCommand { dismiss() }
    }

    private func rows(_ matches: [EditorCommand], _ indices: Range<Int>, _ current: Int) -> some View {
        ForEach(indices, id: \.self) { index in
            let command = matches[index]
            Button {
                choose(command.id)
            } label: {
                HStack {
                    Text(command.localizedTitle)
                    Spacer()
                    if let keys = commands.keyLabel(for: command.id) {
                        Text(keys).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .selectedRow(index == current)
        }
    }

    private func choose(_ id: String) {
        CommandUsage.shared.record(id)
        run(id)
    }
}
