import MemoKit
import SwiftUI
import UIKit

struct MemoDetailView: View {
    let memoID: UUID
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var recorder = AppServices.recorder
    @State private var memo: Memo?
    @State private var confirmDelete = false
    @State private var deleteError: String?

    var body: some View {
        ScrollView {
            if let memo {
                VStack(alignment: .leading, spacing: 12) {
                    let badge = MemoFormat.badge(memo)
                    HStack {
                        Text("\(memo.recordedAt.formatted(date: .complete, time: .standard))  ·  \(MemoFormat.duration(memo.durationSec))")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Text(badge.text).font(.caption.weight(.semibold)).foregroundStyle(badge.color)
                    }
                    if let reason = memo.waitingReason {
                        Label(reason, systemImage: "clock").font(.callout).foregroundStyle(.orange)
                    }
                    if let error = memo.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red)
                    }
                    if let deleteError {
                        Text(deleteError).font(.callout).foregroundStyle(.red)
                    }
                    if let text = memo.transcript {
                        let shown = text.isEmpty ? MemoFile.noSpeechBody : text
                        Text(shown)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transcriptDirection(shown)
                    } else {
                        Text("No transcript yet.").foregroundStyle(.secondary)
                    }
                }
                .padding()
            } else {
                ProgressView().padding()
            }
        }
        .navigationTitle("Memo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let memo {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = memo.transcript ?? ""
                    }
                    .disabled(memo.transcript == nil)
                    if let text = memo.transcript {
                        ShareLink(item: text.isEmpty ? MemoFile.noSpeechBody : text)
                    }
                    if canRetry(memo) {
                        Button("Retry", systemImage: "arrow.clockwise") {
                            Task { await AppServices.pipeline.retry(memo.id) }
                        }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .disabled(!canDelete(memo))
                }
            }
        }
        .alert("Delete this memo?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let memo, memo.state != .done {
                Text("This memo has not finished uploading. Deleting it also deletes the audio recording, and the text will never reach Drive.")
            } else {
                Text("This removes it from the app. The file already in Drive is not touched.")
            }
        }
        .task {
            while !Task.isCancelled {
                let found = await AppServices.store.all().first { $0.id == memoID }
                if found != memo { memo = found }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Any unfinished memo that isn't being recorded right now (waiting, failed, stuck).
    private func canRetry(_ memo: Memo) -> Bool {
        MemoActions.canRetry(memo, activeID: recorder.activeMemoID)
    }

    private func canDelete(_ memo: Memo) -> Bool {
        memo.id != recorder.activeMemoID && memo.state != .transcribing && memo.state != .uploading
    }

    private func delete() async {
        guard let memo else { return }
        do {
            // Queue entry first: if this throws, nothing is lost. A stray audio file is harmless.
            try await AppServices.store.remove(memo.id)
        } catch {
            deleteError = "Could not delete: \(error.localizedDescription)"
            return
        }
        try? FileManager.default.removeItem(at: AppPaths.audioDir.appendingPathComponent(memo.audioFile))
        dismiss()
    }
}
