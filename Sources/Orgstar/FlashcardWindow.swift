import OrgApp
import SwiftUI

/// Window ▸ Review Flashcards: the cards due across the workspace, reviewed one at a time.
/// Opening a card shows its heading in the main window.
struct FlashcardWindow: View {
    let commands: AppCommands
    @State private var review: FlashcardReview
    @Environment(\.openWindow) private var openWindow

    init(workspace: WorkspaceModel, session: DocumentSession, commands: AppCommands) {
        self.commands = commands
        _review = State(initialValue: FlashcardReview(workspace: workspace, session: session))
    }

    var body: some View {
        FlashcardReviewView(review: review) { path, offset in
            if !commands.mainWindowOpen { openWindow(id: "main") }
            commands.jump(path: path, offset: offset)
        }
        .frame(minWidth: 420, minHeight: 360)
        .navigationTitle("Review Flashcards")
        .toolbar {
            Button("Start Again", systemImage: "arrow.clockwise") { Task { await review.start() } }
        }
    }
}
