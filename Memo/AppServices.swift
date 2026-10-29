import Foundation
import MemoKit

/// The app process's single store and pipeline. `MemoStore` keeps an in-memory copy of the
/// queue, so every part of the app (UI, intents, background tasks) must use this one instance.
@MainActor
enum AppServices {
    static let store: MemoStore = {
        prepareContainer()
        let store = MemoStore(file: AppPaths.queueFile, audioDir: AppPaths.audioDir)
        // The store only knows about a damaged queue for this process; keep the notice until
        // the user dismisses it (a background launch may be the one that found it).
        Task { @MainActor in
            if let backup = await store.recoveredFromCorruptQueue {
                LaunchNotices().setCorruptQueueBackup(backup)
            }
        }
        return store
    }()

    /// The one recorder: the memo list's Record button, the widget / Live Activity intent and
    /// the `memo://record` deep link all go through it (see `RecordingControlling`).
    static let recorder = AppRecordingController(
        core: Recorder(queue: store, audioDir: AppPaths.audioDir))

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
        settings: { AppSettings.load() },
        activeRecordingID: { await MainActor.run { recorder.activeMemoID } })

    private static var containerPrepared = false

    /// Runs once per launch, before anything reads the container (`MemoApp.init` and the store
    /// both call it): remembers which container this launch uses (to warn when the App Group
    /// went away), and moves data an install without the App Group left in the app's own
    /// storage into the group once it is available.
    static func prepareContainer() {
        guard !containerPrepared else { return }
        containerPrepared = true
        let notices = LaunchNotices()
        notices.noteContainer(usingAppGroup: AppPaths.usingAppGroup)
        guard AppPaths.usingAppGroup else { return }
        let report = ContainerMigration.migrate(from: AppPaths.fallbackContainer, to: AppPaths.container)
        if !report.problems.isEmpty {
            notices.setMigrationProblem(
                "Moving memos from the app's own storage into the App Group: " + report.problems.joined(separator: " "))
        }
    }
}
