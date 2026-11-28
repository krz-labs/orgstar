#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import OrgPresentation
import SwiftUI

/// Triage: the captured entries one at a time, with a large button for each action. A swipe
/// left on the entry moves on to the next one; a swipe right archives it. Undo in the toolbar
/// takes back the last action.
struct TriageScreen: View {
    let model: TriageModel
    let workspace: WorkspaceModel
    let session: DocumentSession
    /// The weekday weeks start on, for Next Week.
    let startOnWeekday: Int?
    let close: () -> Void
    @Environment(MobileModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var message: String?
    @State private var prompt: EditorScreen.PromptRequest?
    @State private var picking: Picking?
    @State private var refiling = false
    @State private var deleting = false
    @State private var offset: CGFloat = 0

    private enum Picking: String, Identifiable {
        case schedule, deadline
        var id: String { rawValue }
    }

    private var today: Int { Days.absolute(Date(), calendar: .current) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let item = model.current {
                    card(item)
                    buttons
                } else if model.isLoading {
                    ProgressView().frame(maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        model.problem == nil ? "Nothing to Triage" : "Can't Triage", systemImage: model.problem == nil ? "tray" : "exclamationmark.triangle",
                        description: Text(model.problem ?? String(localized: "Every captured entry has been dealt with."))
                    )
                    .frame(maxHeight: .infinity)
                }
            }
            .padding()
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: close) }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(model.title).font(.headline).lineLimit(1)
                        Text("\(model.remaining) left").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { message = model.undo() }
                        .disabled(!model.canUndo)
                }
            }
            .message($message)
        }
        .sheet(item: $prompt) { request in
            PromptSheet(prompt: request.prompt) { answer in
                prompt = nil
                request.reply(answer)
            }
        }
        .sheet(item: $picking) { kind in
            DateSheet(title: kind == .deadline ? "Deadline" : "Schedule", action: "Set", initial: Date()) { picked in
                picking = nil
                if let picked { plan(Days.absolute(picked, calendar: .current), deadline: kind == .deadline) }
            }
        }
        .sheet(isPresented: $refiling) {
            let path = model.current?.path
            RefileSheet(targets: workspace.refileTargets(openPath: path, document: path.flatMap(session.copy(of:)))) { target in
                refiling = false
                if let target { message = model.refile(to: target.label) }
            }
        }
        .confirmationDialog("Delete this entry?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { message = model.delete() }
        } message: {
            Text("The heading and every line under it are removed from the file. Undo puts them back.")
        }
    }

    private func card(_ item: AgendaItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let row = AgendaRow(item: item, day: today, today: today) {
                    AgendaRowView(row: row, day: today, theme: app.theme, dark: colorScheme == .dark)
                }
                let body = model.body()
                if !body.isEmpty {
                    Text(body)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        .offset(x: offset)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onChanged { offset = $0.translation.width }
                .onEnded { drag in
                    withAnimation(.snappy) { offset = 0 }
                    if drag.translation.width < -100 {
                        model.next()
                    } else if drag.translation.width > 100 {
                        message = model.archive()
                    }
                }
        )
        .accessibilityAction(named: "Next") { model.next() }
        .accessibilityAction(named: "Archive") { message = model.archive() }
    }

    private var buttons: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            Menu {
                dateChoices(deadline: false)
            } label: {
                big("Schedule", "calendar")
            }
            Menu {
                dateChoices(deadline: true)
            } label: {
                big("Deadline", "calendar.badge.exclamationmark")
            }
            Button { run(SetTags()) } label: { big("Tags", "tag") }
            Menu {
                ForEach(model.keywords(), id: \.self) { keyword in
                    Button(keyword) { run(SetTodo(keyword: keyword)) }
                }
                Button("None") { run(SetTodo(keyword: nil)) }
            } label: {
                big("TODO State", "checkmark.circle")
            }
            Button { refiling = true } label: { big("Refile", "arrow.turn.down.right") }
            Button { message = model.archive() } label: { big("Archive", "archivebox") }
            Button(role: .destructive) { deleting = true } label: { big("Delete", "trash") }
            Button { model.next() } label: { big("Next", "arrow.right") }
        }
        .buttonStyle(.bordered)
    }

    private func big(_ title: LocalizedStringKey, _ image: String) -> some View {
        Label(title, systemImage: image)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func dateChoices(deadline: Bool) -> some View {
        Button("Today") { plan(today, deadline: deadline) }
        Button("Tomorrow") { plan(today + 1, deadline: deadline) }
        Button("Next Week") { plan(Days.weekStart(today, on: startOnWeekday) + 7, deadline: deadline) }
        Button("Pick Date…") { picking = deadline ? .deadline : .schedule }
    }

    private func plan(_ day: Int, deadline: Bool, answers: [String: String] = [:]) {
        handle(model.plan(day: day, deadline: deadline, answers: answers), title: deadline ? "Set Deadline" : "Schedule") {
            plan(day, deadline: deadline, answers: answers.merging($0) { $1 })
        }
    }

    /// Runs `command` on the current entry, asking what it asks.
    private func run(_ command: any OrgCommand, answers: [String: String] = [:]) {
        handle(model.perform(command, answers: answers), title: command.title) { run(command, answers: answers.merging($0) { $1 }) }
    }

    /// Shows what a step needs: a prompt's answer goes to `again`.
    private func handle(_ step: CommandStep, title: String, again: @escaping ([String: String]) -> Void) {
        switch step {
        case .prompt(let request):
            prompt = EditorScreen.PromptRequest(prompt: request) { answer in
                guard let answer else { return }
                again([request.key: answer])
            }
        case .failed(let text): message = text
        case .external(let request): message = MobileEditor.unavailable(request, title: title)
        case .commit: message = nil
        }
    }
}
#endif
