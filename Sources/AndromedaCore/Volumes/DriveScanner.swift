import Foundation
import Synchronization

/// A folder macOS keeps at a drive's top level that Finder doesn't show.
public struct HiddenSpaceItem: Equatable, Sendable {
    public enum Kind: String, Sendable { case trash, spotlight, fsevents, versions, timeMachineBackups }
    public let kind: Kind
    public let url: URL
    public let bytes: Int64?        // nil = not measured (unreadable)
    public let freesAtLeast: Int64?

    public init(kind: Kind, url: URL, bytes: Int64?, freesAtLeast: Int64?) {
        self.kind = kind
        self.url = url
        self.bytes = bytes
        self.freesAtLeast = freesAtLeast
    }
}

public struct DriveScanResult: Equatable, Sendable {
    public let volume: ExternalVolume
    public let hidden: [HiddenSpaceItem]       // only the kinds present on the drive
    public let largeItems: [LargeItem]
    public let otherBytes: Int64              // sized but not in a large item or hidden item
    public let unreadable: [URL]
    public let finishedAt: Date
    /// Complete top-level folder sizes, keyed by name relative to the volume.
    public let folderSizes: [String: Int64]

    public var rootWasUnreadable: Bool {
        unreadable.contains { $0.standardizedFileURL.path == volume.url.standardizedFileURL.path }
    }

    public init(
        volume: ExternalVolume, hidden: [HiddenSpaceItem], largeItems: [LargeItem], otherBytes: Int64,
        unreadable: [URL], finishedAt: Date, folderSizes: [String: Int64] = [:]
    ) {
        self.volume = volume
        self.hidden = hidden
        self.largeItems = largeItems
        self.otherBytes = otherBytes
        self.unreadable = unreadable
        self.finishedAt = finishedAt
        self.folderSizes = folderSizes
    }
}

public enum DriveScanOutcome: Equatable, Sendable { case done(DriveScanResult), cancelled, disconnected }

/// Scans an external drive, reporting visible items while measuring hidden locations separately.
public struct DriveScanner {
    private let volume: ExternalVolume
    private let uid: uid_t
    private let threshold: Int64
    private let isMounted: @Sendable () -> Bool

    public init(volume: ExternalVolume, uid: uid_t = getuid(), threshold: Int64 = 1_000_000_000,
                isMounted: @escaping @Sendable () -> Bool) {
        self.volume = volume
        self.uid = uid
        self.threshold = threshold
        self.isMounted = isMounted
    }

    var workerLimit: Int {
        volume.kind == .drive && volume.isUSBAPFS ? 6 : LargeItemsScanner.defaultDriveWorkerLimit
    }

    /// Hidden folders relative to the mount, in display order.
    private static func hiddenPaths(uid: uid_t) -> [(HiddenSpaceItem.Kind, String)] {
        [
            (.trash, ".Trashes/\(uid)"),
            (.spotlight, ".Spotlight-V100"),
            (.fsevents, ".fseventsd"),
            (.versions, ".DocumentRevisions-V100"),
            (.timeMachineBackups, "Backups.backupdb"),
        ]
    }

    /// The browser presents visible storage. The drive page measures these system locations separately.
    public static func browserExclusions(on root: URL) -> [URL] {
        hiddenPaths(uid: getuid()).map { _, path in
            root.appendingPathComponent(String(path.prefix(while: { $0 != "/" })), isDirectory: true)
        }
    }

    /// `isMounted` is checked before the walk and after it; false at either point ends `.disconnected`.
    /// A cancelled `control` ends `.cancelled` and the partial result is discarded.
    public func scan(control: ScanControl?) -> DriveScanOutcome {
        guard isMounted() else { return .disconnected }
        if control?.isCancelled == true { return .cancelled }
        let root = volume.url
        let freshRoot = URL(fileURLWithPath: root.path, isDirectory: true)
        let capabilities = try? freshRoot.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
        let volumeCannotClone = capabilities?.volumeSupportsFileCloning == false
        let hiddenLocations = Self.hiddenPaths(uid: uid).compactMap { kind, path -> (HiddenSpaceItem.Kind, URL)? in
            let url = root.appendingPathComponent(path, isDirectory: true)
            var st = stat()
            return lstat(url.path, &st) == 0 ? (kind, url) : nil
        }

        // home = the mount, so home-relative logic (prompting paths, the Library split) never matches a real home.
        let trashes = root.appendingPathComponent(".Trashes", isDirectory: true)
        let env = ScanEnvironment(
            home: root, root: root, trash: trashes,
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        let sizer = AllocatedSizer()
        var walk = LargeItemsScanner(env: env, threshold: threshold, promptingPathsReadable: true, root: root, sizer: sizer)
        walk.bucketsRelativeToHome = false
        walk.skipsSingleLinkInodes = true
        let limit = workerLimit
        walk.driveWorkerLimit = limit
        walk.volumeCannotClone = volumeCannotClone
        walk.prefersWholeCloneFlag = capabilities?.volumeSupportsFileCloning == true

        let hiddenWalk: HiddenDriveWalk?
        if let control, !hiddenLocations.isEmpty, limit > 1 {
            let slots = DriveScanWorkerSlots(limit: limit)
            let task = HiddenDriveWalk()
            walk.sharedDriveWorkerSlots = slots
            // Give visible files the full budget until the first preview has been delivered.
            walk.onFirstDrivePreview = {
                guard !control.isCancelled else { return }
                task.start(slots: slots) {
                    Self.measureHidden(hiddenLocations, volumeCannotClone: volumeCannotClone,
                                       sizer: sizer.reporting(to: control), beforeCountingLinks: task.waitForVisible)
                }
            }
            hiddenWalk = task
        } else {
            hiddenWalk = nil
        }

        let found = walk.scan(excluding: hiddenLocations.map(\.1), control: control,
                              comparisonDepth: volume.hasStableIdentity || control != nil ? 1 : 0)
        hiddenWalk?.visibleDidFinish()
        let concurrentHidden = hiddenWalk?.waitForMeasurement()
        if control?.isCancelled == true { return .cancelled }
        let measured = concurrentHidden
            ?? Self.measureHidden(hiddenLocations, volumeCannotClone: volumeCannotClone,
                                  sizer: sizer.reporting(to: control))
        if control?.isCancelled == true { return .cancelled }
        guard isMounted() else { return .disconnected }
        let mount = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let folders = found.folders.compactMap { path, bytes -> (String, Int64)? in
            guard path.hasPrefix(mount) else { return nil }
            let name = String(path.dropFirst(mount.count))
            guard !name.isEmpty, !name.contains("/") else { return nil }
            return (name, bytes)
        }
        return .done(DriveScanResult(
            volume: volume, hidden: measured.items, largeItems: found.items,
            otherBytes: found.unlisted[.documents] ?? 0,
            unreadable: measured.unreadable + found.unreadable, finishedAt: Date(),
            folderSizes: volume.hasStableIdentity ? Dictionary(uniqueKeysWithValues: folders) : [:]))
    }

    private static func measureHidden(
        _ locations: [(HiddenSpaceItem.Kind, URL)], volumeCannotClone: Bool, sizer: AllocatedSizer,
        beforeCountingLinks: () -> Void = {}
    ) -> HiddenDriveMeasurement {
        var items: [HiddenSpaceItem] = []
        var unreadable: [URL] = []
        for (kind, url) in locations {
            if sizer.control?.isCancelled == true { break }
            let r = sizer.sizeOfHiddenDriveFolder(url, volumeCannotClone: volumeCannotClone,
                                                 beforeCountingLinks: beforeCountingLinks)
            if sizer.control?.isCancelled == true { break }
            unreadable += r.unreadable
            let rootUnreadable = r.bytes == 0
                && r.unreadable.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
            items.append(HiddenSpaceItem(
                kind: kind, url: url,
                bytes: rootUnreadable ? nil : r.bytes,
                freesAtLeast: rootUnreadable ? nil : r.privateBytes))
        }
        return HiddenDriveMeasurement(items: items, unreadable: unreadable)
    }
}

private struct HiddenDriveMeasurement: Sendable {
    let items: [HiddenSpaceItem]
    let unreadable: [URL]
}

/// Owned by one synchronous drive scan. Join the hidden walk before publishing any terminal outcome.
private final class HiddenDriveWalk: Sendable {
    private let group = DispatchGroup()
    private let visible = DispatchGroup()
    private let measurement = Mutex<HiddenDriveMeasurement?>(nil)

    init() { visible.enter() }

    func visibleDidFinish() { visible.leave() }

    func waitForVisible() { visible.wait() }

    func start(slots: DriveScanWorkerSlots, measure: @escaping @Sendable () -> HiddenDriveMeasurement) {
        group.enter()
        slots.claimWhenAvailable { [self] in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer {
                    slots.release()
                    group.leave()
                }
                let measured = measure()
                measurement.withLock { $0 = measured }
            }
        }
    }

    func waitForMeasurement() -> HiddenDriveMeasurement? {
        group.wait()
        return measurement.withLock { $0 }
    }
}
