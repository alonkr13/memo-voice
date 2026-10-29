import Foundation
import MemoKit

/// The app process's single store and pipeline. `MemoStore` keeps an in-memory copy of the
/// queue, so every part of the app (UI, intents, background tasks) must use this one instance.
@MainActor
enum AppServices {
    static let store = MemoStore(file: AppPaths.queueFile, audioDir: AppPaths.audioDir)

    static let drive = DriveClient(tokens: GoogleAuth.shared)

    static let pipeline = Pipeline(
        store: store,
        audioDir: AppPaths.audioDir,
        transcriber: { model, background in
            // iOS forbids Metal work from background tasks: CPU only there.
            WhisperTranscriber(
                modelURL: AppPaths.modelsDir.appendingPathComponent(model.fileName),
                useGPU: !background)
        },
        drive: drive,
        modelReady: { model in await MainActor.run { ModelManager.shared.isDownloaded(model) } },
        settings: { AppSettings.load() })
}
