import Foundation

public struct AppSettings: Codable, Sendable, Equatable {
    public var driveFolderPath: String = "Memos"
    public var modelId: String = "ivrit-turbo"
    /// `he`, `en` or `auto`.
    public var language: String = "he"
    public var uploadAudio: Bool = false
    public var keepAudio: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case driveFolderPath, modelId, language, uploadAudio, keepAudio
    }

    /// Tolerates missing keys so settings saved by older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        driveFolderPath = try c.decodeIfPresent(String.self, forKey: .driveFolderPath) ?? d.driveFolderPath
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId) ?? d.modelId
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        uploadAudio = try c.decodeIfPresent(Bool.self, forKey: .uploadAudio) ?? d.uploadAudio
        keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? d.keepAudio
    }

    public static var fileURL: URL { AppPaths.container.appendingPathComponent("settings.json") }

    /// Missing or corrupt file yields defaults.
    public static func load(from url: URL = AppSettings.fileURL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(to url: URL = AppSettings.fileURL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
