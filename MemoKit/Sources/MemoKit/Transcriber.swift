import Foundation
import whisper

public protocol Transcribing: Sendable {
    /// - Parameters:
    ///   - samples: 16 kHz mono Float PCM in [-1, 1].
    ///   - language: `he`, `en`, or `auto` for auto-detection.
    /// - Returns: the joined segment text and the language whisper used / detected.
    func transcribe(samples: [Float], language: String) async throws
        -> (text: String, detectedLanguage: String)
}

public enum TranscriberError: Error, Equatable, LocalizedError {
    case modelMissing(String)
    case modelLoadFailed(String)
    case transcriptionFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let p): return "Model file not found: \(p)"
        case .modelLoadFailed(let p): return "Could not load the model: \(p)"
        case .transcriptionFailed(let code): return "Transcription failed (whisper error \(code))."
        }
    }
}

/// whisper.cpp transcriber. The model is loaded lazily on the first call and kept until the
/// transcriber is released. All whisper calls run on one private serial queue, so it is safe
/// to use from any thread or task; concurrent calls are processed one after another.
public final class WhisperTranscriber: Transcribing, @unchecked Sendable {
    public let modelURL: URL
    public let threads: Int32
    public let useGPU: Bool

    private let queue = DispatchQueue(label: "com.alonk.memo.whisper", qos: .userInitiated)
    /// Only touched on `queue` (and in `deinit`, when no work can be pending).
    private var context: OpaquePointer?

    public init(modelURL: URL, threads: Int32 = 4, useGPU: Bool = true) {
        self.modelURL = modelURL
        self.threads = threads
        self.useGPU = useGPU
    }

    deinit {
        if let context { whisper_free(context) }
    }

    /// Cancelling the calling task aborts whisper (via its `abort_callback`) and throws
    /// `CancellationError`, so an expiring background task stops within moments.
    public func transcribe(samples: [Float], language: String) async throws
        -> (text: String, detectedLanguage: String) {
        let abort = AbortFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    do {
                        cont.resume(returning: try self.run(samples: samples, language: language, abort: abort))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            abort.set()
        }
    }

    /// Loads the model now (on the whisper queue) instead of on the first transcription.
    public func preload() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do { _ = try self.loadedContext(); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: - On `queue`

    private func loadedContext() throws -> OpaquePointer {
        if let context { return context }
        let path = modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriberError.modelMissing(modelURL.lastPathComponent)
        }
        var cparams = whisper_context_default_params()
        cparams.use_gpu = useGPU
        guard let ctx = whisper_init_from_file_with_params(path, cparams) else {
            throw TranscriberError.modelLoadFailed(modelURL.lastPathComponent)
        }
        context = ctx
        return ctx
    }

    private func run(samples: [Float], language: String, abort: AbortFlag) throws
        -> (text: String, detectedLanguage: String) {
        let lang = language.isEmpty ? "auto" : language
        if abort.isSet { throw CancellationError() }
        guard !samples.isEmpty else { return ("", lang) }
        let ctx = try loadedContext()
        if abort.isSet { throw CancellationError() }

        // whisper.cpp returns no text for input shorter than 1 s; pad short clips with silence
        // so a quick word is still transcribed.
        var input = samples
        let minSamples = 17_600   // 1.1 s at 16 kHz
        if input.count < minSamples {
            input.append(contentsOf: [Float](repeating: 0, count: minSamples - input.count))
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        params.translate = false
        params.no_timestamps = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.detect_language = false   // true would only detect, not transcribe
        // Polled by whisper between compute steps; returning true stops `whisper_full`.
        params.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(data).takeUnretainedValue().isSet
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()

        let status: Int32 = withExtendedLifetime(abort) {
            lang.withCString { cLang in
                params.language = cLang
                return input.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
            }
        }
        if abort.isSet { throw CancellationError() }
        guard status == 0 else { throw TranscriberError.transcriptionFailed(status) }

        // Segment boundaries can fall inside a multi-byte UTF-8 character (common in Hebrew),
        // so join the raw bytes of all segments and decode once.
        var bytes: [UInt8] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            guard let cText = whisper_full_get_segment_text(ctx, i) else { continue }
            let length = strlen(cText)
            cText.withMemoryRebound(to: UInt8.self, capacity: length) {
                bytes.append(contentsOf: UnsafeBufferPointer(start: $0, count: length))
            }
        }
        let text = String(decoding: bytes, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var detected = lang
        if let cCode = whisper_lang_str(whisper_full_lang_id(ctx)) {
            detected = String(cString: cCode)
        }
        return (text, detected)
    }
}

/// Cancellation flag shared between a Swift task and whisper's C abort callback.
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
