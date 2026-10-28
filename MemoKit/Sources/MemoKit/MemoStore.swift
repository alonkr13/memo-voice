import Foundation

/// Persistent memo queue backed by a JSON file (atomic writes).
public actor MemoStore {
    private let file: URL
    private let audioDir: URL
    private var memos: [Memo]
    /// Set when queue.json existed but could not be decoded; the unreadable file was moved here
    /// (not overwritten) so the data can still be recovered. UI should warn about it.
    public private(set) var recoveredFromCorruptQueue: URL?

    /// - Parameters:
    ///   - file: queue JSON file (a missing or corrupt file yields an empty queue).
    ///   - audioDir: directory that `Memo.audioFile` names are relative to.
    public init(file: URL, audioDir: URL) {
        self.file = file
        self.audioDir = audioDir
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        memos = []
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([Memo].self, from: data) {
            memos = decoded
        } else {
            // Existing but unreadable: keep the bytes aside before any write can replace them.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = file.deletingLastPathComponent()
                .appendingPathComponent("queue.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
            if (try? FileManager.default.moveItem(at: file, to: backup)) != nil {
                recoveredFromCorruptQueue = backup
            }
        }
    }

    public func all() -> [Memo] { memos }

    public func add(_ memo: Memo) throws {
        memos.append(memo)
        try persist()
    }

    public func update(_ id: UUID, _ change: (inout Memo) -> Void) throws {
        guard let index = memos.firstIndex(where: { $0.id == id }) else { return }
        change(&memos[index])
        try persist()
    }

    /// Call on launch: memos left mid-step by a kill/crash return to the previous retryable state.
    public func recoverInterrupted() throws {
        let fm = FileManager.default
        for index in memos.indices {
            switch memos[index].state {
            case .transcribing:
                memos[index].state = .recorded
            case .uploading:
                memos[index].state = .transcribed
            case .recording:
                let path = audioDir.appendingPathComponent(memos[index].audioFile).path
                if fm.fileExists(atPath: path) {
                    memos[index].state = .recorded
                } else {
                    memos[index].state = .failed
                    memos[index].lastError = "Recording was interrupted and no audio was saved."
                }
            case .recorded, .transcribed, .done, .failed:
                break
            }
        }
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(memos)
        try data.write(to: file, options: .atomic)
    }
}
