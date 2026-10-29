import AVFoundation
import Foundation
import Testing
@testable import MemoCore

/// Forwards to a real `MemoStore`, and records what the recorder's `activeMemoID` was at the
/// moment each queue write happened (the recovery-safety ordering).
private actor SpyQueue: RecordingQueue {
    let store: MemoStore
    private var probe: (@MainActor @Sendable () -> UUID?)?
    private(set) var activeAtAdd: UUID?
    private(set) var activeAtStop: UUID?
    private(set) var stoppedStateWhileActive: MemoState?

    init(store: MemoStore) { self.store = store }

    func setProbe(_ probe: @escaping @MainActor @Sendable () -> UUID?) { self.probe = probe }

    func add(_ memo: Memo) async throws {
        activeAtAdd = await probe?()
        try await store.add(memo)
    }

    func markStopped(_ id: UUID, durationSec: Double, hasAudio: Bool) async throws -> Memo? {
        let memo = try await store.markStopped(id, durationSec: durationSec, hasAudio: hasAudio)
        // Persisted by now; the recorder must still be protecting this memo.
        activeAtStop = await probe?()
        stoppedStateWhileActive = await store.all().first { $0.id == id }?.state
        return memo
    }

    func remove(_ id: UUID) async throws { try await store.remove(id) }
}

private final class IDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?
    func set(_ id: UUID?) { lock.withLock { value = id } }
    func get() -> UUID? { lock.withLock { value } }
}

/// Uses the real `AVAudioRecorder` (on the simulator it may record silence). Serialized: all
/// tests share the process's `AVAudioSession`.
@Suite(.serialized) @MainActor struct RecorderTests {
    private func env() throws -> (dir: URL, store: MemoStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, MemoStore(file: dir.appendingPathComponent("queue.json"), audioDir: dir))
    }

    private func waitFor(_ timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    @Test func testStartStopCreatesRecordedMemo() async throws {
        let (dir, store) = try env()
        let recorder = Recorder(queue: store, audioDir: dir)

        let id = try await recorder.start()
        #expect(recorder.isRecording)
        #expect(recorder.activeMemoID == id)
        #expect(await store.all().first?.state == .recording)
        try await Task.sleep(for: .milliseconds(700))

        let memo = try #require(await recorder.stop())
        #expect(memo.id == id)
        #expect(memo.state == .recorded)
        #expect(memo.durationSec > 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(memo.audioFile).path))
        #expect(await store.all() == [memo])
        #expect(!recorder.isRecording)
        #expect(recorder.activeMemoID == nil)
        // Persisted, not just in memory.
        let reloaded = MemoStore(file: dir.appendingPathComponent("queue.json"), audioDir: dir)
        #expect(await reloaded.all().first?.state == .recorded)
    }

    @Test func testInterruptionKeepsAudio() async throws {
        let (dir, store) = try env()
        let recorder = Recorder(queue: store, audioDir: dir)
        let notified = IDBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .memoRecorded, object: nil, queue: .main
        ) { note in
            let id = note.userInfo?[Recorder.memoIDKey] as? UUID
            notified.set(id)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let id = try await recorder.start()
        try await Task.sleep(for: .milliseconds(700))
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])

        let finished = await waitFor { await store.all().first?.state == .recorded }
        #expect(finished)
        let memo = try #require(await store.all().first)
        #expect(memo.id == id)
        #expect(memo.durationSec > 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(memo.audioFile).path))
        #expect(await waitFor { recorder.activeMemoID == nil })
        #expect(!recorder.isRecording)
        #expect(notified.get() == id)
        // A later Stop (e.g. from the Live Activity) is harmless.
        #expect(await recorder.stop() == nil)
        #expect(await store.all().first?.state == .recorded)
    }

    /// A recording that reaches the cap stops through the normal path: `recorded`, the
    /// notification posted, the slot freed, and a note saying why.
    @Test func testStopsAtMaxDuration() async throws {
        let (dir, store) = try env()
        let recorder = Recorder(queue: store, audioDir: dir, maxDuration: 1.0)
        let notified = IDBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .memoRecorded, object: recorder, queue: .main
        ) { note in
            notified.set(note.userInfo?[Recorder.memoIDKey] as? UUID)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let id = try await recorder.start()
        #expect(await waitFor { recorder.activeMemoID == nil })
        #expect(!recorder.isRecording)
        #expect(notified.get() == id)
        let memo = try #require(await store.all().first)
        #expect(memo.id == id)
        #expect(memo.state == .recorded)
        #expect(memo.durationSec >= 0.9)
        #expect(recorder.lastError?.contains("limit") == true)
        // The next recording starts clean and is not stopped by the old timer.
        let next = try await recorder.start()
        #expect(recorder.lastError == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.activeMemoID == next)
        _ = await recorder.stop()
    }

    @Test func testStartWhileRecordingIsNoOp() async throws {
        let (dir, store) = try env()
        let recorder = Recorder(queue: store, audioDir: dir)

        async let a = recorder.start()
        async let b = recorder.start()
        let (first, second) = try await (a, b)
        #expect(first == second)
        let third = try await recorder.start()
        #expect(third == first)
        #expect(await store.all().count == 1)
        let audio = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".m4a") }
        #expect(audio.count == 1)

        _ = await recorder.stop()
        #expect(await store.all().count == 1)
    }

    @Test func testStartUsesGivenID() async throws {
        // The app creates the Live Activity for this ID before recording starts.
        let (dir, store) = try env()
        let recorder = Recorder(queue: store, audioDir: dir)
        let wanted = UUID()
        let id = try await recorder.start(id: wanted)
        #expect(id == wanted)
        #expect(await store.all().first?.id == wanted)
        #expect(await recorder.stop()?.id == wanted)
    }

    @Test func testActiveIDSetBeforeMemoAdded() async throws {
        let (dir, store) = try env()
        let spy = SpyQueue(store: store)
        let recorder = Recorder(queue: spy, audioDir: dir)
        await spy.setProbe { recorder.activeMemoID }

        let id = try await recorder.start()
        #expect(await spy.activeAtAdd == id)
        _ = await recorder.stop()
    }

    @Test func testStopPersistsBeforeActiveIDClears() async throws {
        let (dir, store) = try env()
        let spy = SpyQueue(store: store)
        let recorder = Recorder(queue: spy, audioDir: dir)
        await spy.setProbe { recorder.activeMemoID }

        let id = try await recorder.start()
        try await Task.sleep(for: .milliseconds(300))
        _ = await recorder.stop()
        #expect(await spy.activeAtStop == id)
        #expect(await spy.stoppedStateWhileActive == .recorded)
        #expect(recorder.activeMemoID == nil)
    }
}
