import Foundation
import Testing
@testable import MemoKit

@Suite struct MemoFileTests {
    private let jerusalem = TimeZone(identifier: "Asia/Jerusalem")!

    /// 2026-10-29 07:42:13 local time in Asia/Jerusalem (UTC+2 after DST ended on Oct 25).
    private func recordedAt() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jerusalem
        return cal.date(from: DateComponents(year: 2026, month: 10, day: 29,
                                             hour: 7, minute: 42, second: 13))!
    }

    private func memo(transcript: String?) -> Memo {
        Memo(id: UUID(uuidString: "3F2A1C9E-8B7D-4E6F-9A0B-1C2D3E4F5A6B")!,
             recordedAt: recordedAt(), durationSec: 94.4, audioFile: "a.m4a",
             state: .transcribed, transcript: transcript, language: "he",
             model: "ivrit-whisper-large-v3-turbo-q5_0")
    }

    @Test func testFilename() {
        #expect(MemoFile.filename(for: memo(transcript: "x"), timeZone: jerusalem)
                == "2026-10-29 07-42-13.md")
    }

    @Test func testMarkdown() throws {
        let md = MemoFile.markdown(for: memo(transcript: "שלום עולם\n"), timeZone: jerusalem)
        let expected = """
        ---
        id: 3F2A1C9E-8B7D-4E6F-9A0B-1C2D3E4F5A6B
        recorded_at: 2026-10-29T07:42:13+02:00
        duration_sec: 94
        language: he
        model: ivrit-whisper-large-v3-turbo-q5_0
        ---

        שלום עולם

        """
        #expect(md == expected)

        // Front matter keys, exactly and in order.
        let lines = md.components(separatedBy: "\n")
        let keys = lines[1..<6].map { String($0.split(separator: ":", maxSplits: 1)[0]) }
        #expect(keys == ["id", "recorded_at", "duration_sec", "language", "model"])
    }

    @Test(arguments: [nil, "", "   ", " \n\t \n"])
    func testEmptyTranscript(_ transcript: String?) {
        let md = MemoFile.markdown(for: memo(transcript: transcript), timeZone: jerusalem)
        #expect(md.hasSuffix("---\n\n(no speech detected)\n"))
    }
}
