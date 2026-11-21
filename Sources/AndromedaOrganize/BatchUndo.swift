import Foundation
import AndromedaCore

public enum ItemLocation: Equatable, Sendable {
    case atDestination, atOriginal, elsewhere
}

/// One group of an organize run that can be undone on its own.
public struct UndoableGroup: Equatable, Sendable {
    public let id: String
    /// The deepest folder the group created, else the folder its files went into.
    public let folderName: String
    public let moves: Int
    /// False once none of the group's moves is still `.done`.
    public let canUndo: Bool
    /// True once every one of the group's moves was put back (F10: the receipt and History say so).
    public let undone: Bool

    public init(id: String, folderName: String, moves: Int, canUndo: Bool, undone: Bool = false) {
        self.id = id
        self.folderName = folderName
        self.moves = moves
        self.canUndo = canUndo
        self.undone = undone
    }
}

/// Puts an applied organize / move-to-cloud batch back, and settles batches the app was killed in the
/// middle of. Reads only the journal and the disk. Nothing is replaced or deleted: moves go back with
/// `renamex_np(..., RENAME_EXCL)`, created folders go to the Trash whole.
///
/// A line on an external drive (`volumeUUID` set) is acted on only while that same volume, matched by UUID and
/// never by name or path, is in `volumes()`. Otherwise it isn't connected: undo reports it
/// `.skipped(.volumeNotConnected)` and settle leaves it `planned`, both writing nothing, so it can be done once
/// the drive is back. Mounted at another path now, its paths are read under the current mount point.
public struct BatchUndo {
    private let journal: Journal
    private let trasher: any Trasher
    private let volumes: @Sendable () -> [ExternalVolume]

    public init(journal: Journal, trasher: any Trasher, volumes: @escaping @Sendable () -> [ExternalVolume] = { [] }) {
        self.journal = journal
        self.trasher = trasher
        self.volumes = volumes
    }

    /// Slack for the folder-birth-time evidence test (journal timestamps vs filesystem clocks).
    private static let birthSlack: TimeInterval = 1.0

    // MARK: - Journal view

    private struct Row {
        let original: JournalEntry
        let resolution: JournalResolution
        var outcome: Outcome { resolution.outcome }
        /// The follow-up that settled the row (its `done`, or the interrupted-run settle), if any.
        var latest: JournalEntry? { resolution.settle }
    }

    /// Originals of the batch in journal order, resolved by the same rules History uses.
    private func rows(batchID: UUID) throws -> [Row] {
        let entries = try journal.load(batchID: batchID).entries
        let followUps = JournalHistory.followUps(entries: entries)
        return entries.filter { $0.batchID == batchID && $0.relatesTo == nil }.map {
            Row(original: $0, resolution: JournalHistory.resolve($0, followUps: followUps[$0.id] ?? []))
        }
    }

    private func followUp(_ planned: JournalEntry, outcome: Outcome) -> JournalEntry {
        // relatesTo is always the planned original's id, never a follow-up's (ruling R4).
        JournalEntry(
            batchID: planned.batchID, catalogEntryID: planned.catalogEntryID,
            originalPath: planned.originalPath, bytes: planned.bytes, outcome: outcome,
            relatesTo: planned.id, action: planned.action, destinationPath: planned.destinationPath,
            fileID: planned.fileID, planID: planned.planID, provider: planned.provider,
            volumeUUID: planned.volumeUUID, volumeMount: planned.volumeMount, volumeName: planned.volumeName)
    }

    // MARK: - Volumes

    /// The current mount point of each mounted volume, by `ExternalVolume.id`. Read once per call.
    private func mounts() -> [String: String] {
        Dictionary(volumes().map { ($0.id, $0.url.standardizedFileURL.path) }, uniquingKeysWith: { a, _ in a })
    }

    /// `e` with its paths as they are on disk now: unchanged on the startup disk; nil when its drive isn't
    /// connected; under the current mount point otherwise (the recorded mount prefix is matched case-folded,
    /// component by component, as drive roots are). Fails closed: a drive line with no recorded mount, or with a
    /// path that isn't at or under it, is nil (treated as not connected).
    static func onDisk(_ e: JournalEntry, mounts: [String: String]) -> JournalEntry? {
        guard let uuid = e.volumeUUID else { return e }
        guard let now = mounts[uuid], let recorded = e.volumeMount else { return nil }
        let then = components(recorded)
        var outside = false
        func remap(_ path: String?) -> String? {
            guard let path else { return nil }
            let parts = components(path)
            guard parts.count >= then.count,
                  zip(parts, then).allSatisfy({ NamingRules.key($0) == NamingRules.key($1) }) else {
                outside = true
                return nil
            }
            let rest = parts.dropFirst(then.count)
            return rest.isEmpty ? now : (now as NSString).appendingPathComponent(rest.joined(separator: "/"))
        }
        var mapped = e
        mapped.originalPath = remap(e.originalPath)
        mapped.destinationPath = remap(e.destinationPath)
        return outside ? nil : mapped
    }

    private static func components(_ path: String) -> [String] {
        (URL(fileURLWithPath: path).standardizedFileURL.path as NSString).pathComponents
    }

    /// Checked right before writing a line that isn't `done`: the drive may have gone away since `mounts()` was
    /// read, and then "not there" means "not readable", never "gone". One per call (one batch): the volumes are
    /// read again once, at the first drive line that needs it, with each mount root's device; every row after
    /// that costs one `lstat` of its mount root. A root that is gone, or now on another device, is not mounted
    /// (fail closed: nothing is written for it). True on the startup disk.
    private final class MountCheck {
        private let volumes: @Sendable () -> [ExternalVolume]
        private var devices: [String: (path: String, device: dev_t)]?

        init(volumes: @escaping @Sendable () -> [ExternalVolume]) { self.volumes = volumes }

        func stillMounted(_ e: JournalEntry) -> Bool {
            guard let uuid = e.volumeUUID else { return true }
            let devices = self.devices ?? {
                var read: [String: (path: String, device: dev_t)] = [:]
                for v in volumes() where read[v.id] == nil {
                    let path = v.url.standardizedFileURL.path
                    if let st = BatchUndo.lstat(path) { read[v.id] = (path, st.st_dev) }
                }
                self.devices = read
                return read
            }()
            guard let mount = devices[uuid], let st = BatchUndo.lstat(mount.path) else { return false }
            return st.st_dev == mount.device
        }
    }

    // MARK: - Recovery

    /// For each `planned` original with no settle entry: where the item actually is.
    public func recover(batchID: UUID) throws -> [UUID: ItemLocation] {
        var out: [UUID: ItemLocation] = [:]
        let mounts = mounts()
        for row in try rows(batchID: batchID) where row.outcome == .planned {
            // A drive that isn't connected can't say where anything is: not listed.
            guard let e = Self.onDisk(row.original, mounts: mounts) else { continue }
            out[row.original.id] = location(of: e, copy: row.latest?.automationCopy)
        }
        return out
    }

    private func location(of e: JournalEntry, copy: AutomationCopyEvidence? = nil) -> ItemLocation {
        switch e.action {
        case .createFolder:
            // No inode was recorded: same positive-evidence test settleInterrupted applies (R7).
            return createdFolderEvidence(e).0 == .done ? .atDestination : .elsewhere
        case .copy:
            if let dirs = e.automationDirectories, let to = e.destinationPath, let copy,
               dirs.copyReachedDestination(to, evidence: copy) { return .atDestination }
            return .atOriginal
        default:
            guard let id = e.fileID else { return .elsewhere }
            if let cloudFolder = e.cloudOrganizeFolder, let from = e.originalPath, let to = e.destinationPath {
                let operations = CloudFolderOperations(folder: cloudFolder)
                if operations.contains(to, fileID: id) { return .atDestination }
                return operations.contains(from, fileID: id) ? .atOriginal : .elsewhere
            }
            if let directories = e.automationDirectories, let from = e.originalPath, let to = e.destinationPath {
                return directories.location(original: from, moved: to, fileID: id)
            }
            if let st = Self.lstat(e.destinationPath), UInt64(st.st_ino) == id { return .atDestination }
            if let st = Self.lstat(e.originalPath), UInt64(st.st_ino) == id { return .atOriginal }
            return .elsewhere
        }
    }

    /// atDestination -> done, atOriginal -> skipped(.interruptedNotMoved), elsewhere -> skipped(.notWhereWeLeftIt).
    /// An unsettled createFolder is `done` only with positive evidence it is ours, and `.interruptedNotMoved` when
    /// absent; see `createdFolderEvidence`.
    /// Idempotent: a settled row is never settled again. A row on a drive that isn't connected is left `planned`.
    public func settleInterrupted(batchID: UUID) throws {
        let mounts = mounts()
        let check = MountCheck(volumes: volumes)
        for row in try rows(batchID: batchID) where row.outcome == .planned {
            let e = row.original
            guard let disk = Self.onDisk(e, mounts: mounts) else { continue }
            var settle: JournalEntry
            if e.action == .createFolder {
                let (outcome, inode) = createdFolderEvidence(disk)
                settle = followUp(e, outcome: outcome)
                if outcome == .done { settle.fileID = inode }
            } else if e.action == .copy, let directories = disk.automationDirectories, let destination = disk.destinationPath {
                let evidence = row.latest?.automationCopy
                let outcome = directories.settleCopy(destination, entryID: e.id, evidence: evidence)
                settle = followUp(e, outcome: outcome)
                if outcome == .done { settle.automationCopy = evidence }
            } else {
                switch location(of: disk) {
                case .atDestination: settle = followUp(e, outcome: .done)
                case .atOriginal: settle = followUp(e, outcome: .skipped(.interruptedNotMoved))
                case .elsewhere: settle = followUp(e, outcome: .skipped(.notWhereWeLeftIt))
                }
            }
            // A drive that unmounted meanwhile: left `planned`, nothing written, so it settles once it is back.
            if settle.outcome != .done, !check.stillMounted(e) { continue }
            try journal.append(settle)
        }
    }

    /// Absent: the run stopped before making it (the whole run is journalled up front, so an unstarted step
    /// is `planned` too) -> `.interruptedNotMoved`. Present but not a folder, or unreadable -> `.notWhereWeLeftIt`.
    private func createdFolderEvidence(_ e: JournalEntry) -> (Outcome, UInt64?) {
        guard let path = e.originalPath else { return (.skipped(.notWhereWeLeftIt), nil) }
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else {
            // Only a folder that isn't there is "not made yet"; any other failure can't say where it is.
            return (.skipped(errno == ENOENT ? .interruptedNotMoved : .notWhereWeLeftIt), nil)
        }
        guard st.st_mode & S_IFMT == S_IFDIR else { return (.skipped(.notWhereWeLeftIt), nil) }
        let born = Date(
            timeIntervalSince1970: Double(st.st_birthtimespec.tv_sec) + Double(st.st_birthtimespec.tv_nsec) / 1e9)
        guard Self.isEmptyIgnoringDSStore(path), born >= e.timestamp.addingTimeInterval(-Self.birthSlack) else {
            return (.skipped(.destinationOccupied), nil)
        }
        return (.done, UInt64(st.st_ino))
    }

    // MARK: - Undo

    /// Reverse order. Moves go back only if the item at destinationPath has the recorded fileID, originalPath is
    /// free and its parent exists. Created folders go to the Trash only if ours and empty (`.DS_Store` only counts
    /// as empty, if it is a regular file). Settles interrupted rows first. Rows never applied, and rows already undone, get no follow-up.
    /// `progress(done, total)` counts the moves to put back (created folders aren't counted): once with
    /// done 0, then after each move is journaled.
    ///
    /// With a `groupID` only that group's rows are undone, plus every group-less created folder above one of its
    /// moves. Such a shared folder that still holds anything is left alone with no journal line, so a later undo
    /// of the whole run can still trash it.
    /// With an `entryID`, only that move or copy is undone. Folders made for the run remain available.
    ///
    /// A row on a drive that isn't connected (still applied, or left `planned`) is reported
    /// `.skipped(.volumeNotConnected)` with no journal line and isn't counted in `progress`.
    public func undo(
        batchID: UUID, groupID: String? = nil, entryID: UUID? = nil,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> [(entryID: UUID, outcome: Outcome)] {
        try settleInterrupted(batchID: batchID)
        var results: [(entryID: UUID, outcome: Outcome)] = []
        var all = try rows(batchID: batchID)
        let prerequisites = Dictionary(all.compactMap { row in
            row.original.requiredCopyEntryID.map { (row.original.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let backupIDs = Set(prerequisites.values)
        func requiredBackups(for move: UUID) -> Set<UUID> {
            var backups: Set<UUID> = []
            var current = move
            while let copy = prerequisites[current], backups.insert(copy).inserted { current = copy }
            return backups
        }
        // Every backup remains protected until the original move is undone, including earlier
        // copies in a chain. After that, each copy can be checked and removed independently.
        var outstandingMovesByBackup: [UUID: Int] = [:]
        for row in all where row.original.action == .move && (row.outcome == .done || row.outcome == .planned) {
            for copy in requiredBackups(for: row.original.id) { outstandingMovesByBackup[copy, default: 0] += 1 }
        }
        if let entryID {
            all = all.filter { $0.original.id == entryID && [.move, .copy].contains($0.original.action) }
        } else if let groupID {
            let own = all.filter { $0.original.groupID == groupID }
            let destinations = own.filter { $0.original.action == .move }
                .compactMap { $0.original.destinationPath.map(Self.standardized) }
            all = all.filter { row in
                if row.original.groupID == groupID { return true }
                guard row.original.groupID == nil, row.original.action == .createFolder,
                      let path = row.original.originalPath.map(Self.standardized) else { return false }
                return destinations.contains { $0.hasPrefix(path + "/") }
            }
        }
        let mounts = mounts()
        let check = MountCheck(volumes: volumes)
        let todo = all.reversed().filter {
            ($0.outcome == .done && $0.latest != nil)
                || ($0.outcome == .planned && Self.onDisk($0.original, mounts: mounts) == nil)
        }
        let total = todo.filter {
            [.move, .copy].contains($0.original.action) && Self.onDisk($0.original, mounts: mounts) != nil
        }.count
        var done = 0
        progress(0, total)
        for row in todo {
            let e = row.original
            guard let disk = Self.onDisk(e, mounts: mounts) else {
                if [.move, .copy, .createFolder].contains(e.action) { results.append((e.id, .skipped(.volumeNotConnected))) }
                continue
            }
            guard let settled = row.latest else { continue }
            let outcome: Outcome
            var entry = followUp(e, outcome: .restored)
            switch e.action {
            case .move:
                outcome = undoMove(disk)
            case .copy:
                if outstandingMovesByBackup[e.id, default: 0] > 0 {
                    outcome = .skipped(.dependentMoveNotRestored)
                } else if let dirs = disk.automationDirectories, let to = disk.destinationPath, let evidence = settled.automationCopy {
                    if backupIDs.contains(e.id) {
                        if let path = disk.originalPath, let inode = disk.fileID,
                           dirs.sourceMatchesBackup(path, inode: inode, evidence: evidence) {
                            outcome = dirs.undoCopy(to, entryID: e.id, evidence: evidence, trasher: trasher)
                        } else {
                            outcome = .skipped(.backupSourceChanged)
                        }
                    } else {
                        outcome = dirs.undoCopy(to, entryID: e.id, evidence: evidence, trasher: trasher)
                    }
                } else { outcome = .skipped(.notWhereWeLeftIt) }
            case .createFolder:
                // Leave synced folders in place. Other devices may still be adding items to them.
                if e.cloudOrganizeFolder != nil { continue }
                let (o, trashPath, trashInode) = undoFolder(disk, recordedID: settled.fileID)
                outcome = o
                if groupID != nil, e.groupID == nil, o == .skipped(.notEmpty) { continue }
                if o == .restored { entry.trashPath = trashPath; entry.fileID = trashInode }
            default:
                continue
            }
            // The drive went away during the undo: reported as not connected, with no audit line.
            if outcome != .restored, !check.stillMounted(e) {
                results.append((e.id, .skipped(.volumeNotConnected)))
                continue
            }
            entry.outcome = outcome
            try journal.append(entry)
            if outcome == .restored, e.action == .move {
                for copy in requiredBackups(for: e.id) { outstandingMovesByBackup[copy, default: 0] -= 1 }
            }
            results.append((e.id, outcome))
            if e.action == .move || e.action == .copy { done += 1; progress(done, total) }
        }
        return results
    }

    /// The groups of a run that have moves, in journal order.
    public func groups(batchID: UUID) throws -> [UndoableGroup] {
        Self.groups(of: try rows(batchID: batchID))
    }

    /// Every run's groups from journal lines already loaded (History's one read), in one pass: batch id → its
    /// groups, in journal order. Runs whose lines carry no `groupID` (old runs, cloud moves) aren't listed.
    public static func groups(entries: [JournalEntry]) -> [UUID: [UndoableGroup]] {
        var grouped: Set<UUID> = []
        for e in entries where e.relatesTo == nil && e.groupID != nil { grouped.insert(e.batchID) }
        guard !grouped.isEmpty else { return [:] }
        let followUps = JournalHistory.followUps(entries: entries)
        var rows: [UUID: [Row]] = [:]
        for e in entries where e.relatesTo == nil && grouped.contains(e.batchID) {
            rows[e.batchID, default: []].append(
                Row(original: e, resolution: JournalHistory.resolve(e, followUps: followUps[e.id] ?? [])))
        }
        return rows.compactMapValues { r in
            let found = groups(of: r)
            return found.isEmpty ? nil : found
        }
    }

    private static func groups(of all: [Row]) -> [UndoableGroup] {
        var order: [String] = []
        var byGroup: [String: [Row]] = [:]
        for row in all {
            guard let g = row.original.groupID else { continue }
            if byGroup[g] == nil { order.append(g) }
            byGroup[g, default: []].append(row)
        }
        return order.compactMap { id in
            let rows = byGroup[id] ?? []
            let moves = rows.filter { $0.original.action == .move }
            guard !moves.isEmpty else { return nil }
            // The deepest folder the group made ("Unit 1" under its own "Lessons"), else where its files went.
            let created = rows.filter { $0.original.action == .createFolder }.compactMap(\.original.originalPath)
            let folder = created.max { a, b in
                (a as NSString).pathComponents.count < (b as NSString).pathComponents.count
            } ?? moves.first?.original.destinationPath.map { ($0 as NSString).deletingLastPathComponent }
            return UndoableGroup(
                id: id, folderName: (folder.map { ($0 as NSString).lastPathComponent }) ?? "",
                moves: moves.count, canUndo: moves.contains { $0.outcome == .done },
                undone: moves.allSatisfy { $0.outcome == .restored })
        }
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func undoMove(_ e: JournalEntry) -> Outcome {
        guard let dst = e.destinationPath, let src = e.originalPath, let id = e.fileID else {
            return .skipped(.notWhereWeLeftIt)
        }
        if let cloudFolder = e.cloudOrganizeFolder {
            let operations = CloudFolderOperations(folder: cloudFolder)
            if operations.contains(src, fileID: id), !operations.contains(dst, fileID: id) { return .restored }
            return operations.move(from: dst, to: src, fileID: id)
        }
        if let directories = e.automationDirectories {
            if directories.location(original: src, moved: dst, fileID: id) == .atOriginal { return .restored }
            return directories.move(from: dst, to: src, fileID: id, undo: true)
        }
        guard let st = Self.lstat(dst) else {
            // A previous undo may have renamed it back and then failed to journal that: it is home.
            if let home = Self.lstat(src), UInt64(home.st_ino) == id { return .restored }
            return .skipped(.notWhereWeLeftIt)
        }
        guard UInt64(st.st_ino) == id else { return .skipped(.notWhereWeLeftIt) }
        let parent = (src as NSString).deletingLastPathComponent
        guard let pst = Self.lstat(parent), pst.st_mode & S_IFMT == S_IFDIR else {
            return .skipped(.originalParentMissing)
        }
        if Self.lstat(src) != nil { return .skipped(.originalPathOccupied) }
        if renamex_np(dst, src, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            switch code {
            case EEXIST: return .skipped(.originalPathOccupied)
            case ENOENT: return .skipped(.notWhereWeLeftIt)
            default:
                return .failed(FailureText.describe(
                    NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]),
                    ownedByCurrentUser: st.st_uid == getuid()))
            }
        }
        return .restored
    }

    private func undoFolder(_ e: JournalEntry, recordedID: UInt64?) -> (Outcome, String?, UInt64?) {
        guard let path = e.originalPath else { return (.skipped(.alreadyGone), nil, nil) }
        guard let st = Self.lstat(path) else { return (.skipped(.alreadyGone), nil, nil) }
        guard let recordedID, st.st_mode & S_IFMT == S_IFDIR, UInt64(st.st_ino) == recordedID else {
            return (.skipped(.notWhereWeLeftIt), nil, nil)
        }
        guard Self.isEmptyIgnoringDSStore(path) else { return (.skipped(.notEmpty), nil, nil) }
        do {
            let landed = try trasher.trash(URL(fileURLWithPath: path, isDirectory: true))
            return (.restored, landed.path, Self.lstat(landed.path).map { UInt64($0.st_ino) })
        } catch {
            return (.failed(FailureText.describe(error, ownedByCurrentUser: st.st_uid == getuid())), nil, nil)
        }
    }

    // MARK: - Disk helpers

    private static func lstat(_ path: String?) -> stat? {
        guard let path else { return nil }
        var st = stat()
        return Darwin.lstat(path, &st) == 0 ? st : nil
    }

    private static func isEmptyIgnoringDSStore(_ path: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return names.allSatisfy { name in
            guard name == ".DS_Store", let st = lstat(path + "/" + name) else { return false }
            return st.st_mode & S_IFMT == S_IFREG
        }
    }
}
