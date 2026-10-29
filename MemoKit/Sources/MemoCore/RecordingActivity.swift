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

/// The last recording problem, kept across launches: a widget tap that fails has no UI, so the
/// app shows it in the memo list the next time it opens, until dismissed. Written to the app's
/// own defaults and, when the App Group is available, to the shared defaults too.
public enum RecordingErrorLog {
    public static let key = "lastRecordingError"

    public static var defaultStores: [UserDefaults] {
        [UserDefaults.standard] + (WidgetState.defaults.map { [$0] } ?? [])
    }

    /// The first store that has a message.
    public static func load(from stores: [UserDefaults]? = nil) -> String? {
        for store in stores ?? defaultStores {
            if let message = store.string(forKey: key), !message.isEmpty { return message }
        }
        return nil
    }

    /// nil (or empty) clears it in every store.
    public static func save(_ message: String?, to stores: [UserDefaults]? = nil) {
        for store in stores ?? defaultStores {
            if let message, !message.isEmpty {
                store.set(message, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
    }
}
