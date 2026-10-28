import Foundation

/// Locations of shared files. Uses the App Group container when available
/// (so the app and widget share data); otherwise falls back to the app's own
/// Application Support directory (e.g. when a sideloader strips the group).
public struct AppPaths: Sendable {
    public static let appGroupID = "group.com.alonk.memo"

    public static let shared = AppPaths()

    public let groupID: String
    public let container: URL
    public let usingAppGroup: Bool

    public init(groupID: String = AppPaths.appGroupID) {
        self.groupID = groupID
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            container = group
            usingAppGroup = true
        } else {
            let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true))
                ?? fm.temporaryDirectory
            container = base
            usingAppGroup = false
        }
    }

    /// Recorded audio. Created on access.
    public var audioDir: URL { Self.ensureDirectory(container.appendingPathComponent("Audio", isDirectory: true)) }

    /// Downloaded Whisper models. Created on access.
    public var modelsDir: URL { Self.ensureDirectory(container.appendingPathComponent("Models", isDirectory: true)) }

    /// JSON queue of memos.
    public var queueFile: URL { container.appendingPathComponent("queue.json") }

    // Convenience accessors on the shared instance.
    public static var container: URL { shared.container }
    public static var audioDir: URL { shared.audioDir }
    public static var modelsDir: URL { shared.modelsDir }
    public static var queueFile: URL { shared.queueFile }
    public static var usingAppGroup: Bool { shared.usingAppGroup }

    private static func ensureDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
