import Foundation

/// The Drive operation the pipeline needs. `DriveClient`'s convenience upload already dedupes
/// (a file for the same memo and file kind is returned instead of uploaded again).
public protocol MemoUploading: Sendable {
    func upload(name: String, data: Data, mimeType: String, folderPath: String, memoId: UUID) async throws -> String
}

extension DriveClient: MemoUploading {}

public actor Pipeline {
    public typealias TranscriberFactory = @Sendable (_ model: WhisperModel, _ background: Bool) -> any Transcribing
    public typealias ProgressHandler = @Sendable (_ completed: Int, _ total: Int) -> Void

    public init(
        store: MemoStore,
        audioDir: URL,
        transcriber: @escaping TranscriberFactory,
        drive: any MemoUploading,
        modelReady: @escaping @Sendable (WhisperModel) async -> Bool,
        settings: @escaping @Sendable () -> AppSettings,
        decode: @escaping @Sendable (URL) throws -> [Float] = { try AudioDecoder.pcm16kMono(from: $0) }
    ) {}

    public func processAll(background: Bool = false, progress: ProgressHandler? = nil) async {}

    public func retry(_ id: UUID) async {}

    public func pendingCount() async -> Int { 0 }
}
