import ActivityKit
import Foundation

/// The Live Activity shown while recording (lock screen + Dynamic Island). Requested by the app
/// process (ActivityKit is app-only); rendered by the widget extension. Shared through MemoCore
/// so both targets agree on the type.
public struct RecordingActivity: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// When recording began; the UI shows `Text(timerInterval: startedAt...)`.
        public var startedAt: Date
        public init(startedAt: Date) { self.startedAt = startedAt }
    }

    public var memoID: UUID
    public init(memoID: UUID) { self.memoID = memoID }
}

/// Small shared values the app writes and the widget reads.
public enum WidgetState {
    public static let suiteName = AppPaths.appGroupID
    public static let isRecordingKey = "isRecording"
    public static let widgetKind = "MemoRecord"

    /// The App Group defaults, or nil when the group is unavailable (e.g. stripped by
    /// re-signing): then the widget can't know the state and shows a neutral toggle.
    public static var defaults: UserDefaults? {
        AppPaths.usingAppGroup ? UserDefaults(suiteName: suiteName) : nil
    }

    /// nil = unknown.
    public static var isRecording: Bool? {
        guard let d = defaults, d.object(forKey: isRecordingKey) != nil else { return nil }
        return d.bool(forKey: isRecordingKey)
    }

    public static func setRecording(_ value: Bool) {
        defaults?.set(value, forKey: isRecordingKey)
    }
}
