import ActivityKit
import AVFoundation
import MemoKit
import SwiftUI
import WidgetKit

/// The seam between the UI and the recorder. The memo list's Record/Stop button only uses this.
@MainActor
protocol RecordingControlling: ObservableObject {
    var isRecording: Bool { get }
    /// True while a start is in progress (permission, session, queue write).
    var isStarting: Bool { get }
    /// Seconds recorded so far; 0 when idle.
    var elapsed: TimeInterval { get }
    /// Last start/stop problem, shown to the user until dismissed.
    var errorMessage: String? { get set }
    /// The memo being recorded or finalized (nil when idle); the UI must not retry/delete it.
    var activeMemoID: UUID? { get }
    /// Starts a recording, or stops the current one and queues it for processing.
    func toggle() async
}

/// The app's one recorder, used by the in-app button, the widget / Live Activity intent
/// (`ToggleRecordingIntent`) and the `memo://record` deep link. Wraps MemoCore's `Recorder`
/// (which owns the queue ordering and interruption handling) and adds what only the app does:
/// microphone permission, the Live Activity, the widget's shared state, and starting
/// processing when a recording ends.
@MainActor
final class AppRecordingController: RecordingControlling {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Last start/stop problem. Persisted (app-local defaults, plus the App Group when
    /// available) so a failure from a widget tap, which happens with no UI, is still shown in
    /// the memo list the next time the app opens, until dismissed.
    @Published var errorMessage: String? {
        didSet { RecordingErrorLog.save(errorMessage) }
    }

    var activeMemoID: UUID? { core.activeMemoID }

    private let core: Recorder
    private var ticker: Task<Void, Never>?
    /// A Stop that arrived while a start was still in progress; honoured once it finishes.
    private var stopRequested = false
    private var endObserver: NSObjectProtocol?
    /// Ending the Live Activity after a recording ended; `stop()` awaits it.
    private var endingActivities: Task<Void, Never>?
    /// The current recording's Live Activity.
    private var activityID: String?

    init(core: Recorder) {
        self.core = core
        errorMessage = RecordingErrorLog.load()
        endObserver = NotificationCenter.default.addObserver(
            forName: .memoRecorded, object: core, queue: nil
        ) { [weak self] _ in
            // Posted by the main-actor Recorder, synchronously on the main thread.
            MainActor.assumeIsolated { self?.recordingEnded() }
        }
    }

    // MARK: - Entry points

    func toggle() async {
        if core.isRecording { await stop() } else { await start() }
    }

    /// Called by `ToggleRecordingIntent.perform()` in the app process (no UI). Returns the
    /// problem when a start failed, so the intent can surface it.
    static func perform(_ action: RecordingAction) async -> RecordingFailure? {
        let controller = AppServices.recorder
        switch action {
        case .toggle:
            if controller.core.isRecording { await controller.stop(); return nil }
            return await controller.startReportingFailure(requireLiveActivity: true)
        case .start:
            return await controller.startReportingFailure(requireLiveActivity: true)
        case .stop:
            await controller.stop()
            return nil
        }
    }

    /// Called by the intent once it has brought the app to the foreground after a start that
    /// failed only because the Live Activity was unavailable: in the app, recording works
    /// without it (as the spec's fallback says, the app opens and starts recording).
    static func startInForeground() async {
        await AppServices.recorder.start(requireLiveActivity: false)
    }

    /// `memo://record` starts, `memo://stop` stops, `memo://toggle` toggles; any other
    /// `memo://` URL (e.g. `memo://open`, used after a failed widget start) just opens the app.
    /// Returns false for non-`memo` URLs.
    func handle(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "memo" else { return false }
        switch url.host?.lowercased() {
        case "record", "start": Task { await start() }
        case "stop": Task { await stop() }
        case "toggle": Task { await toggle() }
        default: break
        }
        return true
    }

    /// Starts a recording. Returns the problem if it didn't start (also kept in `errorMessage`).
    /// - Parameter requireLiveActivity: true for the widget / Live Activity path (app in the
    ///   background), where `AudioRecordingIntent` needs the Live Activity and iOS would stop
    ///   the recording without it. In the app (foreground) a missing activity is a warning.
    @discardableResult
    func start(requireLiveActivity: Bool = false) async -> String? {
        await startReportingFailure(requireLiveActivity: requireLiveActivity)?.message
    }

    private func startReportingFailure(requireLiveActivity: Bool) async -> RecordingFailure? {
        // One recording at a time; a second start (double tap, widget + app) is a no-op.
        guard !isStarting, core.activeMemoID == nil else { return nil }
        isStarting = true
        stopRequested = false
        // Stale state after a kill (old Live Activity, widget still saying "recording") must
        // not need a second tap or leave two activities.
        await resetStaleState()
        let problem = await beginRecording(requireLiveActivity: requireLiveActivity)
        isStarting = false
        if stopRequested {
            stopRequested = false
            await stop()
        }
        return problem
    }

    private func beginRecording(requireLiveActivity: Bool) async -> RecordingFailure? {
        errorMessage = nil
        guard await Self.microphoneAllowed() else {
            return fail("Microphone permission denied. Enable it in Settings > Memo.")
        }

        // The Live Activity first ("you must start a Live Activity when you begin the audio
        // recording"), for the memo ID the recorder will use.
        let memoID = UUID()
        var warning: String?
        var newActivity: String?
        switch Self.requestLiveActivity(memoID: memoID, startedAt: Date()) {
        case .success(let id):
            newActivity = id
        case .failure(let problem):
            if requireLiveActivity {
                return fail(problem.message + " Recording did not start.", liveActivityUnavailable: true)
            }
            warning = problem.message + " Recording anyway."
        }

        do {
            _ = try await core.start(id: memoID)
        } catch {
            if let newActivity { await Self.endActivities([newActivity]) }
            return fail("Could not start recording: \(error.localizedDescription)")
        }
        activityID = newActivity
        // Whisper must not run alongside the recorder: stop a transcription in flight (its memo
        // goes back to the queue and is processed when this recording ends).
        await AppServices.pipeline.pauseForRecording()
        isRecording = true
        startTicker()
        WidgetState.setRecording(true)
        WidgetCenter.shared.reloadAllTimelines()
        if let warning { errorMessage = warning }
        if let newActivity, let started = core.startedAt {
            await Self.updateActivity(newActivity, startedAt: started)
        }
        return nil
    }

    private func fail(_ message: String, liveActivityUnavailable: Bool = false) -> RecordingFailure {
        errorMessage = message
        return RecordingFailure(message: message, liveActivityUnavailable: liveActivityUnavailable)
    }

    func stop() async {
        if isStarting { stopRequested = true; return }
        if core.isRecording {
            // Persists `recorded`, then posts .memoRecorded (-> recordingEnded) before returning.
            await core.stop()
            await endingActivities?.value
        } else if core.activeMemoID == nil {
            // Nothing recording: a stale Live Activity / widget state (e.g. the app was killed
            // mid-recording). Clean up so they stop claiming a recording.
            await resetStaleState()
        }
    }

    /// Call on launch: ends Live Activities and resets widget state left over from a process
    /// that died while recording.
    /// On a cold start the intent may start a recording while this runs, so idleness is checked
    /// again after every suspension before anything is reset.
    func cleanUpIfIdle() async {
        guard isIdle else { return }
        let stale = Set(Activity<RecordingActivity>.activities.map(\.id))
        if !stale.isEmpty { await Self.endActivities(stale) }
        guard isIdle else { return }
        if WidgetState.isRecording != false {
            WidgetState.setRecording(false)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private var isIdle: Bool { !isStarting && core.activeMemoID == nil }

    /// Only while nothing is recording.
    private func resetStaleState() async {
        let stale = Set(Activity<RecordingActivity>.activities.map(\.id))
        if !stale.isEmpty { await Self.endActivities(stale) }
        if WidgetState.isRecording != false {
            WidgetState.setRecording(false)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - End of a recording (Stop, interruption, encoder error)

    private func recordingEnded() {
        ticker?.cancel()
        ticker = nil
        isRecording = false
        elapsed = 0
        if let problem = core.lastError { errorMessage = problem }
        objectWillChange.send()   // activeMemoID (computed from core) changed too
        // Snapshot now, so an activity for a recording started right after is never ended.
        var ids = Set(Activity<RecordingActivity>.activities.map(\.id))
        if let activityID { ids.insert(activityID) }
        activityID = nil
        endingActivities = Task { await Self.endActivities(ids) }
        WidgetState.setRecording(false)
        WidgetCenter.shared.reloadAllTimelines()
        BackgroundTasks.submitContinued()
    }

    // MARK: - Helpers

    private static func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Asks for the microphone on first launch, so a later widget tap (app in the background,
    /// where no prompt can be shown) can record.
    static func requestMicrophoneIfNeeded() async {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
    }

    private func startTicker() {
        ticker?.cancel()
        let started = core.startedAt ?? Date()
        elapsed = 0
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.elapsed = Date().timeIntervalSince(started)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    struct ActivityProblem: Error { let message: String }

    /// `AudioRecordingIntent` requires a Live Activity for as long as the recording runs. It is
    /// also the lock-screen indicator with the Stop button. Returns the activity's ID.
    private static func requestLiveActivity(memoID: UUID, startedAt: Date) -> Result<String, ActivityProblem> {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return .failure(ActivityProblem(message:
                "Live Activities are turned off for Memo. Turn them on in Settings > Memo > Live Activities so the widget can record."))
        }
        do {
            let activity = try Activity<RecordingActivity>.request(
                attributes: RecordingActivity(memoID: memoID),
                content: ActivityContent(state: .init(startedAt: startedAt), staleDate: staleDate(startedAt)),
                pushType: nil)
            return .success(activity.id)
        } catch {
            return .failure(ActivityProblem(message:
                "The Live Activity could not start (\(error.localizedDescription))."))
        }
    }

    /// Nonisolated and looked up by ID, so no `Activity` value crosses actors.
    nonisolated private static func endActivities(_ ids: Set<String>) async {
        for activity in Activity<RecordingActivity>.activities where ids.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    nonisolated private static func updateActivity(_ id: String, startedAt: Date) async {
        for activity in Activity<RecordingActivity>.activities where activity.id == id {
            await activity.update(ActivityContent(state: .init(startedAt: startedAt), staleDate: staleDate(startedAt)))
        }
    }

    /// Just past the recorder's auto-stop: if the process died mid-recording, the system marks
    /// the activity stale instead of showing a timer that runs forever.
    nonisolated private static func staleDate(_ startedAt: Date) -> Date {
        startedAt.addingTimeInterval(Recorder.defaultMaxDuration + 60)
    }
}
