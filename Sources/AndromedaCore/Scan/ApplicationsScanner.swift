import Foundation

public struct AppItem: Equatable, Sendable {
    public let url: URL
    /// Allocated bytes for this entry. Hard links are deduplicated across the scan.
    public let bytes: Int64
    public let clonesPresent: Bool

    public init(url: URL, bytes: Int64, clonesPresent: Bool = false) {
        self.url = url
        self.bytes = bytes
        self.clonesPresent = clonesPresent
    }
}

/// Sizes the top-level entries of Applications and locates standalone apps in ordinary subfolders.
public struct ApplicationsScanner {
    private struct Entry: Sendable {
        let url: URL
        let identity: FileIdentity
    }

    private struct SizeJob: Sendable {
        let entry: Entry
        let group: Int
        var skipping: Set<FileIdentity> = []
        var isNestedApp = false
    }

    private let roots: [URL]
    private let sizer: AllocatedSizer

    /// Pass the scan's shared `sizer` so a hard link in another stage is not counted twice.
    public init(roots: [URL], sizer: AllocatedSizer = AllocatedSizer()) {
        self.roots = roots
        self.sizer = sizer
    }

    /// Items are sorted by bytes, largest first, then by path. 0-byte items (hard-link duplicates) are left out of
    /// `items`; `total` is unchanged by that. Nested app sizes are already included in their top-level groups.
    /// Catalog-claimed entries are excluded. An unreadable descendant is reported against its top-level group.
    /// A missing root contributes nothing; a root that exists but
    /// can't be listed is in `unreadable`. Symlinks and entries on another device than their root are skipped.
    /// Hidden entries (`.localized`, `.DS_Store`) are sized like any other. A cancelled `control` returns an
    /// empty result. `clonesPresent` is true when any app shares blocks with another file.
    public func scan(excluding claimed: [URL] = [], control: ScanControl?)
        -> (items: [AppItem], total: Int64, unreadable: [URL], clonesPresent: Bool, nestedItems: [AppItem]) {
        // This stage's own view: the scan's other stages may be using the shared sizer right now.
        let sizer = self.sizer.reporting(to: control)
        let lister = DirectoryLister(includeCloneRefCount: false)
        let skipped = Set(claimed.map { $0.standardizedFileURL.path })
        var unreadable: [URL] = []
        var groups: [URL] = []
        var jobs: [SizeJob] = []
        let shouldContinue = { control?.isCancelled != true }
        for root in roots {
            if !shouldContinue() { return ([], 0, [], false, []) }
            var rootStat = stat()
            #if ANDROMEDA_TRACE
            ScanTrace.note("lstat", root)
            #endif
            guard lstat(root.path, &rootStat) == 0 else {
                if errno != ENOENT { unreadable.append(root) }
                continue
            }
            #if ANDROMEDA_TRACE
            ScanTrace.note("list", root)
            #endif
            control?.entering(root)
            guard let entries = lister.entries(atPath: SafetyGuard.withoutSystemPathAlias(root.path),
                                               expectedIdentity: FileIdentity(dev: rootStat.st_dev, ino: rootStat.st_ino),
                                               shouldContinue: shouldContinue) else {
                unreadable.append(root)
                continue
            }
            for entry in entries {
                if !shouldContinue() { return ([], 0, [], false, []) }
                let isDirectory = entry.type == VDIR.rawValue
                if entry.error != 0 {
                    if entry.error != ENOENT {
                        unreadable.append(entry.name.isEmpty ? root : root.appendingPathComponent(entry.name))
                    }
                    continue
                }
                guard !entry.isMountPoint,
                      entry.type == VREG.rawValue || isDirectory,  // never follow symlinks
                      entry.device == rootStat.st_dev
                else { continue }
                let url = root.appendingPathComponent(entry.name, isDirectory: isDirectory)
                if skipped.contains(url.standardizedFileURL.path) { continue }
                let item = Entry(url: url, identity: FileIdentity(dev: entry.device, ino: entry.inode))
                let group = groups.count
                groups.append(url)
                var parentJob = SizeJob(entry: item, group: group)
                if isDirectory, Self.isVisibleLocalDirectory(entry), !SafetyGuard.isPackage(url) {
                    let nested = Self.discover(in: item, lister: lister, claimed: skipped, shouldContinue: shouldContinue)
                    jobs += nested.apps.map { SizeJob(entry: $0, group: group, isNestedApp: true) }
                    parentJob.skipping = nested.excluded
                }
                jobs.append(parentJob)
            }
        }
        let toSize = jobs
        let sized = AppSlots(count: toSize.count)
        DispatchQueue.concurrentPerform(iterations: toSize.count) { i in
            if !shouldContinue() { return }
            let job = toSize[i]
            sized.set(i, autoreleasepool {
                sizer.size(of: job.entry.url, order: i, skipping: job.skipping, matching: job.entry.identity)
            })
        }
        if !shouldContinue() { return ([], 0, [], false, []) }
        var bytesByGroup = Array(repeating: Int64(0), count: groups.count)
        var unreadableGroups: Set<Int> = []
        var sharedGroups: Set<Int> = []
        var nestedItems: [AppItem] = []
        for (i, job) in jobs.enumerated() {
            let result = sized.value(i)
            let bytes = result.bytes - sizer.handedBack(order: i).allocated
            bytesByGroup[job.group] += bytes
            if !result.unreadable.isEmpty { unreadableGroups.insert(job.group) }
            if result.clonesPresent, bytes > 0 { sharedGroups.insert(job.group) }
            if job.isNestedApp, bytes > 0 {
                nestedItems.append(AppItem(url: job.entry.url, bytes: bytes, clonesPresent: result.clonesPresent))
            }
        }
        unreadable += unreadableGroups.sorted().map { groups[$0] }
        let items = groups.indices.compactMap { index -> AppItem? in
            let bytes = bytesByGroup[index]
            return bytes > 0 ? AppItem(url: groups[index], bytes: bytes, clonesPresent: sharedGroups.contains(index)) : nil
        }
        func bySize(_ lhs: AppItem, _ rhs: AppItem) -> Bool {
            lhs.bytes != rhs.bytes ? lhs.bytes > rhs.bytes : lhs.url.path < rhs.url.path
        }
        return (items.sorted(by: bySize), bytesByGroup.reduce(0, +), unreadable, !sharedGroups.isEmpty,
                nestedItems.sorted(by: bySize))
    }

    private static func isVisibleLocalDirectory(_ entry: DirectoryEntry) -> Bool {
        entry.type == VDIR.rawValue && !entry.name.hasPrefix(".") && !entry.isMountPoint
            && entry.flags & (UInt32(SF_DATALESS) | UInt32(UF_HIDDEN)) == 0
    }

    private static func discover(
        in folder: Entry, lister: DirectoryLister, claimed: Set<String>, shouldContinue: () -> Bool
    ) -> (apps: [Entry], excluded: Set<FileIdentity>) {
        var pending = [folder]
        var apps: [Entry] = []
        var excluded: Set<FileIdentity> = []
        while shouldContinue(), let parent = pending.popLast() {
            let path = SafetyGuard.withoutSystemPathAlias(parent.url.path)
            guard let entries = lister.entries(atPath: path, followAncestorLinks: false,
                                               expectedIdentity: parent.identity, shouldContinue: shouldContinue)
            else { continue } // The sizing walk reports unreadable paths.
            for entry in entries {
                if !shouldContinue() { return (apps, excluded) }
                guard entry.error == 0, !entry.isMountPoint, entry.device == folder.identity.dev else { continue }
                let url = parent.url.appendingPathComponent(entry.name, isDirectory: entry.type == VDIR.rawValue)
                let item = Entry(url: url, identity: FileIdentity(dev: entry.device, ino: entry.inode))
                if claimed.contains(url.standardizedFileURL.path) {
                    excluded.insert(item.identity)
                } else if isVisibleLocalDirectory(entry) {
                    if url.pathExtension.lowercased() == "app" {
                        excluded.insert(item.identity)
                        apps.append(item)
                    } else if !SafetyGuard.isPackage(url) {
                        pending.append(item)
                    }
                }
            }
        }
        return (apps, excluded)
    }
}

/// One slot per app sized in parallel; each task writes only its own index.
private final class AppSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [SizeResult?]

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ i: Int, _ value: SizeResult) { lock.lock(); slots[i] = value; lock.unlock() }

    func value(_ i: Int) -> SizeResult { lock.lock(); defer { lock.unlock() }; return slots[i] ?? SizeResult(bytes: 0, unreadable: []) }
}
