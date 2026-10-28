import SwiftUI
import WidgetKit
import MemoKit

struct PlaceholderEntry: TimelineEntry {
    let date: Date
    let usingAppGroup: Bool
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: .now, usingAppGroup: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now, usingAppGroup: AppPaths.usingAppGroup))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        let entry = PlaceholderEntry(date: .now, usingAppGroup: AppPaths.usingAppGroup)
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct PlaceholderWidgetView: View {
    let entry: PlaceholderEntry

    var body: some View {
        VStack(spacing: 4) {
            Text("Memo").font(.headline)
            Text("App Group: \(entry.usingAppGroup ? "yes" : "no")").font(.caption)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MemoPlaceholder", provider: PlaceholderProvider()) { entry in
            PlaceholderWidgetView(entry: entry)
        }
        .configurationDisplayName("Memo")
        .description("Shows whether the App Group is available.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct MemoWidgetBundle: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
    }
}
