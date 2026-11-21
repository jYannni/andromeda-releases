import Foundation

public enum PurgeableEstimate: Equatable, Sendable {
    case bytes(Int64)
    case notMeasurable
}

public struct OtherVolume: Equatable, Sendable {
    public let name: String
    public let roles: [String]
    public let used: Int64

    public init(name: String, roles: [String], used: Int64) {
        self.name = name
        self.roles = roles
        self.used = used
    }
}

public struct VolumeUsage: Equatable, Sendable {
    public let containerCapacity: Int64
    public let containerFree: Int64
    public let dataVolumeUsed: Int64
    public let purgeable: PurgeableEstimate
    /// Every volume in the Data volume's container except the Data volume.
    public let otherVolumes: [OtherVolume]

    /// What Storage settings calls used: container capacity minus container free.
    public var containerUsed: Int64 { containerCapacity - containerFree }

    /// Volumes macOS itself owns: those with a role other than Data (G-R5). A volume with no roles is a
    /// user-created one, which is not "macOS". The VM volume is counted by the swap catalog entry instead.
    private var roledVolumes: [OtherVolume] { otherVolumes.filter { !$0.roles.isEmpty } }

    public var macOSVolumesUsed: Int64 {
        roledVolumes.filter { !$0.roles.contains("VM") && !$0.roles.contains("Data") }.reduce(0) { $0 + $1.used }
    }

    /// Container space that neither the Data volume nor a role-bearing volume accounts for (clamped at 0).
    /// Role-less (user-created) volumes land here, so they can raise the "other volumes" reason.
    public var unattributedContainerBytes: Int64 {
        max(0, containerUsed - (dataVolumeUsed + roledVolumes.reduce(0) { $0 + $1.used }))
    }

    public init(containerCapacity: Int64, containerFree: Int64, dataVolumeUsed: Int64, purgeable: PurgeableEstimate,
                otherVolumes: [OtherVolume] = []) {
        self.otherVolumes = otherVolumes
        self.containerCapacity = containerCapacity
        self.containerFree = containerFree
        self.dataVolumeUsed = dataVolumeUsed
        self.purgeable = purgeable
    }
}

public enum PurgeablePolicy {
    // PROVISIONAL: see docs/research/macos27-checks.md (check 4), pending Yanko's Storage-settings reading.
    public static let measurableOnMacOS27: Bool = true
}

public enum VolumeUsageParser {
    public enum ParseError: Error { case malformedPlist, noDataVolume, missingCapacity }

    public static func parse(
        apfsList plist: Data, importantUsage: Int64, available: Int64, osMajor: Int, dataVolumeUUID: String? = nil
    ) throws -> VolumeUsage {
        let any = try PropertyListSerialization.propertyList(from: plist, options: [], format: nil)
        guard let root = any as? [String: Any], let containers = root["Containers"] as? [[String: Any]] else {
            throw ParseError.malformedPlist
        }
        for container in containers {
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            guard let data = volumes.first(where: {
                guard ($0["Roles"] as? [String])?.contains("Data") == true else { return false }
                guard let dataVolumeUUID else { return true }
                return ($0["APFSVolumeUUID"] as? String)?.caseInsensitiveCompare(dataVolumeUUID) == .orderedSame
            }),
                  let used = int64(data["CapacityInUse"]),
                  let capacity = int64(container["CapacityCeiling"]),
                  let free = int64(container["CapacityFree"])
            else { continue }
            let purgeable: PurgeableEstimate =
                (osMajor >= 27 && !PurgeablePolicy.measurableOnMacOS27)
                ? .notMeasurable
                : .bytes(max(0, importantUsage - available))
            let others = volumes.filter { ($0["Roles"] as? [String])?.contains("Data") != true }.map {
                OtherVolume(
                    name: $0["Name"] as? String ?? "",
                    roles: $0["Roles"] as? [String] ?? [],
                    used: int64($0["CapacityInUse"]) ?? 0)
            }
            return VolumeUsage(
                containerCapacity: capacity, containerFree: free, dataVolumeUsed: used,
                purgeable: purgeable, otherVolumes: others)
        }
        throw ParseError.noDataVolume
    }

    private static func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}

public protocol VolumeUsageProvider: Sendable {
    func current() throws -> VolumeUsage
}

public struct LiveVolumeUsageProvider: VolumeUsageProvider {
    private let runner: any ToolRunner

    public init(runner: any ToolRunner = LiveToolRunner()) { self.runner = runner }

    public func current() throws -> VolumeUsage {
        let exe = URL(fileURLWithPath: "/usr/sbin/diskutil")
        let result = try runner.run(exe, ["apfs", "list", "-plist"])
        guard result.exitCode == 0 else {
            throw ToolError.failed(executable: exe.path, exitCode: result.exitCode, stderr: result.stderr)
        }
        let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        guard let important = values.volumeAvailableCapacityForImportantUsage,
              let available = values.volumeAvailableCapacity
        else { throw VolumeUsageParser.ParseError.missingCapacity }
        return try VolumeUsageParser.parse(
            apfsList: Data(result.stdout.utf8),
            importantUsage: important,
            available: Int64(available),
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            dataVolumeUUID: try? URL(fileURLWithPath: "/System/Volumes/Data").resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    }
}
