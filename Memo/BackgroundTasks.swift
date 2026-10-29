import BackgroundTasks
import MemoKit
import Network
import UIKit

/// `BGTask` isn't annotated `Sendable`; its methods are safe to call from any thread.
private final class TaskRef: @unchecked Sendable {
    let task: BGTask
    init(_ task: BGTask) { self.task = task }
}

/// Last seen connectivity, written from the path monitor's queue.
private final class PathState: @unchecked Sendable {
    private let lock = NSLock()
    private var satisfied: Bool?
    /// Stores `now`; true when it changed from not-satisfied to satisfied (not on the first report).
    func becameSatisfied(_ now: Bool) -> Bool {
        lock.withLock {
            defer { satisfied = now }
            return satisfied == false && now
        }
    }
}

@MainActor private final class BackgroundAssertion {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Runs the pipeline outside of the foreground:
/// - `BGContinuedProcessingTask` (com.alonk.memo.continued), submitted when a recording stops,
///   transcribes and uploads right away with the system's progress UI;
/// - `BGProcessingTask` (com.alonk.memo.process, needs network) is the fallback, scheduled
///   whenever work remains;
/// - in the foreground, the queue runs when the app becomes active and when the network returns.
enum BackgroundTasks {
    static let processID = "com.alonk.memo.process"
    /// Continued-processing identifiers must start with the bundle ID (`com.alonk.memo`).
    static let continuedID = "com.alonk.memo.continued"
    static let title = "Transcribing memo"

    /// Registers the launch handlers. Call once from `MemoApp.init`, before launch finishes.
    /// (Nonisolated on purpose: the handlers are called on a background queue, so they must not
    /// be formed in a main-actor context.)
    static func register() {
        let scheduler = BGTaskScheduler.shared
        scheduler.register(forTaskWithIdentifier: processID, using: nil) { task in
            start(TaskRef(task), continued: false)
        }
        scheduler.register(forTaskWithIdentifier: continuedID, using: nil) { task in
            start(TaskRef(task), continued: true)
        }
    }

    /// Call when a recording stops (the widget's stop intent and the in-app stop). Starts
    /// processing now with system progress UI, continuing if the user leaves the app.
    @MainActor static func submitContinued() {
        scheduleProcessing()   // fallback if the continued task is refused, queued or cut short
        let request = BGContinuedProcessingTaskRequest(
            identifier: continuedID, title: title, subtitle: "Starting…")
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // E.g. submitted while not in the foreground, or one is already running:
            // process in-process instead (joins a running pass if there is one).
            processNow()
        }
    }

    /// Schedules the fallback `BGProcessingTask`. Replaces any earlier request.
    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Processes the queue in this process. When the app isn't active this runs CPU-only under a
    /// short background-time assertion, and stops cleanly if that time runs out.
    @MainActor static func processNow() {
        let background = UIApplication.shared.applicationState != .active
        Task { @MainActor in
            let work = Task { await AppServices.pipeline.processAll(background: background) }
            let assertion = BackgroundAssertion()
            if background {
                assertion.id = UIApplication.shared.beginBackgroundTask(withName: "Process memos") {
                    work.cancel()
                    assertion.end()
                }
            }
            await work.value
            assertion.end()
            if await AppServices.pipeline.pendingCount() > 0 { scheduleProcessing() }
        }
    }

    /// Call when the scene enters the background. A foreground (GPU) pass can't keep running
    /// there, so this switches to a CPU pass in the remaining background time; whatever is left
    /// goes to the `BGProcessingTask`.
    @MainActor static func didEnterBackground() {
        Task { @MainActor in
            guard await AppServices.pipeline.pendingCount() > 0 else { return }
            scheduleProcessing()
            processNow()
        }
    }

    // MARK: - Connectivity

    @MainActor private static var monitor: NWPathMonitor?

    /// Runs the queue when the network comes back while the app is active.
    @MainActor static func startConnectivityMonitor() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = pathHandler()
        m.start(queue: DispatchQueue(label: "com.alonk.memo.path"))
        monitor = m
    }

    private static func pathHandler() -> @Sendable (NWPath) -> Void {
        let state = PathState()
        return { path in
            guard state.becameSatisfied(path.status == .satisfied) else { return }
            Task { @MainActor in
                if UIApplication.shared.applicationState == .active { processNow() }
            }
        }
    }

    // MARK: - BG task handling

    private static func start(_ ref: TaskRef, continued: Bool) {
        let work = Task { @MainActor in await run(ref, continued: continued) }
        // Expiry (or the user cancelling in the system UI) cancels the pass; whisper aborts and
        // the memo in progress returns to its previous state.
        ref.task.expirationHandler = { work.cancel() }
    }

    @MainActor private static func run(_ ref: TaskRef, continued: Bool) async {
        var progress: Pipeline.ProgressHandler?
        if continued {
            progress = { done, total in
                guard let task = ref.task as? BGContinuedProcessingTask else { return }
                task.progress.totalUnitCount = Int64(max(total, 1))
                task.progress.completedUnitCount = Int64(min(done, max(total, 1)))
                let subtitle = done < total ? "Memo \(done + 1) of \(total)" : "Done"
                task.updateTitle(title, subtitle: subtitle)
            }
        }
        await AppServices.pipeline.processAll(background: true, progress: progress)
        let expired = Task.isCancelled
        if await AppServices.pipeline.pendingCount() > 0 { scheduleProcessing() }
        ref.task.setTaskCompleted(success: !expired)
    }
}
