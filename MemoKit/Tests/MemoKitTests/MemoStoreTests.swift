import Foundation
import Testing
@testable import MemoKit

@Suite struct MemoStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memostore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func testPersistsAcrossInstances() async throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("queue.json")
        let memo = Memo(recordedAt: Date(timeIntervalSince1970: 1_000), durationSec: 12.5,
                        audioFile: "a.m4a", state: .recorded, transcript: "שלום")

        let first = MemoStore(file: file, audioDir: dir)
        await first.add(memo)

        let second = MemoStore(file: file, audioDir: dir)
        #expect(await second.all() == [memo])
    }

    @Test func testUpdatePersists() async throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("queue.json")
        let memo = Memo(audioFile: "a.m4a", state: .recorded)
        let store = MemoStore(file: file, audioDir: dir)
        await store.add(memo)
        await store.update(memo.id) { $0.state = .transcribed; $0.transcript = "hi" }

        let reloaded = await MemoStore(file: file, audioDir: dir).all()
        #expect(reloaded.first?.state == .transcribed)
        #expect(reloaded.first?.transcript == "hi")
    }

    @Test func testRecoverInterrupted() async throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("queue.json")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("has.m4a").path,
                                       contents: Data([1, 2, 3]))

        let transcribing = Memo(audioFile: "t.m4a", state: .transcribing)
        let uploading = Memo(audioFile: "u.m4a", state: .uploading)
        let recordingWithAudio = Memo(audioFile: "has.m4a", state: .recording)
        let recordingNoAudio = Memo(audioFile: "missing.m4a", state: .recording)
        let done = Memo(audioFile: "d.m4a", state: .done)

        let store = MemoStore(file: file, audioDir: dir)
        for m in [transcribing, uploading, recordingWithAudio, recordingNoAudio, done] {
            await store.add(m)
        }
        await store.recoverInterrupted()

        // Recovery must also be persisted.
        let byId = Dictionary(uniqueKeysWithValues:
            await MemoStore(file: file, audioDir: dir).all().map { ($0.id, $0) })
        #expect(byId[transcribing.id]?.state == .recorded)
        #expect(byId[uploading.id]?.state == .transcribed)
        #expect(byId[recordingWithAudio.id]?.state == .recorded)
        #expect(byId[recordingNoAudio.id]?.state == .failed)
        #expect(byId[recordingNoAudio.id]?.lastError?.isEmpty == false)
        #expect(byId[done.id]?.state == .done)
    }

    @Test func testSettingsDefaultsAndRoundTrip() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("settings.json")

        let defaults = AppSettings.load(from: url)
        #expect(defaults.driveFolderPath == "Memos")
        #expect(defaults.modelId == "ivrit-turbo")
        #expect(defaults.language == "he")
        #expect(defaults.uploadAudio == false)
        #expect(defaults.keepAudio == false)

        var changed = defaults
        changed.language = "auto"
        changed.keepAudio = true
        changed.save(to: url)
        #expect(AppSettings.load(from: url) == changed)

        try Data("not json".utf8).write(to: url)
        #expect(AppSettings.load(from: url) == AppSettings())
    }
}
