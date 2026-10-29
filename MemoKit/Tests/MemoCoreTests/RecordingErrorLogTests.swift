import Foundation
import Testing
@testable import MemoCore

@Suite struct RecordingErrorLogTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "memo-tests-\(UUID().uuidString)"))
    }

    @Test func testPersistsUntilCleared() throws {
        let local = try suite(), shared = try suite()
        RecordingErrorLog.save("Live Activities are turned off", to: [local, shared])
        #expect(local.string(forKey: RecordingErrorLog.key) == "Live Activities are turned off")
        #expect(shared.string(forKey: RecordingErrorLog.key) == "Live Activities are turned off")
        #expect(RecordingErrorLog.load(from: [local, shared]) == "Live Activities are turned off")

        RecordingErrorLog.save(nil, to: [local, shared])
        #expect(RecordingErrorLog.load(from: [local, shared]) == nil)
        #expect(local.object(forKey: RecordingErrorLog.key) == nil)
        #expect(shared.object(forKey: RecordingErrorLog.key) == nil)
    }

    @Test func testLoadFallsBackToLaterStore() throws {
        let local = try suite(), shared = try suite()
        RecordingErrorLog.save("Microphone permission denied", to: [shared])
        #expect(RecordingErrorLog.load(from: [local, shared]) == "Microphone permission denied")
        RecordingErrorLog.save("", to: [local, shared])
        #expect(RecordingErrorLog.load(from: [local, shared]) == nil)
    }
}
