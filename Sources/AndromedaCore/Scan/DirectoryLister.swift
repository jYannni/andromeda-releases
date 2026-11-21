import Foundation

/// One directory entry with the attributes the large-items walk needs, read by `getattrlistbulk`
/// in the same call that lists the directory.
struct DirectoryEntry {
    let name: String
    /// Non-zero when the file system could not read this entry's attributes; the rest is then unset.
    let error: Int32
    /// `VREG`, `VDIR`, `VLNK`, ...
    let type: UInt32
    let device: dev_t
    /// `st_flags` (`SF_DATALESS`, ...).
    let flags: UInt32
    let inode: UInt64
    /// A mount point's attributes describe the covered directory, not the mounted volume.
    let isMountPoint: Bool
    /// `ATTR_FILE_ALLOCSIZE`: all forks, what `totalFileAllocatedSizeKey` reads. Regular files only.
    let allocated: Int64?
    /// APFS clone refcount; nil when the file system didn't return it. Private size is not asked for:
    /// computing it is about a quarter of the listing's cost and the large-items walk doesn't use it.
    let cloneRefCount: UInt32?
    var modified: Date? = nil
    var accessTime: Double = .nan
    var dataLength: Int64? = nil
    var linkCount: UInt32? = nil
    var privateBytes: Int64? = nil
    var dataForkAllocated: Int64? = nil
    var birthTime: Int64? = nil
    var wholeClone: WholeCloneMetadata? = nil
    var sharesAllBlocks: Bool? = nil

    var hasWholeClone: Bool? {
        sharesAllBlocks ?? cloneRefCount.map { $0 > 1 }
    }
}

struct DirectoryListing {
    struct SmallFiles {
        var count = 0
        var bytes: Int64 = 0
        var containsClones = false
        var allocatedClones = false
    }

    struct SummaryPolicy: Sendable {
        let device: dev_t
        let belowBytes: Int64
        let volumeCannotClone: Bool
        let excludedNames: Set<String>
    }

    var entries: [DirectoryEntry] = []
    var smallFiles = SmallFiles()

    mutating func add(_ entry: DirectoryEntry, policy: SummaryPolicy?) {
        guard let policy, entry.error == 0, !entry.isMountPoint, !entry.name.isEmpty,
              entry.type == VREG.rawValue, entry.device == policy.device,
              entry.linkCount == 1, entry.flags & UInt32(SF_DATALESS) == 0,
              let bytes = entry.allocated, bytes >= 0, bytes < policy.belowBytes,
              let hasWholeClone = entry.hasWholeClone ?? (policy.volumeCannotClone ? false : nil),
              policy.excludedNames.isEmpty || !policy.excludedNames.contains(entry.name.lowercased())
        else {
            entries.append(entry)
            return
        }
        smallFiles.count += 1
        smallFiles.bytes += bytes
        if hasWholeClone {
            smallFiles.containsClones = true
            if bytes > 0 { smallFiles.allocatedClones = true }
        }
    }
}

/// Lists directories with `getattrlistbulk`: one syscall per batch of entries instead of an
/// `lstat`, two `resourceValues` and a `getattrlist` per entry. Reuses one buffer; not thread-safe.
final class DirectoryLister {
    private var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    private let list: attrlist
    private let entryLimit: Int?
    private let apfsPrefetchDevice: dev_t?
    private let readsWholeCloneFlag: Bool

    init(includeModificationTime: Bool = false, includeCreationTime: Bool = false, includeAccessTime: Bool = false,
         includeDataLength: Bool = false, includeLinkCount: Bool = false,
         includeCloneRefCount: Bool = true, includePrivateSize: Bool = false, entryLimit: Int? = nil,
         apfsPrefetchDevice: dev_t? = nil, includeWholeCloneMetadata: Bool = false,
         readsWholeCloneFlag: Bool = false, includeDataAllocation: Bool = false) {
        var l = attrlist()
        l.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        l.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        l.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        l.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        if includeCloneRefCount, !readsWholeCloneFlag { l.forkattr = attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT) }
        if readsWholeCloneFlag { l.forkattr |= attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) }
        if includePrivateSize { l.forkattr |= attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) }
        if includeDataAllocation || includeWholeCloneMetadata { l.fileattr |= attrgroup_t(ATTR_FILE_DATAALLOCSIZE) }
        if includeWholeCloneMetadata {
            l.forkattr |= attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_CLONE_REFCNT)
        }
        if includeModificationTime { l.commonattr |= attrgroup_t(ATTR_CMN_MODTIME) }
        if includeCreationTime { l.commonattr |= attrgroup_t(ATTR_CMN_CRTIME) }
        if includeAccessTime { l.commonattr |= attrgroup_t(ATTR_CMN_ACCTIME) }
        if includeDataLength { l.fileattr |= attrgroup_t(ATTR_FILE_DATALENGTH) }
        if includeLinkCount { l.fileattr |= attrgroup_t(ATTR_FILE_LINKCOUNT) }
        list = l
        self.entryLimit = entryLimit
        self.apfsPrefetchDevice = apfsPrefetchDevice
        self.readsWholeCloneFlag = readsWholeCloneFlag
    }

    /// Every entry of the directory at `path`, or nil when it can't be opened or read (as when
    /// `contentsOfDirectory` throws). Does not follow a symlink at `path`.
    func entries(
        atPath path: String, followAncestorLinks: Bool = true, expectedIdentity: FileIdentity? = nil,
        shouldContinue: () -> Bool = { true }
    ) -> [DirectoryEntry]? {
        listing(atPath: path, followAncestorLinks: followAncestorLinks, expectedIdentity: expectedIdentity,
                shouldContinue: shouldContinue)?.entries
    }

    func listing(
        atPath path: String, followAncestorLinks: Bool = true, expectedIdentity: FileIdentity? = nil,
        summarize policy: DirectoryListing.SummaryPolicy? = nil, shouldContinue: () -> Bool = { true }
    ) -> DirectoryListing? {
        let linkFlag = followAncestorLinks ? O_NOFOLLOW : O_NOFOLLOW_ANY
        let fd = open(path, O_RDONLY | O_DIRECTORY | linkFlag | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if let expectedIdentity {
            var info = stat()
            guard fstat(fd, &info) == 0, FileIdentity(dev: info.st_dev, ino: info.st_ino) == expectedIdentity
            else { return nil }
            if let entryLimit, let apfsPrefetchDevice, info.st_dev == apfsPrefetchDevice {
                let links = Int(info.st_nlink)
                // APFS stat values are a hint to skip speculative reads of wide directories.
                // The ordinary walk still reads the complete directory on this path.
                if links - 2 > entryLimit, info.st_size == Int64(links) * 32 { return nil }
            }
        }
        return readListing(from: fd, usingCloneFlag: readsWholeCloneFlag, summarize: policy, shouldContinue: shouldContinue)
    }

    private func readListing(
        from fd: Int32, usingCloneFlag: Bool, summarize policy: DirectoryListing.SummaryPolicy?, shouldContinue: () -> Bool
    ) -> DirectoryListing? {
        var result = DirectoryListing()
        var attributes = list
        if readsWholeCloneFlag && !usingCloneFlag {
            attributes.forkattr &= ~attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
            attributes.forkattr |= attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT)
        }
        let options = attributes.forkattr == 0 ? 0 : UInt64(FSOPT_ATTR_CMN_EXTENDED)
        while shouldContinue() {
            let count = buffer.withUnsafeMutableBytes { raw in
                getattrlistbulk(fd, &attributes, raw.baseAddress!, raw.count, options)
            }
            if count < 0 { return nil }
            if count == 0 { return result }
            if let entryLimit, count > entryLimit - result.entries.count { return nil }
            let needsCloneCount = buffer.withUnsafeBytes { raw -> Bool in
                var start = 0
                for _ in 0..<count {
                    let length = Int(raw.loadUnaligned(fromByteOffset: start, as: UInt32.self))
                    let entry = Self.parse(raw, start: start, readsWholeCloneFlag: usingCloneFlag)
                    if usingCloneFlag, entry.error == 0, entry.type == VREG.rawValue,
                       entry.flags & UInt32(SF_DATALESS) == 0, entry.sharesAllBlocks == nil {
                        return true
                    }
                    result.add(entry, policy: policy)
                    start += length
                }
                return false
            }
            if needsCloneCount {
                // Use a fresh cursor on the same open directory before publishing any rows or totals.
                guard shouldContinue() else { return nil }
                let exact = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard exact >= 0 else { return nil }
                defer { close(exact) }
                return readListing(from: exact, usingCloneFlag: false, summarize: policy, shouldContinue: shouldContinue)
            }
        }
        return nil
    }

    /// Checks filesystem type and identity on the same opened root directory.
    static func localAPFSDevice(atPath path: String, matching identity: FileIdentity) -> dev_t? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var root = stat()
        var volume = statfs()
        guard fstat(fd, &root) == 0,
              FileIdentity(dev: root.st_dev, ino: root.st_ino) == identity,
              fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
              withUnsafeBytes(of: volume.f_fstypename, {
                  $0.prefix { $0 != 0 }.elementsEqual("apfs".utf8)
              }) else { return nil }
        return root.st_dev
    }

    /// Fields are packed common, directory, file, then extended-common, each in bit order, and are
    /// present only when their bit is in the returned set.
    private static func parse(_ raw: UnsafeRawBufferPointer, start: Int, readsWholeCloneFlag: Bool) -> DirectoryEntry {
        var at = start + MemoryLayout<UInt32>.size
        func read<T>(_: T.Type) -> T {
            defer { at += MemoryLayout<T>.size }
            return raw.loadUnaligned(fromByteOffset: at, as: T.self)
        }
        let returned = read(attribute_set_t.self)
        func has(_ group: attrgroup_t, _ bit: Int32) -> Bool { group & attrgroup_t(bit) != 0 }
        let c = returned.commonattr
        let error = has(c, ATTR_CMN_ERROR) ? Int32(bitPattern: read(UInt32.self)) : 0
        var name = ""
        if has(c, ATTR_CMN_NAME) {
            let refAt = at
            let ref = read(attrreference_t.self)
            let bytes = UnsafeRawBufferPointer(rebasing: raw[(refAt + Int(ref.attr_dataoffset))...])
            let length = max(0, Int(ref.attr_length) - 1)  // drop the NUL
            // Not UTF-8: no path string names it, so the entry reads as unreadable attributes.
            guard let decoded = String(validating: bytes.prefix(length), as: UTF8.self) else {
                return DirectoryEntry(
                    name: "", error: EILSEQ, type: UInt32(VNON.rawValue), device: 0, flags: 0, inode: 0,
                    isMountPoint: false, allocated: nil, cloneRefCount: nil)
            }
            name = decoded
        }
        let device = has(c, ATTR_CMN_DEVID) ? read(dev_t.self) : 0
        let type = has(c, ATTR_CMN_OBJTYPE) ? read(UInt32.self) : UInt32(VNON.rawValue)
        let birthTime = has(c, ATTR_CMN_CRTIME) ? CatalogFileIdentity.timestamp(read(timespec.self)) : nil
        let modified = has(c, ATTR_CMN_MODTIME) ? read(timespec.self) : nil
        let accessed = has(c, ATTR_CMN_ACCTIME) ? read(timespec.self) : nil
        let flags = has(c, ATTR_CMN_FLAGS) ? read(UInt32.self) : 0
        let inode = has(c, ATTR_CMN_FILEID) ? read(UInt64.self) : 0
        let mount = has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) ? read(UInt32.self) : 0
        let linkCount = has(returned.fileattr, ATTR_FILE_LINKCOUNT) ? read(UInt32.self) : nil
        let allocated = has(returned.fileattr, ATTR_FILE_ALLOCSIZE) ? Int64(read(off_t.self)) : nil
        let dataLength = has(returned.fileattr, ATTR_FILE_DATALENGTH) ? Int64(read(off_t.self)) : nil
        let dataAllocated = has(returned.fileattr, ATTR_FILE_DATAALLOCSIZE) ? Int64(read(off_t.self)) : nil
        let privateBytes = has(returned.forkattr, ATTR_CMNEXT_PRIVATESIZE) ? Int64(read(off_t.self)) : nil
        let cloneID = has(returned.forkattr, ATTR_CMNEXT_CLONEID) ? read(UInt64.self) : nil
        let extendedFlags = has(returned.forkattr, ATTR_CMNEXT_EXT_FLAGS) ? read(UInt64.self) : nil
        let refCount = has(returned.forkattr, ATTR_CMNEXT_CLONE_REFCNT) ? read(UInt32.self) : nil
        // APFS can set shares-all for compressed clones whose numeric reference count is zero.
        let useSharingFlag = readsWholeCloneFlag && has(c, ATTR_CMN_FLAGS) && flags & UInt32(UF_COMPRESSED) == 0
        return DirectoryEntry(
            name: name, error: error, type: type, device: device, flags: flags, inode: inode,
            isMountPoint: mount & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0,
            allocated: allocated, cloneRefCount: refCount,
            modified: modified.map { Date(timeIntervalSince1970: Double($0.tv_sec) + Double($0.tv_nsec) / 1e9) },
            accessTime: accessed.map(Self.accessTime) ?? .nan,
            dataLength: dataLength, linkCount: linkCount, privateBytes: privateBytes,
            dataForkAllocated: dataAllocated, birthTime: birthTime,
            wholeClone: cloneID != nil || dataAllocated != nil || (!readsWholeCloneFlag && extendedFlags != nil)
                ? WholeCloneMetadata(id: cloneID ?? 0, mainBytes: dataAllocated, flags: extendedFlags) : nil,
            sharesAllBlocks: useSharingFlag ? extendedFlags.map { $0 & UInt64(EF_SHARES_ALL_BLOCKS) != 0 } : nil)
    }

    static func accessTime(_ time: timespec) -> Double {
        Double(time.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate + Double(time.tv_nsec) / 1e9
    }
}
