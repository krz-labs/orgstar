#if os(iOS)
import OrgApp
import SwiftUI

/// The flashcard review on iPhone and iPad, full screen. `done` closes it, with a card's file
/// and heading to open when Open in Editor was chosen.
struct FlashcardScreen: View {
    let done: (String?, Int) -> Void
    @State private var review: FlashcardReview

    init(workspace: WorkspaceModel, session: DocumentSession, done: @escaping (String?, Int) -> Void) {
        self.done = done
        _review = State(initialValue: FlashcardReview(workspace: workspace, session: session))
    }

    var body: some View {
        NavigationStack {
            FlashcardReviewView(review: review) { path, offset in done(path, offset) }
                .navigationTitle("Review")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { done(nil, 0) }
                    }
                }
        }
    }
}
#endif
