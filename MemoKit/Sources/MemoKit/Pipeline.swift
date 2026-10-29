import Foundation

/// The Drive operation the pipeline needs. `DriveClient`'s convenience upload already dedupes
/// (a file for the same memo and file kind is returned instead of uploaded again).
public protocol MemoUploading: Sendable {
    func upload(name: String, data: Data, mimeType: String, folderPath: String, memoId: UUID) async throws -> String
}

extension DriveClient: MemoUploading {}

/// Takes memos from `recorded` to `done`: transcribe → upload Markdown (and optionally audio) →
/// delete local audio. One memo at a time, oldest first; every state change is saved before the
/// next step starts, so a kill or cancellation at any point is resumable.
///
/// Runs are single-flight: a `processAll()` while another run is active asks that run to look
/// again and waits for it, so only one transcriber is ever loaded.
public actor Pipeline {
    /// Creates the transcriber for a run. `background` is true when running from a background
    /// task, where iOS forbids Metal work, so the caller should create a CPU-only transcriber.
    public typealias TranscriberFactory = @Sendable (_ model: WhisperModel, _ background: Bool) -> any Transcribing
    /// Called with the memos finished in this run (fractional: the current memo's transcription
    /// progress is included) and the number of memos seen so far.
    public typealias ProgressHandler = @Sendable (_ completed: Double, _ total: Int) -> Void

    public static let waitingForModel = "Model not downloaded"
    public static let waitingForSignIn = "Not signed in to Google"

    private let store: MemoStore
    private let audioDir: URL
    private let makeTranscriber: TranscriberFactory
    private let drive: any MemoUploading
    private let modelReady: @Sendable (WhisperModel) async -> Bool
    private let settings: @Sendable () -> AppSettings
    private let decode: @Sendable (URL) throws -> [Float]

    private var current: Task<Void, Never>?
    private var currentIsBackground = false
    private var rerunRequested = false
    private var progressHandler: ProgressHandler?
    private var recovered = false
    /// Callers that joined the current run and are waiting for it to end.
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(
        store: MemoStore,
        audioDir: URL,
        transcriber: @escaping TranscriberFactory,
        drive: any MemoUploading,
        modelReady: @escaping @Sendable (WhisperModel) async -> Bool,
        settings: @escaping @Sendable () -> AppSettings,
        decode: @escaping @Sendable (URL) throws -> [Float] = { try AudioDecoder.pcm16kMono(from: $0) }
    ) {
        self.store = store
        self.audioDir = audioDir
        self.makeTranscriber = transcriber
        self.drive = drive
        self.modelReady = modelReady
        self.settings = settings
        self.decode = decode
    }

    // MARK: - Public API

    /// Processes every `recorded` / `transcribed` memo, including ones added while running, and
    /// returns when nothing is left to do. Cancelling the calling task stops the run promptly
    /// (whisper is aborted); the memo in progress returns to its previous retryable state.
    ///
    /// - Parameter background: true from a BG task (CPU-only transcription). A background call
    ///   that arrives during a foreground run cancels that run and takes over, because the
    ///   foreground run's GPU work would fail once the app is in the background.
    public func processAll(background: Bool = false, progress: ProgressHandler? = nil) async {
        while let running = current {
            if background && !currentIsBackground {
                running.cancel()
                await running.value
                continue   // another caller may have started a run meanwhile
            }
            if let progress { progressHandler = progress }
            rerunRequested = true
            // A joiner doesn't own the run: if it is cancelled it just stops waiting. Only the
            // owner (or a background takeover) may cancel the shared run.
            await waitForCurrentRun()
            return
        }
        let task = Task { await self.run(background: background) }
        current = task
        currentIsBackground = background
        progressHandler = progress
        rerunRequested = false
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// True while a background (BG task) run is active.
    public func isBackgroundRunActive() -> Bool {
        current != nil && currentIsBackground
    }

    /// Memos a run would act on now: pending and not waiting for the model or a sign-in.
    /// (Upload errors such as offline count: they are retried.)
    public func hasProcessableWork() async -> Bool {
        await store.all().contains { Self.isPending($0.state) && $0.waitingReason == nil }
    }

    /// Puts a failed memo (or one with an upload error) back in the queue and processes it.
    public func retry(_ id: UUID) async {
        try? await store.update(id) { memo in
            if memo.state == .failed {
                memo.state = memo.transcript == nil ? .recorded : .transcribed
            }
            memo.lastError = nil
        }
        await processAll()
    }

    /// Memos still waiting to be transcribed or uploaded.
    public func pendingCount() async -> Int {
        await store.all().filter { Self.isPending($0.state) }.count
    }

    // MARK: - Run

    private static func isPending(_ state: MemoState) -> Bool {
        state == .recorded || state == .transcribed
    }

    private enum Outcome { case finished, waiting, cancelled, storeFailed }

    private enum UploadBlock { case signedOut, offline(String) }

    private struct RunState {
        var transcriber: (id: String, instance: any Transcribing)?
        /// Set when uploads can't succeed in this pass (signed out / offline): skip the rest.
        var uploadBlock: UploadBlock?
    }

    private func run(background: Bool) async {
        await runLoop(background: background)
        // No suspension point between the loop's last look at `rerunRequested` and this, so a
        // caller either joined this run (and was served) or finds `current == nil` and starts one.
        current = nil
        progressHandler = nil
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values { cont.resume() }
    }

    /// Waits until the current run ends, or until the calling task is cancelled.
    private func waitForCurrentRun() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if current == nil || Task.isCancelled { cont.resume(); return }
                waiters[id] = cont
            }
        } onCancel: {
            Task { await self.stopWaiting(id) }
        }
    }

    private func stopWaiting(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    private func runLoop(background: Bool) async {
        if await store.writesBlocked { return }
        if !recovered {
            // Only memos left by a previous process can be stuck mid-step: this pipeline is the
            // only writer of `transcribing` / `uploading`, and runs are single-flight.
            do { try await store.recoverInterrupted() } catch { return }
            recovered = true
        }
        var state = RunState()
        var attempted = Set<UUID>()
        var completed = 0
        while !Task.isCancelled {
            if rerunRequested {
                rerunRequested = false
                attempted.removeAll()
                state.uploadBlock = nil
            }
            let queue = await store.all()
                .filter { Self.isPending($0.state) && !attempted.contains($0.id) }
                .sorted { $0.recordedAt < $1.recordedAt }
            guard let memo = queue.first else {
                if rerunRequested && !Task.isCancelled { continue }
                break
            }
            attempted.insert(memo.id)
            let base = Double(completed)
            let total = completed + queue.count
            let handler = progressHandler
            handler?(base, total)
            // Transcription is most of a memo's work: it fills 90 % of the memo's share.
            let report: @Sendable (Double) -> Void = { fraction in
                handler?(base + 0.9 * min(max(fraction, 0), 1), total)
            }

            let outcome = await process(memo, background: background, state: &state, report: report)
            if outcome == .cancelled || outcome == .storeFailed { break }
            completed += 1
        }
        progressHandler?(Double(completed), completed)
    }

    private func process(_ memo: Memo, background: Bool, state: inout RunState,
                         report: @escaping @Sendable (Double) -> Void) async -> Outcome {
        var memo = memo
        if memo.state == .recorded {
            let outcome = await transcribe(&memo, background: background, state: &state, report: report)
            guard outcome == .finished else { return outcome }
        }
        guard memo.state == .transcribed else { return .finished }
        return await upload(memo, state: &state)
    }

    private func transcribe(_ memo: inout Memo, background: Bool, state: inout RunState,
                            report: @escaping @Sendable (Double) -> Void) async -> Outcome {
        let settings = settings()
        let model = WhisperModel.find(settings.modelId) ?? .ivritTurbo
        do {
            guard await modelReady(model) else {
                try await setWaiting(memo, Self.waitingForModel)
                return .waiting
            }
            try await store.update(memo.id) {
                $0.state = .transcribing
                $0.waitingReason = nil
                $0.lastError = nil
            }
        } catch {
            return .storeFailed
        }

        do {
            let audio = audioDir.appendingPathComponent(memo.audioFile)
            let samples = try decode(audio)
            try Task.checkCancellation()
            let transcriber: any Transcribing
            if let cached = state.transcriber, cached.id == model.id {
                transcriber = cached.instance
            } else {
                state.transcriber = nil   // release the previous model before loading another
                transcriber = makeTranscriber(model, background)
                state.transcriber = (model.id, transcriber)
            }
            // The ivrit model is Hebrew-tuned; other models follow the language setting.
            let language = model.id == WhisperModel.ivritTurbo.id ? "he" : settings.language
            let result = try await transcriber.transcribe(
                samples: samples, language: language, progress: report)
            try await store.update(memo.id) {
                $0.state = .transcribed
                $0.transcript = result.text
                $0.language = result.detectedLanguage
                $0.model = model.tag
                $0.lastError = nil
            }
            memo.state = .transcribed
            memo.transcript = result.text
            memo.language = result.detectedLanguage
            memo.model = model.tag
            return .finished
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            do {
                try await store.update(memo.id) {
                    if cancelled {
                        $0.state = .recorded
                    } else {
                        $0.state = .failed
                        $0.lastError = Self.describe(error)
                    }
                }
            } catch {
                return .storeFailed
            }
            return cancelled ? .cancelled : .finished
        }
    }

    private func upload(_ memo: Memo, state: inout RunState) async -> Outcome {
        let settings = settings()
        do {
            switch state.uploadBlock {
            case .signedOut:
                try await setWaiting(memo, Self.waitingForSignIn)
                return .waiting
            case .offline(let message):
                // Don't hammer a dead network; show why and retry on the next run.
                try await store.update(memo.id) { $0.lastError = message; $0.waitingReason = nil }
                return .waiting
            case nil:
                break
            }
            try await store.update(memo.id) { $0.state = .uploading }
        } catch {
            return .storeFailed
        }

        let markdownName = MemoFile.filename(for: memo)
        let baseName = String(markdownName.dropLast(".md".count))
        let audio = audioDir.appendingPathComponent(memo.audioFile)
        do {
            let fileId = try await drive.upload(
                name: markdownName, data: Data(MemoFile.markdown(for: memo).utf8),
                mimeType: "text/markdown", folderPath: settings.driveFolderPath, memoId: memo.id)
            if settings.uploadAudio, FileManager.default.fileExists(atPath: audio.path) {
                let data = try Data(contentsOf: audio, options: .mappedIfSafe)
                _ = try await drive.upload(
                    name: baseName + ".m4a", data: data, mimeType: "audio/mp4",
                    folderPath: settings.driveFolderPath, memoId: memo.id)
            }
            try await store.update(memo.id) {
                $0.state = .done
                $0.driveFileId = fileId
                $0.lastError = nil
                $0.waitingReason = nil
            }
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            let signedOut: Bool = if case DriveError.notSignedIn = error { true } else { false }
            if signedOut {
                state.uploadBlock = .signedOut
            } else if !cancelled && Self.isNetwork(error) {
                state.uploadBlock = .offline(Self.describe(error))
            }
            do {
                try await store.update(memo.id) {
                    $0.state = .transcribed
                    if cancelled { return }
                    if signedOut {
                        $0.waitingReason = Self.waitingForSignIn
                        $0.lastError = nil
                    } else {
                        $0.waitingReason = nil
                        $0.lastError = Self.describe(error)
                    }
                }
            } catch {
                return .storeFailed
            }
            return cancelled ? .cancelled : (signedOut ? .waiting : .finished)
        }

        // Audio is only ever deleted once the memo is done.
        if !settings.keepAudio {
            try? FileManager.default.removeItem(at: audio)
        }
        return .finished
    }

    private func setWaiting(_ memo: Memo, _ reason: String) async throws {
        guard memo.waitingReason != reason || memo.lastError != nil else { return }
        try await store.update(memo.id) {
            $0.waitingReason = reason
            $0.lastError = nil
        }
    }

    private static func isNetwork(_ error: Error) -> Bool {
        if case DriveError.network = error { return true }
        return error is URLError
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
