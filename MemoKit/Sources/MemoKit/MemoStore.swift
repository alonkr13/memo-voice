import Foundation

/// Persistent memo queue backed by a JSON file (atomic writes).
public actor MemoStore {
    private let file: URL
    private let audioDir: URL
    private var memos: [Memo]

    /// - Parameters:
    ///   - file: queue JSON file (a missing or corrupt file yields an empty queue).
    ///   - audioDir: directory that `Memo.audioFile` names are relative to.
    public init(file: URL, audioDir: URL) {
        self.file = file
        self.audioDir = audioDir
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([Memo].self, from: data) {
            memos = decoded
        } else {
            memos = []
        }
    }

    public func all() -> [Memo] { memos }

    public func add(_ memo: Memo) {
        memos.append(memo)
        persist()
    }

    public func update(_ id: UUID, _ change: (inout Memo) -> Void) {
        guard let index = memos.firstIndex(where: { $0.id == id }) else { return }
        change(&memos[index])
        persist()
    }

    /// Call on launch: memos left mid-step by a kill/crash return to the previous retryable state.
    public func recoverInterrupted() {
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
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(memos) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
