import Foundation

public enum ModelDownloadError: Error, Equatable, LocalizedError {
    case httpStatus(Int)
    case wrongSize(expected: Int64, actual: Int64)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let s): return "Model download failed (HTTP \(s))."
        case .wrongSize(let e, let a): return "Model download incomplete (\(a) of \(e) bytes)."
        case .fileSystem(let m): return "Could not save the model: \(m)"
        }
    }
}

@MainActor
public final class ModelManager: ObservableObject {
    @Published public private(set) var progress: [String: Double] = [:]
    public let modelsDir: URL

    public init(modelsDir: URL = AppPaths.modelsDir) {
        self.modelsDir = modelsDir
    }

    public func localURL(_ model: WhisperModel) -> URL {
        modelsDir.appendingPathComponent(model.fileName)
    }

    public func partURL(_ model: WhisperModel) -> URL {
        modelsDir.appendingPathComponent(model.fileName + ".part")
    }

    public func isDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: localURL(model).path)
    }

    public func download(_ model: WhisperModel) async throws {}

    nonisolated static func finalize(
        downloaded: URL, model: WhisperModel, modelsDir: URL, httpStatus: Int?
    ) throws {}
}
