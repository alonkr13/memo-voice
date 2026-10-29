import Foundation

/// A downloadable whisper.cpp ggml model.
public struct WhisperModel: Identifiable, Sendable, Hashable {
    /// Stable id stored in `AppSettings.modelId`.
    public let id: String
    public let displayName: String
    /// File name inside `AppPaths.modelsDir`. Also written as `model:` in memo front matter.
    public let fileName: String
    public let url: URL
    /// Exact size of the complete file; anything else is treated as not downloaded.
    public let sizeBytes: Int64

    public init(id: String, displayName: String, fileName: String, url: URL, sizeBytes: Int64) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.url = url
        self.sizeBytes = sizeBytes
    }

    /// Name recorded in a memo's `model` front-matter field.
    public var tag: String {
        fileName.hasSuffix(".bin") ? String(fileName.dropLast(4)) : fileName
    }

    /// ivrit.ai Hebrew fine-tune of whisper-large-v3-turbo, q5_0. ivrit.ai only publishes the
    /// f16 ggml (1.62 GB); this is `whisper-quantize q5_0` of that exact file (source SHA-256
    /// c8090411…8641b1). The same bytes (SHA-256 6c1da92e…67a572) are published by three
    /// independent uploaders. Pinned to a repo commit so the file cannot change under us.
    public static let ivritTurbo = WhisperModel(
        id: "ivrit-turbo",
        displayName: "ivrit.ai large-v3-turbo (Hebrew, q5_0)",
        fileName: "ivrit-whisper-large-v3-turbo-q5_0.bin",
        url: URL(string: "https://huggingface.co/tagidu/ivrit-whisper-large-v3-turbo-ggml-quantized/resolve/540d7736f31952a65efbdff0dc41e2b4b086a197/ggml-ivrit-large-v3-turbo-q5_0.bin")!,
        sizeBytes: 574_041_195)

    /// OpenAI multilingual `small` (f16): faster, weaker at Hebrew.
    public static let small = WhisperModel(
        id: "small",
        displayName: "OpenAI small (multilingual)",
        fileName: "ggml-small.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
        sizeBytes: 487_601_967)

    public static let all: [WhisperModel] = [ivritTurbo, small]

    public static func find(_ id: String) -> WhisperModel? { all.first { $0.id == id } }
}
