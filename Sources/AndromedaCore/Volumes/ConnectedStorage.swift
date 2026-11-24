import Darwin
import Foundation

/// Free space on mounted local drives. An APFS container contributes its shared space only once.
public struct ConnectedStorage: Equatable, Sendable {
    public struct StartupDisk: Equatable, Sendable {
        public let name: String
        public let volumeID: String?
        public let capacity: Int64
        public let free: Int64
        let containerID: String?
    }

    public let startup: StartupDisk?
    public let totalFree: Int64?
    public let mountedVolumeCount: Int
    public let hasMissingReadings: Bool

    public static func current() -> Self {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let dataRoot = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        let name = (try? root.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "Startup Disk"
        let startup = startupDisk(at: dataRoot, name: name) ?? startupDisk(at: root, name: name)
        let discovered = VolumeDiscovery.mounted(probeRoots: false)
        let knownPaths = Set(discovered.map { $0.url.standardizedFileURL.path })
        let fallback = mountedFileSystems().compactMap { info -> ExternalVolume? in
            let path = fileSystemString(info.f_mntonname)
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard !knownPaths.contains(url.path),
                  info.f_flags & UInt32(MNT_DONTBROWSE) == 0,
                  VolumeDiscovery.isCandidate(url: url, isRootFileSystem: false,
                                              isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0),
                  let device = deviceName(info), let bytes = space(info)
            else { return nil }
            let format = fileSystemString(info.f_fstypename)
            return ExternalVolume(id: "path:" + url.path, name: url.lastPathComponent, url: url, kind: .drive,
                                  isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0, format: format,
                                  capacity: bytes.capacity, available: bytes.free,
                                  containerID: VolumeDiscovery.containerID(bsdName: device, volumeKind: format))
        }
        return Self(startup: startup, volumes: discovered + fallback)
    }

    private static func startupDisk(at url: URL, name: String) -> StartupDisk? {
        var info = statfs()
        guard statfs(url.path, &info) == 0, let bytes = space(info) else { return nil }
        let volumeID = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        let containerID = VolumeDiscovery.containerID(bsdName: deviceName(info), volumeKind: fileSystemString(info.f_fstypename))
        return StartupDisk(name: name, volumeID: volumeID, capacity: bytes.capacity, free: bytes.free,
                           containerID: containerID)
    }

    private static func space(_ info: statfs) -> (capacity: Int64, free: Int64)? {
        guard let capacity = Int64(exactly: info.f_blocks), let free = Int64(exactly: info.f_bavail) else { return nil }
        let (capacityBytes, capacityOverflow) = capacity.multipliedReportingOverflow(by: Int64(info.f_bsize))
        let (freeBytes, freeOverflow) = free.multipliedReportingOverflow(by: Int64(info.f_bsize))
        guard !capacityOverflow, !freeOverflow, capacityBytes > 0, freeBytes <= capacityBytes else { return nil }
        return (capacityBytes, freeBytes)
    }

    private static func deviceName(_ info: statfs) -> String? {
        // A sealed startup snapshot can have a BSD name like disk3s1s1.
        fileSystemString(info.f_mntfromname).wholeMatch(of: #/\/dev\/(disk\d+(?:s\d+)?)(?:s\d+)?/#).map { String($0.1) }
    }

    private static func fileSystemString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// The kernel's mount table stays available when Foundation can't enumerate volumes.
    private static func mountedFileSystems() -> [statfs] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // Allow for mounts added between the count and the read.
        return Array(unsafeUninitializedCapacity: Int(count) + 8) { buffer, initializedCount in
            let bytes = Int32(buffer.count * MemoryLayout<statfs>.stride)
            initializedCount = max(0, Int(getfsstat(buffer.baseAddress, bytes, MNT_NOWAIT)))
        }
    }

    init(startup: StartupDisk?, volumes: [ExternalVolume]) {
        self.startup = startup
        let drives = volumes.filter { $0.kind != .diskImage }
        mountedVolumeCount = drives.count + 1
        var missing = startup == nil
        var readings: [Int64] = []
        if let startup { readings.append(startup.free) }

        let additional = drives.filter { volume in
            guard let startupContainer = startup?.containerID else { return true }
            return volume.containerID != startupContainer
        }
        let shared = Dictionary(grouping: additional.filter { $0.containerID != nil }, by: \.containerID)
        for group in shared.values {
            if group.allSatisfy(\.isReadOnly) {
                readings.append(0)
            } else if let free = group.compactMap({ $0.apfsStorage?.containerFree }).first {
                readings.append(free)
            } else if let free = group.compactMap(Self.available).max() {
                readings.append(free)
            } else {
                missing = true
            }
        }
        for volume in additional where volume.containerID == nil {
            if let free = Self.available(volume) { readings.append(free) } else { missing = true }
        }
        totalFree = readings.isEmpty ? nil : readings.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
        hasMissingReadings = missing
    }

    private static func available(_ volume: ExternalVolume) -> Int64? {
        guard volume.capacity > 0, (0...volume.capacity).contains(volume.available) else { return nil }
        return volume.isReadOnly ? 0 : volume.available
    }
}
