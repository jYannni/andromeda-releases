import CryptoKit
import AndromedaCore
import Foundation

enum ArchiveFailure: LocalizedError, Equatable {
    case unsupportedSource(String)
    case changed(String)
    case system(String, Int32)
    case verification
    case cancelled
    case driveUnavailable
    case insufficientSpace
    case occupied
    case notReady
    case missingFileVerification
    case archivedFileMismatch
    case sameArchiveDevice
    case archiveAlreadyOnDrive
    case archiveDiskTopologyUnavailable
    case mediaUnavailable
    case mediaRestoreDestination
    case portableChecksumsMismatch
    case checksumSnapshotTooLarge
    case collectionZIP

    var errorDescription: String? {
        switch self {
        case .unsupportedSource(let path): "Andromeda couldn’t safely copy \(path). Choose a local project or a folder on connected media without links, online-only items, or mounted volumes inside."
        case .changed(let path): "\(path) changed during this operation. Review it again before retrying."
        case .system(let path, let code): "\(path) couldn’t be read or written (\(String(cString: strerror(code))))."
        case .verification: "The copy didn’t match the original’s contents or metadata."
        case .cancelled: "The archive operation was cancelled."
        case .driveUnavailable: "Connect the original writable APFS drive and try again."
        case .insufficientSpace: "There isn’t enough space on the destination."
        case .occupied: "Something already exists at the destination. Andromeda leaves it in place."
        case .notReady: "This archive isn’t ready for that action."
        case .missingFileVerification: "Run Check Integrity on this archive to save its file verification before restoring individual files."
        case .archivedFileMismatch: "This file no longer matches the archive’s saved verification."
        case .sameArchiveDevice: "Choose a drive on a different physical disk. These volumes share a disk."
        case .archiveAlreadyOnDrive: "This archive already has a copy on that drive. Check its record in External Archives."
        case .archiveDiskTopologyUnavailable: "Andromeda couldn’t confirm that these volumes use separate disks. Reconnect the drives and try again."
        case .mediaUnavailable: "Reconnect the original media and review the folder again."
        case .mediaRestoreDestination: "Choose a local folder to restore this media archive."
        case .portableChecksumsMismatch: "The portable checksum file is missing or no longer matches the saved verification."
        case .checksumSnapshotTooLarge: "Choose a smaller folder. The checksum list is limited to 100,000 files and 16 MiB."
        case .collectionZIP: "Andromeda couldn’t create or read back the ZIP. Check the available space and try again."
        }
    }
}

/// Files and directories in the order they must be created. Device, inode, and change time
/// detect replacement and concurrent edits. Access time changes as files are read.
struct ArchiveTree: Equatable, Sendable {
    enum Verification: Equatable {
        case archive, mediaSource, mediaDestination
    }

    enum Metadata {
        case strict, archiveCopy
    }

    struct Fingerprint: Codable {
        struct Entry: Codable {
            let path: String
            let digest: Data
            let firstLink: String?
        }

        let digest: Data
        let entries: [Entry]
        let recordsLinkRoles: Bool?
        let mediaDigest: Data?
    }

    struct Node: Hashable, Sendable {
        let relative: String
        let folder: Bool
        let identity: FileIdentity
        let mode: mode_t
        let flags: UInt32
        let bytes: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init(_ s: stat, relative: String) {
            self.relative = relative
            folder = s.st_mode & S_IFMT == S_IFDIR
            identity = FileIdentity(dev: s.st_dev, ino: s.st_ino)
            mode = s.st_mode
            flags = s.st_flags
            bytes = folder ? 0 : s.st_size
            modifiedSeconds = s.st_mtimespec.tv_sec
            modifiedNanos = s.st_mtimespec.tv_nsec
            changedSeconds = s.st_ctimespec.tv_sec
            changedNanos = s.st_ctimespec.tv_nsec
        }

        func under(_ root: String) -> String { relative.isEmpty ? root : root + "/" + relative }
    }

    let nodes: [Node]
    let requiredBytes: Int64

    init(at root: String, control: ScanControl, preparingCopy: Bool = true,
         maximumNodes: Int? = nil, allowsPath: (String) -> Bool = { _ in true }) throws {
        var collected: [Node] = []
        var bytes: Int64 = 0
        var visited = 0

        func visit(_ relative: String, on device: dev_t?) throws {
            try Self.check(control)
            if let maximumNodes {
                guard visited < maximumNodes else { throw ArchiveFailure.checksumSnapshotTooLarge }
                visited += 1
            }
            let path = relative.isEmpty ? root : root + "/" + relative
            guard allowsPath(path) else { throw ArchiveFailure.unsupportedSource(path) }
            var info = stat()
            guard lstat(path, &info) == 0 else { throw ArchiveFailure.system(path, errno) }
            let kind = info.st_mode & S_IFMT
            let excludedFlags = UInt32(preparingCopy ? SF_DATALESS | UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND
                                                     : SF_DATALESS)
            guard (kind == S_IFREG || kind == S_IFDIR), device == nil || device == info.st_dev,
                  info.st_flags & excludedFlags == 0 else { throw ArchiveFailure.unsupportedSource(path) }
            // O_NOFOLLOW_ANY checks the ancestors too. Check the opened object against lstat.
            let node = Node(info, relative: relative)
            try Self.withNode(node, at: path) { fd in
                if node.folder {
                    // list the opened directory, so an ancestor swap cannot lead outside this tree
                    let listing = try Self.children(fd, path: path, limit: maximumNodes.map { $0 - visited },
                                                    control: maximumNodes == nil ? nil : control)
                    guard preparingCopy || Set(listing.lazy.map({ Data($0.utf8) })).count == listing.count else {
                        throw ArchiveFailure.changed(path)
                    }
                    for name in listing {
                        try visit(relative.isEmpty ? name : relative + "/" + name, on: info.st_dev)
                    }
                } else if preparingCopy {
                    let allocated = Int64(info.st_blocks) * 512
                    // A compressed or sparse file may expand. Allocated space can also include resource forks.
                    bytes += max(node.bytes, allocated)
                }
            }
            // One block of overhead per entry, including empty files and directories.
            if preparingCopy { bytes += 4096 }
            collected.append(node)
        }

        try visit("", on: nil)
        // Children were collected after reading their parent so the parent's metadata was
        // checked both before and after enumeration. Sorting puts every parent before its children.
        nodes = collected.sorted { $0.relative < $1.relative }
        requiredBytes = bytes
    }

    struct ReusableFile {
        let node: Node
        let path: String
        let fingerprint: Data
    }

    @discardableResult
    func copy(from source: String, to destination: String, device: dev_t, control: ScanControl, metadata: Metadata = .strict,
              reusing candidates: [Data: ReusableFile] = [:]) throws -> Int {
        var copiedFiles: [FileIdentity: String] = [:]
        var reused = 0
        for node in nodes {
            try Self.check(control)
            let from = node.under(source), to = node.under(destination)
            // URL path components can normalize Unicode. Keep the original name bytes the digest covers.
            let pathBytes = to.utf8
            guard let separator = pathBytes.lastIndex(of: UInt8(ascii: "/")), separator != pathBytes.startIndex else {
                throw ArchiveFailure.changed(to)
            }
            let parent = Self.openDirectory(String(decoding: pathBytes[..<separator], as: UTF8.self))
            guard parent >= 0 else { throw ArchiveFailure.system(to, errno) }
            defer { close(parent) }
            try Self.checkDevice(parent, path: to, device: device)
            let name = String(decoding: pathBytes[pathBytes.index(after: separator)...], as: UTF8.self)
            if node.folder {
                guard mkdirat(parent, name, 0o700) == 0 else { throw ArchiveFailure.system(to, errno) }
            } else {
                try Self.withNode(node, at: from) { input in
                    if let sibling = copiedFiles[node.identity] {
                        guard linkat(AT_FDCWD, Self.systemPath(sibling), parent, name, 0) == 0 else {
                            throw ArchiveFailure.system(to, errno)
                        }
                        return
                    }
                    if let candidate = candidates[Data(node.relative.utf8)],
                       try Self.reuse(candidate, to: name, under: parent, path: to, control: control, metadata: metadata) {
                        reused += 1
                    } else {
                        try Self.copyRegularFile(input, to: name, under: parent, path: to, device: device)
                    }
                }
                copiedFiles[node.identity] = to
                control.file(bytes: node.bytes)
            }
        }
        // Apply folder metadata after adding the children, so modification dates are preserved.
        for node in nodes.reversed() where node.folder {
            try Self.check(control)
            let from = node.under(source), to = node.under(destination)
            try Self.withNode(node, at: from) { input in
                let output = Self.openDirectory(to)
                guard output >= 0 else { throw ArchiveFailure.system(to, errno) }
                defer { close(output) }
                try Self.checkDevice(output, path: to, device: device)
                guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                    throw ArchiveFailure.system(to, errno)
                }
            }
        }
        return reused
    }

    private static func reuse(_ candidate: ReusableFile, to name: String, under parent: Int32,
                              path: String, control: ScanControl, metadata: Metadata) throws -> Bool {
        var hash = FingerprintWriter()
        let node = candidate.node
        do {
            _ = try fingerprint(node, at: candidate.path, relative: node.relative, firstLink: node.relative,
                                control: control, metadata: metadata, into: &hash)
        } catch {
            try check(control)
            return false
        }
        guard Data(hash.aggregate.finalize()) == candidate.fingerprint else { return false }
        return try withNode(node, at: candidate.path) { fd in
            guard fclonefileat(fd, parent, name, UInt32(CLONE_ACL)) == 0 else { return false }
            let output = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard output >= 0 else { throw ArchiveFailure.system(path, errno) }
            defer { close(output) }
            guard fsync(output) == 0 else { throw ArchiveFailure.system(path, errno) }
            return true
        }
    }

    func copyRegularFile(from source: String, to name: String, under parent: Int32, path: String, device: dev_t) throws {
        guard let node = nodes.first, !node.folder else { throw ArchiveFailure.unsupportedSource(source) }
        try Self.withNode(node, at: source) { input in
            try Self.copyRegularFile(input, to: name, under: parent, path: path, device: device)
        }
    }

    private static func copyRegularFile(_ input: Int32, to name: String, under parent: Int32, path: String, device: dev_t) throws {
        let output = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw ArchiveFailure.system(path, errno) }
        defer { close(output) }
        try checkDevice(output, path: path, device: device)
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0,
              fsync(output) == 0 else { throw ArchiveFailure.system(path, errno) }
    }

    func fingerprint(at root: String, control: ScanControl, reportProgress: Bool = false,
                     metadata: Metadata = .strict) throws -> Data {
        try fingerprints(at: root, control: control, reportProgress: reportProgress, includeEntries: false,
                         metadata: metadata).digest
    }

    func fingerprints(
        at root: String, control: ScanControl, reportProgress: Bool = false, includeEntries: Bool,
        verification: Verification = .archive, metadata: Metadata = .strict,
        onFileDigest: ((String, Data) throws -> Void)? = nil
    ) throws -> Fingerprint {
        var hash = FingerprintWriter(media: verification == .archive ? nil : SHA256())
        var entries: [Fingerprint.Entry] = []
        if includeEntries { entries.reserveCapacity(nodes.count) }
        var firstLinks: [FileIdentity: String] = [:]
        for node in nodes {
            try Self.check(control)
            let path = node.under(root)
            let firstLink = node.folder ? nil : firstLinks[node.identity] ?? node.relative
            if let firstLink { firstLinks[node.identity] = firstLink }
            if includeEntries { hash.entry = SHA256() }
            let fileDigest = try Self.fingerprint(
                node, at: path, relative: node.relative, firstLink: firstLink, control: control,
                metadataRequired: verification != .mediaSource, metadata: metadata, into: &hash)
            if let fileDigest { try onFileDigest?(node.relative, fileDigest) }
            if let entry = hash.entry {
                let earlierLink = firstLink.flatMap { $0.utf8.elementsEqual(node.relative.utf8) ? nil : $0 }
                entries.append(.init(path: node.relative, digest: Data(entry.finalize()), firstLink: earlierLink))
            }
            if reportProgress, !node.folder { control.file(bytes: node.bytes) }
        }
        return Fingerprint(digest: Data(hash.aggregate.finalize()), entries: entries,
                           recordsLinkRoles: includeEntries ? true : nil, mediaDigest: hash.media.map { Data($0.finalize()) })
    }

    /// Verifies a detached file using the path and hard-link role it had inside the original tree.
    func fileFingerprint(
        at path: String, relative: String, firstLink: String, control: ScanControl, metadata: Metadata = .strict,
        changingFinderTags: AutomationFinderTags.Change = .unchanged
    ) throws -> Data {
        guard nodes.count == 1, let node = nodes.first, !node.folder else { throw ArchiveFailure.changed(path) }
        try Self.check(control)
        var hash = FingerprintWriter()
        _ = try Self.fingerprint(node, at: path, relative: relative, firstLink: firstLink, control: control,
                                 metadata: metadata, changingFinderTags: changingFinderTags, into: &hash)
        return Data(hash.aggregate.finalize())
    }

    private static func fingerprint(
        _ node: Node, at path: String, relative: String, firstLink: String?,
        control: ScanControl, metadataRequired: Bool = true, metadata: Metadata = .strict,
        changingFinderTags: AutomationFinderTags.Change = .unchanged,
        into hash: inout FingerprintWriter
    ) throws -> Data? {
        if metadataRequired {
            hash.feed(Data(relative.utf8))
            // Access and change times, inode IDs, and allocation/compression can legitimately differ.
            hash.feed(Data("\(node.mode)|\(node.flags & ~UInt32(UF_COMPRESSED))|\(node.bytes)|\(node.modifiedSeconds)|\(node.modifiedNanos)".utf8))
        }
        if hash.media != nil {
            hash.feedMedia(Data(relative.utf8))
            hash.feedMedia(Data((node.folder ? "directory" : "file:\(node.bytes)").utf8))
        }
        return try withNode(node, at: path) { fd in
            let resource = metadataRequired ? try hashMetadata(fd, path: path, policy: metadata,
                                                               changingFinderTags: changingFinderTags, hash: &hash) : nil
            if hash.media != nil {
                if metadataRequired {
                    hash.feedMedia(resource ?? Data())
                } else {
                    let length = fgetxattr(fd, "com.apple.ResourceFork", nil, 0, 0, 0)
                    if length < 0 {
                        guard errno == ENOATTR || errno == ENOTSUP else { throw ArchiveFailure.system(path, errno) }
                        hash.feedMedia(Data())
                    } else {
                        hash.feedMedia(try resourceFork(fd, length: length, path: path, control: control))
                    }
                }
            }
            if let firstLink {
                if metadataRequired { hash.feed(Data(firstLink.utf8)) }
                if hash.media != nil { hash.feedMedia(Data(firstLink.utf8)) }
                let digest = try dataForkSHA256(fd, control: control)
                if metadataRequired { hash.feed(digest) }
                if hash.media != nil { hash.feedMedia(digest) }
                return digest
            }
            return nil
        }
    }

    static func dataForkSHA256(_ fd: Int32, control: ScanControl) throws -> Data {
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var content = SHA256()
        while true {
            try check(control)
            guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { break }
            content.update(data: data)
        }
        return Data(content.finalize())
    }

    static func dataForkSHA256(of node: Node, under root: String, control: ScanControl) throws -> Data {
        try withNode(node, at: node.under(root)) { fd in try dataForkSHA256(fd, control: control) }
    }

    private static func withNode<T>(_ node: Node, at path: String, _ body: (Int32) throws -> T) throws -> T {
        let fd = open(systemPath(path), O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC | (node.folder ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw ArchiveFailure.system(path, errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Node(info, relative: node.relative) == node else {
            throw ArchiveFailure.changed(path)
        }
        let result = try body(fd)
        guard fstat(fd, &info) == 0, Node(info, relative: node.relative) == node else {
            throw ArchiveFailure.changed(path)
        }
        return result
    }

    static func children(_ fd: Int32, path: String, limit: Int? = nil, control: ScanControl? = nil) throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw ArchiveFailure.system(path, errno) }
        guard let directory = fdopendir(duplicate) else {
            let code = errno
            close(duplicate)
            throw ArchiveFailure.system(path, code)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            if let control { try check(control) }
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw ArchiveFailure.system(path, errno) }
                return names
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(validating: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard let name else { throw ArchiveFailure.unsupportedSource(path) }
            if name != "." && name != ".." {
                if let limit, names.count >= limit { throw ArchiveFailure.checksumSnapshotTooLarge }
                names.append(name)
            }
        }
    }

    private static func hashMetadata(
        _ fd: Int32, path: String, policy: Metadata, changingFinderTags: AutomationFinderTags.Change,
        hash: inout FingerprintWriter
    ) throws -> Data? {
        let length = flistxattr(fd, nil, 0, 0)
        guard length >= 0 else { throw ArchiveFailure.system(path, errno) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard length == 0 || flistxattr(fd, &buffer, length, 0) == length else {
            throw ArchiveFailure.changed(path)
        }
        var names = try buffer.split(separator: 0).map { name in
            guard let name = String(validating: name, as: UTF8.self) else {
                throw ArchiveFailure.unsupportedSource(path)
            }
            return name
        }
        // Gatekeeper can assign the copying app's provenance to files and folders it creates.
        if policy == .archiveCopy { names.removeAll { $0 == "com.apple.provenance" } }
        switch changingFinderTags {
        case .unchanged: break
        case .replace:
            if !names.contains(AutomationFinderTags.attribute) { names.append(AutomationFinderTags.attribute) }
        case .remove: names.removeAll { $0 == AutomationFinderTags.attribute }
        }
        names.sort()
        hash.feed(Data(String(names.count).utf8))
        var resource: Data?
        for name in names {
            hash.feed(Data(name.utf8))
            if name == AutomationFinderTags.attribute, case .replace(let data) = changingFinderTags {
                hash.feed(data)
                continue
            }
            let length = fgetxattr(fd, name, nil, 0, 0, 0)
            guard length >= 0 else { throw ArchiveFailure.system(path, errno) }
            if name == "com.apple.ResourceFork" {
                let digest = try resourceFork(fd, length: length, path: path)
                hash.feed(digest)
                resource = digest
            } else {
                guard length <= 16 * 1_048_576 else { throw ArchiveFailure.unsupportedSource(path) }
                var value = Data(count: length)
                guard length == 0 || value.withUnsafeMutableBytes({
                    fgetxattr(fd, name, $0.baseAddress, length, 0, 0)
                }) == length else { throw ArchiveFailure.changed(path) }
                hash.feed(value)
            }
        }
        errno = 0
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var length = 0
            guard let description = acl_to_text(acl, &length) else { throw ArchiveFailure.system(path, errno) }
            defer { acl_free(description) }
            hash.feed(Data(bytes: description, count: length))
        } else {
            guard errno == 0 || errno == ENOENT else { throw ArchiveFailure.system(path, errno) }
            hash.feed(Data())
        }
        return resource
    }

    private static func resourceFork(_ fd: Int32, length: Int, path: String, control: ScanControl? = nil) throws -> Data {
        var fork = SHA256()
        var offset = 0
        while offset < length {
            if let control { try check(control) }
            let count = min(1_048_576, length - offset)
            var block = Data(count: count)
            guard offset <= UInt32.max, block.withUnsafeMutableBytes({
                fgetxattr(fd, "com.apple.ResourceFork", $0.baseAddress, count, UInt32(offset), 0)
            }) == count else { throw ArchiveFailure.changed(path) }
            fork.update(data: block)
            offset += count
        }
        return Data(fork.finalize())
    }

    private struct FingerprintWriter {
        var aggregate = SHA256()
        var entry: SHA256?
        var media: SHA256? = nil

        mutating func feedMedia(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { media?.update(bufferPointer: $0) }
            media?.update(data: data)
        }

        mutating func feed(_ data: Data) {
            // Keep the existing framing so records written before per-entry fingerprints still verify.
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { bytes in
                aggregate.update(bufferPointer: bytes)
                entry?.update(bufferPointer: bytes)
            }
            aggregate.update(data: data)
            entry?.update(data: data)
        }
    }

    static func check(_ control: ScanControl) throws {
        if control.isCancelled { throw ArchiveFailure.cancelled }
    }

    static func openDirectory(_ path: String) -> Int32 {
        open(systemPath(path), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    }

    /// Foundation may turn /private/var and /private/tmp into the system symlink spellings.
    /// Keep all other ancestors subject to O_NOFOLLOW_ANY.
    static func systemPath(_ path: String) -> String {
        if ["/var", "/tmp"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return "/private" + path }
        return path
    }

    private static func checkDevice(_ fd: Int32, path: String, device: dev_t) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == device else { throw ArchiveFailure.changed(path) }
    }
}
