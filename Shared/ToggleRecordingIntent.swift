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
// (WIDGET_EXTENSION, set in project.yml) compiles a `perform()` that never links the
// recorder, store or audio session code; it reports an error instead of failing silently.
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
    /// Runs in the background (record without opening the app: the whole point of the
    /// widget), and may move to the foreground only to show a failed start.
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Action", default: .toggle)
    var action: RecordingAction

    init() {}

    init(action: RecordingAction) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        // Not expected (this intent runs in the app process), but never fail silently.
        let problem: String? = "Memo could not record from the widget. Open Memo and tap Record."
        #else
        let problem = await AppRecordingController.perform(action)
        #endif
        if let problem {
            // The error is also persisted and shown in the memo list. Open the app to show it
            // when the system allows that; otherwise report it to the system.
            if systemContext.currentMode.canContinueInForeground {
                try await continueInForeground(alwaysConfirm: false)
            } else {
                throw RecordingIntentError(message: problem)
            }
        }
        return .result()
    }
}

struct RecordingIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}
