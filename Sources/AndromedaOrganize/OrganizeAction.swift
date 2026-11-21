import AndromedaCore
import Foundation

public enum OrganizeAction: Equatable, Sendable {
    case createFolder(URL)
    /// Renaming within one folder is a move.
    case move(from: URL, to: URL)
    case copy(from: URL, to: URL)
}

/// What a source item looked like when the plan was built; checked again before it moves.
///
/// `bytes` is the display/journal size (recursive allocated size for a folder). It is never used as
/// identity. Identity is inode + mtime, plus `identitySize` for regular files: `st_size` for a file,
/// nil for a directory (where `st_size` means nothing). A regular file whose `identitySize` is nil
/// fails closed (`changedSinceScan`).
public struct ItemSnapshot: Equatable, Sendable {
    public let fileID: UInt64
    public let bytes: Int64
    public let modified: Date
    public let identitySize: Int64?
    public let changed: Date?

    public init(fileID: UInt64, bytes: Int64, modified: Date, identitySize: Int64? = nil, changed: Date? = nil) {
        self.fileID = fileID
        self.bytes = bytes
        self.modified = modified
        self.identitySize = identitySize
        self.changed = changed
    }
}

public struct PlannedStep: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let action: OrganizeAction
    /// Required for `.move`; nil for `.createFolder`.
    public let snapshot: ItemSnapshot?
    /// One of `OrganizeCatalogID`.
    public let catalogEntryID: String
    /// Set for cloud moves.
    public let provider: CloudProvider?
    /// The `PlanGroup.id` this step belongs to; nil for kind folders, shared parents and non-group plans.
    public let groupID: String?
    /// A concrete child directory approved by a recursive automation rule.
    var automationDirectories: AutomationDirectories?
    var copyFinderTags: [String] = []
    var removedCopyTags: [String] = []
    /// The preceding published copy in a chain. A final move revalidates the whole chain.
    var requiredCopyID: UUID?

    public init(id: UUID = UUID(), action: OrganizeAction, snapshot: ItemSnapshot?,
                catalogEntryID: String, provider: CloudProvider?, groupID: String? = nil) {
        self.id = id
        self.action = action
        self.snapshot = snapshot
        self.catalogEntryID = catalogEntryID
        self.provider = provider
        self.groupID = groupID
    }
}

/// Shown to the user, never acted on.
public struct LeftAlone: Equatable, Sendable {
    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

/// The external drive a plan's folder is on (plan 7): matched by `uuid` only, never by name or path.
public struct PlanVolume: Equatable, Sendable, Codable {
    /// `ExternalVolume.id`.
    public var uuid: String
    /// The mount point when the plan was made.
    public var mountPath: String
    /// The drive's name when the plan was made; History shows it while the drive isn't connected.
    public var name: String?

    public init(uuid: String, mountPath: String, name: String? = nil) {
        self.uuid = uuid
        self.mountPath = mountPath
        self.name = name
    }
}

public struct OrganizePlan: Equatable, Sendable {
    public let planID: UUID
    /// "Downloads", "Move to iCloud Drive"
    public let title: String
    /// `createFolder` steps precede the moves that need them.
    public let steps: [PlannedStep]
    public let leftAlone: [LeftAlone]
    /// Set when the plan's folder is on an external drive; nil for the startup disk.
    public var volume: PlanVolume?
    public internal(set) var cloudOrganizeFolder: AutomationDirectories.Folder?
    public internal(set) var automationDirectories: AutomationDirectories?

    public init(planID: UUID = UUID(), title: String, steps: [PlannedStep], leftAlone: [LeftAlone],
                cloudOrganizeFolder: AutomationDirectories.Folder? = nil) {
        self.planID = planID
        self.title = title
        self.steps = steps
        self.leftAlone = leftAlone
        self.cloudOrganizeFolder = cloudOrganizeFolder
    }
}

extension ItemSnapshot {
    /// The one lstat-based snapshot factory every planner uses (ruling R6/P3).
    /// `st_ino` is the file ID, `st_mtimespec` the modification time; `identitySize` is `st_size` for a
    /// regular file and nil for a directory. nil when lstat fails or the item is not a file or folder
    /// (a symlink is never snapshotted).
    public static func capture(_ url: URL, bytes: Int64) -> ItemSnapshot? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let identity: Int64?
        switch st.st_mode & S_IFMT {
        case S_IFREG: identity = Int64(st.st_size)
        case S_IFDIR: identity = nil
        default: return nil
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return ItemSnapshot(fileID: UInt64(st.st_ino), bytes: bytes, modified: modified, identitySize: identity)
    }
}
