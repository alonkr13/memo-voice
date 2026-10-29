import Foundation

/// Persistent memo queue backed by a JSON file (atomic writes).
public actor MemoStore {
    private let file: URL
    private let audioDir: URL
    private var memos: [Memo]
    /// Set when queue.json existed but was unreadable or had undecodable records; a copy of the
    /// original file was saved here first. UI should warn about it.
    public private(set) var recoveredFromCorruptQueue: URL?
    /// True when the queue file was damaged and could not be backed up; all writes throw.
    public private(set) var writesBlocked = false

    public enum StoreError: Error { case writesBlocked }

    private struct Lossy: Decodable {
        let memo: Memo?
        init(from decoder: Decoder) throws {
            memo = try? decoder.singleValueContainer().decode(Memo.self)
        }
    }

    /// - Parameters:
    ///   - file: queue JSON file (a missing file yields an empty queue).
    ///   - audioDir: directory that `Memo.audioFile` names are relative to.
    /// `copyItem` is the seam used to back up a damaged queue file (injectable for tests).
    public init(
        file: URL, audioDir: URL,
        copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) {
        self.file = file
        self.audioDir = audioDir
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        memos = []
        guard FileManager.default.fileExists(atPath: file.path) else { return }

        var damaged = false
        if let data = try? Data(contentsOf: file),
           let lossy = try? JSONDecoder().decode([Lossy].self, from: data) {
            memos = lossy.compactMap(\.memo)
            damaged = memos.count != lossy.count
        } else {
            damaged = true
        }
        guard damaged else { return }

        // Keep the original bytes aside before any write can replace them. If that is
        // impossible, refuse to write at all rather than risk destroying the only copy.
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = file.deletingLastPathComponent()
            .appendingPathComponent("queue.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        do {
            try copyItem(file, backup)
            recoveredFromCorruptQueue = backup
        } catch {
            writesBlocked = true
        }
    }

    public func all() -> [Memo] { memos }

    public func add(_ memo: Memo) throws {
        try persist(memos + [memo])
    }

    public func update(_ id: UUID, _ change: (inout Memo) -> Void) throws {
        guard let index = memos.firstIndex(where: { $0.id == id }) else { return }
        var updated = memos
        change(&updated[index])
        try persist(updated)
    }

    /// Removes a memo from the queue (persisted before it is dropped from memory). Deleting its
    /// audio file is the caller's job.
    public func remove(_ id: UUID) throws {
        guard memos.contains(where: { $0.id == id }) else { return }
        try persist(memos.filter { $0.id != id })
    }

    /// Call on launch: memos left mid-step by a kill/crash return to the previous retryable state.
    /// - Parameters:
    ///   - excluding: memos to leave alone (e.g. the one being recorded right now).
    ///   - only: when set, recover just this memo.
    public func recoverInterrupted(excluding: Set<UUID> = [], only: UUID? = nil) throws {
        let fm = FileManager.default
        var updated = memos
        for index in updated.indices {
            if excluding.contains(updated[index].id) { continue }
            if let only, updated[index].id != only { continue }
            switch updated[index].state {
            case .transcribing:
                updated[index].state = .recorded
            case .uploading:
                updated[index].state = .transcribed
            case .recording:
                let path = audioDir.appendingPathComponent(updated[index].audioFile).path
                if fm.fileExists(atPath: path) {
                    updated[index].state = .recorded
                } else {
                    updated[index].state = .failed
                    updated[index].lastError = "Recording was interrupted and no audio was saved."
                }
            case .recorded, .transcribed, .done, .failed:
                break
            }
        }
        try persist(updated)
    }

    /// Writes `new` and only then adopts it as the in-memory state.
    private func persist(_ new: [Memo]) throws {
        if writesBlocked { throw StoreError.writesBlocked }
        let data = try JSONEncoder().encode(new)
        try data.write(to: file, options: .atomic)
        memos = new
    }
}
