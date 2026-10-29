import Foundation

/// The Markdown file uploaded for each memo.
public enum MemoFile {
    public static let noSpeechBody = "(no speech detected)"

    /// `yyyy-MM-dd HH-mm-ss.md` in local time of the recording start.
    public static func filename(for memo: Memo, timeZone: TimeZone = .current) -> String {
        formatter("yyyy-MM-dd HH-mm-ss", timeZone).string(from: memo.recordedAt) + ".md"
    }

    /// Front matter (`id, recorded_at, duration_sec, language, model`) plus the transcript.
    /// An empty or whitespace-only transcript becomes `(no speech detected)` so an
    /// accidental tap is still uploaded instead of silently dropped.
    public static func markdown(for memo: Memo, timeZone: TimeZone = .current) -> String {
        let recordedAt = formatter("yyyy-MM-dd'T'HH:mm:ssxxxxx", timeZone).string(from: memo.recordedAt)
        let text = (memo.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.isEmpty ? noSpeechBody : text
        return """
        ---
        id: \(memo.id.uuidString)
        recorded_at: \(recordedAt)
        duration_sec: \(Int(memo.durationSec.rounded()))
        language: \(scalar(memo.language))
        model: \(scalar(memo.model))
        ---

        \(body)

        """
    }

    /// Single-line YAML value; missing values are written as `null`.
    private static func scalar(_ value: String?) -> String {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return "null"
        }
        return v.replacingOccurrences(of: "\n", with: " ")
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }
}
