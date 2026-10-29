import AVFoundation
import MemoKit
import SwiftUI

/// The seam between the UI and the recorder. The memo list's Record/Stop button only uses this.
/// Task 3 replaces `AppRecordingController` (keeping this surface) with the real recorder
/// (widget `AudioRecordingIntent`, Live Activity).
@MainActor
protocol RecordingControlling: ObservableObject {
    var isRecording: Bool { get }
    /// Seconds recorded so far; 0 when idle.
    var elapsed: TimeInterval { get }
    /// Last start/stop problem, shown to the user.
    var errorMessage: String? { get }
    /// Starts a recording, or stops the current one and queues it for processing.
    func toggle() async
}

/// Minimal in-app recorder: mono 16 kHz AAC to `AppPaths.audioDir`. A `recording` memo is added
/// at the start (so a kill leaves a recoverable entry), and becomes `recorded` on stop, after
/// which processing starts via `BackgroundTasks.submitContinued()`.
@MainActor
final class AppRecordingController: NSObject, RecordingControlling, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    /// The memo being recorded right now (nil when idle); the UI must not retry/delete it.
    @Published private(set) var activeMemoID: UUID?
    @Published private(set) var isStarting = false
    private var memoID: UUID? {
        get { activeMemoID }
        set { activeMemoID = newValue }
    }
    private var fileURL: URL?
    private var startedAt = Date()
    private var ticker: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    func toggle() async {
        if isRecording { finishRecording(); return }
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        await start()
    }

    private func start() async {
        errorMessage = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone permission denied. Enable it in Settings > Memo."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let stamp = Int(Date().timeIntervalSince1970)
            let url = AppPaths.audioDir.appendingPathComponent(
                "memo-\(stamp)-\(UUID().uuidString.prefix(6)).m4a")
            let rec = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            rec.delegate = self
            // Register the memo before recording so the capture can never be orphaned; if the
            // queue can't be written, don't record at all.
            let memo = Memo(recordedAt: Date(), audioFile: url.lastPathComponent, state: .recording)
            try await AppServices.store.add(memo)
            guard rec.record() else {
                try? await AppServices.store.remove(memo.id)
                errorMessage = "Recording did not start."
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            recorder = rec
            memoID = memo.id
            fileURL = url
            startedAt = Date()
            elapsed = 0
            isRecording = true
            observeInterruptions()
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.elapsed = Date().timeIntervalSince(self.startedAt)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    /// Idempotent: runs on Stop, on the recorder's own finish and on audio interruptions.
    private func finishRecording() {
        guard let rec = recorder, let id = memoID, let url = fileURL else { return }
        recorder = nil
        memoID = nil
        fileURL = nil
        ticker?.cancel()
        ticker = nil
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        let duration = Date().timeIntervalSince(startedAt)
        rec.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        elapsed = 0
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        Task { @MainActor in
            do {
                try await Self.markStopped(AppServices.store, id: id, duration: duration, hasAudio: size > 0)
                BackgroundTasks.submitContinued()
            } catch {
                errorMessage = "Recording saved but the queue could not be updated: \(error.localizedDescription)"
            }
        }
    }

    /// Nonisolated so the `inout` closure isn't formed in a main-actor context (it isn't Sendable).
    nonisolated private static func markStopped(
        _ store: MemoStore, id: UUID, duration: Double, hasAudio: Bool
    ) async throws {
        try await store.update(id) { memo in
            memo.durationSec = duration
            if hasAudio {
                memo.state = .recorded
            } else {
                memo.state = .failed
                memo.lastError = "No audio was captured."
            }
        }
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.finishRecording() }
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.finishRecording() }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.finishRecording() }
    }
}
