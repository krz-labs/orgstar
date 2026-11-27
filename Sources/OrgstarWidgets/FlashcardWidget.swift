import OrgApp
import SwiftUI
import WidgetKit

/// How many flashcards are due; tapping it starts the review.
struct FlashcardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "sh.krz.orgstar.flashcards", provider: FlashcardProvider()) { entry in
            FlashcardView(entry: entry)
        }
        .configurationDisplayName("Flashcards")
        .description("How many flashcards are due for review.")
        #if os(macOS)
        .supportedFamilies([.systemSmall])
        #else
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
        #endif
    }
}

struct FlashcardEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has written one.
    let snapshot: FlashcardSnapshot?
}

/// The count now, and again each time another card falls due.
struct FlashcardProvider: TimelineProvider {
    func placeholder(in context: Context) -> FlashcardEntry {
        FlashcardEntry(date: .now, snapshot: FlashcardSnapshot(due: [.now.addingTimeInterval(-60)]))
    }

    func getSnapshot(in context: Context, completion: @escaping (FlashcardEntry) -> Void) {
        completion(FlashcardEntry(date: .now, snapshot: widgetsLocked ? nil : FlashcardSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FlashcardEntry>) -> Void) {
        let snapshot = widgetsLocked ? nil : FlashcardSnapshot.read()
        let dates = [Date.now] + (snapshot?.changes(after: .now) ?? [])
        completion(Timeline(entries: dates.map { FlashcardEntry(date: $0, snapshot: snapshot) }, policy: .never))
    }
}

struct FlashcardView: View {
    let entry: FlashcardEntry
    @Environment(\.widgetFamily) private var family

    private var count: Int { entry.snapshot?.count(at: entry.date) ?? 0 }

    var body: some View {
        content
            .widgetURL(AppLink.review.url)
            #if os(macOS)
            .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
            #else
            .containerBackground(for: .widget) { family == .systemSmall ? Color(uiColor: .systemBackground) : Color.clear }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            Text("\(count) cards due")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -2) {
                    Text("\(count)").font(.title2.weight(.semibold)).widgetAccentable()
                    Text("cards").font(.caption2)
                }
            }
            .accessibilityLabel("\(count) cards due")
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("Flashcards", systemImage: "rectangle.on.rectangle.angled").font(.subheadline.weight(.semibold)).widgetAccentable()
                Spacer(minLength: 0)
                if entry.snapshot == nil {
                    Text(widgetsLocked ? "Widgets need orgstar+." : "Open orgstar to count your cards here.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(count)").font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(count == 0 ? "Nothing due" : "due for review").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
