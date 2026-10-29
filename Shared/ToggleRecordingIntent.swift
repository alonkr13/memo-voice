// Compiled into BOTH the Memo app and the MemoWidget extension: the widget and the Live Activity
// need the type for `Button(intent:)`, but the intent only ever runs in the APP process.
//
// Why the app process: the intent adopts `LiveActivityIntent` (and `AudioRecordingIntent`).
// Apple: "If you adopt the LiveActivityIntent or AudioPlaybackIntent protocol, the system runs
// the app intent in the app's process" and, for LiveActivityIntent, "the system launches your
// app process without opening the app, performs the intent, and starts the Live Activity"
// (WidgetKit "Adding interactivity to widgets and Live Activities"; AppIntents
// "LiveActivityIntent"). `AudioRecordingIntent` requires starting a Live Activity when the
// recording begins, which only the app process can do (ActivityKit). The widget build
// (WIDGET_EXTENSION, set in project.yml) compiles a no-op `perform()` and never links the
// recorder, store or audio session code.
import AppIntents
import Foundation

/// What a tap should do. The widget passes what it currently shows, so a stale "Stop" never
/// starts a recording; `.toggle` is for when the state is unknown (no App Group) and for
/// Shortcuts / the Action button.
enum RecordingAction: String, AppEnum {
    case toggle, start, stop

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Recording Action" }
    static var caseDisplayRepresentations: [RecordingAction: DisplayRepresentation] {
        [.toggle: "Start or Stop", .start: "Start", .stop: "Stop"]
    }
}

struct ToggleRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Record Memo" }
    static var description: IntentDescription {
        IntentDescription("Starts recording a voice memo, or stops the one being recorded.")
    }
    /// Record without bringing the app to the foreground (the whole point of the widget).
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Action", default: .toggle)
    var action: RecordingAction

    init() {}

    init(action: RecordingAction) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await AppRecordingController.perform(action)
        #endif
        return .result()
    }
}
