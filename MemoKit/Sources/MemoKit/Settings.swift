import Foundation

public struct AppSettings: Codable, Sendable, Equatable {
    public var driveFolderPath: String = "Memos"
    public var modelId: String = "ivrit-turbo"
    /// `he`, `en` or `auto`.
    public var language: String = "he"
    public var uploadAudio: Bool = false
    public var keepAudio: Bool = false

    public init() {}

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
