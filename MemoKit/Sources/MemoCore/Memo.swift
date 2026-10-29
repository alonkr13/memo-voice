import Foundation

public enum MemoState: String, Codable, Sendable {
    case recording, recorded, transcribing, transcribed, uploading, done, failed
}

public struct Memo: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var recordedAt: Date
    public var durationSec: Double
    /// File name relative to the audio directory.
    public var audioFile: String
    public var state: MemoState
    public var transcript: String?
    public var language: String?
    public var model: String?
    public var driveFileId: String?
    public var lastError: String?
    public var waitingReason: String?

    public init(
        id: UUID = UUID(),
        recordedAt: Date = Date(),
        durationSec: Double = 0,
        audioFile: String,
        state: MemoState = .recording,
        transcript: String? = nil,
        language: String? = nil,
        model: String? = nil,
        driveFileId: String? = nil,
        lastError: String? = nil,
        waitingReason: String? = nil
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.durationSec = durationSec
        self.audioFile = audioFile
        self.state = state
        self.transcript = transcript
        self.language = language
        self.model = model
        self.driveFileId = driveFileId
        self.lastError = lastError
        self.waitingReason = waitingReason
    }

    /// Tolerant of missing optional fields (and durationSec) so schema additions don't break loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        durationSec = try c.decodeIfPresent(Double.self, forKey: .durationSec) ?? 0
        audioFile = try c.decode(String.self, forKey: .audioFile)
        state = try c.decode(MemoState.self, forKey: .state)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        driveFileId = try c.decodeIfPresent(String.self, forKey: .driveFileId)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        waitingReason = try c.decodeIfPresent(String.self, forKey: .waitingReason)
    }
}
