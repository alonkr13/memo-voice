import MemoCore
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
    /// Lowercase hex SHA-256 of the complete file, verified before a download is accepted.
    public let sha256: String

    public init(id: String, displayName: String, fileName: String, url: URL, sizeBytes: Int64,
                sha256: String) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256.lowercased()
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
        sizeBytes: 574_041_195,
        sha256: "6c1da92e8e41dd64b8cc402eee7eb7a433d2152567e1a4d9cf181fefcc67a572")

    /// OpenAI multilingual `small` (f16): faster, weaker at Hebrew. Pinned to repo commit
    /// 5359861c; SHA-256 is the LFS oid reported by the Hugging Face API for that commit.
    public static let small = WhisperModel(
        id: "small",
        displayName: "OpenAI small (multilingual)",
        fileName: "ggml-small.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin")!,
        sizeBytes: 487_601_967,
        sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b")

    public static let all: [WhisperModel] = [ivritTurbo, small]

    public static func find(_ id: String) -> WhisperModel? { all.first { $0.id == id } }
}
