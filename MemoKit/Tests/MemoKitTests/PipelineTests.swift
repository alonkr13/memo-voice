import Foundation
import Testing
@testable import MemoKit
@testable import MemoCore

/// Fake Drive: records uploads and models the convenience upload's dedupe (a file already in
/// Drive for the same memo and file kind is returned without a new upload).
private actor FakeDrive: MemoUploading {
    struct Upload: Equatable { let name: String; let mimeType: String; let memoId: UUID; let text: String }
    private(set) var uploads: [Upload] = []
    /// "memoId|ext" → existing Drive file id.
    var existing: [String: String] = [:]
    /// Errors thrown by successive upload attempts (nil = succeed).
    var script: [Error?] = []
    var defaultError: Error?

    func setExisting(_ memoId: UUID, _ ext: String, _ id: String) { existing["\(memoId)|\(ext)"] = id }
    func setScript(_ s: [Error?]) { script = s }
    func setDefaultError(_ e: Error?) { defaultError = e }

    func upload(name: String, data: Data, mimeType: String, folderPath: String, memoId: UUID) async throws -> String {
        let key = "\(memoId)|\((name as NSString).pathExtension)"
        if let id = existing[key] { return id }
        let error: Error? = script.isEmpty ? defaultError : script.removeFirst()
        if let error { throw error }
        let id = "ID-\(uploads.count + 1)"
        uploads.append(Upload(name: name, mimeType: mimeType, memoId: memoId,
                              text: String(decoding: data, as: UTF8.self)))
        existing[key] = id
        return id
    }
}

private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.withLock { _value } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}

private struct FakeTranscriber: Transcribing {
    let handler: @Sendable ([Float], String) async throws -> (text: String, detectedLanguage: String)
    func transcribe(samples: [Float], language: String) async throws -> (text: String, detectedLanguage: String) {
        try await handler(samples, language)
    }
}

/// Reports progress as whisper would, through the progress-aware entry point.
private struct ProgressingTranscriber: Transcribing {
    func transcribe(samples: [Float], language: String) async throws -> (text: String, detectedLanguage: String) {
        try await transcribe(samples: samples, language: language, progress: nil)
    }
    func transcribe(samples: [Float], language: String,
                    progress: (@Sendable (Double) -> Void)?) async throws -> (text: String, detectedLanguage: String) {
        progress?(0.5)
        progress?(1.0)
        return ("x", language)
    }
}

private struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

@Suite struct PipelineTests {
    fileprivate struct Env {
        let dir: URL
        let store: MemoStore
        let drive: FakeDrive
        let calls: Box<[String]>   // languages passed to the transcriber, one per call
        let factoryCalls: Box<[Bool]>   // `background` flag per transcriber creation
        let pipeline: Pipeline

        func audioURL(_ memo: Memo) -> URL { dir.appendingPathComponent(memo.audioFile) }
        func memo(_ id: UUID) async -> Memo? { await store.all().first { $0.id == id } }
    }

    private func makeEnv(
        settings: AppSettings = AppSettings(),
        modelReady: Bool = true,
        transcriber custom: (any Transcribing)? = nil,
        activeRecordingID: @escaping @Sendable () async -> UUID? = { nil },
        transcribe: (@Sendable ([Float], String) async throws -> (text: String, detectedLanguage: String))? = nil
    ) throws -> Env {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MemoStore(file: dir.appendingPathComponent("queue.json"), audioDir: dir)
        let drive = FakeDrive()
        let calls = Box<[String]>([])
        let factoryCalls = Box<[Bool]>([])
        let handler = transcribe ?? { _, lang in ("שלום עולם", lang == "auto" ? "en" : lang) }
        let transcriber: any Transcribing = custom ?? FakeTranscriber { samples, lang in
            calls.mutate { $0.append(lang) }
            return try await handler(samples, lang)
        }
        let pipeline = Pipeline(
            store: store, audioDir: dir,
            transcriber: { _, background in factoryCalls.mutate { $0.append(background) }; return transcriber },
            drive: drive,
            modelReady: { _ in modelReady },
            settings: { settings },
            decode: { _ in [Float](repeating: 0.1, count: 16_000) },
            activeRecordingID: activeRecordingID)
        return Env(dir: dir, store: store, drive: drive, calls: calls,
                   factoryCalls: factoryCalls, pipeline: pipeline)
    }

    @discardableResult
    private func addMemo(_ env: Env, at t: TimeInterval = 1_000, state: MemoState = .recorded,
                         transcript: String? = nil, attempts: Int = 0) async throws -> Memo {
        let memo = Memo(recordedAt: Date(timeIntervalSince1970: t), durationSec: 3,
                        audioFile: "\(UUID().uuidString).m4a", state: state, transcript: transcript,
                        transcribeAttempts: attempts)
        try Data("audio".utf8).write(to: env.audioURL(memo))
        try await env.store.add(memo)
        return memo
    }

    @Test func testRetryRecoversOrphanedTranscribingAfterFirstRun() async throws {
        let env = try makeEnv()
        await env.pipeline.processAll()   // recovery already ran once for this pipeline
        let memo = try await addMemo(env, state: .transcribing)
        await env.pipeline.retry(memo.id)
        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .done)
    }

    @Test func testRetryRecoversOrphanedUploadingAndDedupes() async throws {
        let env = try makeEnv()
        await env.pipeline.processAll()
        let memo = try await addMemo(env, state: .uploading, transcript: "שלום")
        await env.drive.setExisting(memo.id, "md", "EXISTING")
        await env.pipeline.retry(memo.id)
        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .done)
        #expect(m.driveFileId == "EXISTING")
        #expect(await env.drive.uploads.isEmpty)
    }

    @Test func testRecoverInterruptedExcludingLeavesRecordingAlone() async throws {
        let env = try makeEnv()
        let active = try await addMemo(env, state: .recording)
        let orphan = try await addMemo(env, at: 2_000, state: .recording)
        try await env.store.recoverInterrupted(excluding: [active.id])
        #expect(await env.memo(active.id)?.state == .recording)
        #expect(await env.memo(orphan.id)?.state == .recorded)
    }

    /// While a recording is in progress nothing is transcribed (whisper must not run alongside
    /// the recorder); already-transcribed memos still upload. The recording memo is untouched.
    @Test func testProcessAllDuringActiveRecordingDoesNotTranscribe() async throws {
        let probe = try makeEnv()   // only to create a memo id up front
        let recordingMemo = try await addMemo(probe, state: .recording)
        let id = recordingMemo.id
        let active = Box<UUID?>(id)
        let env = try makeEnv(activeRecordingID: { active.value })
        try await env.store.add(recordingMemo)
        try Data("audio".utf8).write(to: env.audioURL(recordingMemo))
        let waiting = try await addMemo(env, at: 500)
        let ready = try await addMemo(env, at: 600, state: .transcribed, transcript: "hi")

        await env.pipeline.processAll()
        #expect(await env.memo(id)?.state == .recording)
        #expect(env.calls.value.isEmpty)
        let w = try #require(await env.memo(waiting.id))
        #expect(w.state == .recorded)
        #expect(w.transcribeAttempts == 0)
        #expect(await env.memo(ready.id)?.state == .done)
        #expect(await env.drive.uploads.map(\.memoId) == [ready.id])
        await env.pipeline.retry(id)
        #expect(await env.memo(id)?.state == .recording)

        // Recording over: the waiting memo is transcribed on the next pass.
        active.mutate { $0 = nil }
        await env.pipeline.processAll()
        #expect(await env.memo(waiting.id)?.state == .done)
        #expect(env.calls.value.count == 1)
    }

    /// A recording that starts mid-transcription stops whisper; the memo goes back to
    /// `recorded` without using up an attempt, and is transcribed after the recording.
    @Test func testRecordingStartPausesTranscription() async throws {
        let active = Box<UUID?>(nil)
        let hold = Box(true)
        let env = try makeEnv(activeRecordingID: { active.value }, transcribe: { _, lang in
            while hold.value { try await Task.sleep(for: .milliseconds(10)) }
            return ("ok", lang)
        })
        let memo = try await addMemo(env)
        let run = Task { await env.pipeline.processAll(background: true) }
        for _ in 0..<300 where await env.memo(memo.id)?.state != .transcribing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await env.memo(memo.id)?.transcribeAttempts == 1)
        active.mutate { $0 = UUID() }       // the recorder claims its slot first...
        await env.pipeline.pauseForRecording()   // ...then the app pauses the pipeline
        await run.value                      // the run ends (nothing else it may do)
        let paused = try #require(await env.memo(memo.id))
        #expect(paused.state == .recorded)
        #expect(paused.transcribeAttempts == 0)
        #expect(paused.lastError == nil)
        #expect(paused.transcript == nil)

        hold.mutate { $0 = false }
        active.mutate { $0 = nil }
        await env.pipeline.processAll()
        let done = try #require(await env.memo(memo.id))
        #expect(done.state == .done)
        #expect(done.transcript == "ok")
        #expect(done.transcribeAttempts == 1)
    }

    @Test func testAttemptsCountedAndThreeStrikesFails() async throws {
        let env = try makeEnv()
        let fresh = try await addMemo(env, at: 1_000)
        let exhausted = try await addMemo(env, at: 2_000, attempts: 3)
        await env.pipeline.processAll()
        #expect(await env.memo(fresh.id)?.transcribeAttempts == 1)
        #expect(await env.memo(fresh.id)?.state == .done)
        let m = try #require(await env.memo(exhausted.id))
        #expect(m.state == .failed)
        #expect(m.lastError == Memo.tooManyAttemptsMessage)
        #expect(env.calls.value.count == 1)   // the exhausted memo wasn't transcribed again
        #expect(FileManager.default.fileExists(atPath: env.audioURL(exhausted).path))
    }

    @Test func testRecoveryFailsMemoLeftTranscribingThreeTimes() async throws {
        let env = try makeEnv()
        let third = try await addMemo(env, at: 1_000, state: .transcribing, attempts: 3)
        let second = try await addMemo(env, at: 2_000, state: .transcribing, attempts: 2)
        await env.pipeline.processAll()
        let t = try #require(await env.memo(third.id))
        #expect(t.state == .failed)
        #expect(t.lastError == Memo.tooManyAttemptsMessage)
        // Two interruptions so far: it gets its third try.
        let s = try #require(await env.memo(second.id))
        #expect(s.state == .done)
        #expect(s.transcribeAttempts == 3)
    }

    @Test func testRetryResetsAttempts() async throws {
        let env = try makeEnv()
        let memo = try await addMemo(env, attempts: 3)
        await env.pipeline.processAll()
        #expect(await env.memo(memo.id)?.state == .failed)
        await env.pipeline.retry(memo.id)
        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .done)
        #expect(m.transcribeAttempts == 1)
        #expect(m.lastError == nil)
    }

    @Test func testCancelledCountsAndFewerAttemptsGoFirst() async throws {
        // An older memo that already ran out of time once goes after a newer untried one.
        let env = try makeEnv()
        let older = try await addMemo(env, at: 1_000, attempts: 1)
        let newer = try await addMemo(env, at: 2_000)
        await env.pipeline.processAll()
        let names = await env.drive.uploads.map(\.name)
        #expect(names == [MemoFile.filename(for: newer), MemoFile.filename(for: older)])
    }

    @Test func testRunsBeforeOrdering() {
        let a = Memo(recordedAt: Date(timeIntervalSince1970: 1), audioFile: "a", transcribeAttempts: 2)
        let b = Memo(recordedAt: Date(timeIntervalSince1970: 9), audioFile: "b", transcribeAttempts: 0)
        let c = Memo(recordedAt: Date(timeIntervalSince1970: 5), audioFile: "c", transcribeAttempts: 0)
        #expect([a, b, c].sorted(by: Pipeline.runsBefore).map(\.audioFile) == ["c", "b", "a"])
    }

    /// A background run taking over from a foreground one is the pipeline's own decision, not an
    /// interruption of the memo: it doesn't use up an attempt.
    @Test func testBackgroundTakeoverDoesNotCountAttempt() async throws {
        let calls = Box(0)
        let env = try makeEnv(transcribe: { _, lang in
            calls.mutate { $0 += 1 }
            if calls.value == 1 { try await Task.sleep(for: .seconds(60)) }
            return ("ok", lang)
        })
        let memo = try await addMemo(env)
        let foreground = Task { await env.pipeline.processAll() }
        for _ in 0..<300 where await env.memo(memo.id)?.state != .transcribing {
            try await Task.sleep(for: .milliseconds(10))
        }
        await env.pipeline.processAll(background: true)
        await foreground.value
        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .done)
        #expect(m.transcribeAttempts == 1)
    }

    @Test func testHappyPath() async throws {
        let env = try makeEnv()
        let memo = try await addMemo(env)
        await env.pipeline.processAll()

        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .done)
        #expect(m.transcript == "שלום עולם")
        #expect(m.language == "he")
        #expect(m.model == WhisperModel.ivritTurbo.tag)
        #expect(m.driveFileId == "ID-1")
        #expect(m.lastError == nil && m.waitingReason == nil)
        let uploads = await env.drive.uploads
        #expect(uploads.count == 1)
        let md = try #require(uploads.first)
        #expect(md.name == MemoFile.filename(for: memo))
        #expect(md.mimeType == "text/markdown")
        #expect(md.text.contains("שלום עולם"))
        #expect(md.text.contains("id: \(memo.id.uuidString)"))
        #expect(!FileManager.default.fileExists(atPath: env.audioURL(memo).path))
    }

    @Test func testKeepsAudioWhenSettingOn() async throws {
        var s = AppSettings(); s.keepAudio = true
        let env = try makeEnv(settings: s)
        let memo = try await addMemo(env)
        await env.pipeline.processAll()
        #expect(await env.memo(memo.id)?.state == .done)
        #expect(FileManager.default.fileExists(atPath: env.audioURL(memo).path))
    }

    @Test func testUploadsAudioWhenSettingOn() async throws {
        var s = AppSettings(); s.uploadAudio = true
        let env = try makeEnv(settings: s)
        let memo = try await addMemo(env)
        await env.pipeline.processAll()

        #expect(await env.memo(memo.id)?.state == .done)
        let uploads = await env.drive.uploads
        #expect(uploads.count == 2)
        let base = String(MemoFile.filename(for: memo).dropLast(3))
        #expect(Set(uploads.map(\.name)) == [base + ".md", base + ".m4a"])
        #expect(uploads.first { $0.name.hasSuffix(".m4a") }?.mimeType == "audio/mp4")
        #expect(uploads.allSatisfy { $0.memoId == memo.id })
    }

    @Test func testUploadFailureKeepsTranscribed() async throws {
        let env = try makeEnv()
        await env.drive.setDefaultError(DriveError.http(500, "server"))
        let memo = try await addMemo(env)
        await env.pipeline.processAll()

        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .transcribed)
        #expect(m.transcript == "שלום עולם")
        #expect(m.lastError?.isEmpty == false)
        #expect(m.waitingReason == nil)
        #expect(FileManager.default.fileExists(atPath: env.audioURL(memo).path))
        #expect(await env.pipeline.hasProcessableWork() == true)

        // Network back: the next run uploads it without transcribing again.
        await env.drive.setDefaultError(nil)
        await env.pipeline.processAll()
        let after = try #require(await env.memo(memo.id))
        #expect(after.state == .done)
        #expect(after.lastError == nil)
        #expect(env.calls.value.count == 1)
    }

    @Test func testNoDuplicateOnRetry() async throws {
        // The .md is already in Drive (an earlier upload whose response was lost).
        let env = try makeEnv()
        let memo = try await addMemo(env, state: .transcribed, transcript: "hi")
        await env.drive.setExisting(memo.id, "md", "EXISTING")
        await env.pipeline.processAll()
        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .done)
        #expect(m.driveFileId == "EXISTING")
        #expect(await env.drive.uploads.isEmpty)
    }

    @Test func testNoDuplicateOnRetryWithAudio() async throws {
        var s = AppSettings(); s.uploadAudio = true
        let env = try makeEnv(settings: s)
        // First attempt: .md succeeds, .m4a fails.
        await env.drive.setScript([nil, DriveError.network(URLError(.networkConnectionLost))])
        let memo = try await addMemo(env)
        await env.pipeline.processAll()
        #expect(await env.memo(memo.id)?.state == .transcribed)

        await env.pipeline.processAll()
        #expect(await env.memo(memo.id)?.state == .done)
        let names = await env.drive.uploads.map(\.name)
        #expect(names.count == 2)
        #expect(names.filter { $0.hasSuffix(".md") }.count == 1)
        #expect(names.filter { $0.hasSuffix(".m4a") }.count == 1)
    }

    @Test func testWaitsForModel() async throws {
        let env = try makeEnv(modelReady: false)
        let memo = try await addMemo(env)
        await env.pipeline.processAll()
        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .recorded)
        #expect(m.waitingReason == "Model not downloaded")
        #expect(m.lastError == nil)
        #expect(env.calls.value.isEmpty)
        // Waiting isn't processable work: a BG task may report success.
        #expect(await env.pipeline.hasProcessableWork() == false)
        #expect(await env.pipeline.pendingCount() == 1)
    }

    @Test func testWaitsForSignIn() async throws {
        let env = try makeEnv()
        await env.drive.setDefaultError(DriveError.notSignedIn)
        let memo = try await addMemo(env)
        await env.pipeline.processAll()
        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .transcribed)
        #expect(m.waitingReason == "Not signed in to Google")
        #expect(m.lastError == nil)
        #expect(FileManager.default.fileExists(atPath: env.audioURL(memo).path))
    }

    @Test func testTranscriptionFailure() async throws {
        let env = try makeEnv(transcribe: { _, _ in throw Boom() })
        let memo = try await addMemo(env)
        await env.pipeline.processAll()
        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .failed)
        #expect(m.lastError == "boom")
        #expect(FileManager.default.fileExists(atPath: env.audioURL(memo).path))
        #expect(await env.drive.uploads.isEmpty)

        // Failed memos are not retried automatically, only via retry(_:).
        await env.pipeline.processAll()
        #expect(env.calls.value.count == 1)
    }

    @Test func testRetryFailed() async throws {
        let attempts = Box(0)
        let env = try makeEnv(transcribe: { _, lang in
            attempts.mutate { $0 += 1 }
            if attempts.value == 1 { throw Boom() }
            return ("ok", lang)
        })
        let memo = try await addMemo(env)
        await env.pipeline.processAll()
        #expect(await env.memo(memo.id)?.state == .failed)
        await env.pipeline.retry(memo.id)
        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .done)
        #expect(m.lastError == nil)
    }

    @Test func testEmptyTranscriptUploads() async throws {
        let env = try makeEnv(transcribe: { _, lang in ("", lang) })
        let memo = try await addMemo(env)
        await env.pipeline.processAll()
        #expect(await env.memo(memo.id)?.state == .done)
        #expect(await env.drive.uploads.first?.text.contains(MemoFile.noSpeechBody) == true)
    }

    @Test func testLanguageChoice() async throws {
        // ivrit is Hebrew-tuned: Auto means Hebrew; Hebrew and English pass through.
        for (setting, expected) in [("auto", "he"), ("he", "he"), ("en", "en")] {
            var s = AppSettings(); s.language = setting
            let env = try makeEnv(settings: s)
            try await addMemo(env)
            await env.pipeline.processAll()
            #expect(env.calls.value == [expected], "setting \(setting)")
        }
        #expect(Pipeline.language(for: .small, setting: "auto") == "auto")
        #expect(Pipeline.language(for: .ivritTurbo, setting: "auto") == "he")

        // small follows the setting and records the detected language.
        var s2 = AppSettings(); s2.language = "auto"; s2.modelId = WhisperModel.small.id
        let env2 = try makeEnv(settings: s2)
        let memo = try await addMemo(env2)
        await env2.pipeline.processAll()
        #expect(env2.calls.value == ["auto"])
        let m = try #require(await env2.memo(memo.id))
        #expect(m.language == "en")
        #expect(m.model == WhisperModel.small.tag)
    }

    @Test func testOldestFirstAndOneTranscriberPerRun() async throws {
        let env = try makeEnv()
        let newer = try await addMemo(env, at: 2_000)
        let older = try await addMemo(env, at: 1_000)
        await env.pipeline.processAll()
        let names = await env.drive.uploads.map(\.name)
        #expect(names == [MemoFile.filename(for: older), MemoFile.filename(for: newer)])
        #expect(env.factoryCalls.value == [false])
    }

    @Test func testBackgroundFlagReachesFactory() async throws {
        let env = try makeEnv()
        try await addMemo(env)
        await env.pipeline.processAll(background: true)
        #expect(env.factoryCalls.value == [true])
    }

    @Test func testRecoversInterruptedOnFirstRun() async throws {
        let env = try makeEnv()
        let stuck = try await addMemo(env, state: .transcribing)
        await env.pipeline.processAll()
        #expect(await env.memo(stuck.id)?.state == .done)
    }

    @Test func testCancelReturnsToRecorded() async throws {
        let env = try makeEnv(transcribe: { _, lang in
            try await Task.sleep(for: .seconds(60))   // throws CancellationError when cancelled
            return ("never", lang)
        })
        let memo = try await addMemo(env)
        let run = Task { await env.pipeline.processAll(background: true) }
        for _ in 0..<200 where await env.memo(memo.id)?.state != .transcribing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await env.memo(memo.id)?.state == .transcribing)
        run.cancel()
        await run.value
        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .recorded)
        #expect(m.lastError == nil)
        #expect(m.transcript == nil)
        // Running out of (background) time counts as an interrupted attempt.
        #expect(m.transcribeAttempts == 1)
        #expect(FileManager.default.fileExists(atPath: env.audioURL(memo).path))
    }

    /// A joiner (e.g. a short background-time pass) that gets cancelled must only stop waiting:
    /// the shared run it joined keeps going and finishes the memo.
    @Test func testCancelledJoinerDoesNotCancelRun() async throws {
        let gate = Box(false)
        let env = try makeEnv(transcribe: { _, lang in
            // Held until the test opens the gate; Task.sleep throws if the run is cancelled.
            while !gate.value { try await Task.sleep(for: .milliseconds(10)) }
            return ("ok", lang)
        })
        let memo = try await addMemo(env)
        let owner = Task { await env.pipeline.processAll(background: true) }
        for _ in 0..<200 where await env.memo(memo.id)?.state != .transcribing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await env.pipeline.isBackgroundRunActive())
        let joiner = Task { await env.pipeline.processAll() }
        try await Task.sleep(for: .milliseconds(50))
        joiner.cancel()
        await joiner.value
        // The joiner returned without waiting for the run to finish...
        #expect(await env.memo(memo.id)?.state == .transcribing)
        // ...and the owner's run was not cancelled: it still completes the memo.
        gate.mutate { $0 = true }
        await owner.value
        let m = try #require(await env.memo(memo.id))
        #expect(m.state == .done)
        #expect(m.transcript == "ok")
        #expect(await env.pipeline.isBackgroundRunActive() == false)
    }

    @Test func testTranscriptionProgressIsForwarded() async throws {
        let env = try makeEnv(transcriber: ProgressingTranscriber())
        try await addMemo(env)
        let seen = Box<[Double]>([])
        await env.pipeline.processAll(background: true) { done, total in
            #expect(total == 1)
            seen.mutate { $0.append(done) }
        }
        let values = seen.value
        #expect(values.first == 0)
        #expect(values.contains { $0 > 0 && $0 < 1 })   // mid-transcription progress
        #expect(values.last == 1)
        #expect(values == values.sorted())              // never goes backwards
    }

    @Test func testSingleFlight() async throws {
        let env = try makeEnv(transcribe: { _, lang in
            try await Task.sleep(for: .milliseconds(100))
            return ("x", lang)
        })
        try await addMemo(env, at: 1_000)
        try await addMemo(env, at: 2_000)
        async let a: Void = env.pipeline.processAll()
        async let b: Void = env.pipeline.processAll()
        _ = await (a, b)
        #expect(env.calls.value.count == 2)
        #expect(await env.drive.uploads.count == 2)
        #expect(await env.store.all().allSatisfy { $0.state == .done })
        #expect(await env.pipeline.pendingCount() == 0)
    }

    @Test func testMemoAddedDuringRunIsProcessed() async throws {
        let envBox = Box<Env?>(nil)
        let added = Box(false)
        let env = try makeEnv(transcribe: { _, lang in
            if !added.value, let env = envBox.value {
                added.mutate { $0 = true }
                let late = Memo(recordedAt: Date(timeIntervalSince1970: 5_000), audioFile: "late.m4a", state: .recorded)
                try Data("a".utf8).write(to: env.audioURL(late))
                try await env.store.add(late)
            }
            return ("x", lang)
        })
        envBox.mutate { $0 = env }
        try await addMemo(env)
        await env.pipeline.processAll()
        #expect(await env.store.all().count == 2)
        #expect(await env.store.all().allSatisfy { $0.state == .done })
    }
}
