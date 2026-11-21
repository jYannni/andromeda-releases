import Foundation

/// Sizes of one measured root (spec §7.1 rev 2: allocated bytes are never reported alone).
public struct RootSize: Equatable, Sendable {
    /// Allocated bytes (`st_blocks * 512`): what the tree "uses".
    public var bytes: Int64
    /// Bytes no other file shares: what removal frees at least. nil when any counted file's
    /// private size is unknown on a clone-capable volume; equals `bytes` where clones can't exist.
    public var privateBytes: Int64?
    /// Some file has an APFS clone refcount above 1.
    public var clonesPresent: Bool
    /// Entries the walk could not read or stat, plus entries that changed under it (a child that
    /// was something else by the time it was opened), plus directories below the depth bound.
    public var unreadable: Int
    /// Directories the descent policy refused to enter; nothing beneath them is in `bytes`. The
    /// reply carries it as `skippedCount`, so a figure with refused subtrees never reads as exact.
    public var skipped: Int
    /// The walk stopped on its entry or time budget; the sizes cover only what was visited.
    public var truncated: Bool

    public init(bytes: Int64, privateBytes: Int64?, clonesPresent: Bool, unreadable: Int, skipped: Int = 0, truncated: Bool) {
        self.bytes = bytes
        self.privateBytes = privateBytes
        self.clonesPresent = clonesPresent
        self.unreadable = unreadable
        self.skipped = skipped
        self.truncated = truncated
    }
}

/// Which directories a walk may descend into (R12, R21). A directory the policy refuses is skipped
/// with everything beneath it and counts nothing in `bytes`; it is counted in `skipped`, not in
/// `unreadable` and not as truncation. The app's non-root pass still counts what the caller can
/// read there.
///
/// The writability rules apply to the root too (as `skipWorldWritable` always has). The owner rule
/// applies only below the root: the root is a compiled-in system path or a home whose owner
/// `OtherAccountsOperation` has already checked, and a home is owned by its account.
public struct DescentPolicy: Equatable, Sendable {
    /// Never descend into a directory with `S_IWOTH` set, sticky or not (R12). Any local user can
    /// fill one, so counting it would let them inflate the figure.
    public var skipWorldWritable: Bool
    /// Never descend into a directory with `S_IWGRP` set unless its group is one of
    /// `trustedGroups` (R21). A `staff` group-writable directory under `/Library` is writable by
    /// every local account.
    public var skipGroupWritable: Bool
    /// Groups whose members are administrators anyway: wheel (0) and admin (80).
    public var trustedGroups: Set<gid_t>
    /// Below the root, descend only into a directory owned by a system UID (below 500) (R21). A
    /// standard user who owns a directory inside `/Library` or `/private` can otherwise put
    /// anything there to inflate or stall the walk.
    public var systemOwnedOnly: Bool

    public init(skipWorldWritable: Bool, skipGroupWritable: Bool, trustedGroups: Set<gid_t> = [0, 80],
                systemOwnedOnly: Bool) {
        self.skipWorldWritable = skipWorldWritable
        self.skipGroupWritable = skipGroupWritable
        self.trustedGroups = trustedGroups
        self.systemOwnedOnly = systemOwnedOnly
    }

    /// Every directory is entered: the rev 2 entries, whose roots are root-owned system trees.
    public static let unrestricted = DescentPolicy(skipWorldWritable: false, skipGroupWritable: false, systemOwnedOnly: false)
    /// The three outside entries (R21): system-owned, not world- or group-writable.
    public static let outside = DescentPolicy(skipWorldWritable: true, skipGroupWritable: true, systemOwnedOnly: true)
    /// Another account's home (R12, R16, R21): the account owns its tree, so only writability counts.
    public static let home = DescentPolicy(skipWorldWritable: true, skipGroupWritable: true, systemOwnedOnly: false)

    func allowsDescent(into st: stat, isRoot: Bool) -> Bool {
        if skipWorldWritable, st.st_mode & S_IWOTH != 0 { return false }
        if skipGroupWritable, st.st_mode & S_IWGRP != 0, !trustedGroups.contains(st.st_gid) { return false }
        if systemOwnedOnly, !isRoot, st.st_uid >= 500 { return false }
        return true
    }
}

/// The root-run allocated-size walk (R5: a deliberate copy of plan 1's rule, not an import of
/// AndromedaCore). Never follows symlinks, never leaves the root's device, counts each
/// `(st_dev, st_ino)` once, and stops on an entry or time budget (R9).
///
/// The walk holds file descriptors, never paths (R20). Only the root is opened by path, and it is
/// then checked against the `lstat` that decided it. Every child is decided by `fstatat` on its
/// parent's descriptor, opened with `openat(O_NOFOLLOW)` and checked by `fstat` against that
/// decision, and has its clone attributes read with `getattrlistat(FSOPT_NOFOLLOW)`, which returns
/// the identity it read alongside the sizes. A child that is something else by the time it is
/// opened is counted as unreadable and skipped, so a directory swapped for a symlink between the
/// stat and the open is never entered, however the race goes. Files are never opened at all: a
/// swapped-in FIFO or device can't block the walk.
public struct RootSizer: Sendable {
    public let maxEntries: Int
    public let maxSeconds: Double

    /// Directories deeper than this below the root are not entered; each counts as one unreadable
    /// entry. Each open level holds one file descriptor, and a launchd daemon's soft limit is 256
    /// (`launchctl limit maxfiles`), so the walk takes at most half of them and leaves the rest to
    /// XPC and logging. Real trees under `/Library`, `/private` or a home stay far below this.
    public static let maxDepth = 128

    /// Test seam: runs after the deciding `lstat`/`fstatat` of the root or a child and before it
    /// is opened or its attributes read, with its logical path. A test swaps it in that window.
    var raceHook: (@Sendable (String) -> Void)?

    public init(maxEntries: Int = Budget.standard.maxEntries, maxSeconds: Double = Budget.standard.maxSeconds) {
        self.maxEntries = maxEntries
        self.maxSeconds = maxSeconds
    }

    public init(budget: Budget) {
        self.init(maxEntries: budget.maxEntries, maxSeconds: budget.maxSeconds)
    }

    private struct FileID: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    /// One open directory on the descent path.
    private struct Frame {
        let dir: UnsafeMutablePointer<DIR>
        let fd: Int32
        /// The logical path: the root string as given, then `/name` per level.
        let path: String
        let depth: Int
    }

    /// - excluding: absolute paths under `path` whose whole subtree is skipped. Each entry's
    ///   logical path is the root string as given plus `/name` per level, so an entry under an
    ///   excluded path starts with it exactly; matching on a component boundary keeps `/a/b` from
    ///   excluding `/a/bc`. Entries carry no trailing slash.
    /// - policy: which directories the walk may enter (R12, R21).
    public func size(ofPath path: String, excluding: [String] = [], policy: DescentPolicy = .unrestricted) -> RootSize {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        func outOfTime() -> Bool {
            guard maxSeconds > 0 else { return true }  // also catches NaN
            return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start) / 1e9 >= maxSeconds
        }

        var bytes: Int64 = 0
        var privateBytes: Int64? = 0
        var clones = false
        var unreadable = 0
        var skipped = 0
        var truncated = false
        var entries = 0
        var seen = Set<FileID>()
        var volumeCanClone: Bool?
        func result() -> RootSize {
            RootSize(bytes: bytes, privateBytes: privateBytes, clonesPresent: clones,
                     unreadable: unreadable, skipped: skipped, truncated: truncated)
        }
        func isExcluded(_ p: String) -> Bool {
            excluding.contains { p == $0 || p.hasPrefix($0 + "/") }
        }

        if outOfTime() {
            truncated = true
            return result()
        }

        // A missing root (e.g. no pending update) is zero, not unreadable.
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else {
            if errno != ENOENT { unreadable = 1 }
            return result()
        }
        // A root that is a symlink is never followed; nothing else but a directory has a tree.
        guard rootStat.st_mode & S_IFMT == S_IFDIR else { return result() }
        if !excluding.isEmpty, isExcluded(path) { return result() }
        let rootDevice = rootStat.st_dev
        entries = 1

        // The one open by path. It must be the directory lstat decided on, not a swap-in.
        raceHook?(path)
        let rootFd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFd >= 0 else {
            unreadable = 1
            return result()
        }
        var opened = stat()
        guard fstat(rootFd, &opened) == 0, opened.st_dev == rootStat.st_dev, opened.st_ino == rootStat.st_ino else {
            close(rootFd)
            unreadable = 1
            return result()
        }
        guard policy.allowsDescent(into: rootStat, isRoot: true) else {
            close(rootFd)
            skipped = 1
            return result()
        }
        guard let rootDir = fdopendir(rootFd) else {
            close(rootFd)
            unreadable = 1
            return result()
        }

        // Iterative depth-first walk: the stack is the chain of open ancestors, bottom = root.
        var stack = [Frame(dir: rootDir, fd: rootFd, path: path, depth: 0)]
        defer { for frame in stack { closedir(frame.dir) } }
        let needPaths = !excluding.isEmpty || raceHook != nil

        while let top = stack.last {
            // readdir returns NULL at the end of a directory and on an error; errno tells which.
            errno = 0
            guard let ent = readdir(top.dir) else {
                if errno != 0 { unreadable += 1 }  // the rest of this directory is lost
                closedir(top.dir)
                stack.removeLast()
                continue
            }
            let processed: Bool = withUnsafePointer(to: &ent.pointee.d_name) { tuple in
                let name = UnsafeRawPointer(tuple).assumingMemoryBound(to: CChar.self)
                if Self.isDotOrDotDot(name, length: Int(ent.pointee.d_namlen)) { return true }

                // Per entry, not per directory: one huge directory can't hold the walk past budget.
                if entries >= maxEntries || outOfTime() {
                    truncated = true
                    return false
                }
                entries += 1

                var st = stat()
                guard fstatat(top.fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                    unreadable += 1
                    return true
                }
                // A mount point inside the tree: another device is never entered or counted.
                guard st.st_dev == rootDevice else { return true }
                let childPath = needPaths ? top.path + "/" + String(cString: name) : ""

                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    if !excluding.isEmpty, isExcluded(childPath) { return true }
                    guard policy.allowsDescent(into: st, isRoot: false) else {
                        skipped += 1
                        return true
                    }
                    guard top.depth < Self.maxDepth else {
                        unreadable += 1
                        return true
                    }
                    raceHook?(childPath)
                    // O_NOFOLLOW refuses a symlink in the name's place; fstat catches any other
                    // swap (a directory renamed in, a new mount) by identity.
                    let fd = openat(top.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else {
                        unreadable += 1
                        return true
                    }
                    var now = stat()
                    guard fstat(fd, &now) == 0, now.st_dev == st.st_dev, now.st_ino == st.st_ino else {
                        close(fd)
                        unreadable += 1
                        return true
                    }
                    // The same directory, but its mode or owner may have changed since fstatat
                    // decided: the policy is judged on what was actually opened.
                    guard policy.allowsDescent(into: now, isRoot: false) else {
                        close(fd)
                        skipped += 1
                        return true
                    }
                    guard let dir = fdopendir(fd) else {
                        close(fd)
                        unreadable += 1
                        return true
                    }
                    stack.append(Frame(dir: dir, fd: fd, path: childPath, depth: top.depth + 1))
                case S_IFREG:
                    // A file is only reached here excluded if the exclusion names the file itself.
                    if !excluding.isEmpty, isExcluded(childPath) { return true }
                    // Only multiply-linked inodes can repeat; tracking just those bounds memory.
                    if st.st_nlink > 1, !seen.insert(FileID(dev: st.st_dev, ino: st.st_ino)).inserted {
                        return true
                    }
                    raceHook?(childPath)
                    let allocated = Int64(st.st_blocks) * 512
                    switch Self.cloneAttributes(dirFd: top.fd, name: name, expected: st) {
                    case .changed:
                        // Something else stands at this name now: count nothing for it.
                        unreadable += 1
                    case .known(let privateSize, let refCount):
                        bytes += allocated
                        privateBytes = privateBytes.map { $0 + privateSize }
                        if refCount > 1 { clones = true }
                    case .unknown:
                        // Not reported: exact on a volume that can't clone, unknown on one that can.
                        bytes += allocated
                        let canClone = volumeCanClone ?? {
                            let c = Self.volumeSupportsCloning(fd: rootFd)
                            volumeCanClone = c
                            return c
                        }()
                        privateBytes = canClone ? nil : privateBytes.map { $0 + allocated }
                    }
                default:
                    // Symlinks (never followed), sockets, devices, fifos: no allocated data of
                    // their own to count, as in plan 1. None is ever opened.
                    break
                }
                return true
            }
            if !processed { break }
        }
        return result()
    }

    private static func isDotOrDotDot(_ name: UnsafePointer<CChar>, length: Int) -> Bool {
        (length == 1 && name[0] == 0x2E) || (length == 2 && name[0] == 0x2E && name[1] == 0x2E)
    }

    /// `VOL_CAP_INT_CLONE` of the volume holding `fd`, read on the descriptor (volume attributes
    /// come back for any directory of the volume, verified on macOS 27). Unknown counts as
    /// clone-capable, so an unreadable capability yields "unknown", not a guess.
    private static func volumeSupportsCloning(fd: Int32) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        let size = MemoryLayout<UInt32>.size + MemoryLayout<vol_capabilities_attr_t>.size
        var buffer = [UInt8](repeating: 0, count: size)
        let rc = buffer.withUnsafeMutableBytes { fgetattrlist(fd, &list, $0.baseAddress, size, 0) }
        guard rc == 0 else { return true }
        let caps = buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: vol_capabilities_attr_t.self)
        }
        // Index VOL_CAPABILITIES_INTERFACES (1) of the four-word sets.
        let clone = UInt32(VOL_CAP_INT_CLONE)
        guard caps.valid.1 & clone != 0 else { return true }
        return caps.capabilities.1 & clone != 0
    }

    private enum CloneAttributes {
        /// The name no longer holds the file `fstatat` decided on (something else, or nothing).
        case changed
        /// The file system returned the private size (and refcount, 1 when missing).
        case known(privateSize: Int64, refCount: UInt32)
        /// The volume returned no private size, or the call failed for a reason other than the
        /// name having gone.
        case unknown
    }

    /// `ATTR_CMNEXT_PRIVATESIZE` and `ATTR_CMNEXT_CLONE_REFCNT` via one `getattrlistat` on the
    /// parent's descriptor, the clone rule copied from `AndromedaCore.AllocatedSizer.cloneAttributes`
    /// (R5). `FSOPT_NOFOLLOW` reads a swapped-in symlink itself rather than its target, and the
    /// device, object type and file ID come back in the same call, so a result that isn't the
    /// regular file `expected` describes is reported as `.changed` rather than counted.
    private static func cloneAttributes(dirFd: Int32, name: UnsafePointer<CChar>, expected: stat) -> CloneAttributes {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_DEVID)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONE_REFCNT)
        // length, returned attribute_set_t, dev_t, fsobj_type_t, u_int64_t file ID, off_t private
        // size, u_int32_t refcount: the order getattrlist packs them.
        let size = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
            + MemoryLayout<dev_t>.size + MemoryLayout<fsobj_type_t>.size + MemoryLayout<UInt64>.size
            + MemoryLayout<off_t>.size + MemoryLayout<UInt32>.size
        var buffer = [UInt8](repeating: 0, count: size)
        let options = UInt(UInt32(FSOPT_ATTR_CMN_EXTENDED) | UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_PACK_INVAL_ATTRS))
        // errno is read next to the call, inside the closure, before anything else can overwrite it.
        let (rc, err) = buffer.withUnsafeMutableBytes { bytes -> (Int32, Int32) in
            let rc = getattrlistat(dirFd, name, &list, bytes.baseAddress, size, options)
            return (rc, rc == 0 ? 0 : errno)
        }
        guard rc == 0 else {
            // The file was unlinked (or its parent is no longer a directory) since fstatat: its
            // bytes would be counted on a name that holds nothing, so it is "changed", not sized.
            return err == ENOENT || err == ENOTDIR ? .changed : .unknown
        }
        return buffer.withUnsafeBytes { raw in
            var offset = MemoryLayout<UInt32>.size
            let returned = raw.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
            offset += MemoryLayout<attribute_set_t>.size
            let identity = attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
            // Without the identity attributes nothing can be checked: treat the sizes as unknown.
            guard returned.commonattr & identity == identity else { return .unknown }
            let dev = raw.loadUnaligned(fromByteOffset: offset, as: dev_t.self)
            offset += MemoryLayout<dev_t>.size
            let type = raw.loadUnaligned(fromByteOffset: offset, as: fsobj_type_t.self)
            offset += MemoryLayout<fsobj_type_t>.size
            let fileID = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            offset += MemoryLayout<UInt64>.size
            guard dev == expected.st_dev, type == fsobj_type_t(VREG.rawValue), fileID == UInt64(expected.st_ino) else {
                return .changed
            }
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return .unknown }
            let privateSize = raw.loadUnaligned(fromByteOffset: offset, as: off_t.self)
            offset += MemoryLayout<off_t>.size
            let hasRefCount = returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT) != 0
            let refCount = hasRefCount ? raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self) : 1
            return .known(privateSize: Int64(privateSize), refCount: refCount)
        }
    }
}
