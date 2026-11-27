import OrgCore
import SwiftUI

/// The review screen, on the Mac and on iPhone and iPad: a card's front, Show Answer, then
/// the back with org-fc's four ratings as large buttons. On the Mac, Space or Return flips
/// and A, H, G and E rate, as in org-fc.
public struct FlashcardReviewView: View {
    @Bindable var review: FlashcardReview
    /// Opens the shown card's heading in the editor.
    let open: (String, Int) -> Void

    public init(review: FlashcardReview, open: @escaping (String, Int) -> Void) {
        self.review = review
        self.open = open
    }

    public var body: some View {
        VStack(spacing: 0) {
            if review.isLoading && !review.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let face = review.face, let item = review.current {
                card(face, item)
                Divider()
                controls(face)
                    .padding(16)
            } else {
                ContentUnavailableView {
                    Label(review.reviewed > 0 ? "Review Done" : "No Cards Due", systemImage: "rectangle.on.rectangle.angled")
                } description: {
                    Text(review.reviewed > 0
                         ? "\(review.reviewed) reviewed. Nothing else is due."
                         : "Flashcards are headings tagged fc, in org-fc's format. Make one with Make Normal Flashcard or another Make Flashcard command.")
                } actions: {
                    Button("Check Again") { Task { await review.start() } }
                }
            }
        }
        .alert("Flashcards", isPresented: Binding(get: { review.message != nil }, set: { if !$0 { review.message = nil } })) {
            Button("OK") { review.message = nil }
        } message: {
            Text(review.message ?? "")
        }
        .task { if !review.loaded { await review.start() } }
    }

    private func card(_ face: Flashcards.Face, _ item: Flashcards.Item) -> some View {
        let side = review.flipped ? face.back : face.front
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(review.queue.count) left").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Menu {
                        Button("Open in Editor", systemImage: "square.and.pencil") { open(item.path, item.card.headingOffset) }
                        Button("Suspend Card", systemImage: "pause.circle") { review.suspend() }
                    } label: {
                        Label("Card Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .fixedSize()
                }
                Text(Self.styled(side, title: true)).font(.title2.weight(.semibold))
                if !side.text.isEmpty {
                    Text(Self.styled(side, title: false)).font(.body)
                }
                if let expected = face.expected, review.flipped {
                    answerCheck(expected)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    private func answerCheck(_ expected: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(review.typedIsRight ? "Correct" : "Not quite", systemImage: review.typedIsRight ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(review.typedIsRight ? Color.green : Color.red)
            Text("Your answer: \(review.typed)")
            if !review.typedIsRight { Text("Expected: \(expected)") }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func controls(_ face: Flashcards.Face) -> some View {
        if review.flipped {
            HStack(spacing: 10) {
                rating(.again, "Again", .red, key: "a")
                rating(.hard, "Hard", .orange, key: "h")
                rating(.good, "Good", .green, key: "g")
                rating(.easy, "Easy", .blue, key: "e")
            }
        } else if face.expected != nil {
            HStack(spacing: 10) {
                TextField("Your Answer", text: $review.typed)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { review.flip() }
                big(Button("Check") { review.flip() }, tint: .accentColor)
                    .frame(maxWidth: 160)
            }
        } else {
            big(Button("Show Answer") { review.flip() }, tint: .accentColor)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func rating(_ rating: Flashcards.Rating, _ title: LocalizedStringKey, _ tint: Color, key: KeyEquivalent) -> some View {
        big(Button(title) { review.rate(rating) }, tint: tint)
            .keyboardShortcut(key, modifiers: [])
    }

    private func big(_ button: Button<Text>, tint: Color) -> some View {
        button
            .font(.headline)
            .buttonStyle(BigButtonStyle(tint: tint))
    }

    #if os(iOS)
    static let buttonHeight: CGFloat = 64
    #else
    static let buttonHeight: CGFloat = 40
    #endif

    private struct BigButtonStyle: ButtonStyle {
        let tint: Color
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: FlashcardReviewView.buttonHeight)
                .background(tint.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// The side's title (a placeholder while hidden) or text, with its marks in bold.
    static func styled(_ side: Flashcards.Face.Side, title: Bool) -> AttributedString {
        let titleText = side.title ?? "[…]"
        let whole = (side.title ?? "") + "\n" + side.text
        let part = title ? titleText : side.text
        var string = AttributedString(part)
        if title && side.title == nil { string.foregroundColor = .secondary }
        let offset = title ? 0 : ((side.title ?? "") as NSString).length + 1
        let ns = whole as NSString
        for mark in side.marks {
            let lower = mark.lowerBound - offset
            guard lower >= 0, mark.upperBound - offset <= (part as NSString).length, mark.upperBound <= ns.length,
                  let range = Range(NSRange(location: lower, length: mark.count), in: part),
                  let attributed = Range(range, in: string) else { continue }
            string[attributed].inlinePresentationIntent = .stronglyEmphasized
            string[attributed].foregroundColor = .accentColor
        }
        return string
    }
}
