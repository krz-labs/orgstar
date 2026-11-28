import AppKit
import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI

/// Triage, in a sheet over the agenda window: the captured entries one at a time, with single
/// keys for each action. The keys are fixed, as the agenda's are: s schedules, d sets a
/// deadline, : sets tags, t sets the TODO state, r refiles, a or $ archives, k or Delete
/// deletes, n or Space moves on, u undoes the last action, Return shows the entry in the main
/// window, q or Escape closes.
struct TriageView: View {
    let model: TriageModel
    let session: DocumentSession
    let workspace: WorkspaceModel
    let commands: AppCommands
    let close: () -> Void
    @State private var prompt: PromptRequest?
    @State private var message: String?
    @FocusState private var focused: Bool
    @Environment(\.textScale) private var scale
    @Environment(\.orgTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// The actions in the order the legend shows them: key label, title, key.
    private static let actions: [(label: String, title: LocalizedStringResource, key: Character)] = [
        ("s", "Schedule", "s"), ("d", "Deadline", "d"), (":", "Tags", ":"), ("t", "TODO State", "t"),
        ("r", "Refile", "r"), ("a", "Archive", "a"), ("k", "Delete", "k"),
        ("n", "Next", "n"), ("u", "Undo", "u"), ("↩", "Open", "\r"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.title).font(.scaled(.headline, scale)).lineLimit(1)
                Spacer()
                Text("\(model.remaining) left")
                    .font(.scaled(.callout, scale).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("\(model.remaining) entries left"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if let item = model.current {
                card(item)
            } else if model.isLoading {
                ProgressView().frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    model.problem == nil ? "Nothing to Triage" : "Can't Triage", systemImage: model.problem == nil ? "tray" : "exclamationmark.triangle",
                    description: Text(model.problem ?? String(localized: "Every captured entry has been dealt with."))
                )
                .frame(maxHeight: .infinity)
            }
            Divider()
            legend
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 400, idealHeight: 480)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if prompt != nil {
                PromptBar(request: $prompt)
            } else if let message {
                Text(message)
                    .font(.scaled(.callout, scale))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in handle(press) }
    }

    private func card(_ item: AgendaItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let todo = item.todo {
                        Text(todo)
                            .font(.scaled(.callout, scale).weight(.bold))
                            .foregroundStyle(theme.color(item.isDone ? "done" : "todo") ?? (item.isDone ? .green : .red))
                    }
                    Text(AgendaRow(item: item, day: 0, today: 0)?.title ?? item.text)
                        .font(.scaled(.title3, scale).weight(.semibold))
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Text(item.category).foregroundStyle(.secondary)
                    ForEach(item.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.scaled(.caption, scale))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                .font(.scaled(.callout, scale))
                let body = model.body()
                if !body.isEmpty {
                    Text(body)
                        .font(.scaled(.body, scale).monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            ForEach(Self.actions, id: \.label) { action in
                Button {
                    act(action.key)
                } label: {
                    HStack(spacing: 4) {
                        Text(action.label)
                            .font(.scaled(.caption, scale).monospaced().weight(.bold))
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18)))
                        Text(action.title).font(.scaled(.caption, scale))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.current == nil && action.key != "u")
            }
            Spacer(minLength: 8)
            Button("Done", action: close).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard prompt == nil else { return .ignored }
        if press.key == .return {
            act("\r")
            return .handled
        }
        if press.key == .space || (press.key == .rightArrow && press.modifiers.isEmpty) {
            act("n")
            return .handled
        }
        if press.key == .delete || press.key == .deleteForward {
            act("k")
            return .handled
        }
        if press.key == .escape {
            close()
            return .handled
        }
        guard press.modifiers.subtracting(.shift).isEmpty, let key = press.characters.first else { return .ignored }
        switch key {
        case "$": act("a")
        case "q": close()
        case "s", "d", ":", "t", "r", "a", "k", "n", "u": act(key)
        default: return .ignored
        }
        return .handled
    }

    private func act(_ key: Character) {
        message = nil
        if key == "u" {
            message = model.undo()
            return
        }
        guard let item = model.current else { return }
        switch key {
        case "s": run(SetPlanning(deadline: false))
        case "d": run(SetPlanning(deadline: true))
        case ":": run(SetTags())
        case "t":
            ask(Prompt(key: "todo", message: String(localized: "TODO state (empty for none):"), choices: model.keywords())) { answer in
                let word = answer.trimmingCharacters(in: .whitespaces)
                run(SetTodo(keyword: word.isEmpty ? nil : word))
            }
        case "r":
            let targets = workspace.refileTargets(openPath: item.path, document: item.path.flatMap(session.copy(of:)))
            ask(Prompt(key: "refile", message: String(localized: "Refile to:"), choices: targets.map(\.label))) { answer in
                guard targets.contains(where: { $0.label == answer }) else { return }
                message = model.refile(to: answer)
            }
        case "a":
            #if APPSTORE
            if let path = item.path, let line = item.headingLine, let near = item.headingOffset,
               let offset = session.locateHeading(path: path, line: line, near: near) {
                guard commands.reach(session.archiveFile(from: (path, offset)).map { [$0] } ?? []) else { return }
            }
            #endif
            message = model.archive()
        case "k":
            message = model.delete().map { String(localized: "\($0); u undoes it", comment: "After Triage deleted an entry") }
        case "n": model.next()
        case "\r":
            guard let path = item.path, let offset = item.headingOffset else { return }
            commands.jump(path: path, offset: offset)
        default: break
        }
    }

    /// Runs `command` on the current entry, asking what it asks.
    private func run(_ command: any OrgCommand, answers: [String: String] = [:]) {
        switch model.perform(command, answers: answers) {
        case .prompt(let request):
            ask(request) { answer in run(command, answers: answers.merging([request.key: answer]) { $1 }) }
        case .failed(let text): message = text
        case .external: message = String(localized: "Not available from the agenda")
        case .commit: break
        }
    }

    private func ask(_ prompt: Prompt, apply: @escaping (String) -> Void) {
        self.prompt = PromptRequest(prompt: prompt) { answer in
            focused = true
            if let answer { apply(answer) }
        }
    }
}
