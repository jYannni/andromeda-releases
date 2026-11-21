import Foundation

/// A mounted volume other than the startup disk, as Andromeda presents it.
public struct ExternalVolume: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case drive, diskImage, timeMachine }

    /// The container and volume figures reported by the APFS inventory.
    public struct APFSStorage: Equatable, Sendable {
        public let containerCapacity: Int64
        public let containerFree: Int64
        public let volumeUsed: Int64
        public let quota: Int64?
        public let reserve: Int64?

        public init(containerCapacity: Int64, containerFree: Int64, volumeUsed: Int64, quota: Int64?, reserve: Int64?) {
            self.containerCapacity = containerCapacity
            self.containerFree = containerFree
            self.volumeUsed = volumeUsed
            self.quota = quota
            self.reserve = reserve
        }
    }

    /// Volume UUID string; falls back to "path:" + mount path when the filesystem has none.
    public let id: String
    public let name: String
    /// Mount point.
    public let url: URL
    public let kind: Kind
    public let isReadOnly: Bool
    /// Localized format description, e.g. "APFS".
    public let format: String
    /// The mounted volume's resource values, which can reflect an APFS quota.
    public let capacity: Int64
    public let available: Int64
    /// The APFS container the volume is in (`disk5` for `disk5s1`); nil when it isn't APFS or can't be read.
    public let containerID: String?
    /// Disk Arbitration confirmed an external USB APFS volume.
    let isUSBAPFS: Bool
    public let apfsStorage: APFSStorage?

    public var used: Int64 { max(0, capacity - available) }
    public var hasStableIdentity: Bool { !id.isEmpty && !id.hasPrefix("path:") }
    public var isOrganizable: Bool { !isReadOnly && kind != .timeMachine }

    public init(
        id: String, name: String, url: URL, kind: Kind, isReadOnly: Bool,
        format: String, capacity: Int64, available: Int64, containerID: String? = nil, isUSBAPFS: Bool = false,
        apfsStorage: APFSStorage? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
        self.isReadOnly = isReadOnly
        self.format = format
        self.capacity = capacity
        self.available = available
        self.containerID = containerID
        self.isUSBAPFS = isUSBAPFS
        self.apfsStorage = apfsStorage
    }
}
