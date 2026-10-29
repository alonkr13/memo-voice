import MemoKit
import SwiftUI

/// Recent memos with status, plus the Record/Stop button.
/// Refresh strategy: the store has no change notifications, so the view polls it once a second
/// while visible (cheap: an in-memory actor read), and reloads on appear and pull-to-refresh.
struct MemoListView: View {
    @ObservedObject private var recorder = AppServices.recorder
    @State private var memos: [Memo] = []
    @State private var warning: String?

    var body: some View {
        List {
            if let warning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            if let message = recorder.errorMessage {
                Section {
                    Label(message, systemImage: "mic.slash.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                    Button("Dismiss") { recorder.errorMessage = nil }
                        .font(.callout)
                }
            }
            if memos.isEmpty {
                Section {
                    Text("No memos yet. Tap Record, or use the widget.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(memos) { memo in
                NavigationLink(value: memo.id) { MemoRow(memo: memo) }
                    .swipeActions(edge: .trailing) {
                        if MemoActions.canRetry(memo, activeID: recorder.activeMemoID) {
                            Button("Retry") { Task { await AppServices.pipeline.retry(memo.id) } }
                                .tint(.orange)
                        }
                    }
            }
        }
        .navigationTitle("Memos")
        .navigationDestination(for: UUID.self) { MemoDetailView(memoID: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .refreshable {
            await AppServices.pipeline.processAll()
            await reload()
        }
        .safeAreaInset(edge: .bottom) { recordButton }
        .task {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var recordButton: some View {
        Button {
            Task { await recorder.toggle() }
        } label: {
            Label(recorder.isRecording ? "Stop  \(MemoFormat.duration(recorder.elapsed))" : "Record",
                  systemImage: recorder.isRecording ? "stop.fill" : "mic.fill")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .disabled(recorder.isStarting)
        .tint(recorder.isRecording ? .gray : .red)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func reload() async {
        let store = AppServices.store
        let all = await store.all().sorted { $0.recordedAt > $1.recordedAt }
        if all != memos { memos = all }
        var text: String?
        if await store.writesBlocked {
            text = "The memo queue file is damaged and could not be backed up, so nothing can be saved. Recordings are not being queued."
        } else if let backup = await store.recoveredFromCorruptQueue {
            text = "Some saved memos could not be read. A copy of the original queue was kept as \(backup.lastPathComponent)."
        }
        if text != warning { warning = text }
    }
}

private struct MemoRow: View {
    let memo: Memo

    var body: some View {
        let badge = MemoFormat.badge(memo)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(memo.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.medium))
                Text(MemoFormat.duration(memo.durationSec))
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(badge.text)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(badge.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(badge.color)
            }
            if let reason = memo.waitingReason {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }
            if let error = memo.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let first = firstLine {
                Text(first)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transcriptDirection(first)
            }
        }
        .padding(.vertical, 2)
    }

    private var firstLine: String? {
        guard let text = memo.transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        if text.isEmpty { return memo.state == .done ? MemoFile.noSpeechBody : nil }
        return text.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
