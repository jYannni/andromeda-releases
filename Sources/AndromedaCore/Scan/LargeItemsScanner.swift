import Foundation
import Synchronization

public struct LargeItem: Equatable, Sendable {
    public let url: URL
    /// Allocated bytes of unclaimed content; excludes claimed, Trash, symlinked and not-downloaded
    /// descendants. Large items are for reveal only and are never offered for removal.
    public let bytes: Int64
    /// A guess at the Storage-settings bucket; the UI labels it "probably".
    public let probableBucket: AppleBucket

    /// Some of its space is shared with clones, so removing it would free less than `bytes`.
    /// Display only: large items are never offered for removal.
    public let clonesPresent: Bool

    public init(url: URL, bytes: Int64, probableBucket: AppleBucket, clonesPresent: Bool = false) {
        self.clonesPresent = clonesPresent
        self.url = url
        self.bytes = bytes
        self.probableBucket = probableBucket
    }
}

/// Finds the deepest big files and folders in home that the catalog did not claim (the "long tail").
public struct LargeItemsScanner {
    private let env: ScanEnvironment
    private let threshold: Int64
    private let promptingPathsReadable: Bool
    private let root: URL
    private let sizer: AllocatedSizer
    /// Test seam: replaces the `getattrlistbulk` listing. Nil in production. Must be safe to call from
    /// several threads at once (the walk lists sibling subtrees in parallel).
    var listEntries: (@Sendable (String) -> [DirectoryEntry]?)?
    /// Default depth for parallel sibling walks; 0 disables parallel walking (test seam).
    var parallelDepth = 3
    static let defaultDriveWorkerLimit = 4
    var driveWorkerLimit = Self.defaultDriveWorkerLimit
    var sharedDriveWorkerSlots: DriveScanWorkerSlots?
    var onFirstDrivePreview: (@Sendable () -> Void)?
    /// False for a drive, which has no Library: `probableBucket` is never called, every item is `.documents`
    /// and every unlisted byte goes to `.documents`.
    public var bucketsRelativeToHome = true
    /// An isolated walk of a single volume tree, without a sizer shared by other scan stages.
    var skipsSingleLinkInodes = false
    /// The drive confirmed that it cannot contain clones.
    var volumeCannotClone = false
    /// Only the visible drive walk requires a yes-or-no answer about whole clones.
    var prefersWholeCloneFlag = false

    /// `root` is where the walk starts; nil means `env.home` (the whole-home scan). `probableBucket` stays relative to `env.home`.
    /// `promptingPathsReadable` is `fda == .granted`. When false the walk records each protected folder
    /// (Desktop, Documents, app containers, ...) as unreadable and never stats, lists or sizes anything inside it.
    public init(env: ScanEnvironment, threshold: Int64 = 1_000_000_000, promptingPathsReadable: Bool = true, root: URL? = nil, sizer: AllocatedSizer = AllocatedSizer()) {
        self.env = env
        self.root = root ?? env.home
        self.threshold = threshold
        self.promptingPathsReadable = promptingPathsReadable
        self.sizer = sizer
    }

    /// `unlistedClones` is true when some unlisted bytes share space. `unlistedCloneBuckets` identifies those buckets.
    /// `unlisted[b]` is the allocated bytes sized under home's children of probable bucket `b` that are not inside
    /// a reported item (small files, folders below the threshold). Same walk, no extra I/O.
    /// A cancelled `control` stops the walk; the caller discards the partial result.
    public func scan(
        excluding claimed: [URL], control: ScanControl? = nil, comparisonDepth: Int = 0, captureFolderPresence: Bool = false
    ) -> (items: [LargeItem], unreadable: [URL], unlisted: [AppleBucket: Int64], unlistedClones: Bool,
          folders: [String: Int64], listedDirectories: [String: Set<String>], unlistedCloneBuckets: Set<AppleBucket>) {
        var homeStat = stat()
        #if ANDROMEDA_TRACE
        ScanTrace.note("lstat", root)
        #endif
        guard lstat(root.path, &homeStat) == 0 else {
            return ([], errno == ENOENT ? [] : [root], [:], false, [:], [:], [])
        }
        // This stage's own view: the applications stage may be using the shared sizer right now.
        let sizer = self.sizer.reporting(to: control)
        let identity = FileIdentity(dev: homeStat.st_dev, ino: homeStat.st_ino)
        let verifiedLocalAPFS = prefersWholeCloneFlag
            && DirectoryLister.localAPFSDevice(atPath: root.path, matching: identity) != nil
        let list: @Sendable (String, DirectoryListing.SummaryPolicy?) -> DirectoryListing?
        if let seam = listEntries {
            list = { path, _ in seam(path).map { DirectoryListing(entries: $0) } }
        } else {
            let pool = DirectoryListerPool(includeLinkCount: skipsSingleLinkInodes,
                                           includeCloneRefCount: !volumeCannotClone,
                                           readsWholeCloneFlag: verifiedLocalAPFS)
            list = { pool.listing(atPath: $0, summarize: $1, control: control) }
        }
        let skipped = Set((claimed + [env.trash]).map(Self.skipKey))
        var skippedNames: [String: Set<String>] = [:]
        if skipsSingleLinkInodes, !bucketsRelativeToHome {
            for path in skipped {
                let urlPath = path as NSString
                skippedNames[urlPath.deletingLastPathComponent, default: []].insert(urlPath.lastPathComponent)
            }
        }
        var run = Run(
            sizer: sizer,
            control: control,
            threshold: threshold,
            promptingPathsReadable: promptingPathsReadable,
            env: env,
            home: env.home,
            listEntries: list,
            parallelDepth: parallelDepth,
            driveWorkerLimit: driveWorkerLimit,
            bucketsRelativeToHome: bucketsRelativeToHome,
            comparisonDepth: comparisonDepth,
            captureFolderPresence: captureFolderPresence,
            skipsSingleLinkInodes: skipsSingleLinkInodes,
            volumeCannotClone: volumeCannotClone,
            verifiedLocalAPFS: verifiedLocalAPFS,
            device: homeStat.st_dev,
            skipped: skipped,
            skippedNames: skippedNames,
            onFirstDrivePreview: onFirstDrivePreview,
            workerSlots: sharedDriveWorkerSlots)
        _ = run.visit(root, isHome: true)
        if control?.isCancelled == true { return ([], [], [:], false, [:], [:], []) }
        return (run.items.sorted { $0.bytes > $1.bytes }, run.unreadable, run.unlisted, !run.unlistedCloneBuckets.isEmpty,
                run.folders, run.listedDirectories, run.unlistedCloneBuckets)
    }

    /// Rule behind the "probably" label. Case-insensitive, relative to `home`.
    public static func probableBucket(for url: URL, home: URL) -> AppleBucket {
        let path = components(url)
        let base = components(home)
        guard path.count > base.count, isInside(path, base) else { return .documents }
        let rel = Array(path.dropFirst(base.count))
        func eq(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        if eq(rel[0], "Library") {
            return rel.count > 1 && eq(rel[1], "Mobile Documents") ? .icloudDrive : .systemData
        }
        if rel[0].hasPrefix(".") { return .systemData }
        return .documents
    }

    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.path.split(separator: "/").map(String.init)
    }

    /// Case-insensitive (APFS default) key for a claimed or skipped path.
    private static func skipKey(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }

    private static func isInside(_ path: [String], _ ancestor: [String]) -> Bool {
        path.count >= ancestor.count
            && zip(path, ancestor).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
    }

    private struct Run: Sendable {
        let sizer: AllocatedSizer
        let control: ScanControl?
        let threshold: Int64
        let promptingPathsReadable: Bool
        let env: ScanEnvironment
        let home: URL
        let listEntries: @Sendable (String, DirectoryListing.SummaryPolicy?) -> DirectoryListing?
        let parallelDepth: Int
        let driveWorkerLimit: Int
        let bucketsRelativeToHome: Bool
        let comparisonDepth: Int
        let captureFolderPresence: Bool
        let skipsSingleLinkInodes: Bool
        let volumeCannotClone: Bool
        let verifiedLocalAPFS: Bool
        /// Device of `home`. The walk stays on it, like AllocatedSizer: nodes on another device
        /// (e.g. the DeviceFS mount under ~/Library/Developer/CoreDevice) are skipped, not counted
        /// or reported. No test covers this, since a test can't create a mount.
        let device: dev_t
        /// Lowercased standardized paths of claimed nodes and the Trash. `visit` stops at the first
        /// one it reaches, so an exact match is enough; descendants are never visited.
        let skipped: Set<String>
        let skippedNames: [String: Set<String>]
        let onFirstDrivePreview: (@Sendable () -> Void)?
        var firstParallelDepth: Int?
        var workerSlots: DriveScanWorkerSlots?
        var items: [LargeItem] = []
        var unreadable: [URL] = []
        var folders: [String: Int64] = [:]
        var listedDirectories: [String: Set<String>] = [:]
        var comparisonOmissions = 0
        /// Unreported bytes per bucket, attributed at home's direct children.
        var unlisted: [AppleBucket: Int64] = [:]
        var unlistedCloneBuckets: Set<AppleBucket> = []
        typealias Size = (bytes: Int64, clones: Bool, unreported: Int64, unreportedClones: Bool)

        /// Prompting is decided on the first three components below home (see `isPromptingPath`), so
        /// once a node that deep passed, nothing below it can be prompting.
        private func mayPrompt(_ depth: Int) -> Bool { !promptingPathsReadable && depth <= 3 }

        /// Returns the node's allocated size and whether it holds clones; records it when it is a
        /// deepest big node. Reads the node with `lstat` and URL resource values: used for home and for
        /// listed entries whose bulk attributes can't stand in for those.
        mutating func visit(_ url: URL, isHome: Bool = false, depth: Int = 0) -> Size {
            if let control, control.isCancelled { return (0, false, 0, false) }
            if !isHome, mayPrompt(depth), env.isPromptingPath(url) {
                unreadable.append(url)  // decided on the path, before any stat
                return (0, false, 0, false)
            }
            var st = stat()
            #if ANDROMEDA_TRACE
            ScanTrace.note("lstat", url)
            #endif
            guard lstat(url.path, &st) == 0 else {
                if errno != ENOENT { unreadable.append(url) }
                return (0, false, 0, false)
            }
            let kind = st.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else { return (0, false, 0, false) }  // never follow symlinks
            if !isHome {
                if st.st_dev != device { return (0, false, 0, false) }
                if skipped.contains(LargeItemsScanner.skipKey(url)) { return (0, false, 0, false) }
                if kind == S_IFDIR, st.st_flags & UInt32(SF_DATALESS) != 0 {
                    #if ANDROMEDA_TRACE
                    ScanTrace.note("skip-dataless", url)
                    #endif
                    return (0, false, 0, false)  // rev E: a dataless folder is never listed, whatever its status
                }
                if Self.isNotDownloaded(url) { return (0, false, 0, false) }
            }
            if kind == S_IFREG {
                if comparisonDepth > 0, st.st_nlink > 1 { comparisonOmissions += 1 }
                return measureFile(url)
            }
            return measureDirectory(url, key: LargeItemsScanner.skipKey(url), isHome: isHome, depth: depth)
        }

        /// `visit(_:)` for an entry of a directory listing, from the attributes the listing returned.
        /// Same checks in the same order; falls back to `visit(_:)` where the listing can't vouch.
        mutating func visit(_ entry: DirectoryEntry, in parent: URL, parentKey: String, depth: Int)
            -> Size
        {
            let isDirectory = entry.type == VDIR.rawValue
            func url() -> URL { parent.appendingPathComponent(entry.name, isDirectory: isDirectory) }
            // An entry error is a failed lstat; a mount point's listed device is the covered folder's.
            guard entry.error == 0, !entry.isMountPoint else { return visit(url(), depth: depth) }
            if let control, control.isCancelled { return (0, false, 0, false) }
            if mayPrompt(depth), env.isPromptingPath(url()) {
                unreadable.append(url())
                return (0, false, 0, false)
            }
            guard entry.type == VREG.rawValue || isDirectory else { return (0, false, 0, false) }
            if entry.device != device { return (0, false, 0, false) }
            let key = parentKey + "/" + entry.name.lowercased()
            if skipped.contains(key) { return (0, false, 0, false) }
            // An iCloud or File Provider placeholder is a dataless file or folder: its data isn't on this disk,
            // so it uses next to nothing here. It is skipped from the flag alone. Asking File Provider for the
            // downloading status cost one daemon round trip per placeholder, and on a Mac with big cloud
            // folders that was most of the scan (8,648 of ~25,000 busy samples, Mac mini, 2026-11-08).
            if entry.flags & UInt32(SF_DATALESS) != 0 {
                #if ANDROMEDA_TRACE
                ScanTrace.note("skip-dataless", url())
                #endif
                return (0, false, 0, false)  // rev E: a dataless folder is never listed; a dataless file holds no local data
            }
            guard !isDirectory else { return measureDirectory(url(), key: key, isHome: false, depth: depth) }
            guard let allocated = entry.allocated, let hasWholeClone = entry.hasWholeClone ?? noCloneOnThisVolume(for: entry) else {
                if comparisonDepth > 0 { return visit(url(), depth: depth) }
                return measureFile(url())  // Read attributes that the bulk listing did not supply.
            }
            let skipDedup = skipsSingleLinkInodes && entry.linkCount == 1
            if skipDedup { control?.file(bytes: allocated) }
            let ownsAllocation = skipDedup || sizer.claimListed(device: entry.device, inode: ino_t(entry.inode), allocated: allocated)
            let countedBytes = ownsAllocation ? allocated : 0
            let countedClone = ownsAllocation && hasWholeClone
            // A linked file can be counted under different paths depending on which walk saw it
            // first. Never turn that change in attribution into a reported folder delta.
            if comparisonDepth > 0, countedBytes != allocated || (skipsSingleLinkInodes && !skipDedup) {
                comparisonOmissions += 1
            }
            if countedBytes >= threshold {
                report(url(), bytes: countedBytes, clones: countedClone)
                return (countedBytes, countedClone, 0, false)
            }
            return (countedBytes, countedClone, countedBytes, countedClone)
        }

        private func noCloneOnThisVolume(for entry: DirectoryEntry) -> Bool? {
            guard volumeCannotClone, entry.inode != 0 || (skipsSingleLinkInodes && entry.linkCount == 1) else { return nil }
            return false
        }

        private static func isNotDownloaded(_ url: URL) -> Bool {
            #if ANDROMEDA_TRACE
            ScanTrace.note("attrs-ubiquitous", url)
            #endif
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
            return status == .notDownloaded  // iCloud placeholder; nil counts as downloaded
        }

        private mutating func measureFile(_ url: URL, sized result: SizeResult? = nil)
            -> Size
        {
            let r = result ?? sizer.size(of: url)
            unreadable += r.unreadable
            if r.bytes >= threshold {
                report(url, bytes: r.bytes, clones: r.clonesPresent)
                return (r.bytes, r.clonesPresent, 0, false)
            }
            return (r.bytes, r.clonesPresent, r.bytes, r.clonesPresent)
        }

        /// `key` is `skipKey(url)`, passed down so children's keys are built without URL work.
        private mutating func measureDirectory(_ url: URL, key: String, isHome: Bool, depth: Int)
            -> Size
        {
            if !isHome {
                #if ANDROMEDA_TRACE
                ScanTrace.note("attrs-ispackage", url)
                #endif
                if SafetyGuard.isPackage(url) {
                    // The package sizer shares inode accounting but does not report which paths own hard links.
                    if comparisonDepth > 0, skipsSingleLinkInodes { comparisonOmissions += 1 }
                    let measured = verifiedLocalAPFS ? sizer.sizeOfLocalAPFSPackage(url, device: device) : nil
                    return measureFile(url, sized: measured)
                }
            }
            var total: Int64 = 0
            let unreadableBefore = unreadable.count
            let omissionsBefore = comparisonOmissions
            var clones = false
            var unreported: Int64 = 0
            var unreportedClones = false
            // Home's Library child is split one level down (Mobile Documents is iCloud Drive, the rest System
            // Data); held locally so a reported Library contributes nothing.
            let splitsByChild = bucketsRelativeToHome && depth == 1 && url.lastPathComponent.caseInsensitiveCompare("Library") == .orderedSame
            var split: [AppleBucket: Int64] = [:]
            var splitCloneBuckets: Set<AppleBucket> = []
            var childReachedThreshold = false
            #if ANDROMEDA_TRACE
            ScanTrace.note("list", url)
            #endif
            control?.entering(url)
            var beforeListing = stat()
            let canRecordPresence = captureFolderPresence && depth < comparisonDepth
                && lstat(url.path, &beforeListing) == 0 && beforeListing.st_mode & S_IFMT == S_IFDIR
            // Ordinary small files need neither paths nor individual work items on an isolated drive.
            // Keep named entries for folders, claimed paths, uncertain metadata and hard links.
            let policy: DirectoryListing.SummaryPolicy?
            if skipsSingleLinkInodes, !bucketsRelativeToHome, promptingPathsReadable, !captureFolderPresence,
               control?.reportsEveryUpdate != true {
                policy = .init(device: device, belowBytes: threshold, volumeCannotClone: volumeCannotClone,
                               excludedNames: skippedNames[key, default: []])
            } else {
                policy = nil
            }
            if let listing = listEntries(url.path, policy) {
                let entries = listing.entries
                let small = listing.smallFiles
                total = small.bytes
                unreported = small.bytes
                clones = small.containsClones
                unreportedClones = small.allocatedClones
                if small.count > 0 { control?.files(count: small.count, bytes: small.bytes) }
                if isHome, small.bytes > 0 {
                    unlisted[.documents, default: 0] += small.bytes
                    if small.allocatedClones { unlistedCloneBuckets.insert(.documents) }
                }
                if canRecordPresence {
                    recordDirectoryNames(entries, in: url, before: beforeListing)
                }
                if isHome, skipsSingleLinkInodes, let control {
                    let excluded = skippedNames[key, default: []]
                    let currentDevice = device
                    let folders = entries.lazy.filter { entry in
                        entry.error == 0 && entry.type == VDIR.rawValue && entry.device == currentDevice
                            && !entry.isMountPoint && !entry.name.isEmpty && !entry.name.hasPrefix(".")
                            && entry.flags & UInt32(SF_DATALESS | UF_HIDDEN) == 0
                            && !excluded.contains(entry.name.lowercased())
                    }.prefix(8).map { url.appendingPathComponent($0.name, isDirectory: true) }
                    control.foundDriveFolders(Array(folders))
                }
                let children = isHome && skipsSingleLinkInodes && control != nil
                    ? prioritizeLargeRootFiles(entries) : entries
                let measured = measureChildren(children, in: url, key: key, depth: depth)
                for (entry, n) in zip(children, measured) {
                    total += n.bytes
                    if n.clones { clones = true }
                    unreported += n.unreported
                    unreportedClones = unreportedClones || n.unreportedClones
                    if n.unreported > 0 {
                        if isHome, !bucketsRelativeToHome {
                            unlisted[.documents, default: 0] += n.unreported
                            if n.unreportedClones { unlistedCloneBuckets.insert(.documents) }
                        } else if isHome {
                            // Library's own children are attributed inside its walk, so the Library directory is
                            // skipped here. (A Library that is a package would be lost; not expected.)
                            let isLibraryDir = entry.type == VDIR.rawValue
                                && entry.name.caseInsensitiveCompare("Library") == .orderedSame
                            if !isLibraryDir {
                                let child = url.appendingPathComponent(entry.name, isDirectory: entry.type == VDIR.rawValue)  // explicit: no stat
                                let bucket = LargeItemsScanner.probableBucket(for: child, home: home)
                                unlisted[bucket, default: 0] += n.unreported
                                if n.unreportedClones { unlistedCloneBuckets.insert(bucket) }
                            }
                        } else if splitsByChild {
                            let child = url.appendingPathComponent(entry.name, isDirectory: entry.type == VDIR.rawValue)  // explicit: no stat
                            let bucket = LargeItemsScanner.probableBucket(for: child, home: home)
                            split[bucket, default: 0] += n.unreported
                            if n.unreportedClones { splitCloneBuckets.insert(bucket) }
                        }
                    }
                    if n.bytes >= threshold { childReachedThreshold = true }
                }
            } else {
                unreadable.append(url)
            }
            if !isHome, total >= threshold, !childReachedThreshold {
                report(url, bytes: total, clones: clones)
                unreported = 0  // its bytes are in the reported item
                unreportedClones = false
                split = [:]
                splitCloneBuckets.removeAll()
            }
            for (bucket, bytes) in split { unlisted[bucket, default: 0] += bytes }
            unlistedCloneBuckets.formUnion(splitCloneBuckets)
            if depth > 0, depth <= comparisonDepth, unreadableBefore == unreadable.count,
               omissionsBefore == comparisonOmissions {
                folders[url.path] = total
                if depth == 1, skipsSingleLinkInodes, !bucketsRelativeToHome {
                    control?.measuredDriveFolder(url, bytes: total)
                }
            }
            return (total, clones, unreported, unreportedClones)
        }

        /// A drive-root file with its own inode can be measured before a long folder walk.
        /// Preserve the order of all other entries, including any hard links.
        private func prioritizeLargeRootFiles(_ entries: [DirectoryEntry]) -> [DirectoryEntry] {
            func isLargeFile(_ entry: DirectoryEntry) -> Bool {
                entry.type == VREG.rawValue && entry.linkCount == 1 && (entry.allocated ?? 0) >= threshold
            }
            let folders = entries.indices.lazy.filter { entries[$0].type == VDIR.rawValue }.prefix(2)
            guard folders.count == 1, let folder = folders.first,
                  entries.dropFirst(folder + 1).contains(where: isLargeFile) else { return entries }
            let remainder = entries[folder...]
            return entries[..<folder] + remainder.filter(isLargeFile) + remainder.filter { !isLargeFile($0) }
        }

        private mutating func recordDirectoryNames(_ entries: [DirectoryEntry], in parent: URL, before: stat) {
            var after = stat()
            guard lstat(parent.path, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return }
            var names = Set<String>()
            for entry in entries {
                // Unidentified entries prevent using this listing as proof of absence.
                guard entry.error == 0, !entry.name.isEmpty, entry.type != VNON.rawValue else { return }
                if entry.type == VDIR.rawValue {
                    names.insert(entry.name.lowercased())
                    guard names.count <= 512 else { return }
                }
            }
            listedDirectories[parent.path] = names
        }

        /// Each child's sizes, in listing order. Near the top of the tree, sibling subtrees run in
        /// parallel. Consecutive files share a worker so a wide directory needs fewer walk copies.
        /// Worker results merge in listing order, and the sizer's inode set is shared.
        private mutating func measureChildren(_ entries: [DirectoryEntry], in url: URL, key: String, depth: Int)
            -> [Size]
        {
            let driveControl = skipsSingleLinkInodes ? control : nil
            let parentPath = driveControl == nil ? "" : url.path
            let folderCount = entries.reduce(0) { $0 + ($1.type == VDIR.rawValue ? 1 : 0) }
            // If a drive starts with a chain of single-child directories, allow two
            // levels of parallel work when its first branch is below the default depth.
            let deferredParallelism = skipsSingleLinkInodes && parallelDepth > 0
                && (firstParallelDepth.map { $0 >= parallelDepth && depth - $0 < 2 } ?? true)
            let canFork = folderCount >= 2 && (depth < parallelDepth || deferredParallelism)
            let ranges = canFork ? Self.workRanges(entries) : []
            // A narrow root can fan out on the next level. Share the budget from the first fork.
            if canFork, skipsSingleLinkInodes, firstParallelDepth == nil, workerSlots == nil {
                workerSlots = DriveScanWorkerSlots(limit: driveWorkerLimit)
            }
            let workers = ranges.isEmpty ? 0 : workerSlots.map { $0.claim(upTo: ranges.count - 1) + 1 } ?? ranges.count
            guard workers > 1 else {
                // Foundation calls on the way autorelease; without a pool they pile up until the scan ends.
                guard let driveControl, folderCount >= 2 else {
                    return entries.map { entry in autoreleasepool { visit(entry, in: url, parentKey: key, depth: depth + 1) } }
                }
                var priority = PreferredJob()
                var readAhead: [Int: Size] = [:]
                return entries.indices.map { index in
                    if let preferred = priority.index(control: driveControl, parent: parentPath, find: { name in
                        entries.firstIndex { $0.type == VDIR.rawValue && $0.name == name }
                    }), preferred > index, readAhead[preferred] == nil {
                        readAhead[preferred] = autoreleasepool {
                            visit(entries[preferred], in: url, parentKey: key, depth: depth + 1)
                        }
                    }
                    return readAhead.removeValue(forKey: index) ?? autoreleasepool {
                        visit(entries[index], in: url, parentKey: key, depth: depth + 1)
                    }
                }
            }
            let template: Run = {
                var copy = self
                copy.firstParallelDepth = firstParallelDepth ?? depth
                copy.items = []
                copy.unreadable = []
                copy.unlisted = [:]
                copy.unlistedCloneBuckets = []
                copy.folders = [:]
                copy.listedDirectories = [:]
                copy.comparisonOmissions = 0
                return copy
            }()
            let results = ResultSlots<(sizes: [Size], run: Run)>(count: ranges.count)
            let findJob: @Sendable (String) -> Int? = { name in
                ranges.firstIndex { range in
                    let entry = entries[range.lowerBound]
                    return entry.type == VDIR.rawValue && entry.name == name
                }
            }
            let firstJob = driveControl?.preferredDriveChild(in: parentPath).flatMap(findJob)
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                defer { if worker > 0 { template.workerSlots?.release() } }
                func measure(_ i: Int) {
                    var child = template
                    let sizes = entries[ranges[i]].map { entry in
                        autoreleasepool { child.visit(entry, in: url, parentKey: key, depth: depth + 1) }
                    }
                    results.set(i, (sizes, child))
                }
                if workers == ranges.count {
                    // Submit the requested subtree first when it is known at the start of this fork.
                    if let firstJob, worker == 0 { measure(firstJob) }
                    else if worker == firstJob { measure(0) }
                    else { measure(worker) }
                } else {
                    // A worker that finishes a small subtree can take the next one instead of waiting.
                    var priority = PreferredJob()
                    while let i = results.claimNext(prioritizing: priority.index(
                        control: driveControl, parent: parentPath, find: findJob
                    )) { measure(i) }
                }
            }
            var sizes: [Size] = []
            sizes.reserveCapacity(entries.count)
            for r in results.values {
                items += r.run.items
                unreadable += r.run.unreadable
                folders.merge(r.run.folders) { first, _ in first }
                listedDirectories.merge(r.run.listedDirectories) { first, _ in first }
                comparisonOmissions += r.run.comparisonOmissions
                for (bucket, bytes) in r.run.unlisted { unlisted[bucket, default: 0] += bytes }
                unlistedCloneBuckets.formUnion(r.run.unlistedCloneBuckets)
                sizes += r.sizes
            }
            return sizes
        }

        private static func workRanges(_ entries: [DirectoryEntry]) -> [Range<Int>] {
            let maximumFilesPerWorker = 128
            var ranges: [Range<Int>] = []
            var start = 0
            for index in entries.indices {
                if entries[index].type == VDIR.rawValue {
                    if start < index { ranges.append(start..<index) }
                    ranges.append(index..<(index + 1))
                    start = index + 1
                } else if index - start + 1 == maximumFilesPerWorker {
                    ranges.append(start..<(index + 1))
                    start = index + 1
                }
            }
            if start < entries.count { ranges.append(start..<entries.count) }
            return ranges
        }

        private struct PreferredJob {
            var child: String?
            var index: Int?

            mutating func index(control: ScanControl?, parent: String, find: (String) -> Int?) -> Int? {
                let next = control?.preferredDriveChild(in: parent)
                if next != child {
                    child = next
                    index = next.flatMap(find)
                }
                return index
            }
        }

        private mutating func report(_ url: URL, bytes: Int64, clones: Bool) {
            let item = LargeItem(
                url: url, bytes: bytes,
                probableBucket: bucketsRelativeToHome ? LargeItemsScanner.probableBucket(for: url, home: home) : .documents,
                clonesPresent: clones)
            items.append(item)
            if skipsSingleLinkInodes, !bucketsRelativeToHome, control?.foundDriveLargeItem(item) == true {
                onFirstDrivePreview?()
            }
        }
    }
}

/// The caller counts as one worker. Recursive walks claim additional slots without waiting.
final class DriveScanWorkerSlots: Sendable {
    private struct State {
        var available: Int
        var waiting: (@Sendable () -> Void)?
    }

    private let state: Mutex<State>

    init(limit: Int) { state = Mutex(State(available: limit - 1)) }

    func claim(upTo maximum: Int) -> Int {
        state.withLock { state in
            let taken = min(state.available, maximum)
            state.available -= taken
            return taken
        }
    }

    /// A caller may enqueue one asynchronous job. Releasing a slot transfers it directly to that job.
    func claimWhenAvailable(_ submit: @escaping @Sendable () -> Void) {
        let claimed = state.withLock { state in
            if state.available > 0 {
                state.available -= 1
                return true
            }
            precondition(state.waiting == nil)
            state.waiting = submit
            return false
        }
        if claimed { submit() }
    }

    func release() {
        let submit = state.withLock { state -> (@Sendable () -> Void)? in
            if let waiting = state.waiting {
                state.waiting = nil
                return waiting
            }
            state.available += 1
            return nil
        }
        submit?()
    }
}

/// Keeps one buffer per simultaneous directory read. Each lister belongs exclusively to the
/// caller until its entries have been copied out, and all idle buffers are freed when the scan ends.
private final class DirectoryListerPool: @unchecked Sendable {
    private let lock = NSLock()
    private var idle: [DirectoryLister] = []
    private let includeLinkCount: Bool
    private let includeCloneRefCount: Bool
    private let readsWholeCloneFlag: Bool

    init(includeLinkCount: Bool, includeCloneRefCount: Bool, readsWholeCloneFlag: Bool) {
        self.includeLinkCount = includeLinkCount
        self.includeCloneRefCount = includeCloneRefCount
        self.readsWholeCloneFlag = readsWholeCloneFlag
    }

    func listing(
        atPath path: String, summarize policy: DirectoryListing.SummaryPolicy?, control: ScanControl?
    ) -> DirectoryListing? {
        lock.lock()
        let available = idle.popLast()
        lock.unlock()
        let lister = available ?? DirectoryLister(includeLinkCount: includeLinkCount,
                                                  includeCloneRefCount: includeCloneRefCount,
                                                  readsWholeCloneFlag: readsWholeCloneFlag)
        let listing = lister.listing(atPath: path, summarize: policy, shouldContinue: { control?.isCancelled != true })
        lock.lock()
        idle.append(lister)
        lock.unlock()
        return listing
    }
}

/// One slot per parallel task; each task writes only its own index.
private final class ResultSlots<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [T?]
    private var next = 0
    private var claimedAhead: Set<Int> = []

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func claimNext(prioritizing index: Int?) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if let index, index >= next, index < slots.count, claimedAhead.insert(index).inserted {
            return index
        }
        while claimedAhead.remove(next) != nil { next += 1 }
        guard next < slots.count else { return nil }
        defer { next += 1 }
        return next
    }

    func set(_ i: Int, _ value: T) { lock.lock(); slots[i] = value; lock.unlock() }

    /// Every slot, in order; call after all tasks have finished.
    var values: [T] { lock.lock(); defer { lock.unlock() }; return slots.map { $0! } }
}
