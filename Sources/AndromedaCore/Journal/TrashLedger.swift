import Foundation

public enum RestoreError: Error, Equatable {
    /// Not a Trash move this app made, already restored or deleted, or no longer in the Trash.
    case notRestorable
    case originalPathOccupied
    case originalParentMissing
    case volumeNotConnected
    /// Something else now sits at the recorded Trash location, or the location is outside the Trash.
    case notOurs
}

/// Follow-up actions on items this app moved to the Trash: Restore, and "Delete permanently".
///
/// An item is **ours, and still in the Trash**, only when all of these hold:
/// - its journal entry is `.done` with a `trashPath` and a `trashFileID`;
/// - no later entry relating to it is `.restored`, `.permanentlyDeleted` or `.skipped(.alreadyGone)`;
/// - the standardized `trashPath` is strictly inside `env.trash` (never `env.trash` itself), and so is
///   its fully resolved path;
/// - something exists there, and its `lstat` inode equals `trashFileID`.
///
/// Anything else in the Trash, including the user's own files, is never touched.
///
/// This is the only place in the product that permanently deletes. The check and the deletion are
/// separate system calls, so a swap in between can't be ruled out entirely; the window is a single
/// item wide, and the Trash is a folder only the user (and this app on their behalf) writes to.
public struct TrashLedger {
    private let env: ScanEnvironment
    private let journal: Journal
    private let volumes: @Sendable () -> [ExternalVolume]

    public init(env: ScanEnvironment, journal: Journal, volumes: @escaping @Sendable () -> [ExternalVolume] = { [] }) {
        self.env = env
        self.journal = journal
        self.volumes = volumes
    }

    /// Every item that is ours and still in the Trash, newest first.
    public func restorable() throws -> [JournalEntry] {
        restorable(from: try journal.load().entries)
    }

    /// Same as `restorable()`, from entries the caller has already loaded (no second read of the journal).
    public func restorable(from entries: [JournalEntry]) -> [JournalEntry] {
        let settled = Self.settledIDs(entries)
        let pending = entries.filter { Self.isRestorableMove($0) && !settled.contains($0.id) }
        let ids = Set(pending.compactMap(\.volumeUUID))
        let connected = ids.isEmpty ? [] : volumes()
        var mounted: [String: ExternalDuplicateVolume] = [:]
        for volume in connected where ids.contains(volume.id) {
            mounted[volume.id] = ExternalDuplicateVolume(volume)
        }
        return pending.compactMap { entry in
            if let uuid = entry.volumeUUID {
                guard let drive = mounted[uuid],
                      let owned = try? externalItem(entry, on: drive, confirmContents: false) else { return nil }
                return owned.entry
            }
            if case .ours = check(entry) { return entry }
            return nil
        }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Moves the item back to its original path. The original folder must still exist (it is not
    /// recreated) and nothing may be at the original path.
    ///
    /// If the move succeeds but the journal append then throws, the error is rethrown: the item is
    /// already back in place, and a later call sees the Trash location empty and refuses with
    /// `.notRestorable`, so nothing is ever moved twice.
    public func restore(_ entryID: UUID) throws {
        let entries = try journal.load().entries
        guard let entry = entries.last(where: { $0.id == entryID }),
              Self.isRestorableMove(entry), let originalPath = entry.originalPath,
              !Self.settledIDs(entries).contains(entry.id)
        else { throw RestoreError.notRestorable }

        if let uuid = entry.volumeUUID {
            guard let connected = volumes().first(where: { $0.id == uuid }),
                  let drive = ExternalDuplicateVolume(connected) else { throw RestoreError.volumeNotConnected }
            let item = try externalItem(entry, on: drive, confirmContents: true)
            try drive.rename(item.trash, to: item.original) {
                $0.st_ino == item.info.st_ino && $0.st_size == item.info.st_size
                    && DuplicateScanner.unchanged(item.info, $0)
            }
            try journal.append(followUp(entry, .restored))
            return
        }

        _ = try ownedURL(entry)

        let original = URL(fileURLWithPath: originalPath).standardizedFileURL
        var st = stat()
        guard lstat(original.deletingLastPathComponent().path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR
        else { throw RestoreError.originalParentMissing }
        guard lstat(original.path, &st) != 0, errno == ENOENT else { throw RestoreError.originalPathOccupied }

        // Re-check right before the move: the earlier checks took time.
        let trashURL = try ownedURL(entry)
        if !Self.allowsPermanentDeletion(entry.catalogEntryID) {
            // Anchor the restore in a real directory so a substituted symlink cannot redirect it.
            let parent = URL(fileURLWithPath: originalPath).deletingLastPathComponent().path
            let fd = open(SafetyGuard.withoutSystemPathAlias(parent), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw RestoreError.originalParentMissing }
            defer { close(fd) }
            if renameatx_np(AT_FDCWD, trashURL.path, fd, original.lastPathComponent, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST { throw RestoreError.originalPathOccupied }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try FileManager.default.moveItem(at: trashURL, to: original)
        }
        try journal.append(followUp(entry, .restored))
    }

    /// Permanently deletes this batch's items that are ours and still in the Trash.
    ///
    /// Every item considered gets a journal entry relating to it: `.permanentlyDeleted`,
    /// `.skipped(.alreadyGone)`, `.skipped(.notOurs)`, or `.failed` when the deletion itself fails
    /// (a failed item is in neither returned list). Items already restored, deleted or found gone
    /// are not considered again. If the journal can't be written, this stops and throws.
    public func permanentlyDelete(batchID: UUID) throws -> (deleted: [UUID], skipped: [(UUID, SkipReason)]) {
        let entries = try journal.load().entries
        let settled = Self.settledIDs(entries)
        var deleted: [UUID] = []
        var skipped: [(UUID, SkipReason)] = []

        for entry in entries where entry.batchID == batchID && Self.isTrashMove(entry) && !settled.contains(entry.id) {
            if entry.volumeUUID != nil || !Self.allowsPermanentDeletion(entry.catalogEntryID) { continue }
            switch check(entry) {
            case .gone:
                try journal.append(followUp(entry, .skipped(.alreadyGone)))
                skipped.append((entry.id, .alreadyGone))
            case .notOurs:
                try journal.append(followUp(entry, .skipped(.notOurs)))
                skipped.append((entry.id, .notOurs))
            case .ours(let url):
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    try journal.append(followUp(entry, .failed(String(String(describing: error).prefix(500)))))
                    continue
                }
                try journal.append(followUp(entry, .permanentlyDeleted))
                deleted.append(entry.id)
            }
        }
        return (deleted, skipped)
    }

    // MARK: - Ownership

    public static func allowsPermanentDeletion(_ catalogEntryID: String) -> Bool {
        catalogEntryID != DuplicateScanner.cleanupCatalogID && catalogEntryID != ApplicationCleanup.catalogID
            && catalogEntryID != InstallerCleanup.catalogID && catalogEntryID != SimilarImageCleanup.catalogID
            && catalogEntryID != BrowserFileCleanup.catalogID
    }

    private enum Check {
        case ours(URL)
        case gone
        case notOurs
    }

    private struct ExternalItem {
        let entry: JournalEntry
        let trash: URL
        let original: URL
        let info: stat
    }

    private func externalItem(
        _ entry: JournalEntry, on drive: ExternalDuplicateVolume, confirmContents: Bool
    ) throws -> ExternalItem {
        guard entry.catalogEntryID == DuplicateScanner.cleanupCatalogID,
              entry.volumeUUID == drive.uuid, let recordedMount = entry.volumeMount,
              let originalPath = entry.originalPath, let trashPath = entry.trashPath,
              let original = drive.remap(originalPath, from: recordedMount),
              let trash = drive.remap(trashPath, from: recordedMount),
              drive.matches(original, device: drive.identity.dev),
              trash.path == drive.trashDestination(for: original, id: entry.id).path,
              let fd = drive.openDirectory(trash.deletingLastPathComponent()) else { throw RestoreError.notOurs }
        defer { close(fd) }
        var info = stat()
        guard fstatat(fd, trash.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw errno == ENOENT ? RestoreError.notRestorable : RestoreError.notOurs
        }
        guard info.st_dev == drive.identity.dev, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0,
              entry.trashFileID.map({ $0 == UInt64(info.st_ino) }) != false
        else { throw RestoreError.notOurs }
        if entry.outcome == .planned {
            var source = stat()
            guard lstat(original.path, &source) != 0, errno == ENOENT else { throw RestoreError.notOurs }
        }
        if confirmContents || entry.trashFileID == nil {
            guard let digest = entry.duplicateDigest,
                  DuplicateScanner.matchesTrashFingerprint(at: trash, info: info, digest: digest)
            else { throw RestoreError.notOurs }
        }
        var remapped = entry
        remapped.originalPath = original.path
        remapped.trashPath = trash.path
        remapped.outcome = .done
        return ExternalItem(entry: remapped, trash: trash, original: original, info: info)
    }

    private func ownedURL(_ entry: JournalEntry) throws -> URL {
        switch check(entry) {
        case .ours(let url): return url
        case .gone: throw RestoreError.notRestorable
        case .notOurs: throw RestoreError.notOurs
        }
    }

    private func check(_ entry: JournalEntry) -> Check {
        guard let trashPath = entry.trashPath, let fileID = entry.trashFileID else { return .notOurs }
        let url = URL(fileURLWithPath: trashPath).standardizedFileURL
        guard Self.isStrictlyInside(url.path, env.trash.standardizedFileURL.path) else { return .notOurs }

        var st = stat()
        guard lstat(url.path, &st) == 0 else { return errno == ENOENT ? .gone : .notOurs }

        // The resolved location must be inside the resolved Trash too, so a symlinked parent can't
        // point the deletion somewhere else.
        guard let resolved = Self.realPath(url.path), let resolvedTrash = Self.realPath(env.trash.path),
              Self.isStrictlyInside(resolved, resolvedTrash)
        else { return .notOurs }

        guard UInt64(st.st_ino) == fileID else { return .notOurs }
        return .ours(url)
    }

    private static func isStrictlyInside(_ path: String, _ root: String) -> Bool {
        let p = components(path), r = components(root)
        return p.count > r.count && Array(p.prefix(r.count)) == r
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func realPath(_ path: String) -> String? {
        guard let buf = realpath(path, nil) else { return nil }
        defer { free(buf) }
        return String(cString: buf)
    }

    // MARK: - Journal helpers

    private static func isTrashMove(_ entry: JournalEntry) -> Bool {
        entry.outcome == .done && entry.trashPath != nil && entry.resolvedAction == .trash
    }

    private static func isRestorableMove(_ entry: JournalEntry) -> Bool {
        isTrashMove(entry) || (entry.outcome == .planned && entry.resolvedAction == .trash
            && entry.volumeUUID != nil && entry.catalogEntryID == DuplicateScanner.cleanupCatalogID
            && entry.trashPath != nil && entry.duplicateDigest != nil)
    }

    /// Entries that a later entry has closed: restored, deleted, or found gone from the Trash.
    private static func settledIDs(_ entries: [JournalEntry]) -> Set<UUID> {
        Set(entries.compactMap { e -> UUID? in
            switch e.outcome {
            case .restored, .permanentlyDeleted, .skipped(.alreadyGone): e.relatesTo
            default: nil
            }
        })
    }

    private func followUp(_ entry: JournalEntry, _ outcome: Outcome) -> JournalEntry {
        JournalEntry(
            batchID: entry.batchID, catalogEntryID: entry.catalogEntryID,
            originalPath: entry.originalPath, trashPath: entry.trashPath, trashFileID: entry.trashFileID,
            bytes: entry.bytes, outcome: outcome, relatesTo: entry.id)
    }
}
