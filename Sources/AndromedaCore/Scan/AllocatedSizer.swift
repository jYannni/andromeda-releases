import Foundation
import os

public struct SizeResult: Equatable, Sendable {
    /// Allocated bytes: what the item uses. Never shown as reclaimable (spec §7.1 rev 2).
    public var bytes: Int64
    /// Bytes no other file shares: what removal frees at least. nil when unknown for any
    /// counted file on a volume that supports clones.
    public var privateBytes: Int64?
    /// APFS reported a shared allocation in a counted file, so `privateBytes` is a lower estimate.
    public var clonesPresent: Bool
    public var unreadable: [URL]

    public init(bytes: Int64, privateBytes: Int64?, clonesPresent: Bool, unreadable: [URL]) {
        self.bytes = bytes
        self.privateBytes = privateBytes
        self.clonesPresent = clonesPresent
        self.unreadable = unreadable
    }

    /// No clones: everything allocated is private.
    public init(bytes: Int64, unreadable: [URL]) {
        self.init(bytes: bytes, privateBytes: bytes, clonesPresent: false, unreadable: unreadable)
    }
}

/// One file's sizes as read from disk.
struct FileSizes: Equatable, Sendable {
    var allocated: Int64
    /// nil when the volume supports clones but didn't report the file's private size.
    var privateBytes: Int64?
    var cloneRefCount: UInt32
    /// The data fork alone, comparable to APFS's private-size attribute.
    var dataForkAllocated: Int64? = nil

    var hasSharedAllocation: Bool {
        if cloneRefCount > 1 { return true }
        guard let privateBytes, privateBytes >= 0, let dataForkAllocated else { return false }
        return privateBytes < dataForkAllocated
    }
}

/// A file or directory by (device, inode). Firmlinks give one directory two paths; this is the same either way.
public struct FileIdentity: Hashable, Sendable {
    public let dev: dev_t
    public let ino: ino_t

    public init(dev: dev_t, ino: ino_t) {
        self.dev = dev
        self.ino = ino
    }

    /// nil when `lstat` fails. A symlink is identified as itself, not its target.
    public init?(path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        self.init(dev: st.st_dev, ino: st.st_ino)
    }
}

/// Measures real on-disk (allocated) size, deduped by inode across every call on one instance and every
/// view made from it with `reporting(to:)`.
///
/// One sizer serves a whole scan, and its stages run at the same time (the applications stage beside the
/// home walk, parallel jobs inside each stage). So nothing a caller sets is stored on it: the seen-inode set
/// is the only shared mutable state, and it is locked. Each stage takes its own view, `reporting(to:)`,
/// which shares that set but has its own progress control and its own parallel-job bookkeeping; what to
/// skip is passed per call (`size(of:skipping:)`).
public final class AllocatedSizer: @unchecked Sendable {
    /// What every view of one sizer shares.
    private final class Store: Sendable {
        /// The seen-inode set, split by inode so parallel walkers rarely wait on the same lock.
        static let shardCount = 64
        let seen: [OSAllocatedUnfairLock<Set<FileIdentity>>] = (0..<Store.shardCount).map { _ in OSAllocatedUnfairLock(initialState: []) }
        let readSizes: @Sendable (URL) throws -> FileSizes

        init(readSizes: @escaping @Sendable (URL) throws -> FileSizes) { self.readSizes = readSizes }

        func shard(_ id: FileIdentity) -> OSAllocatedUnfairLock<Set<FileIdentity>> { seen[Int(id.ino % UInt64(Store.shardCount))] }
    }

    private let store: Store
    /// Receives a report per file and folder; a cancelled control ends a walk early with a partial total.
    public let control: ScanControl?

    private init(store: Store, control: ScanControl?) {
        self.store = store
        self.control = control
    }

    public convenience init() {
        let cloning = OSAllocatedUnfairLock<[dev_t: Bool]>(initialState: [:])
        self.init(store: Store(readSizes: { url in try AllocatedSizer.liveSizes(url, cloningByDevice: cloning) }), control: nil)
    }

    /// Test seam: inject the size reader to simulate read failures. Files read this way have no clones.
    convenience init(readSize: @escaping @Sendable (URL) throws -> Int64) {
        self.init(readSizes: { url in
            let n = try readSize(url)
            return FileSizes(allocated: n, privateBytes: n, cloneRefCount: 1)
        })
    }

    /// Test seam: inject private sizes and clone refcounts.
    convenience init(readSizes: @escaping @Sendable (URL) throws -> FileSizes) {
        self.init(store: Store(readSizes: readSizes), control: nil)
    }

    /// A view for one stage: same seen-inode set (a hard link counts once across stages), reporting to
    /// `control`, with fresh `size(of:order:)` bookkeeping. Cheap; the shared sizer is never changed.
    public func reporting(to control: ScanControl?) -> AllocatedSizer {
        AllocatedSizer(store: store, control: control)
    }

    /// True the first time `id` is offered.
    private func insertSeen(_ id: FileIdentity) -> Bool { store.shard(id).withLock { $0.insert(id).inserted } }

    private func isSeen(_ id: FileIdentity) -> Bool { store.shard(id).withLock { $0.contains(id) } }

    private static func liveSizes(_ url: URL, cloningByDevice: OSAllocatedUnfairLock<[dev_t: Bool]>) throws -> FileSizes {
        #if ANDROMEDA_TRACE
        ScanTrace.note("attrs", url)
        #endif
        let v = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        let allocated = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        if let ext = cloneAttributes(url.path) {
            return FileSizes(allocated: allocated, privateBytes: ext.privateSize, cloneRefCount: ext.refCount,
                             dataForkAllocated: v.fileAllocatedSize.map(Int64.init))
        }
        // Not reported: exact on a volume that can't clone, unknown on one that can.
        var st = stat()
        #if ANDROMEDA_TRACE
        ScanTrace.note("lstat", url)
        #endif
        let dev = lstat(url.path, &st) == 0 ? st.st_dev : -1
        let canClone = cloningByDevice.withLock { $0[dev] } ?? {
            #if ANDROMEDA_TRACE
            ScanTrace.note("attrs", url)
            #endif
            let c = (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?
                .volumeSupportsFileCloning ?? true
            cloningByDevice.withLock { $0[dev] = c }
            return c
        }()
        return FileSizes(allocated: allocated, privateBytes: canClone ? nil : allocated, cloneRefCount: 1)
    }

    /// `ATTR_CMNEXT_PRIVATESIZE` and `ATTR_CMNEXT_CLONE_REFCNT` via one `getattrlist`. nil unless the
    /// file system returned the private size. A missing refcount reads as 1.
    private static func cloneAttributes(_ path: String) -> (privateSize: Int64, refCount: UInt32)? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONE_REFCNT)
        // length, returned attribute_set_t, off_t private size, u_int32_t refcount.
        let size = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
            + MemoryLayout<off_t>.size + MemoryLayout<UInt32>.size
        var buffer = [UInt8](repeating: 0, count: size)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED) | UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_PACK_INVAL_ATTRS)
        #if ANDROMEDA_TRACE
        ScanTrace.note("getattrlist", path: path)
        #endif
        let rc = buffer.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress, size, options) }
        guard rc == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            var offset = MemoryLayout<UInt32>.size
            let returned = raw.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
            offset += MemoryLayout<attribute_set_t>.size
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            let privateSize = raw.loadUnaligned(fromByteOffset: offset, as: off_t.self)
            offset += MemoryLayout<off_t>.size
            let hasRefCount = returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT) != 0
            let refCount = hasRefCount ? raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self) : 1
            return (Int64(privateSize), refCount)
        }
    }

    /// `skipping`: a directory or file with one of these identities is neither counted nor descended into.
    public func size(of url: URL, skipping: Set<FileIdentity> = []) -> SizeResult {
        size(of: url, order: nil, skipping: skipping)
    }

    /// Hidden drive folders use bulk metadata when the filesystem returns all size attributes.
    /// A partial listing falls back for the entire subtree before any of its files are counted.
    func sizeOfHiddenDriveFolder(
        _ url: URL, volumeCannotClone: Bool, beforeCountingLinks: () -> Void
    ) -> SizeResult {
        var root = stat()
        guard lstat(url.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else {
            beforeCountingLinks()
            return control?.isCancelled == true ? SizeResult(bytes: 0, unreadable: []) : size(of: url)
        }
        let lister = DirectoryLister(includeLinkCount: true, includeCloneRefCount: !volumeCannotClone,
                                     includePrivateSize: !volumeCannotClone)
        var total = SizeResult(bytes: 0, unreadable: [])
        var pending = [url]
        while let folder = pending.popLast(), control?.isCancelled != true {
            autoreleasepool {
                let path = SafetyGuard.withoutSystemPathAlias(folder.path)
                var current = stat()
                guard lstat(path, &current) == 0 else { total.unreadable.append(folder); return }
                guard current.st_dev == root.st_dev, current.st_mode & S_IFMT == S_IFDIR else { return }
                control?.entering(folder)
                let entries = lister.entries(atPath: path, followAncestorLinks: false,
                                             shouldContinue: { control?.isCancelled != true })
                guard control?.isCancelled != true else { return }
                guard let entries, entries.allSatisfy({
                    guard $0.error == 0, !$0.isMountPoint, $0.type != VNON.rawValue,
                          !$0.name.isEmpty, $0.device != 0 else { return false }
                    if $0.device != root.st_dev || $0.type != VREG.rawValue { return true }
                    return $0.inode != 0 && $0.allocated != nil
                        && ($0.privateBytes != nil || volumeCannotClone)
                        && $0.flags & UInt32(SF_DATALESS) == 0
                }) else {
                    // Only the metadata API may fall back. An unopenable directory remains unreadable.
                    let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
                    guard fd >= 0 else { total.unreadable.append(folder); return }
                    defer { close(fd) }
                    var opened = stat()
                    guard fstat(fd, &opened) == 0, opened.st_dev == current.st_dev, opened.st_ino == current.st_ino
                    else { total.unreadable.append(folder); return }
                    beforeCountingLinks()
                    guard control?.isCancelled != true else { return }
                    let measured = walk(folder, device: root.st_dev, order: nil, skipping: [])
                    total.bytes += measured.bytes
                    total.privateBytes = total.privateBytes.flatMap { sum in measured.privateBytes.map { sum + $0 } }
                    total.clonesPresent = total.clonesPresent || measured.clonesPresent
                    total.unreadable += measured.unreadable
                    return
                }
                for entry in entries where entry.device == root.st_dev {
                    if control?.isCancelled == true { return }
                    if entry.type == VDIR.rawValue {
                        pending.append(folder.appendingPathComponent(entry.name, isDirectory: true))
                    } else if entry.type == VREG.rawValue, let allocated = entry.allocated {
                        let sizes = FileSizes(allocated: allocated, privateBytes: entry.privateBytes ?? allocated,
                                              cloneRefCount: entry.cloneRefCount ?? 1)
                        let counted: FileSizes
                        if entry.linkCount == 1 {
                            control?.file(bytes: allocated)
                            counted = sizes
                        } else {
                            // Give visible paths first claim on any inode that can have more than one name.
                            beforeCountingLinks()
                            guard control?.isCancelled != true else { return }
                            counted = countListed(device: entry.device, inode: ino_t(entry.inode), sizes: sizes)
                        }
                        total.bytes += counted.allocated
                        total.privateBytes = total.privateBytes.flatMap { sum in counted.privateBytes.map { sum + $0 } }
                        total.clonesPresent = total.clonesPresent || counted.hasSharedAllocation
                    }
                }
            }
        }
        return total
    }

    /// A package is one scan item. Collect complete metadata before claiming inodes or reporting file counts.
    /// The ordinary walk handles ambiguous entries, links, and packages that exceed the staging budget.
    func sizeOfLocalAPFSPackage(_ url: URL, device: dev_t) -> SizeResult? {
        var root = stat()
        guard control?.reportsEveryUpdate != true,
              lstat(url.path, &root) == 0, root.st_dev == device, root.st_mode & S_IFMT == S_IFDIR
        else { return nil }
        let rootIdentity = FileIdentity(dev: device, ino: root.st_ino)
        let rootPath = SafetyGuard.withoutSystemPathAlias(url.path)
        guard DirectoryLister.localAPFSDevice(atPath: rootPath, matching: rootIdentity) != nil else { return nil }

        let fileLimit = 50_000
        let folderLimit = 2_048
        // The package needs private allocation and a sharing warning, but no numeric reference count.
        // DirectoryLister retries compressed files and incomplete flag records with numeric counts.
        let lister = DirectoryLister(includeLinkCount: true, includePrivateSize: true,
                                     entryLimit: fileLimit, readsWholeCloneFlag: true, includeDataAllocation: true)
        var folders = [(url: url, identity: rootIdentity)]
        var files: [(inode: ino_t, allocated: Int64, privateBytes: Int64, hasSharedAllocation: Bool)] = []
        var folderCount = 1
        control?.entering(url)
        while let (folder, identity) = folders.popLast() {
            let complete = autoreleasepool { () -> Bool in
                guard control?.isCancelled != true else { return false }
                if folder != url { control?.entering(folder) }
                let path = SafetyGuard.withoutSystemPathAlias(folder.path)
                var before = stat()
                guard lstat(path, &before) == 0, before.st_mode & S_IFMT == S_IFDIR,
                      FileIdentity(dev: before.st_dev, ino: before.st_ino) == identity,
                      let entries = lister.entries(atPath: path, followAncestorLinks: false,
                                                   expectedIdentity: identity,
                                                   shouldContinue: { control?.isCancelled != true })
                else { return false }
                var after = stat()
                guard lstat(path, &after) == 0,
                      FileIdentity(dev: after.st_dev, ino: after.st_ino) == identity,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
                else { return false }

                for entry in entries {
                    guard entry.error == 0, !entry.name.isEmpty, entry.device == device, !entry.isMountPoint,
                          entry.flags & UInt32(SF_DATALESS) == 0 else { return false }
                    let inode = ino_t(entry.inode)
                    switch entry.type {
                    case VDIR.rawValue:
                        guard inode != 0, folderCount < folderLimit else { return false }
                        folderCount += 1
                        folders.append((folder.appendingPathComponent(entry.name, isDirectory: true),
                                        FileIdentity(dev: device, ino: inode)))
                    case VREG.rawValue:
                        guard entry.linkCount == 1, inode != 0, files.count < fileLimit,
                              let allocated = entry.allocated, allocated >= 0,
                              let privateBytes = entry.privateBytes, privateBytes >= 0,
                              let dataBytes = entry.dataForkAllocated, dataBytes >= 0,
                              let hasWholeClone = entry.hasWholeClone else { return false }
                        files.append((inode, allocated, privateBytes, hasWholeClone || privateBytes < dataBytes))
                    case VLNK.rawValue:
                        continue
                    default:
                        return false
                    }
                }
                return true
            }
            guard complete else { return nil }
        }

        var result = SizeResult(bytes: 0, unreadable: [])
        for file in files {
            if control?.isCancelled == true { break }
            guard claimListed(device: device, inode: file.inode, allocated: file.allocated) else { continue }
            result.bytes += file.allocated
            result.privateBytes = result.privateBytes.map { $0 + file.privateBytes }
            result.clonesPresent = result.clonesPresent || file.hasSharedAllocation
        }
        return result
    }

    /// `size(of:)` for one of several jobs sized in parallel, numbered in the order a single thread would
    /// size them. A file hard-linked into two jobs is counted by the lower-numbered one, as one thread
    /// would: if a later job got there first, its count is handed back through `handedBack(order:)`,
    /// which the caller subtracts from that job's result once every job has finished. The numbering is
    /// per view: give each batch of jobs its own `reporting(to:)` view.
    public func size(of url: URL, order: Int) -> SizeResult { size(of: url, order: Optional(order), skipping: []) }

    func size(of url: URL, order: Int, skipping: Set<FileIdentity>, matching identity: FileIdentity) -> SizeResult {
        size(of: url, order: Optional(order), skipping: skipping, matching: identity)
    }

    /// What job `order` counted for files that an earlier job then claimed (see `size(of:order:)`).
    public func handedBack(order: Int) -> (allocated: Int64, privateBytes: Int64) {
        owners.withLock { $0.handedBack[order] ?? (0, 0) }
    }

    private func size(of url: URL, order: Int?, skipping: Set<FileIdentity>, matching identity: FileIdentity? = nil) -> SizeResult {
        var st = stat()
        #if ANDROMEDA_TRACE
        ScanTrace.note("lstat", url)
        #endif
        guard lstat(url.path, &st) == 0 else {
            return SizeResult(bytes: 0, unreadable: identity == nil ? [] : [url])
        }
        let current = FileIdentity(dev: st.st_dev, ino: st.st_ino)
        if let identity, current != identity { return SizeResult(bytes: 0, unreadable: [url]) }

        if !skipping.isEmpty, skipping.contains(current) {
            return SizeResult(bytes: 0, unreadable: [])
        }
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            guard let f = countFile(url, st, order: order) else { return SizeResult(bytes: 0, unreadable: [url]) }
            control?.file(bytes: f.allocated)
            return SizeResult(
                bytes: f.allocated, privateBytes: f.privateBytes, clonesPresent: f.hasSharedAllocation,
                unreadable: [])
        case S_IFDIR:
            return walk(url, device: st.st_dev, order: order, skipping: skipping)
        default:  // symlinks, sockets, devices, etc.
            return SizeResult(bytes: 0, unreadable: [])
        }
    }

    /// Stays on the root's device: mounted volumes inside the tree are skipped, not counted or reported.
    private func walk(_ root: URL, device: dev_t, order: Int?, skipping: Set<FileIdentity>) -> SizeResult {
        var total: Int64 = 0
        var privateTotal: Int64? = 0
        var clones = false
        var unreadable: [URL] = []
        var recorded = Set<String>()
        func record(_ u: URL) {
            if recorded.insert(u.standardizedFileURL.path).inserted { unreadable.append(u) }
        }

        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        #if ANDROMEDA_TRACE
        ScanTrace.note("enter", root)
        #endif
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [],
            errorHandler: { url, _ in record(url); return true })
        else { return SizeResult(bytes: 0, unreadable: [root]) }

        control?.entering(root)
        // A pool per item: the enumerator and resource values autorelease, and a big package would
        // otherwise hold all of it until the scan ends.
        while autoreleasepool(invoking: { () -> Bool in
            if let control, control.isCancelled { return false }
            guard let item = enumerator.nextObject() as? URL else { return false }
            var st = stat()
            #if ANDROMEDA_TRACE
            ScanTrace.note("lstat", item)
            #endif
            guard lstat(item.path, &st) == 0 else { record(item); return true }
            if st.st_dev != device {
                enumerator.skipDescendants()
                return true
            }
            if !skipping.isEmpty, skipping.contains(FileIdentity(dev: st.st_dev, ino: st.st_ino)) {
                if st.st_mode & S_IFMT == S_IFDIR { enumerator.skipDescendants() }
                return true
            }
            guard st.st_mode & S_IFMT == S_IFREG else {
                #if ANDROMEDA_TRACE
                if st.st_mode & S_IFMT == S_IFDIR { ScanTrace.note("enter", item) }
                #endif
                if st.st_mode & S_IFMT == S_IFDIR { control?.entering(item) }
                return true
            }
            guard let f = countFile(item, st, order: order) else { record(item); return true }
            control?.file(bytes: f.allocated)
            total += f.allocated
            privateTotal = privateTotal.flatMap { sum in f.privateBytes.map { sum + $0 } }
            if f.hasSharedAllocation { clones = true }
            return true
        }) {}
        return SizeResult(bytes: total, privateBytes: privateTotal, clonesPresent: clones, unreadable: unreadable)
    }

    /// `size(of:)` for a regular file whose sizes the caller already read in its directory listing
    /// (`DirectoryLister`): same inode dedup, same progress report.
    func countListed(device: dev_t, inode: ino_t, sizes: FileSizes, skipping: Set<FileIdentity> = []) -> FileSizes {
        claimListed(device: device, inode: inode, allocated: sizes.allocated, skipping: skipping)
            ? sizes : FileSizes(allocated: 0, privateBytes: 0, cloneRefCount: 1)
    }

    /// Reports progress for a listed file and returns whether this path owns its allocation.
    func claimListed(device: dev_t, inode: ino_t, allocated: Int64, skipping: Set<FileIdentity> = []) -> Bool {
        let id = FileIdentity(dev: device, ino: inode)
        let ownsAllocation = !skipping.contains(id) && insertSeen(id)
        control?.file(bytes: ownsAllocation ? allocated : 0)
        return ownsAllocation
    }

    /// Per view, so two stages' jobs numbered from 0 at the same time don't mix.
    private struct Owner { var order: Int; var allocated: Int64; var privateBytes: Int64 }
    private struct Owners { var byFile: [FileIdentity: Owner] = [:]; var handedBack: [Int: (Int64, Int64)] = [:] }
    private let owners = OSAllocatedUnfairLock(initialState: Owners())

    /// A multi-name file met by job `order`. Inside this view's batch it goes to the lowest-numbered job; the
    /// batch's first claim also marks it seen, so another stage (or a walk without `order`) doesn't count it
    /// again, and a file another stage already counted is zero here.
    private func countShared(_ id: FileIdentity, _ url: URL, order: Int) -> FileSizes? {
        let zero = FileSizes(allocated: 0, privateBytes: 0, cloneRefCount: 1)
        // Read together under the owners lock (then the shard lock, as the claim below does): checked apart,
        // a later job in this batch could claim the file in between and look like another stage.
        let (owner, otherStage) = owners.withLock { o -> (Owner?, Bool) in
            let owner = o.byFile[id]
            return (owner, owner == nil && isSeen(id))
        }
        if let owner, owner.order <= order { return zero }
        if otherStage { return zero }
        guard let f = try? store.readSizes(url) else { return nil }
        let claimed = owners.withLock { o -> Bool in
            if let owner = o.byFile[id] {
                guard owner.order > order else { return false }
                let back = o.handedBack[owner.order] ?? (0, 0)
                o.handedBack[owner.order] = (back.0 + owner.allocated, back.1 + owner.privateBytes)
            } else if !insertSeen(id) {
                return false  // counted by another stage meanwhile
            }
            o.byFile[id] = Owner(order: order, allocated: f.allocated, privateBytes: f.privateBytes ?? f.allocated)
            return true
        }
        return claimed ? f : zero
    }

    /// Sizes of a regular file; all zero if its inode was already counted; nil if the size
    /// could not be read (the inode is then NOT marked seen, so a later call can retry).
    private func countFile(_ url: URL, _ st: stat, order: Int?) -> FileSizes? {
        let id = FileIdentity(dev: st.st_dev, ino: st.st_ino)
        // Only a file with several names can be met by two jobs; it goes to the lowest-numbered job.
        if let order, st.st_nlink > 1 { return countShared(id, url, order: order) }
        if isSeen(id) { return FileSizes(allocated: 0, privateBytes: 0, cloneRefCount: 1) }
        guard let f = try? store.readSizes(url) else { return nil }
        // Two walkers can read the same new inode at once: only the first insert counts it.
        return insertSeen(id) ? f : FileSizes(allocated: 0, privateBytes: 0, cloneRefCount: 1)
    }
}
