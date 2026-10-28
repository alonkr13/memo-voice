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
        try await first.add(memo)

        let second = MemoStore(file: file, audioDir: dir)
        #expect(await second.all() == [memo])
    }

    @Test func testUpdatePersists() async throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("queue.json")
        let memo = Memo(audioFile: "a.m4a", state: .recorded)
        let store = MemoStore(file: file, audioDir: dir)
        try await store.add(memo)
        try await store.update(memo.id) { $0.state = .transcribed; $0.transcript = "hi" }

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
            try await store.add(m)
        }
        try await store.recoverInterrupted()

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

    @Test func testCorruptQueueIsBackedUpNotOverwritten() async throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("queue.json")
        let garbage = Data("{{ not json".utf8)
        try garbage.write(to: file)

        let store = MemoStore(file: file, audioDir: dir)
        #expect(await store.all().isEmpty)
        let backup = try #require(await store.recoveredFromCorruptQueue)
        let memo = Memo(audioFile: "a.m4a", state: .recorded)
        try await store.add(memo)

        #expect(try Data(contentsOf: backup) == garbage)
        #expect(await MemoStore(file: file, audioDir: dir).all() == [memo])
    }

    @Test func testDecodesMemoWithMissingOptionalFields() async throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("queue.json")
        let id = UUID()
        let json = #"[{"id":"\#(id.uuidString)","recordedAt":0,"audioFile":"a.m4a","state":"recorded"}]"#
        try Data(json.utf8).write(to: file)
        let store = MemoStore(file: file, audioDir: dir)
        #expect(await store.all().first?.id == id)
        #expect(await store.recoveredFromCorruptQueue == nil)
    }

    @Test func testAddThrowsWhenFileNotWritable() async throws {
        let dir = try tempDir()
        let blocker = dir.appendingPathComponent("blocker")
        try Data([0]).write(to: blocker)
        let store = MemoStore(file: blocker.appendingPathComponent("queue.json"), audioDir: dir)
        await #expect(throws: (any Error).self) {
            try await store.add(Memo(audioFile: "a.m4a"))
        }
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
