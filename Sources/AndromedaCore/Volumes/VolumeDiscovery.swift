import DiskArbitration
import Foundation

/// The raw resource values for one mounted URL. A test seam: `classify` is pure.
public struct VolumeFacts: Sendable {
    public var url: URL
    public var name: String
    public var uuid: String?
    public var isLocal: Bool
    public var isRootFileSystem: Bool
    public var isInternal: Bool?
    public var isReadOnly: Bool
    public var format: String
    public var capacity: Int64
    public var available: Int64
    /// DiskArbitration device model is "Disk Image".
    public var isDiskImage: Bool
    /// `Backups.backupdb` or `.timemachine` at the volume root (lstat only).
    public var hasTimeMachineMarker: Bool
    /// The APFS container, from DiskArbitration's BSD name (`disk5s1` → `disk5`).
    public var containerID: String?
    public var isUSBAPFS: Bool

    public init(
        url: URL, name: String, uuid: String?, isLocal: Bool, isRootFileSystem: Bool,
        isInternal: Bool?, isReadOnly: Bool, format: String, capacity: Int64, available: Int64,
        isDiskImage: Bool, hasTimeMachineMarker: Bool, containerID: String? = nil, isUSBAPFS: Bool = false
    ) {
        self.url = url
        self.name = name
        self.uuid = uuid
        self.isLocal = isLocal
        self.isRootFileSystem = isRootFileSystem
        self.isInternal = isInternal
        self.isReadOnly = isReadOnly
        self.format = format
        self.capacity = capacity
        self.available = available
        self.isDiskImage = isDiskImage
        self.hasTimeMachineMarker = hasTimeMachineMarker
        self.containerID = containerID
        self.isUSBAPFS = isUSBAPFS
    }
}

public enum VolumeDiscovery {
    /// Queries a mounted volume during an explicit file action. Opening the root may ask for removable-volume access.
    public static func supportsExclusiveRename(at root: URL) -> Bool? {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        let offset = MemoryLayout<UInt32>.size
        let size = offset + MemoryLayout<vol_capabilities_attr_t>.size
        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ fgetattrlist(fd, &list, $0.baseAddress, size, 0) }) == 0
        else { return nil }
        let capabilities = buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: vol_capabilities_attr_t.self)
        }
        let exclusive = UInt32(VOL_CAP_INT_RENAME_EXCL)
        guard capabilities.valid.1 & exclusive != 0 else { return nil }
        return capabilities.capabilities.1 & exclusive != 0
    }

    /// Drops the startup volume, system-internal volumes and network shares; labels the rest;
    /// sorted by mount path.
    public static func classify(
        _ facts: [VolumeFacts], timeMachineDestinations: Set<String> = []
    ) -> [ExternalVolume] {
        classify(facts, timeMachineDestinations: timeMachineDestinations, apfsInventory: APFSInventory())
    }

    static func classify(
        _ facts: [VolumeFacts], timeMachineDestinations: Set<String> = [], apfsInventory: APFSInventory
    ) -> [ExternalVolume] {
        let backupIDs = Set(timeMachineDestinations.union(apfsInventory.backupUUIDs).map { $0.uppercased() })
        return facts
            .filter { isCandidate(url: $0.url, isRootFileSystem: $0.isRootFileSystem, isLocal: $0.isLocal) }
            .sorted { $0.url.path < $1.url.path }
            .map { f in
                let isTM =
                    f.hasTimeMachineMarker
                    || (f.uuid.map { backupIDs.contains($0.uppercased()) } ?? false)
                let kind: ExternalVolume.Kind = isTM ? .timeMachine : (f.isDiskImage ? .diskImage : .drive)
                let id: String
                if let u = f.uuid, !u.isEmpty { id = u } else { id = "path:" + f.url.path }
                return ExternalVolume(
                    id: id, name: f.name, url: f.url, kind: kind, isReadOnly: f.isReadOnly,
                    format: f.format, capacity: f.capacity, available: f.available, containerID: f.containerID,
                    isUSBAPFS: f.isUSBAPFS, apfsStorage: apfsInventory.storage(for: f))
            }
    }

    /// The cheap test every mount passes before any DiskArbitration or Time Machine probe: not the startup
    /// volume, not a `/System/Volumes/` volume, and known to be local (a share, or one that can't say, is out).
    static func isCandidate(url: URL, isRootFileSystem: Bool, isLocal: Bool?) -> Bool {
        !isRootFileSystem && (isLocal ?? false) && url.standardizedFileURL.path != "/"
            && !url.standardizedFileURL.path.hasPrefix("/System/Volumes/")
    }

    /// Verifies the selected mount before and after a drive scan without opening its directory.
    public static func isStillMounted(_ volume: ExternalVolume) -> Bool {
        isStillMounted(volume, mountAt: mountState, identityAt: { root in
            let values = try? root.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsLocalKey])
            return (values?.volumeUUIDString, values?.volumeIsLocal)
        }, discover: { mounted(probeRoots: false) })
    }

    enum MountState: Equatable {
        case mounted(fsid0: Int32, fsid1: Int32)
        case absent
        case unverifiable

        func agrees(with earlier: MountState) -> Bool {
            self != .absent && (self == .unverifiable || earlier == .unverifiable || self == earlier)
        }
    }

    static func isStillMounted(
        _ volume: ExternalVolume,
        mountAt: (URL) -> MountState,
        identityAt: (URL) -> (uuid: String?, isLocal: Bool?),
        discover: () -> [ExternalVolume]
    ) -> Bool {
        let root = URL(fileURLWithPath: volume.url.path, isDirectory: true).standardizedFileURL
        guard isCandidate(url: root, isRootFileSystem: false, isLocal: true) else { return false }
        let before = mountAt(root)
        guard before != .absent else { return false }
        let expected = UUID(uuidString: volume.id)
        if let expected {
            let observed = identityAt(root)
            let uuid = observed.uuid.flatMap(UUID.init(uuidString:))
            if observed.isLocal == false || (uuid != nil && uuid != expected) { return false }
            let after = mountAt(root)
            guard after.agrees(with: before) else { return false }
            if before != .unverifiable, after == before, observed.isLocal == true, uuid == expected {
                return true
            }
        }

        // Some filesystems do not report a UUID, and Foundation may omit either key.
        // Rediscover in those cases, requiring the same path as well as the original ID.
        let found = discover().contains { candidate in
            guard candidate.url.standardizedFileURL.path == root.path else { return false }
            if let expected { return UUID(uuidString: candidate.id) == expected }
            return candidate.id == volume.id
        }
        return found && mountAt(root).agrees(with: before)
    }

    private static func mountState(at root: URL) -> MountState {
        var info = statfs()
        guard statfs(root.path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .absent : .unverifiable
        }
        let isBrowsableLocal = info.f_flags & UInt32(MNT_LOCAL) != 0 && info.f_flags & UInt32(MNT_DONTBROWSE) == 0
        guard isBrowsableLocal else { return .absent }
        let path = withUnsafeBytes(of: info.f_mntonname) {
            String(validating: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard let path else { return .unverifiable }
        guard path == root.path else { return .absent }
        return .mounted(fsid0: info.f_fsid.val.0, fsid1: info.f_fsid.val.1)
    }

    /// Live: every mounted, non-hidden volume, classified.
    ///
    /// `probeRoots` allows reading each drive's root for Time Machine markers. Without Full Disk Access, opening a
    /// drive's root makes macOS ask "access files on a removable volume", unasked, at launch (and it blocks a
    /// process that can't show the prompt, such as a CI runner). So callers pass `fda == .granted`. APFS
    /// Backup roles and configured destination UUIDs can identify Time Machine without opening the root.
    public static func mounted(probeRoots: Bool = true) -> [ExternalVolume] {
        guard
            let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: resourceKeys, options: [.skipHiddenVolumes])
        else { return [] }
        // Only the resource keys first: shares, the startup disk and system volumes never reach a probe.
        let candidates = urls.filter { url in
            guard let v = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsRootFileSystemKey])
            else { return false }
            return isCandidate(url: url, isRootFileSystem: v.volumeIsRootFileSystem ?? false, isLocal: v.volumeIsLocal)
        }
        guard !candidates.isEmpty else { return [] }
        let session = DASessionCreate(kCFAllocatorDefault)
        let facts = candidates.compactMap { facts(for: $0, session: session, probeRoots: probeRoots) }
        var apfsInventory = APFSInventory()
        if facts.contains(where: { $0.containerID != nil }) {
            let diskutil = URL(fileURLWithPath: "/usr/sbin/diskutil")
            if let result = try? LiveToolRunner().run(diskutil, ["apfs", "list", "-plist"]), result.exitCode == 0 {
                apfsInventory = APFSInventory(data: Data(result.stdout.utf8))
            }
        }
        return classify(facts, timeMachineDestinations: timeMachineDestinationUUIDs(), apfsInventory: apfsInventory)
    }

    struct APFSInventory {
        private(set) var backupUUIDs: Set<String> = []
        private var volumes: [String: (container: String?, storage: ExternalVolume.APFSStorage)] = [:]

        init() {}

        init(data: Data) {
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let containers = plist["Containers"] as? [Any]
            else { return }
            var seenUUIDs: Set<String> = []
            for case let container as [String: Any] in containers {
                guard let members = container["Volumes"] as? [Any] else { continue }
                let reference = container["ContainerReference"] as? String
                let capacity = Self.bytes(container["CapacityCeiling"])
                let free = Self.bytes(container["CapacityFree"])
                for case let member as [String: Any] in members {
                    guard let id = member["APFSVolumeUUID"] as? String, !id.isEmpty else { continue }
                    if (member["Roles"] as? [String])?.contains("Backup") == true {
                        backupUUIDs.insert(id)
                    }
                    guard let uuid = UUID(uuidString: id)?.uuidString else { continue }
                    guard seenUUIDs.insert(uuid).inserted else {
                        // Even a row with missing figures makes the UUID ambiguous.
                        volumes.removeValue(forKey: uuid)
                        continue
                    }
                    let quota = Self.bytes(member["CapacityQuota"])
                    let reserve = Self.bytes(member["CapacityReserve"])
                    guard let capacity, capacity > 0, let free, free <= capacity,
                          let used = Self.bytes(member["CapacityInUse"]), used <= capacity,
                          member["CapacityQuota"] == nil || quota != nil,
                          member["CapacityReserve"] == nil || reserve != nil
                    else { continue }
                    volumes[uuid] = (reference, ExternalVolume.APFSStorage(
                        containerCapacity: capacity, containerFree: free, volumeUsed: used,
                        quota: quota == 0 ? nil : quota, reserve: reserve == 0 ? nil : reserve))
                }
            }
        }

        func storage(for facts: VolumeFacts) -> ExternalVolume.APFSStorage? {
            guard let id = facts.uuid, let uuid = UUID(uuidString: id)?.uuidString,
                  let match = volumes[uuid], facts.containerID == nil || facts.containerID == match.container
            else { return nil }
            return match.storage
        }

        private static func bytes(_ value: Any?) -> Int64? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let bytes = Int64(number.stringValue), bytes >= 0
            else { return nil }
            return bytes
        }
    }

    /// The facts `mounted()` reads, for one mount URL. Nil when its resource values can't be read, or when it
    /// fails the cheap filter (`isCandidate`), so no probe runs for it.
    static func facts(for url: URL, probeRoots: Bool = true) -> VolumeFacts? {
        facts(for: url, session: DASessionCreate(kCFAllocatorDefault), probeRoots: probeRoots)
    }

    private static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeUUIDStringKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey,
        .volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ]

    private static func facts(for url: URL, session: DASession?, probeRoots: Bool) -> VolumeFacts? {
        guard let v = try? url.resourceValues(forKeys: Set(resourceKeys)),
              isCandidate(url: url, isRootFileSystem: v.volumeIsRootFileSystem ?? false, isLocal: v.volumeIsLocal)
        else { return nil }
        let disk = diskInfo(url, session: session)
        return VolumeFacts(
            url: url, name: v.volumeName ?? url.lastPathComponent,
            uuid: v.volumeUUIDString, isLocal: v.volumeIsLocal ?? false,
            isRootFileSystem: v.volumeIsRootFileSystem ?? false,
            isInternal: v.volumeIsInternal, isReadOnly: v.volumeIsReadOnly ?? false,
            format: v.volumeLocalizedFormatDescription ?? "",
            capacity: Int64(v.volumeTotalCapacity ?? 0),
            available: Int64(v.volumeAvailableCapacity ?? 0),
            isDiskImage: disk.isDiskImage,
            hasTimeMachineMarker: probeRoots && hasTimeMachineMarker(atPath: url.path),
            containerID: disk.containerID, isUSBAPFS: disk.isUSBAPFS)
    }

    /// One Disk Arbitration description per volume supplies the device and filesystem facts.
    private static func diskInfo(_ url: URL, session: DASession?) -> (isDiskImage: Bool, containerID: String?, isUSBAPFS: Bool) {
        guard let session,
            let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
            let desc = DADiskCopyDescription(disk) as? [String: Any]
        else { return (false, nil, false) }
        let model = desc[kDADiskDescriptionDeviceModelKey as String] as? String
        let isDiskImage = model?.trimmingCharacters(in: .whitespaces) == "Disk Image"
        let container = containerID(
            bsdName: desc[kDADiskDescriptionMediaBSDNameKey as String] as? String,
            volumeKind: desc[kDADiskDescriptionVolumeKindKey as String] as? String)
        let isUSBAPFS = confirmsUSBAPFS(
            containerID: container, deviceProtocol: desc[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            isInternal: desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool, isDiskImage: isDiskImage)
        return (isDiskImage, container, isUSBAPFS)
    }

    static func confirmsUSBAPFS(containerID: String?, deviceProtocol: String?, isInternal: Bool?, isDiskImage: Bool) -> Bool {
        containerID != nil && deviceProtocol == "USB" && isInternal == false && !isDiskImage
    }

    /// An APFS volume's container: its BSD name less the slice (`disk5s1` → `disk5`). Nil for any other
    /// filesystem (partitions don't share space) or a name with no slice.
    static func containerID(bsdName: String?, volumeKind: String?) -> String? {
        guard volumeKind?.lowercased() == "apfs", let bsdName,
              let match = bsdName.wholeMatch(of: /(disk\d+)s\d+/) else { return nil }
        return String(match.1)
    }

    /// Volume UUIDs of every Time Machine destination configured on this Mac.
    /// Missing or unreadable preferences give an empty set.
    static func timeMachineDestinationUUIDs(
        plistPath: String = "/Library/Preferences/com.apple.TimeMachine.plist"
    ) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: plistPath),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let destinations = plist["Destinations"] as? [[String: Any]]
        else { return [] }
        return Set(destinations.flatMap { ($0["DestinationUUIDs"] as? [String]) ?? [] })
    }

    /// Time Machine layouts at a volume root: HFS+ (`Backups.backupdb`), `.timemachine`,
    /// APFS (`backup_manifest.plist`), or a directory named with Time Machine's stamp,
    /// `YYYY-MM-DD-HHMMSS.previous` / `.backup` / `.inProgress`. A user's "iPhone.backup" doesn't count.
    static func hasTimeMachineMarker(atPath root: String) -> Bool {
        for marker in ["Backups.backupdb", ".timemachine", "backup_manifest.plist"] {
            var st = stat()
            if lstat(root + "/" + marker, &st) == 0 { return true }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.contains { n in
            guard n.wholeMatch(of: /\d{4}-\d{2}-\d{2}-\d{6}\.(backup|previous|inProgress)/) != nil else { return false }
            var st = stat()
            return lstat(root + "/" + n, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
        }
    }

    /// A user-selected write destination can be probed even when passive volume discovery didn't
    /// open its root. Use a fresh check before archive writes or releasing a local original.
    public static func isTimeMachineDestination(_ volume: ExternalVolume) -> Bool {
        volume.kind == .timeMachine || timeMachineDestinationUUIDs().contains(volume.id)
            || hasTimeMachineMarker(atPath: volume.url.path)
    }
}
