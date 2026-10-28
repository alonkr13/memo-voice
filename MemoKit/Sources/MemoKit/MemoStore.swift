import Foundation

public actor MemoStore {
    public init(file: URL, audioDir: URL) {}
    public func all() -> [Memo] { [] }
    public func add(_ memo: Memo) {}
    public func update(_ id: UUID, _ change: (inout Memo) -> Void) {}
    public func recoverInterrupted() {}
}
