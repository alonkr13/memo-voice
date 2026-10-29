import Foundation
import Testing
@testable import MemoCore

@Suite struct ContainerMigrationTests {
    private let fm = FileManager.default

    private func dirs() throws -> (source: URL, dest: URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("AppSupport", isDirectory: true)
        let dest = root.appendingPathComponent("Group", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        return (source, dest)
    }

    private func write(_ data: Data, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func writeQueue(_ memos: [Memo], in dir: URL) throws {
        try write(JSONEncoder().encode(memos), dir.appendingPathComponent("queue.json"))
    }

    private func queue(in dir: URL) async -> [Memo] {
        await MemoStore(file: dir.appendingPathComponent("queue.json"), audioDir: dir).all()
    }

    @Test func testMovesEverythingIntoEmptyGroup() async throws {
        let (source, dest) = try dirs()
        let memo = Memo(recordedAt: Date(timeIntervalSince1970: 1), audioFile: "a.m4a", state: .recorded)
        try writeQueue([memo], in: source)
        try write(Data("audio".utf8), source.appendingPathComponent("Audio/a.m4a"))
        try write(Data("model".utf8), source.appendingPathComponent("Models/ggml.bin"))
        var settings = AppSettings(); settings.language = "en"
        settings.save(to: source.appendingPathComponent("settings.json"))

        let report = ContainerMigration.migrate(from: source, to: dest)
        #expect(report.problems.isEmpty)
        #expect(report.memosMerged == 1)
        #expect(report.filesMoved == 3)
        #expect(await queue(in: dest) == [memo])
        #expect(try Data(contentsOf: dest.appendingPathComponent("Audio/a.m4a")) == Data("audio".utf8))
        #expect(try Data(contentsOf: dest.appendingPathComponent("Models/ggml.bin")) == Data("model".utf8))
        #expect(AppSettings.load(from: dest.appendingPathComponent("settings.json")).language == "en")
        for gone in ["queue.json", "Audio/a.m4a", "Models/ggml.bin", "settings.json"] {
            #expect(!fm.fileExists(atPath: source.appendingPathComponent(gone).path), "\(gone)")
        }
        // Nothing left: a second run is a no-op.
        #expect(ContainerMigration.migrate(from: source, to: dest) == ContainerMigration.Report())
    }

    @Test func testMergesByIDAndKeepsGroupSettings() async throws {
        let (source, dest) = try dirs()
        let shared = UUID()
        let groupCopy = Memo(id: shared, recordedAt: Date(timeIntervalSince1970: 1), audioFile: "s.m4a", state: .done)
        let staleCopy = Memo(id: shared, recordedAt: Date(timeIntervalSince1970: 1), audioFile: "s.m4a", state: .recorded)
        let onlyInGroup = Memo(recordedAt: Date(timeIntervalSince1970: 2), audioFile: "g.m4a", state: .recorded)
        let onlyInApp = Memo(recordedAt: Date(timeIntervalSince1970: 3), audioFile: "n.m4a", state: .recorded)
        try writeQueue([groupCopy, onlyInGroup], in: dest)
        try writeQueue([staleCopy, onlyInApp], in: source)
        var groupSettings = AppSettings(); groupSettings.language = "auto"
        groupSettings.save(to: dest.appendingPathComponent("settings.json"))
        var appSettings = AppSettings(); appSettings.language = "en"
        appSettings.save(to: source.appendingPathComponent("settings.json"))

        let report = ContainerMigration.migrate(from: source, to: dest)
        #expect(report.problems.isEmpty)
        #expect(report.memosMerged == 1)
        #expect(await queue(in: dest) == [groupCopy, onlyInGroup, onlyInApp])
        #expect(AppSettings.load(from: dest.appendingPathComponent("settings.json")).language == "auto")
        #expect(!fm.fileExists(atPath: source.appendingPathComponent("queue.json").path))
        #expect(!fm.fileExists(atPath: source.appendingPathComponent("settings.json").path))
    }

    /// Interrupted after the merged queue was written but before the source was deleted (or
    /// after audio was copied but before its source was removed): the rerun finishes the job
    /// without duplicating anything.
    @Test func testRerunAfterInterruptionDoesNotDuplicate() async throws {
        let (source, dest) = try dirs()
        let memo = Memo(recordedAt: Date(timeIntervalSince1970: 7), audioFile: "a.m4a", state: .recorded)
        try writeQueue([memo], in: source)
        try writeQueue([memo], in: dest)
        try write(Data("audio".utf8), source.appendingPathComponent("Audio/a.m4a"))
        try write(Data("audio".utf8), dest.appendingPathComponent("Audio/a.m4a"))

        let report = ContainerMigration.migrate(from: source, to: dest)
        #expect(report.problems.isEmpty)
        #expect(report.memosMerged == 0)
        #expect(await queue(in: dest) == [memo])
        #expect(try fm.contentsOfDirectory(atPath: dest.appendingPathComponent("Audio").path) == ["a.m4a"])
        #expect(!fm.fileExists(atPath: source.appendingPathComponent("queue.json").path))
        #expect(!fm.fileExists(atPath: source.appendingPathComponent("Audio/a.m4a").path))
    }

    @Test func testDifferentFileWithSameNameIsKeptUnderAnotherName() throws {
        let (source, dest) = try dirs()
        try write(Data("from app".utf8), source.appendingPathComponent("Audio/a.m4a"))
        try write(Data("in group!!".utf8), dest.appendingPathComponent("Audio/a.m4a"))

        let report = ContainerMigration.migrate(from: source, to: dest)
        #expect(report.problems.count == 1)
        let names = try fm.contentsOfDirectory(atPath: dest.appendingPathComponent("Audio").path).sorted()
        #expect(names.count == 2)
        #expect(try Data(contentsOf: dest.appendingPathComponent("Audio/a.m4a")) == Data("in group!!".utf8))
        let other = try #require(names.first { $0 != "a.m4a" })
        #expect(try Data(contentsOf: dest.appendingPathComponent("Audio/\(other)")) == Data("from app".utf8))
    }

    @Test func testUnreadableGroupQueueLeavesSourceAlone() async throws {
        let (source, dest) = try dirs()
        let memo = Memo(recordedAt: Date(timeIntervalSince1970: 7), audioFile: "a.m4a", state: .recorded)
        try writeQueue([memo], in: source)
        let garbage = Data("{{ not json".utf8)
        try write(garbage, dest.appendingPathComponent("queue.json"))

        let report = ContainerMigration.migrate(from: source, to: dest)
        #expect(report.problems.count == 1)
        #expect(report.memosMerged == 0)
        #expect(try Data(contentsOf: dest.appendingPathComponent("queue.json")) == garbage)
        #expect(await queue(in: source) == [memo])
    }

    @Test func testDamagedSourceQueueMergesGoodRecordsAndKeepsCopy() async throws {
        let (source, dest) = try dirs()
        let good = Memo(recordedAt: Date(timeIntervalSince1970: 5), audioFile: "g.m4a", state: .recorded)
        var array = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode([good])) as? [[String: Any]])
        array.append(["nonsense": true])
        let original = try JSONSerialization.data(withJSONObject: array)
        try write(original, source.appendingPathComponent("queue.json"))

        let report = ContainerMigration.migrate(from: source, to: dest)
        #expect(report.memosMerged == 1)
        #expect(report.problems.count == 1)
        #expect(await queue(in: dest) == [good])
        let backups = try fm.contentsOfDirectory(atPath: dest.path).filter { $0.hasPrefix("queue.premigration-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: dest.appendingPathComponent(backups[0])) == original)
        #expect(!fm.fileExists(atPath: source.appendingPathComponent("queue.json").path))
    }

    @Test func testSameDirectoryIsNoOp() throws {
        let (source, _) = try dirs()
        try writeQueue([Memo(audioFile: "a.m4a")], in: source)
        #expect(ContainerMigration.migrate(from: source, to: source) == ContainerMigration.Report())
        #expect(fm.fileExists(atPath: source.appendingPathComponent("queue.json").path))
    }
}

@Suite struct LaunchNoticesTests {
    private func notices() -> LaunchNotices {
        let suite = "notices-\(UUID().uuidString)"
        return LaunchNotices(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func testWarnsWhenAppGroupGoesAway() {
        let n = notices()
        n.noteContainer(usingAppGroup: false)   // first launch without the group: nothing lost
        #expect(!n.appGroupLost)
        n.noteContainer(usingAppGroup: true)
        #expect(!n.appGroupLost)
        n.noteContainer(usingAppGroup: false)
        #expect(n.appGroupLost)
        n.noteContainer(usingAppGroup: false)   // stays until dismissed
        #expect(n.appGroupLost)
        n.dismissAppGroupLost()
        #expect(!n.appGroupLost)
        n.noteContainer(usingAppGroup: true)
        n.noteContainer(usingAppGroup: false)
        #expect(n.appGroupLost)
        n.noteContainer(usingAppGroup: true)    // the group is back: nothing to warn about
        #expect(!n.appGroupLost)
    }

    @Test func testCorruptQueueBackupPersistsUntilDismissed() {
        let n = notices()
        #expect(n.corruptQueueBackup == nil)
        n.setCorruptQueueBackup(URL(fileURLWithPath: "/tmp/queue.corrupt-1-abc.json"))
        #expect(LaunchNotices(defaults: n.defaults).corruptQueueBackup == "queue.corrupt-1-abc.json")
        n.dismissCorruptQueueBackup()
        #expect(n.corruptQueueBackup == nil)

        n.setMigrationProblem("x")
        #expect(n.migrationProblem == "x")
        n.dismissMigrationProblem()
        #expect(n.migrationProblem == nil)
    }
}
