import AVFoundation
import Foundation

/// The queue writes the recorder needs. `MemoStore` conforms; tests wrap it to observe ordering.
public protocol RecordingQueue: Sendable {
    func add(_ memo: Memo) async throws
    /// Marks a memo as finished recording: `recorded` (or `failed` with a reason when no audio
    /// was captured). Returns the updated memo.
    func markStopped(_ id: UUID, durationSec: Double, hasAudio: Bool) async throws -> Memo?
    func remove(_ id: UUID) async throws
}

extension MemoStore: RecordingQueue {
    @discardableResult
    public func markStopped(_ id: UUID, durationSec: Double, hasAudio: Bool) throws -> Memo? {
        try update(id) { memo in
            memo.durationSec = durationSec
            if hasAudio {
                memo.state = .recorded
                memo.lastError = nil
            } else {
                memo.state = .failed
                memo.lastError = "No audio was captured."
            }
        }
        return all().first { $0.id == id }
    }
}

public extension Notification.Name {
    /// Posted on the main thread after a recording ends for any reason (Stop, an interruption
    /// such as a call or Siri, an encoder error) and its final state is persisted.
    /// `userInfo[Recorder.memoIDKey]` is the memo's `UUID`.
    static let memoRecorded = Notification.Name("com.alonk.memo.memoRecorded")
}

/// Records mono 16 kHz AAC (`.m4a`) into `audioDir`, one recording at a time.
///
/// Losing a recording is the worst failure, so the queue is kept consistent at every step:
/// - `activeMemoID` is set *before* the `recording` memo is added, so launch recovery
///   (`MemoStore.recoverInterrupted(excluding:)`) never sees an unprotected in-progress memo;
/// - on stop, the `recorded`/`failed` state is persisted *before* `activeMemoID` clears;
/// - an interruption (phone call, Siri, another app taking the audio session), an encoder
///   error or a media-services reset ends the recording and keeps what was captured.
///
/// A recording that runs for `maxDuration` (30 minutes by default) is stopped through the normal
/// stop path (persisted `recorded`, `.memoRecorded` posted), so a forgotten recording can't grow
/// without bound or outlive what the pipeline can transcribe.
///
/// Microphone permission is the caller's job.
@MainActor
public final class Recorder: NSObject {
    nonisolated public static let memoIDKey = "memoID"
    /// The default recording cap: 30 minutes.
    nonisolated public static let defaultMaxDuration: TimeInterval = 30 * 60

    public private(set) var isRecording = false
    /// The memo being recorded or finalized right now (nil when idle). Processing and UI must
    /// leave it alone.
    public private(set) var activeMemoID: UUID?
    /// When the current recording began (nil when idle).
    public private(set) var startedAt: Date?
    /// The last problem finalizing a recording (the audio file is kept regardless).
    public private(set) var lastError: String?

    public enum RecorderError: Error, LocalizedError {
        case didNotStart
        public var errorDescription: String? { "Recording did not start." }
    }

    private let queue: any RecordingQueue
    private let audioDir: URL
    private let session: AVAudioSession
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var observers: [NSObjectProtocol] = []
    private let maxDuration: TimeInterval
    private var autoStop: Task<Void, Never>?
    /// Becomes `lastError` when the stop in progress finishes (set by the auto-stop).
    private var stopNote: String?

    public static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    /// - Parameter maxDuration: seconds after which a recording stops by itself.
    public init(queue: any RecordingQueue, audioDir: URL, session: AVAudioSession = .sharedInstance(),
                maxDuration: TimeInterval = Recorder.defaultMaxDuration) {
        self.queue = queue
        self.audioDir = audioDir
        self.session = session
        self.maxDuration = maxDuration
    }

    /// Starts recording and returns the new memo's ID (`id`, so a caller can create the Live
    /// Activity for it first). If a recording is already running (or starting, or finalizing),
    /// does nothing and returns that memo's ID.
    public func start(id: UUID = UUID()) async throws -> UUID {
        if let active = activeMemoID { return active }
        lastError = nil
        stopNote = nil

        let now = Date()
        let url = audioDir.appendingPathComponent(
            "memo-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).m4a")
        let memo = Memo(id: id, recordedAt: now, audioFile: url.lastPathComponent, state: .recording)
        // Claim the slot synchronously (no suspension since the check above), so a concurrent
        // start() sees it, and so recovery skips this memo from the moment it exists.
        activeMemoID = memo.id

        let rec: AVAudioRecorder
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            rec = try AVAudioRecorder(url: url, settings: Self.settings)
            rec.delegate = self
        } catch {
            activeMemoID = nil
            deactivateSession()
            throw error
        }

        // Register the memo before capturing so the audio can never be orphaned; if the queue
        // can't be written, don't record at all.
        do {
            try await queue.add(memo)
        } catch {
            activeMemoID = nil
            deactivateSession()
            throw error
        }

        guard rec.record() else {
            try? await queue.remove(memo.id)
            try? FileManager.default.removeItem(at: url)
            activeMemoID = nil
            deactivateSession()
            throw RecorderError.didNotStart
        }
        recorder = rec
        fileURL = url
        startedAt = Date()
        isRecording = true
        observeSession()
        scheduleAutoStop(for: memo.id)
        return memo.id
    }

    /// Stops the current recording, persists its final state and returns the memo. Returns nil
    /// when nothing is recording (or another stop is already finalizing it). Idempotent.
    @discardableResult
    public func stop() async -> Memo? {
        guard let rec = recorder, let id = activeMemoID, let url = fileURL else { return nil }
        recorder = nil
        fileURL = nil
        autoStop?.cancel()
        autoStop = nil
        removeObservers()
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? rec.currentTime
        rec.stop()
        deactivateSession()
        isRecording = false
        startedAt = nil

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var memo: Memo?
        do {
            memo = try await queue.markStopped(id, durationSec: duration, hasAudio: size > 0)
        } catch {
            // The file stays on disk; the memo is still `recording` in the queue, and launch
            // recovery turns it into `recorded` once nothing protects it.
            lastError = "Recording saved but the queue could not be updated: \(error.localizedDescription)"
        }
        if lastError == nil, let note = stopNote { lastError = note }
        stopNote = nil
        // Only now is it safe for recovery/processing to see this memo.
        activeMemoID = nil
        NotificationCenter.default.post(name: .memoRecorded, object: self, userInfo: [Self.memoIDKey: id])
        return memo
    }

    private func scheduleAutoStop(for id: UUID) {
        autoStop?.cancel()
        let limit = maxDuration
        autoStop = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, let self, self.activeMemoID == id, self.isRecording else { return }
            let minutes = Int((limit / 60).rounded())
            // Becomes `lastError` before `.memoRecorded` is posted, so the app shows why the
            // recording ended (the audio is saved and queued as usual).
            self.stopNote = "Recording stopped automatically at the \(minutes)-minute limit. It was saved."
            _ = await self.stop()
        }
    }

    private func deactivateSession() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Interruptions

    private func observeSession() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.stopSoon() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopSoon() }
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func stopSoon() {
        Task { @MainActor in await self.stop() }
    }
}

extension Recorder: AVAudioRecorderDelegate {
    /// The system stopped the recorder (e.g. it lost the session). Finalize what was captured.
    /// Also called after our own `stop()`; the identity check keeps a late callback from an
    /// earlier recorder from stopping a newer recording.
    nonisolated public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let ref = ObjectIdentifier(recorder)
        Task { @MainActor in await self.stop(ifCurrent: ref) }
    }

    nonisolated public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let ref = ObjectIdentifier(recorder)
        Task { @MainActor in await self.stop(ifCurrent: ref) }
    }

    private func stop(ifCurrent ref: ObjectIdentifier) async {
        guard let current = recorder, ObjectIdentifier(current) == ref else { return }
        await stop()
    }
}
