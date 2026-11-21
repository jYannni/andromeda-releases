import CryptoKit
import Foundation

public enum SkipReason: String, Codable, Sendable {
    case changedSinceScan, appRunning, safetyViolation, alreadyGone, notOurs
    case applicationNotMoved
    case backupNotVerified, dependentMoveNotRestored, backupSourceChanged
    /// A privileged item, but no helper runner was available.
    case helperUnavailable
    /// A once-per-boot privileged action that already ran in this boot session.
    case alreadyDoneThisBoot
    // Organize (spec §6.3).
    case destinationOccupied, originalPathOccupied, originalParentMissing, notEmpty
    case crossVolume, notWhereWeLeftIt, interruptedNotMoved
    /// The run was on an external drive that isn't connected now (plan 7): nothing was checked or written.
    case volumeNotConnected
}

/// What a journal entry did. Entries written before this existed have no `action`; see
/// `JournalEntry.resolvedAction`.
public enum JournalAction: String, Codable, Sendable {
    case trash, command, move, copy, createFolder, evict
}

/// A staged automation copy's identities, recorded before it can be published.
public struct AutomationCopyEvidence: Codable, Equatable, Sendable {
    public let stageInode: UInt64
    public let fileInode: UInt64
    public let fingerprint: Data?
    /// Present when a required backup and its source have different Finder tags.
    public let sourceFingerprint: Data?
    /// Identity of a nested destination parent. Older receipts rely on the approved destination root.
    public let destinationParent: AutomationDirectories.Folder?

    public init(stageInode: UInt64, fileInode: UInt64, fingerprint: Data? = nil, sourceFingerprint: Data? = nil,
                destinationParent: AutomationDirectories.Folder? = nil) {
        self.stageInode = stageInode
        self.fileInode = fileInode
        self.fingerprint = fingerprint
        self.sourceFingerprint = sourceFingerprint
        self.destinationParent = destinationParent
    }
}

/// Result of one removal (or follow-up) step. Encoded as `{"kind": ...}` plus payload keys,
/// so the journal stays stable and readable.
public enum Outcome: Codable, Equatable, Sendable {
    case done
    case skipped(SkipReason)
    case failed(String)
    case restored
    case permanentlyDeleted
    /// Written before an organize move; settled by a follow-up whose `relatesTo` is this entry.
    case planned

    private enum CodingKeys: String, CodingKey { case kind, reason, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "done": self = .done
        case "skipped": self = .skipped(try c.decode(SkipReason.self, forKey: .reason))
        case "failed": self = .failed(try c.decode(String.self, forKey: .message))
        case "restored": self = .restored
        case "permanently-deleted": self = .permanentlyDeleted
        case "planned": self = .planned
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "Unknown outcome kind '\(kind)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .done: try c.encode("done", forKey: .kind)
        case .skipped(let reason):
            try c.encode("skipped", forKey: .kind)
            try c.encode(reason, forKey: .reason)
        case .failed(let message):
            try c.encode("failed", forKey: .kind)
            try c.encode(message, forKey: .message)
        case .restored: try c.encode("restored", forKey: .kind)
        case .permanentlyDeleted: try c.encode("permanently-deleted", forKey: .kind)
        case .planned: try c.encode("planned", forKey: .kind)
        }
    }
}

public struct JournalEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var batchID: UUID
    public var timestamp: Date
    public var catalogEntryID: String
    public var originalPath: String?
    public var trashPath: String?
    /// Inode of the trashed item.
    public var trashFileID: UInt64?
    /// The original inode for a directory moved to Trash by cleanup. Older receipts omit it.
    public var cleanedDirectoryInode: UInt64?
    /// Executable followed by its arguments.
    public var command: [String]?
    /// Allocated bytes ("uses").
    public var bytes: Int64?
    /// Private bytes, the floor of what removal frees (spec §7.1 rev 2). nil when not measurable
    /// or written before this field existed.
    public var privateBytes: Int64?
    /// nil when written before this field existed.
    public var clonesPresent: Bool?
    public var outcome: Outcome
    public var relatesTo: UUID?
    /// nil when written before this field existed; see `resolvedAction`.
    public var action: JournalAction?
    /// Where an organize move put the item.
    public var destinationPath: String?
    /// Inode of the item (organize moves, evictions).
    public var fileID: UInt64?
    public var planID: UUID?
    /// Raw value of `CloudProvider`, for `evict` and cloud moves.
    public var provider: String?
    /// The organize group this line belongs to; nil when written before this field existed or outside a group.
    public var groupID: String?
    /// The volume UUID of the external drive the line's paths are on; nil means the startup disk (and every
    /// line written before drives existed).
    public var volumeUUID: String?
    /// The drive's mount point when the line was written; undo remaps paths when it is mounted elsewhere now.
    public var volumeMount: String?
    /// The drive's name when the line was written, for History while it isn't connected.
    public var volumeName: String?
    public var automationDirectories: AutomationDirectories? = nil
    public var cloudOrganizeFolder: AutomationDirectories.Folder? = nil
    /// Stored as seconds since the reference date to preserve submillisecond filesystem changes.
    public var automationSourceChanged: TimeInterval? = nil
    public var automationCopy: AutomationCopyEvidence? = nil
    /// The preceding copy in a folder automation chain, including older one-copy rules.
    public var requiredCopyEntryID: UUID? = nil
    /// Content evidence for an external duplicate move whose final journal write may have been interrupted.
    var duplicateDigest: Data? = nil

    public var resolvedAction: JournalAction { action ?? (trashPath != nil ? .trash : .command) }
    public var itemFileID: UInt64? { fileID ?? trashFileID }

    public init(
        id: UUID = UUID(), batchID: UUID, timestamp: Date = Date(), catalogEntryID: String,
        originalPath: String? = nil, trashPath: String? = nil, trashFileID: UInt64? = nil,
        command: [String]? = nil, bytes: Int64? = nil, privateBytes: Int64? = nil, clonesPresent: Bool? = nil,
        outcome: Outcome, relatesTo: UUID? = nil,
        action: JournalAction? = nil, destinationPath: String? = nil, fileID: UInt64? = nil,
        planID: UUID? = nil, provider: String? = nil, groupID: String? = nil,
        volumeUUID: String? = nil, volumeMount: String? = nil, volumeName: String? = nil,
        cleanedDirectoryInode: UInt64? = nil
    ) {
        self.id = id
        self.batchID = batchID
        self.timestamp = timestamp
        self.catalogEntryID = catalogEntryID
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.trashFileID = trashFileID
        self.cleanedDirectoryInode = cleanedDirectoryInode
        self.command = command
        self.bytes = bytes
        self.privateBytes = privateBytes
        self.clonesPresent = clonesPresent
        self.outcome = outcome
        self.relatesTo = relatesTo
        self.action = action
        self.destinationPath = destinationPath
        self.fileID = fileID
        self.planID = planID
        self.provider = provider
        self.groupID = groupID
        self.volumeUUID = volumeUUID
        self.volumeMount = volumeMount
        self.volumeName = volumeName
    }
}

public enum JournalError: Error, Equatable {
    case syscall(String, errno: Int32)
}

public struct CleanupSpaceMeasurement: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case cleanup, permanentDeletion }

    public let batchID: UUID
    public let operation: Operation
    public let before: Int64
    public let after: Int64
    public let measuredAt: Date
    public var change: Int64 { after - before }

    public init?(batchID: UUID, operation: Operation, before: Int64, after: Int64) {
        guard before >= 0, after >= 0 else { return nil }
        self.batchID = batchID
        self.operation = operation
        self.before = before
        self.after = after
        measuredAt = Date()
    }
}

/// Append-only JSON Lines log of removal outcomes in `directory/journal.jsonl`.
/// Crash-tolerant: a torn last line is counted as corrupt on load and never blocks later appends.
///
/// Appends from different Journal instances or processes serialize on the same ledger inode.
/// The instance lock also protects readers and accounting within a single Journal.
public final class Journal: @unchecked Sendable {
    fileprivate struct FileStamp: Equatable, Sendable {
        private struct Timestamp: Equatable, Sendable {
            let seconds: Int
            let nanoseconds: Int

            init(_ time: timespec) {
                seconds = time.tv_sec
                nanoseconds = time.tv_nsec
            }
        }

        private let identity: FileIdentity
        let bytes: Int64
        private let birth: Timestamp
        private let modified: Timestamp
        private let changed: Timestamp

        init(_ info: stat) {
            identity = FileIdentity(dev: info.st_dev, ino: info.st_ino)
            bytes = info.st_size
            birth = Timestamp(info.st_birthtimespec)
            modified = Timestamp(info.st_mtimespec)
            changed = Timestamp(info.st_ctimespec)
        }
    }

    public struct Revision: Equatable, Sendable {
        fileprivate let stamp: FileStamp
        fileprivate let digest: SHA256.Digest?
        public var supportsAppendRead: Bool { digest != nil }
    }

    public enum Snapshot: Sendable {
        case unchanged
        case loaded(revision: Revision?, entries: [JournalEntry], corruptLines: Int)
        /// Only the newly appended entries and corrupt-line count. The caller merges duplicate IDs.
        case appended(revision: Revision, entries: [JournalEntry], corruptLines: Int)
    }

    private let fileURL: URL
    private let cleanupMeasurementsURL: URL
    private let lock = NSLock()
    private var fileReads = 0

    /// How many times this instance has read the journal file. A test seam: it pins that a caller
    /// reads the file once, not once per consumer.
    public var fileReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return fileReads
    }

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("journal.jsonl")
        cleanupMeasurementsURL = directory.appendingPathComponent("cleanup-measurements.jsonl")
    }

    public var directory: URL { fileURL.deletingLastPathComponent() }

    public static func liveDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("io.github.jyannni.diskplain", isDirectory: true)
            .appendingPathComponent("journal", isDirectory: true)
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        // Built once per decoder: making two formatters per line dominated load time on large journals (F8).
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let d = frac.date(from: string) { return d }
            if let d = whole.date(from: string) { return d }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Bad ISO-8601 date '\(string)'"))
        }
        return d
    }

    /// Appends one line and syncs it to disk.
    ///
    /// A thrown error does NOT mean the entry was not persisted: the bytes may have landed
    /// before a later step (e.g. fsync) failed. A retry can therefore write the same `id`
    /// twice; `load()` collapses duplicates (last occurrence wins).
    public func append(_ entry: JournalEntry) throws {
        try append(contentsOf: [entry])
    }

    /// Appends several entries, one line each, as one locked write and sync operation: on return they are all
    /// on disk, with the same guarantee `append(_:)` gives one entry. The on-disk format is the same as that many
    /// `append(_:)` calls. A crash mid-write can leave any prefix of the lines (the last one possibly torn, which
    /// `load()` counts as corrupt). The same caveat applies: a thrown error does not mean nothing was persisted.
    public func append(contentsOf entries: [JournalEntry]) throws {
        guard !entries.isEmpty else { return }
        let encoder = Self.makeEncoder()
        var lines = Data()
        for entry in entries {
            lines.append(try encoder.encode(entry))
            lines.append(0x0A)
        }

        try appendLines(lines, to: fileURL)
    }

    public func appendCleanupMeasurement(_ measurement: CleanupSpaceMeasurement) throws {
        var line = try Self.makeEncoder().encode(measurement)
        line.append(0x0A)
        try appendLines(line, to: cleanupMeasurementsURL)
    }

    /// Independent of the removal ledger, so an unreadable reading never affects restore.
    public func cleanupMeasurements() -> [CleanupSpaceMeasurement] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: cleanupMeasurementsURL) else { return [] }
        let decoder = Self.makeDecoder()
        return data.split(separator: 0x0A).compactMap { line in
            guard let reading = try? decoder.decode(CleanupSpaceMeasurement.self, from: Data(line)),
                  reading.before >= 0, reading.after >= 0 else { return nil }
            return reading
        }
    }

    private func appendLines(_ lines: Data, to fileURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        let fd = open(fileURL.path, O_RDWR | O_APPEND | O_CREAT | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw JournalError.syscall("open", errno: errno) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw JournalError.syscall("flock", errno: errno) }
        }

        var size = stat()
        guard fstat(fd, &size) == 0 else { throw JournalError.syscall("fstat", errno: errno) }
        guard size.st_mode & S_IFMT == S_IFREG else { throw JournalError.syscall("write journal", errno: EINVAL) }
        var payload = Data()
        if size.st_size == 0 {
            // A different process can create the file and exit before acquiring the lock. Sync its
            // name before publishing the first line so a failed directory sync leaves the file empty.
            let dfd = open(fileURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard dfd >= 0 else { throw JournalError.syscall("open(dir)", errno: errno) }
            defer { close(dfd) }
            try Self.sync(dfd, operation: "fsync(dir)")
        } else {
            // Start on a fresh line after a torn write. Inspect the inode held by the append lock.
            var last: UInt8 = 0
            var n: Int
            repeat { n = pread(fd, &last, 1, size.st_size - 1) } while n < 0 && errno == EINTR
            guard n == 1 else { throw JournalError.syscall("pread", errno: n < 0 ? errno : EIO) }
            if last != 0x0A { payload.append(0x0A) }
        }
        payload.append(lines)

        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw JournalError.syscall("write", errno: errno)
                }
                if n == 0 { throw JournalError.syscall("write", errno: EIO) }
                offset += n
            }
        }
        while fcntl(fd, F_FULLFSYNC) != 0 {
            if errno == EINTR { continue }
            try Self.sync(fd, operation: "fsync")
            break
        }
    }

    private static func sync(_ fd: Int32, operation: String) throws {
        while fsync(fd) != 0 {
            if errno != EINTR { throw JournalError.syscall(operation, errno: errno) }
        }
    }

    public func load() throws -> (entries: [JournalEntry], corruptLines: Int) {
        try load(matching: nil)
    }

    /// Read a complete journal for a caller that can reuse a derived result while the file is unchanged.
    /// A growing journal can return only new lines when its old prefix is byte-for-byte unchanged.
    /// An absent file has no reusable revision. If the file changes during the read, the caller retries later.
    public func snapshot(since previous: Revision?, readAppends: Bool = true) throws -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        let fd = open(fileURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return .loaded(revision: nil, entries: [], corruptLines: 0) }
            throw JournalError.syscall("open", errno: errno)
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw JournalError.syscall("fstat", errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw JournalError.syscall("read journal", errno: EINVAL) }
        let stamp = FileStamp(info)
        if stamp == previous?.stamp { return .unchanged }

        fileReads += 1
        let data = try file.readToEnd() ?? Data()
        // Bound the journals that callers keep decoded. Larger journals still get unchanged checks.
        let appendLimit = 32 * 1024 * 1024
        let offset: Int?
        if readAppends, data.count <= appendLimit, let previous, let digest = previous.digest,
           previous.stamp.bytes < data.count, SHA256.hash(data: data.prefix(Int(previous.stamp.bytes))) == digest {
            offset = Int(previous.stamp.bytes)
        } else {
            offset = nil
        }
        let digest = data.count <= appendLimit && (data.isEmpty || data.last == 0x0A) ? SHA256.hash(data: data) : nil
        let revision = Revision(stamp: stamp, digest: digest)
        let result = Self.decode(data.dropFirst(offset ?? 0), matching: nil)
        guard fstat(fd, &info) == 0 else { throw JournalError.syscall("fstat", errno: errno) }
        guard FileStamp(info) == stamp, stat(fileURL.path, &info) == 0, FileStamp(info) == stamp else {
            throw JournalError.syscall("journal changed while reading", errno: EAGAIN)
        }
        if offset != nil { return .appended(revision: revision, entries: result.entries, corruptLines: result.corruptLines) }
        return .loaded(revision: revision, entries: result.entries, corruptLines: result.corruptLines)
    }

    /// Only the entries of one batch (originals and follow-ups share the `batchID`), in the same order and with
    /// the same duplicate collapsing as `load()`. Lines that don't contain the batch id are skipped before
    /// decoding, so the cost is a byte scan of the file rather than a decode of every run ever journaled.
    /// `corruptLines` counts only unreadable lines that mention the batch.
    public func load(batchID: UUID) throws -> (entries: [JournalEntry], corruptLines: Int) {
        let (entries, corrupt) = try load(matching: batchID)
        return (entries.filter { $0.batchID == batchID }, corrupt)
    }

    private func load(matching batchID: UUID?) throws -> (entries: [JournalEntry], corruptLines: Int) {
        lock.lock()
        defer { lock.unlock() }

        let data: Data
        fileReads += 1
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ([], 0)
        }
        return Self.decode(data, matching: batchID)
    }

    private static func decode(_ data: Data, matching batchID: UUID?) -> (entries: [JournalEntry], corruptLines: Int) {
        let decoder = Self.makeDecoder()
        var decoded: [JournalEntry] = []
        var corrupt = 0
        let needle = batchID.map { Data($0.uuidString.utf8) }
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let needle, slice.range(of: needle) == nil { continue }
            if slice.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            if let e = try? decoder.decode(JournalEntry.self, from: Data(slice)) {
                decoded.append(e)
            } else {
                corrupt += 1
            }
        }
        // Duplicate ids: keep the last occurrence, at its file position.
        var seen = Set<UUID>()
        var entries: [JournalEntry] = []
        for e in decoded.reversed() where seen.insert(e.id).inserted { entries.append(e) }
        entries.reverse()
        return (entries, corrupt)
    }
}
