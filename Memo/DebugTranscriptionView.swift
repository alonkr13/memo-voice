import AVFoundation
import MemoKit
import SwiftUI
import UIKit
import os

/// Debug-only screen for the Whisper spike: download a model, record a test clip, transcribe
/// the latest audio and show time, memory and the text.
struct DebugTranscriptionView: View {
    @ObservedObject private var models = ModelManager.shared
    @StateObject private var vm = DebugTranscriptionModel()

    var body: some View {
        Form {
            modelSection
            Section("Language") {
                Picker("Language", selection: $vm.language) {
                    Text("Hebrew").tag("he")
                    Text("English").tag("en")
                    Text("Auto").tag("auto")
                }
                .pickerStyle(.segmented)
            }
            audioSection
            resultSection
        }
        .navigationTitle("Transcription test")
        .task { await vm.refreshLastAudio() }
        .onChange(of: vm.modelId) { vm.dropTranscriber() }
    }

    private var selectedModel: WhisperModel { WhisperModel.find(vm.modelId) ?? .ivritTurbo }

    private var modelSection: some View {
        Section {
            Picker("Model", selection: $vm.modelId) {
                ForEach(WhisperModel.all) { Text($0.displayName).tag($0.id) }
            }
            let model = selectedModel
            if let fraction = models.progress[model.id] {
                ProgressView(value: fraction) {
                    Text("Downloading… \(Int(fraction * 100))% of \(Self.mb(model.sizeBytes))")
                }
            } else if models.isDownloaded(model) {
                LabeledContent("Status", value: "Downloaded (\(Self.mb(model.sizeBytes)))")
                Button("Delete model", role: .destructive) {
                    vm.dropTranscriber()
                    models.delete(model)
                }
            } else {
                Button("Download (\(Self.mb(model.sizeBytes)), Wi-Fi)") {
                    Task {
                        do { try await models.download(model) } catch { vm.status = error.localizedDescription }
                    }
                }
            }
            if let error = models.errors[model.id] {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        } header: {
            Text("Model")
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            LabeledContent("Last audio", value: vm.lastAudio?.lastPathComponent ?? "none")
            if vm.isRecording {
                Button("Stop recording (\(Int(vm.recordingRemaining)) s left)") { vm.stopRecording() }
            } else {
                Button("Record 30 s test clip") { Task { await vm.recordTestClip() } }
                    .disabled(vm.running)
            }
            Button(vm.running ? "Transcribing…" : "Transcribe last memo") {
                Task { await vm.transcribeLast(model: selectedModel, manager: models) }
            }
            .disabled(vm.running || vm.isRecording || vm.lastAudio == nil
                      || !models.isDownloaded(selectedModel))
            if !vm.status.isEmpty {
                Text(vm.status).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var resultSection: some View {
        if let r = vm.result {
            Section("Result") {
                LabeledContent("Model", value: r.modelTag)
                LabeledContent("Audio length", value: String(format: "%.1f s", r.audioSec))
                LabeledContent("Decode", value: String(format: "%.1f s", r.decodeSec))
                LabeledContent("Model load", value: String(format: "%.1f s", r.loadSec))
                LabeledContent("Transcribe", value: String(format: "%.1f s", r.transcribeSec))
                LabeledContent("Speed", value: String(format: "%.2f× real time",
                                                      r.audioSec / max(r.transcribeSec, 0.001)))
                LabeledContent("Available mem at start", value: Self.mb(r.availableAtStart))
                LabeledContent("Min available mem", value: Self.mb(r.minAvailable))
                LabeledContent("Peak extra memory", value: Self.mb(r.availableAtStart - r.minAvailable))
                LabeledContent("Detected language", value: r.detectedLanguage)
                Text(r.text.isEmpty ? MemoFile.noSpeechBody : r.text)
                    .textSelection(.enabled)
                    .multilineTextAlignment(r.detectedLanguage == "he" ? .trailing : .leading)
                    .frame(maxWidth: .infinity,
                           alignment: r.detectedLanguage == "he" ? .trailing : .leading)
                Button("Copy report") { UIPasteboard.general.string = r.report }
            }
        }
    }

    static func mb(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

struct DebugRunResult {
    var modelTag: String
    var audioSec: Double
    var decodeSec: Double
    var loadSec: Double
    var transcribeSec: Double
    var availableAtStart: Int64
    var minAvailable: Int64
    var detectedLanguage: String
    var text: String

    var report: String {
        """
        model: \(modelTag)
        audio: \(String(format: "%.1f", audioSec)) s
        decode: \(String(format: "%.1f", decodeSec)) s, load: \(String(format: "%.1f", loadSec)) s, \
        transcribe: \(String(format: "%.1f", transcribeSec)) s
        available memory at start: \(DebugTranscriptionView.mb(availableAtStart)), \
        min: \(DebugTranscriptionView.mb(minAvailable)), \
        peak extra: \(DebugTranscriptionView.mb(availableAtStart - minAvailable))
        detected language: \(detectedLanguage)

        \(text)
        """
    }
}

@MainActor
final class DebugTranscriptionModel: ObservableObject {
    @Published var modelId: String
    @Published var language: String
    @Published var lastAudio: URL?
    @Published var isRecording = false
    @Published var recordingRemaining: Double = 0
    @Published var running = false
    @Published var status = ""
    @Published var result: DebugRunResult?

    private var recorder: AVAudioRecorder?
    /// One loaded model at a time; a second one would not fit in memory.
    private var transcriber: (id: String, instance: WhisperTranscriber)?
    private var minAvailable: Int64 = 0

    init() {
        let settings = AppSettings.load()
        modelId = settings.modelId
        language = settings.language
    }

    func dropTranscriber() { transcriber = nil }

    /// Newest memo whose audio exists; otherwise the newest .m4a in the audio directory.
    func refreshLastAudio() async {
        let audioDir = AppPaths.audioDir
        let fm = FileManager.default
        let memos = await MemoStore(file: AppPaths.queueFile, audioDir: audioDir).all()
            .sorted { $0.recordedAt > $1.recordedAt }
        for memo in memos {
            let url = audioDir.appendingPathComponent(memo.audioFile)
            if fm.fileExists(atPath: url.path) { lastAudio = url; return }
        }
        let files = (try? fm.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        lastAudio = files
            .filter { $0.pathExtension == "m4a" }
            .max { Self.modified($0) < Self.modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    func recordTestClip() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            status = "Microphone permission denied."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let url = AppPaths.audioDir.appendingPathComponent(
                "debug-\(Int(Date().timeIntervalSince1970)).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            guard rec.record(forDuration: 30) else {
                status = "Recording did not start."
                return
            }
            recorder = rec
            isRecording = true
            status = "Recording…"
            while rec.isRecording {
                recordingRemaining = max(0, 30 - rec.currentTime)
                try? await Task.sleep(for: .milliseconds(250))
            }
            isRecording = false
            recorder = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            status = "Saved \(url.lastPathComponent)."
            await refreshLastAudio()
        } catch {
            isRecording = false
            recorder = nil
            status = "Recording failed: \(error.localizedDescription)"
        }
    }

    func stopRecording() { recorder?.stop() }

    func transcribeLast(model: WhisperModel, manager: ModelManager) async {
        guard let url = lastAudio else { return }
        running = true
        result = nil
        status = "Decoding audio…"
        UIApplication.shared.isIdleTimerDisabled = true   // GPU work stops if the app is backgrounded
        defer {
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
        }

        let availableAtStart = Int64(os_proc_available_memory())
        minAvailable = availableAtStart
        let sampler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sampleMemory()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { sampler.cancel() }

        let clock = ContinuousClock()
        do {
            let t0 = clock.now
            let samples = try await Task.detached(priority: .userInitiated) {
                try AudioDecoder.pcm16kMono(from: url)
            }.value
            let decoded = clock.now

            let whisper: WhisperTranscriber
            if let cached = transcriber, cached.id == model.id {
                whisper = cached.instance
            } else {
                transcriber = nil
                whisper = WhisperTranscriber(modelURL: manager.localURL(model))
                transcriber = (model.id, whisper)
            }
            status = "Loading model…"
            try await whisper.preload()
            let loaded = clock.now

            status = "Transcribing \(String(format: "%.0f", Double(samples.count) / 16_000)) s of audio…"
            let out = try await whisper.transcribe(samples: samples, language: language)
            let done = clock.now
            sampleMemory()

            result = DebugRunResult(
                modelTag: model.tag,
                audioSec: Double(samples.count) / 16_000,
                decodeSec: Self.seconds(decoded - t0),
                loadSec: Self.seconds(loaded - decoded),
                transcribeSec: Self.seconds(done - loaded),
                availableAtStart: availableAtStart,
                minAvailable: minAvailable,
                detectedLanguage: out.detectedLanguage,
                text: out.text)
            status = ""
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func sampleMemory() {
        minAvailable = min(minAvailable, Int64(os_proc_available_memory()))
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
