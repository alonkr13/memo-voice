import CryptoKit
import Foundation

public enum ModelDownloadError: Error, Equatable, LocalizedError {
    case httpStatus(Int)
    case wrongSize(expected: Int64, actual: Int64)
    case fileSystem(String)
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let s): return "Model download failed (HTTP \(s))."
        case .wrongSize(let e, let a): return "Model download incomplete (\(a) of \(e) bytes)."
        case .fileSystem(let m): return "Could not save the model: \(m)"
        case .checksumMismatch: return "Model download is corrupt (checksum mismatch). Please download it again."
        }
    }
}

/// Downloads Whisper models into `AppPaths.modelsDir` with a background `URLSession`, so a
/// download keeps going while the app is suspended. A finished download is first moved to
/// `<file>.part`, its size and SHA-256 checked, and only then renamed to `<file>`;
/// `isDownloaded` only accepts the final file at its exact expected size.
@MainActor
public final class ModelManager: ObservableObject {
    public static let backgroundSessionID = "com.alonk.memo.models"
    /// The app's single instance (a background session identifier may only be used once).
    public static let shared = ModelManager()

    /// Fraction 0...1 for each model id currently downloading.
    @Published public private(set) var progress: [String: Double] = [:]
    /// Last download error for each model id, cleared when a new download starts.
    @Published public private(set) var errors: [String: String] = [:]

    public let modelsDir: URL
    private let sessionID: String
    private var session: URLSession?
    private var waiters: [String: [CheckedContinuation<Void, Error>]] = [:]
    private var backgroundCompletion: (() -> Void)?

    /// Creating a manager never touches the network; the session is created on first use.
    public init(modelsDir: URL = AppPaths.modelsDir,
                sessionIdentifier: String = ModelManager.backgroundSessionID) {
        self.modelsDir = modelsDir
        self.sessionID = sessionIdentifier
    }

    public func localURL(_ model: WhisperModel) -> URL {
        modelsDir.appendingPathComponent(model.fileName)
    }

    public func partURL(_ model: WhisperModel) -> URL {
        Self.partURL(model, in: modelsDir)
    }

    public func isDownloaded(_ model: WhisperModel) -> Bool {
        Self.fileSize(localURL(model)) == model.sizeBytes
    }

    /// Downloads `model` unless it is already present. Concurrent calls for the same model
    /// share one download. Returns once the file is in place.
    public func download(_ model: WhisperModel) async throws {
        if isDownloaded(model) { return }
        let session = ensureSession()
        let inFlight = await session.allTasks.contains {
            $0.taskDescription == model.id && ($0.state == .running || $0.state == .suspended)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if isDownloaded(model) { cont.resume(); return }
            let first = waiters[model.id] == nil
            waiters[model.id, default: []].append(cont)
            guard first, !inFlight else { return }
            errors[model.id] = nil
            progress[model.id] = 0
            let task = session.downloadTask(with: model.url)
            task.taskDescription = model.id
            task.countOfBytesClientExpectsToReceive = model.sizeBytes
            task.resume()
        }
    }

    /// Deletes the model file (and any leftover partial file).
    public func delete(_ model: WhisperModel) {
        objectWillChange.send()
        try? FileManager.default.removeItem(at: localURL(model))
        try? FileManager.default.removeItem(at: partURL(model))
    }

    /// Call on launch: re-attaches to downloads that continued while the app was not running,
    /// so their progress is shown and their completion is handled.
    public func reconnect() async {
        let tasks = await ensureSession().allTasks
        for task in tasks {
            guard let id = task.taskDescription, task.state == .running || task.state == .suspended
            else { continue }
            progress[id] = task.progress.fractionCompleted
        }
    }

    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == sessionID else { completion(); return }
        backgroundCompletion = completion
        _ = ensureSession()
    }

    // MARK: - Delegate callbacks (main actor)

    fileprivate func report(_ id: String, fraction: Double) {
        progress[id] = fraction
    }

    fileprivate func finished(_ id: String, error: Error?) {
        progress[id] = nil
        if let error { errors[id] = error.localizedDescription }
        let pending = waiters.removeValue(forKey: id) ?? []
        for cont in pending {
            if let error { cont.resume(throwing: error) } else { cont.resume() }
        }
    }

    fileprivate func backgroundEventsFinished() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    private func ensureSession() -> URLSession {
        if let session { return session }
        let config = URLSessionConfiguration.background(withIdentifier: sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsExpensiveNetworkAccess = false   // Wi-Fi only, not cellular or hotspot
        let delegate = DownloadDelegate(modelsDir: modelsDir, manager: self)
        let s = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        session = s
        return s
    }

    // MARK: - File handling (any thread)

    nonisolated static func partURL(_ model: WhisperModel, in dir: URL) -> URL {
        dir.appendingPathComponent(model.fileName + ".part")
    }

    nonisolated static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Lowercase hex SHA-256 of a file, read in 4 MB chunks so a large model never sits in memory.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 4 * 1_048_576) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Moves a finished download to `<file>.part`, verifies HTTP status, size and SHA-256, then renames
    /// it to its final name. Must run synchronously inside `didFinishDownloadingTo`, because
    /// the system deletes `downloaded` as soon as that callback returns.
    nonisolated static func finalize(
        downloaded: URL, model: WhisperModel, modelsDir: URL, httpStatus: Int?
    ) throws {
        let fm = FileManager.default
        if let status = httpStatus, !(200..<300).contains(status) {
            try? fm.removeItem(at: downloaded)
            throw ModelDownloadError.httpStatus(status)
        }
        let part = partURL(model, in: modelsDir)
        var dest = modelsDir.appendingPathComponent(model.fileName)
        do {
            try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: part.path) { try fm.removeItem(at: part) }
            try fm.moveItem(at: downloaded, to: part)
        } catch {
            throw ModelDownloadError.fileSystem(error.localizedDescription)
        }
        let size = fileSize(part) ?? -1
        guard size == model.sizeBytes else {
            try? fm.removeItem(at: part)
            throw ModelDownloadError.wrongSize(expected: model.sizeBytes, actual: size)
        }
        // A corrupt file of the right size is useless and can't be resumed: drop it.
        let digest: String
        do {
            digest = try sha256(of: part)
        } catch {
            try? fm.removeItem(at: part)
            throw ModelDownloadError.fileSystem(error.localizedDescription)
        }
        guard digest == model.sha256 else {
            try? fm.removeItem(at: part)
            throw ModelDownloadError.checksumMismatch
        }
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: part, to: dest)
        } catch {
            throw ModelDownloadError.fileSystem(error.localizedDescription)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true   // large and re-downloadable
        try? dest.setResourceValues(values)
    }
}

/// URLSession delegate. Runs on the session's private queue and forwards to the main actor.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let modelsDir: URL
    private weak var manager: ModelManager?
    private let lock = NSLock()
    private var failures: [Int: Error] = [:]
    private var lastReported: [Int: Double] = [:]

    init(modelsDir: URL, manager: ModelManager) {
        self.modelsDir = modelsDir
        self.manager = manager
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, let model = WhisperModel.find(id) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.sizeBytes
        let fraction = min(1, Double(totalBytesWritten) / Double(max(total, 1)))
        let shouldReport: Bool = lock.withLock {
            let last = lastReported[downloadTask.taskIdentifier] ?? -1
            guard fraction - last >= 0.002 else { return false }
            lastReported[downloadTask.taskIdentifier] = fraction
            return true
        }
        guard shouldReport else { return }
        let m = manager
        Task { @MainActor in m?.report(id, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let model = WhisperModel.find(id) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
        do {
            try ModelManager.finalize(downloaded: location, model: model,
                                      modelsDir: modelsDir, httpStatus: status)
        } catch {
            lock.withLock { failures[downloadTask.taskIdentifier] = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let stored: Error? = lock.withLock {
            lastReported[task.taskIdentifier] = nil
            return failures.removeValue(forKey: task.taskIdentifier)
        }
        guard let id = task.taskDescription else { return }
        let result = error ?? stored
        let m = manager
        Task { @MainActor in m?.finished(id, error: result) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let m = manager
        Task { @MainActor in m?.backgroundEventsFinished() }
    }
}
