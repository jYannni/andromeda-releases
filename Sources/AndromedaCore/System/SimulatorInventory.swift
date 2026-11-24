import Foundation

/// The entries that CoreSimulator reports for the active Xcode and the current user's device set.
public struct SimulatorInventory: Equatable, Sendable {
    public enum Group: String, Sendable {
        case devices = "simulator-unavailable-devices"
        case runtimes = "simulator-runtimes"
        case systemRuntimes = "orphaned-simulator-runtimes"
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let detail: String
        public let bytes: Int64?
        public let systemAssetBytes: Int64?
        public var canRemove: Bool { arguments != nil }
        fileprivate let group: Group
        fileprivate let arguments: [String]?
    }

    private static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
    private static let systemAssetFolder = "com_apple_MobileAsset_iOSSimulatorRuntime"
    private static let runtimePrefix = "com.apple.CoreSimulator.SimRuntime."

    public let devices: [Entry]
    public let runtimes: [Entry]
    public let systemRuntimes: [Entry]
    public let devicesAvailable: Bool
    public let runtimeImagesAvailable: Bool
    /// Allocated space in system asset directories outside the active Xcode runtime list.
    public let unlistedSystemAssetBytes: Int64?

    public subscript(group: Group) -> [Entry] {
        switch group {
        case .devices: devices
        case .runtimes: runtimes
        case .systemRuntimes: systemRuntimes
        }
    }

    public static func read(
        using tools: any ToolRunner, group: Group, env: ScanEnvironment? = nil
    ) -> SimulatorInventory {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(12)
        func run(_ executable: URL, _ arguments: [String]) -> Data? {
            let result: ToolResult?
            if let live = tools as? LiveToolRunner {
                result = try? live.run(executable, arguments, wakeOnExit: true, shouldContinue: { clock.now < deadline })
            } else {
                result = try? tools.run(executable, arguments)
            }
            guard let result, result.exitCode == 0 else { return nil }
            return Data(result.stdout.utf8)
        }

        let listing = run(xcrun, ["simctl", "list", "-j", "devices", "runtimes"])
            .flatMap { try? JSONDecoder().decode(Listing.self, from: $0) }
        let images = group == .devices ? nil : run(xcrun, ["simctl", "runtime", "list", "-j"])
            .flatMap { try? JSONDecoder().decode([String: Image].self, from: $0) }
        let imagesByID = images ?? [:]
        let usesMountedBundles = imagesByID.values.contains { $0.paths.contains(where: isMountedBundlePath) }
        let mounts = usesMountedBundles ? run(hdiutil, ["info", "-plist"])
            .flatMap { try? PropertyListDecoder().decode(MountedImages.self, from: $0) }?.byMountPoint : [:]
        let backingAssetNames = imagesByID.compactMapValues { image in
            image.paths.lazy.compactMap { systemAssetName(backingPath(for: $0, mounts: mounts ?? [:])) }.first
        }
        let backingAssetCounts = Dictionary(grouping: backingAssetNames.values, by: { $0 }).mapValues(\.count)
        let assetSizes = group == .systemRuntimes && images != nil ? env.flatMap(measureSystemAssets) : nil
        let deviceGroups = listing?.devices ?? [:]
        let installed = listing?.runtimes ?? []
        let byRuntime = Dictionary(installed.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })

        let devices = deviceGroups.flatMap { runtime, devices in
            let os = byRuntime[runtime]?.name ?? runtimeTitle(runtime)
            return devices.map { device in
                let id = device.udid.uuidString
                return Entry(id: id, name: device.name,
                             detail: "\(os) · \(device.isAvailable == false ? "Unavailable" : device.state)",
                             bytes: device.dataPathSize, systemAssetBytes: nil, group: .devices, arguments: ["simctl", "delete", id])
            }
        }.sorted(by: byNameAndDetail)

        let runtimeImages = imagesByID.map { key, image in
            let runtime = image.runtimeIdentifier.flatMap { byRuntime[$0] }
            let name = runtime?.name ?? image.runtimeIdentifier.map(runtimeTitle)
                ?? [image.platformName, image.version].compactMap { $0 }.joined(separator: " ")
            let nameOfAsset = backingAssetNames[key]
            let group: Group = nameOfAsset != nil || image.paths.contains(where: isSystemAsset)
                ? .systemRuntimes : .runtimes
            let onDiskBytes = nameOfAsset.flatMap { backingAssetCounts[$0] == 1 ? assetSizes?[$0] : nil }
            let id = UUID(uuidString: key)?.uuidString
            let arguments = image.deletable == true ? id.map { ["simctl", "runtime", "delete", $0] } : nil
            let count = image.runtimeIdentifier.flatMap { deviceGroups[$0]?.count } ?? 0
            return Entry(id: id ?? key, name: name.isEmpty ? "Simulator runtime" : name,
                         detail: runtimeDetail(build: image.build, count: count, knowsDevices: listing?.devices != nil),
                         bytes: image.sizeBytes, systemAssetBytes: onDiskBytes, group: group, arguments: arguments)
        }

        let imageRuntimeIDs = Set(imagesByID.values.compactMap(\.runtimeIdentifier))
        let otherRuntimes = installed.filter { !imageRuntimeIDs.contains($0.identifier) }.map { runtime in
            Entry(id: runtime.identifier, name: runtime.name,
                  detail: runtimeDetail(build: runtime.buildversion, count: deviceGroups[runtime.identifier]?.count ?? 0,
                                        knowsDevices: listing?.devices != nil),
                  bytes: nil, systemAssetBytes: nil, group: .runtimes, arguments: nil)
        }

        let unlistedSystemAssetBytes: Int64?
        // A failed mount lookup can hide registered assets. Avoid labelling the remainder as unlisted.
        if images != nil, mounts != nil, let assetSizes {
            unlistedSystemAssetBytes = assetSizes.reduce(into: Int64(0)) { total, asset in
                if backingAssetCounts[asset.key] == nil { total += asset.value }
            }
        } else {
            unlistedSystemAssetBytes = nil
        }

        return SimulatorInventory(devices: devices,
                                  runtimes: (runtimeImages.filter { $0.group == .runtimes } + otherRuntimes)
                                      .sorted(by: byNameAndDetail),
                                  systemRuntimes: runtimeImages.filter { $0.group == .systemRuntimes }
                                      .sorted(by: byNameAndDetail),
                                  devicesAvailable: listing?.devices != nil, runtimeImagesAvailable: images != nil,
                                  unlistedSystemAssetBytes: unlistedSystemAssetBytes)
    }

    public func removalPlan(for group: Group, selected: Set<String>) -> RemovalPlan? {
        let entries = self[group].filter { selected.contains($0.id) }
        guard !entries.isEmpty, entries.count == selected.count, entries.allSatisfy(\.canRemove) else { return nil }
        let removals = entries.compactMap { entry -> PlannedRemoval? in
            guard let arguments = entry.arguments else { return nil }
            return PlannedRemoval(catalogEntryID: group.rawValue, action: .runTool(executable: Self.xcrun, arguments: arguments),
                                  expectedBytes: nil, expectation: nil, appsMustBeQuit: [])
        }
        return RemovalPlan(removals: removals)
    }

    private static func measureSystemAssets(env: ScanEnvironment) -> [String: Int64]? {
        let folder = env.root.appendingPathComponent("System/Library/AssetsV2", isDirectory: true)
            .appendingPathComponent(systemAssetFolder, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return nil }

        let sizer = AllocatedSizer()
        var bytes: [String: Int64] = [:]
        for child in children where child.pathExtension == "asset" {
            guard let values = try? child.resourceValues(forKeys: keys) else { return nil }
            guard values.isDirectory == true, values.isSymbolicLink == false else { continue }
            let size = sizer.size(of: child)
            guard size.unreadable.isEmpty else { return nil }
            bytes[child.lastPathComponent] = size.bytes
        }
        return bytes
    }

    private static func isMountedBundlePath(_ path: String) -> Bool {
        path.hasPrefix("/Library/Developer/CoreSimulator/Cryptex/Images/bundle/")
    }

    /// A Cryptex may expose an inner simulator image from a mounted outer image. Follow its backing
    /// image to find the asset that is actually counted in the disk scan.
    private static func backingPath(for path: String, mounts: [String: String]) -> String {
        var path = path
        var visited: Set<String> = []
        while visited.insert(path).inserted {
            if isSystemAsset(path) { break }
            guard let mount = mounts.keys.filter({ path == $0 || path.hasPrefix($0 + "/") })
                .max(by: { $0.count < $1.count }), let backing = mounts[mount] else { break }
            path = backing
        }
        return path
    }

    private static func systemAssetName(_ path: String) -> String? {
        guard isSystemAsset(path) else { return nil }
        let components = URL(fileURLWithPath: path).pathComponents
        guard let folder = components.firstIndex(of: systemAssetFolder), folder + 1 < components.count else { return nil }
        let name = components[folder + 1]
        return name.hasSuffix(".asset") ? name : nil
    }

    private static func isSystemAsset(_ path: String) -> Bool {
        path.hasPrefix("/System/Library/AssetsV2/") || path.hasPrefix("/Library/Apple/System/Library/AssetsV2/")
    }

    private static func byNameAndDetail(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        if order != .orderedSame { return order == .orderedAscending }
        let details = lhs.detail.localizedStandardCompare(rhs.detail)
        return details == .orderedSame ? lhs.id < rhs.id : details == .orderedAscending
    }

    private static func runtimeDetail(build: String?, count: Int, knowsDevices: Bool) -> String {
        let devices = knowsDevices ? "\(count) \(count == 1 ? "device" : "devices")" : "Device count unavailable"
        return [build, devices].compactMap { $0 }.joined(separator: " · ")
    }

    private static func runtimeTitle(_ identifier: String) -> String {
        guard identifier.hasPrefix(runtimePrefix) else { return identifier }
        let parts = identifier.dropFirst(runtimePrefix.count).split(separator: "-")
        guard let platform = parts.first else { return identifier }
        let version = parts.dropFirst().prefix { Int($0) != nil }.joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }

    private struct Listing: Decodable {
        let devices: [String: [Device]]?
        let runtimes: [Runtime]?
    }

    private struct Device: Decodable {
        let udid: UUID
        let name: String
        let state: String
        let isAvailable: Bool?
        let dataPathSize: Int64?
    }

    private struct Runtime: Decodable {
        let identifier: String
        let name: String
        let buildversion: String?
    }

    private struct MountedImages: Decodable {
        let images: [MountedImage]

        var byMountPoint: [String: String] {
            var mounts: [String: String] = [:]
            for image in images {
                guard let path = image.path, path.hasPrefix("/") else { continue }
                for entity in image.entities ?? [] {
                    if let mount = entity.mountPoint { mounts[mount] = path }
                }
            }
            return mounts
        }
    }

    private struct MountedImage: Decodable {
        let path: String?
        let entities: [Entity]?

        enum CodingKeys: String, CodingKey {
            case path = "image-path"
            case entities = "system-entities"
        }

        struct Entity: Decodable {
            let mountPoint: String?
            enum CodingKeys: String, CodingKey { case mountPoint = "mount-point" }
        }
    }

    private struct Image: Decodable {
        let runtimeIdentifier: String?
        let platformIdentifier: String?
        let version: String?
        let build: String?
        let path: String?
        let parentMountPath: String?
        let sizeBytes: Int64?
        let deletable: Bool?

        var paths: [String] { [path, parentMountPath].compactMap { $0 } }

        var platformName: String? {
            switch platformIdentifier {
            case "com.apple.platform.iphonesimulator": "iOS"
            case "com.apple.platform.appletvsimulator": "tvOS"
            case "com.apple.platform.watchsimulator": "watchOS"
            case "com.apple.platform.xrsimulator": "visionOS"
            default: nil
            }
        }
    }
}
