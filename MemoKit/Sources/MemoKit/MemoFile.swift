import Foundation

/// The Markdown file uploaded for each memo.
public enum MemoFile {
    public static func filename(for memo: Memo, timeZone: TimeZone = .current) -> String {
        ""
    }

    public static func markdown(for memo: Memo, timeZone: TimeZone = .current) -> String {
        ""
    }
}
