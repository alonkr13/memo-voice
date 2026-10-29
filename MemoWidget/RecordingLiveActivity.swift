import ActivityKit
import AppIntents
import MemoCore
import SwiftUI
import WidgetKit

/// Lock screen + Dynamic Island while recording: elapsed time and a Stop button. The app starts
/// and ends the activity; the button runs `ToggleRecordingIntent(action: .stop)` in the app.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivity.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording").font(.headline)
                    ElapsedText(startedAt: context.state.startedAt).font(.title3)
                }
                Spacer()
                StopButton()
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Recording", systemImage: "mic.fill")
                        .foregroundStyle(.red)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(startedAt: context.state.startedAt)
                        .font(.title3)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StopButton()
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            } compactTrailing: {
                ElapsedText(startedAt: context.state.startedAt)
                    .frame(maxWidth: 48)
            } minimal: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            }
            .keylineTint(.red)
        }
    }
}

private struct ElapsedText: View {
    let startedAt: Date
    var body: some View {
        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
            .monospacedDigit()
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: ToggleRecordingIntent(action: .stop)) {
            Label("Stop", systemImage: "stop.fill")
                .font(.headline)
        }
        .tint(.red)
    }
}
