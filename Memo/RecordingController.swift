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
    /// Last start/stop problem, shown to the user.
    var errorMessage: String? { get }
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
    @Published var errorMessage: String?

    var activeMemoID: UUID? { core.activeMemoID }

    private let core: Recorder
    private var ticker: Task<Void, Never>?
    /// A Stop that arrived while a start was still in progress; honoured once it finishes.
    private var stopRequested = false
    private var endObserver: NSObjectProtocol?

    init(core: Recorder) {
        self.core = core
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

    /// Called by `ToggleRecordingIntent.perform()` in the app process.
    static func perform(_ action: RecordingAction) async {
        let controller = AppServices.recorder
        switch action {
        case .toggle: await controller.toggle()
        case .start: await controller.start()
        case .stop: await controller.stop()
        }
    }

    /// `memo://record` starts, `memo://stop` stops, `memo://toggle` toggles. Returns false for
    /// other URLs.
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

    func start() async {
        // One recording at a time; a second start (double tap, widget + app) is a no-op.
        guard !isStarting, core.activeMemoID == nil else { return }
        isStarting = true
        stopRequested = false
        await beginRecording()
        isStarting = false
        if stopRequested {
            stopRequested = false
            await stop()
        }
    }

    private func beginRecording() async {
        errorMessage = nil
        guard await Self.microphoneAllowed() else {
            errorMessage = "Microphone permission denied. Enable it in Settings > Memo."
            return
        }
        let id: UUID
        do {
            id = try await core.start()
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            return
        }
        isRecording = true
        startTicker()
        startLiveActivity(memoID: id, startedAt: core.startedAt ?? Date())
        WidgetState.setRecording(true)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func stop() async {
        if isStarting { stopRequested = true; return }
        if core.isRecording {
            // Persists `recorded`, then posts .memoRecorded (-> recordingEnded) before returning.
            await core.stop()
        } else if core.activeMemoID == nil {
            // Nothing recording: a stale Live Activity / widget state (e.g. the app was killed
            // mid-recording). Clean up so they stop claiming a recording.
            cleanUpIfIdle()
        }
    }

    /// Call on launch: ends Live Activities and resets widget state left over from a process
    /// that died while recording.
    func cleanUpIfIdle() {
        guard !isStarting, core.activeMemoID == nil else { return }
        endLiveActivities()
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
        endLiveActivities()
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

    /// `AudioRecordingIntent` requires a Live Activity for as long as the recording runs. It is
    /// also the lock-screen indicator with the Stop button. Failure doesn't stop the recording.
    private func startLiveActivity(memoID: UUID, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            errorMessage = "Live Activities are turned off for Memo, so there is no lock-screen Stop button (and iOS may stop widget recordings). Turn them on in Settings > Memo."
            return
        }
        do {
            _ = try Activity<RecordingActivity>.request(
                attributes: RecordingActivity(memoID: memoID),
                content: ActivityContent(state: .init(startedAt: startedAt), staleDate: nil),
                pushType: nil)
        } catch {
            errorMessage = "Recording, but the Live Activity could not start: \(error.localizedDescription)"
        }
    }

    private func endLiveActivities() {
        let activities = Activity<RecordingActivity>.activities
        guard !activities.isEmpty else { return }
        Task {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
