import AppIntents
import MemoCore
import SwiftUI
import WidgetKit

struct RecordEntry: TimelineEntry {
    let date: Date
    /// nil = unknown (no App Group): show a neutral toggle.
    let isRecording: Bool?
}

struct RecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordEntry { RecordEntry(date: .now, isRecording: false) }

    func getSnapshot(in context: Context, completion: @escaping (RecordEntry) -> Void) {
        completion(RecordEntry(date: .now, isRecording: context.isPreview ? false : WidgetState.isRecording))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordEntry>) -> Void) {
        // The app reloads timelines on every start/stop; a tap also reloads after perform().
        completion(Timeline(entries: [RecordEntry(date: .now, isRecording: WidgetState.isRecording)],
                            policy: .never))
    }
}

/// How the widget starts a recording.
enum RecordWidgetMode {
    /// `ToggleRecordingIntent` (AudioRecordingIntent) runs in the app process without opening it.
    case intent
    /// Opens the app via `memo://record`, which starts recording immediately.
    case deepLink
}

struct RecordWidgetView: View {
    let entry: RecordEntry
    let mode: RecordWidgetMode

    private var title: String {
        switch entry.isRecording {
        case true?: return "Stop"
        case false?: return "Record"
        case nil: return "Record / Stop"
        }
    }

    private var symbol: String {
        switch entry.isRecording {
        case true?: return "stop.fill"
        case false?: return "mic.fill"
        case nil: return "mic.circle"
        }
    }

    /// The widget passes what it shows, so a stale "Stop" never starts a new recording.
    private var action: RecordingAction {
        switch entry.isRecording {
        case true?: return .stop
        case false?: return .start
        case nil: return .toggle
        }
    }

    private var label: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .semibold))
                .frame(width: 76, height: 76)
                .background(Circle().fill(entry.isRecording == true ? Color.gray : Color.red))
                .foregroundStyle(.white)
            Text(title).font(.headline).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        switch mode {
        case .intent:
            Button(intent: ToggleRecordingIntent(action: action)) { label }
                .buttonStyle(.plain)
                .containerBackground(.fill.tertiary, for: .widget)
        case .deepLink:
            let host = entry.isRecording == true ? "stop" : "record"
            label
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "memo://\(host)"))
        }
    }
}

/// The main widget: one tap records without opening the app.
struct RecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.widgetKind, provider: RecordProvider()) { entry in
            RecordWidgetView(entry: entry, mode: .intent)
        }
        .configurationDisplayName("Record")
        .description("One tap starts a voice memo; tap again to stop.")
        .supportedFamilies([.systemSmall])
    }
}

/// Fallback: opens the app through `memo://record`, which starts recording immediately. Use it
/// if the intent widget doesn't record on the device.
struct RecordLinkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.widgetKind + ".link", provider: RecordProvider()) { entry in
            RecordWidgetView(entry: entry, mode: .deepLink)
        }
        .configurationDisplayName("Record (opens app)")
        .description("Opens Memo and starts recording right away.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct MemoWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordWidget()
        RecordLinkWidget()
        RecordingLiveActivity()
    }
}
