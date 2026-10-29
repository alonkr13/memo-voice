import Foundation

/// Moves what an install without the App Group left in the app's own container (Application
/// Support) into the App Group container, once the group is available: the memo queue, audio,
/// downloaded models, settings and queue backups. Call at launch, before the store is created.
///
/// Crash-safe and repeatable: files are renamed (atomic on one volume) or copied to a temporary
/// name, renamed into place and only then deleted from the source; audio moves before the queue
/// (so no merged record points at audio that isn't there yet); the queue is merged by memo ID and
/// written before the source queue is deleted. A run interrupted at any point is finished by the
/// next one and never duplicates or drops a record.
public enum ContainerMigration {
    public struct Report: Sendable, Equatable {
        /// Memos added to the destination queue.
        public var memosMerged = 0
        /// Files moved (audio, models, settings, backups).
        public var filesMoved = 0
        /// Things that could not be done cleanly; nothing was deleted for them.
        public var problems: [String] = []
        public init() {}
    }

    public static let queueName = "queue.json"
    public static let settingsName = "settings.json"
    public static let subdirectories = ["Audio", "Models"]

    private struct Lossy: Decodable {
        let memo: Memo?
        init(from decoder: Decoder) throws {
            memo = try? decoder.singleValueContainer().decode(Memo.self)
        }
    }

    public static func migrate(from source: URL, to destination: URL,
                               fileManager fm: FileManager = .default) -> Report {
        var report = Report()
        guard source.standardizedFileURL.path != destination.standardizedFileURL.path else { return report }

        // 1. Audio and models first: the queue must never reference audio that isn't there.
        for name in subdirectories {
            let from = source.appendingPathComponent(name, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(atPath: from.path), !items.isEmpty else { continue }
            let to = destination.appendingPathComponent(name, isDirectory: true)
            do {
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
            } catch {
                report.problems.append("Could not create \(name) in the App Group: \(error.localizedDescription)")
                continue
            }
            for item in items where !item.hasSuffix(".migrating") {
                moveFile(from.appendingPathComponent(item), to: to.appendingPathComponent(item),
                         fm: fm, report: &report)
            }
        }

        // 2. Earlier queue backups (queue.corrupt-*.json).
        if let items = try? fm.contentsOfDirectory(atPath: source.path) {
            for item in items where item.hasPrefix("queue.corrupt-") || item.hasPrefix("queue.premigration-") {
                moveFile(source.appendingPathComponent(item), to: destination.appendingPathComponent(item),
                         fm: fm, report: &report)
            }
        }

        // 3. The queue, merged by ID (the destination's copy of a memo wins).
        mergeQueue(from: source.appendingPathComponent(queueName),
                   to: destination.appendingPathComponent(queueName), fm: fm, report: &report)

        // 4. Settings: the group's own settings win if it has them.
        let settingsFrom = source.appendingPathComponent(settingsName)
        if fm.fileExists(atPath: settingsFrom.path) {
            let settingsTo = destination.appendingPathComponent(settingsName)
            if fm.fileExists(atPath: settingsTo.path) {
                try? fm.removeItem(at: settingsFrom)
            } else {
                moveFile(settingsFrom, to: settingsTo, fm: fm, report: &report)
            }
        }
        return report
    }

    private static func mergeQueue(from: URL, to: URL, fm: FileManager, report: inout Report) {
        guard fm.fileExists(atPath: from.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let backupName = "queue.premigration-\(stamp)-\(UUID().uuidString.prefix(8)).json"

        guard let data = try? Data(contentsOf: from),
              let lossy = try? JSONDecoder().decode([Lossy].self, from: data) else {
            // Unreadable: keep the bytes next to the group's queue, never drop them.
            moveFile(from, to: to.deletingLastPathComponent().appendingPathComponent(backupName),
                     fm: fm, report: &report)
            report.problems.append("The memo queue from the app's own storage could not be read. A copy was kept as \(backupName).")
            return
        }
        let incoming = lossy.compactMap(\.memo)
        let sourceDamaged = incoming.count != lossy.count

        var existing: [Memo] = []
        if fm.fileExists(atPath: to.path) {
            guard let destData = try? Data(contentsOf: to),
                  let destLossy = try? JSONDecoder().decode([Lossy].self, from: destData),
                  destLossy.allSatisfy({ $0.memo != nil }) else {
                // Writing would destroy records we can't read; leave both files for the store
                // (which backs up a damaged queue) and try again next launch.
                report.problems.append("The memo queue in the App Group could not be read, so memos from the app's own storage were not merged yet.")
                return
            }
            existing = destLossy.compactMap(\.memo)
        }

        let known = Set(existing.map(\.id))
        let added = incoming.filter { !known.contains($0.id) }
        if !added.isEmpty {
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(existing + added).write(to: to, options: .atomic)
            } catch {
                report.problems.append("Could not merge memos into the App Group queue: \(error.localizedDescription)")
                return
            }
            report.memosMerged = added.count
        }

        // Only now that every readable record is in the destination may the source go.
        if sourceDamaged {
            moveFile(from, to: to.deletingLastPathComponent().appendingPathComponent(backupName),
                     fm: fm, report: &report)
            report.problems.append("Some memos from the app's own storage could not be read. A copy of that queue was kept as \(backupName).")
        } else {
            try? fm.removeItem(at: from)
        }
    }

    /// Moves one file without ever losing it: same-size file already at the destination means
    /// an earlier run finished the copy (the source is then just removed); a different file
    /// there is kept, and the source is moved next to it under another name.
    private static func moveFile(_ from: URL, to: URL, fm: FileManager, report: inout Report) {
        var target = to
        if fm.fileExists(atPath: to.path) {
            if size(from, fm) == size(to, fm) {
                try? fm.removeItem(at: from)
                return
            }
            target = to.deletingLastPathComponent().appendingPathComponent(
                to.lastPathComponent + ".migrated-\(UUID().uuidString.prefix(8))")
            report.problems.append("\(to.lastPathComponent) already existed in the App Group; the other copy was kept as \(target.lastPathComponent).")
        }
        // Atomic on the same volume (the app and group containers normally are).
        if rename(from.path, target.path) == 0 {
            report.filesMoved += 1
            return
        }
        let temp = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".migrating")
        do {
            try? fm.removeItem(at: temp)
            try fm.copyItem(at: from, to: temp)
            try fm.moveItem(at: temp, to: target)
        } catch {
            try? fm.removeItem(at: temp)
            report.problems.append("Could not move \(from.lastPathComponent) into the App Group: \(error.localizedDescription)")
            return
        }
        try? fm.removeItem(at: from)
        report.filesMoved += 1
    }

    private static func size(_ url: URL, _ fm: FileManager) -> Int64? {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

/// Banners that must survive relaunches until the user dismisses them. Kept in the app's own
/// defaults (`UserDefaults.standard`), which exist with or without the App Group.
public struct LaunchNotices {
    public let defaults: UserDefaults

    static let lastContainerKey = "lastContainerWasAppGroup"
    static let appGroupLostKey = "appGroupLostNotice"
    static let corruptBackupKey = "corruptQueueBackupNotice"
    static let migrationProblemKey = "containerMigrationNotice"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Call once per launch with the container in use. If the last launch used the App Group
    /// and this one can't, memos from then are in a container this install can't read: that
    /// is remembered until dismissed (or until the group is back).
    public func noteContainer(usingAppGroup: Bool) {
        let previous = defaults.object(forKey: Self.lastContainerKey) as? Bool
        if usingAppGroup {
            defaults.removeObject(forKey: Self.appGroupLostKey)
        } else if previous == true {
            defaults.set(true, forKey: Self.appGroupLostKey)
        }
        defaults.set(usingAppGroup, forKey: Self.lastContainerKey)
    }

    public var appGroupLost: Bool { defaults.bool(forKey: Self.appGroupLostKey) }
    public func dismissAppGroupLost() { defaults.removeObject(forKey: Self.appGroupLostKey) }

    /// File name of the backup `MemoStore` made of a damaged queue.
    public var corruptQueueBackup: String? { defaults.string(forKey: Self.corruptBackupKey) }
    public func setCorruptQueueBackup(_ url: URL) { defaults.set(url.lastPathComponent, forKey: Self.corruptBackupKey) }
    public func dismissCorruptQueueBackup() { defaults.removeObject(forKey: Self.corruptBackupKey) }

    public var migrationProblem: String? { defaults.string(forKey: Self.migrationProblemKey) }
    public func setMigrationProblem(_ text: String) { defaults.set(text, forKey: Self.migrationProblemKey) }
    public func dismissMigrationProblem() { defaults.removeObject(forKey: Self.migrationProblemKey) }
}
