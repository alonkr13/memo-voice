import MemoKit
import SwiftUI

extension String {
    /// True when the first letter is Hebrew or Arabic, so a transcript can be laid out RTL
    /// regardless of the UI language.
    var startsRightToLeft: Bool {
        for scalar in unicodeScalars where scalar.properties.isAlphabetic {
            return (0x0590...0x08FF).contains(scalar.value)
        }
        return false
    }
}

extension View {
    /// Natural reading direction for spoken text.
    func transcriptDirection(_ text: String) -> some View {
        environment(\.layoutDirection, text.startsRightToLeft ? .rightToLeft : .leftToRight)
    }
}

enum MemoFormat {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func badge(_ memo: Memo) -> (text: String, color: Color) {
        switch memo.state {
        case .recording: return ("Recording", .red)
        case .recorded: return (memo.waitingReason == nil ? "Queued" : "Waiting", .orange)
        case .transcribing: return ("Transcribing", .blue)
        case .transcribed: return (memo.waitingReason == nil ? "Uploading" : "Waiting", .orange)
        case .uploading: return ("Uploading", .blue)
        case .done: return ("Uploaded", .green)
        case .failed: return ("Failed", .red)
        }
    }
}

enum MemoActions {
    /// Retry is offered for every unfinished memo except the one being recorded right now.
    static func canRetry(_ memo: Memo, activeID: UUID?) -> Bool {
        memo.state != .done && memo.id != activeID
    }
}
