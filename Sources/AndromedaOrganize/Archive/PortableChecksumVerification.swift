import AndromedaCore
import Foundation

/// Checks the data forks listed in a SHA-256 manifest relative to its folder or a selected root.
public struct PortableChecksumVerification: Sendable {
    static let maximumManifestBytes = 16 * 1_048_576
    static let maximumFileCount = 100_000

    public struct Issue: Sendable {
        public enum Kind: String, Sendable { case missing = "Missing", mismatch = "Content differs", unreadable = "Couldn’t verify" }
        public let path: String
        public let kind: Kind
    }

    public let manifestName: String
    public let verified: Int
    public let failed: Int
    public let issues: [Issue]

    private enum Failure: LocalizedError {
        case unreadableManifest, unreadableRoot, invalidLine(Int), noChecksums, changedManifest, changedRoot

        var errorDescription: String? {
            switch self {
            case .unreadableManifest: "Choose a readable SHA-256 manifest of up to 16 MiB."
            case .unreadableRoot: "Choose a readable local folder to check against the checksum file."
            case .invalidLine(let line): "Line \(line) has an invalid checksum, an unsafe path, or a repeated file."
            case .noChecksums: "The manifest contains no SHA-256 checksums."
            case .changedManifest: "The manifest or its folder changed during verification. Try again."
            case .changedRoot: "The folder selected for verification changed. Choose it again."
            }
        }
    }

    private struct Entry {
        let path: String
        let components: [String]
        let digest: Data
    }

    public static func verify(
        _ manifest: URL, relativeTo root: URL? = nil, env: ScanEnvironment, canReadProtectedPaths: Bool, control: ScanControl
    ) throws -> Self {
        try ArchiveTree.check(control)
        let manifest = manifest.standardizedFileURL
        let parent = manifest.deletingLastPathComponent()
        guard manifest.isFileURL, canReadProtectedPaths || !env.isPromptingPath(manifest) else { throw Failure.unreadableManifest }
        let manifestDirectory = ArchiveTree.openDirectory(parent.path)
        guard manifestDirectory >= 0 else { throw Failure.unreadableManifest }
        defer { close(manifestDirectory) }
        var manifestFolder = stat()
        guard fstat(manifestDirectory, &manifestFolder) == 0 else { throw Failure.unreadableManifest }
        let manifestName = manifest.lastPathComponent
        let fd = openFile([manifestName], below: manifestDirectory, device: manifestFolder.st_dev)
        guard fd >= 0 else { throw Failure.unreadableManifest }
        defer { close(fd) }
        guard let before = regularFile(fd, on: manifestFolder.st_dev),
              (1...Int64(maximumManifestBytes)).contains(before.bytes) else {
            throw Failure.unreadableManifest
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: Int(before.bytes)), data.count == before.bytes,
              regularFile(fd, on: manifestFolder.st_dev) == before else { throw Failure.changedManifest }
        let entries = try parse(data, control: control)
        let dataRoot = root?.standardizedFileURL ?? parent
        var dataDirectory = manifestDirectory
        var dataFolder = manifestFolder
        if root != nil {
            let host = dataRoot.host()?.lowercased() ?? ""
            guard dataRoot.isFileURL, host.isEmpty || host == "localhost",
                  canReadProtectedPaths || !env.isPromptingPath(dataRoot) else { throw Failure.unreadableRoot }
            dataDirectory = ArchiveTree.openDirectory(dataRoot.path)
            guard dataDirectory >= 0 else { throw Failure.unreadableRoot }
        }
        defer { if root != nil { close(dataDirectory) } }
        if root != nil {
            var volume = statfs()
            guard fstat(dataDirectory, &dataFolder) == 0, dataFolder.st_flags & UInt32(SF_DATALESS) == 0,
                  fstatfs(dataDirectory, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
                throw Failure.unreadableRoot
            }
        }
        var failed = 0
        var issues: [Issue] = []
        for entry in entries {
            try ArchiveTree.check(control)
            let url = dataRoot.appendingPathComponent(entry.path)
            let issue = canReadProtectedPaths || !env.isPromptingPath(url)
                ? try check(entry, below: dataDirectory, device: dataFolder.st_dev, control: control) : .unreadable
            if let issue {
                failed += 1
                if issues.count < 200 { issues.append(Issue(path: entry.path, kind: issue)) }
            }
        }
        try ArchiveTree.check(control)
        let reopened = ArchiveTree.openDirectory(parent.path)
        guard reopened >= 0 else { throw Failure.changedManifest }
        defer { close(reopened) }
        var currentFolder = stat()
        var currentManifest = stat()
        guard fstat(reopened, &currentFolder) == 0,
              currentFolder.st_dev == manifestFolder.st_dev, currentFolder.st_ino == manifestFolder.st_ino,
              fstatat(reopened, manifestName, &currentManifest, AT_SYMLINK_NOFOLLOW) == 0,
              ArchiveTree.Node(currentManifest, relative: "") == before else { throw Failure.changedManifest }
        if root != nil {
            let reopenedRoot = ArchiveTree.openDirectory(dataRoot.path)
            guard reopenedRoot >= 0 else { throw Failure.changedRoot }
            defer { close(reopenedRoot) }
            guard fstat(reopenedRoot, &currentFolder) == 0,
                  currentFolder.st_dev == dataFolder.st_dev, currentFolder.st_ino == dataFolder.st_ino else {
                throw Failure.changedRoot
            }
        }
        try ArchiveTree.check(control)
        return Self(manifestName: manifestName, verified: entries.count - failed, failed: failed, issues: issues)
    }

    private static func check(
        _ entry: Entry, below root: Int32, device: dev_t, control: ScanControl
    ) throws -> Issue.Kind? {
        let fd = openFile(entry.components, below: root, device: device)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .unreadable }
        defer { close(fd) }
        guard let before = regularFile(fd, on: device) else { return .unreadable }
        let digest: Data
        do { digest = try ArchiveTree.dataForkSHA256(fd, control: control) }
        catch {
            try ArchiveTree.check(control)
            return .unreadable
        }
        let current = openFile(entry.components, below: root, device: device)
        guard current >= 0 else { return .unreadable }
        defer { close(current) }
        guard regularFile(current, on: device) == before else { return .unreadable }
        control.file(bytes: before.bytes)
        return digest == entry.digest ? nil : .mismatch
    }

    private static func openFile(_ components: [String], below root: Int32, device: dev_t) -> Int32 {
        guard let filename = components.last else { errno = EINVAL; return -1 }
        var parent = dup(root)
        guard parent >= 0 else { return -1 }
        for component in components.dropLast() {
            let next = openComponent(component, below: parent, device: device, directory: true)
            let failure = errno
            close(parent)
            guard next >= 0 else { errno = failure; return -1 }
            parent = next
        }
        let fd = openComponent(filename, below: parent, device: device, directory: false)
        let failure = errno
        close(parent)
        errno = failure
        return fd
    }

    private static func openComponent(_ name: String, below parent: Int32, device: dev_t, directory: Bool) -> Int32 {
        var expected = stat()
        guard fstatat(parent, name, &expected, AT_SYMLINK_NOFOLLOW) == 0 else { return -1 }
        guard expected.st_dev == device, expected.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              expected.st_flags & UInt32(SF_DATALESS) == 0 else { errno = EINVAL; return -1 }
        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0)
        let fd = openat(parent, name, flags)
        guard fd >= 0 else { return -1 }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == expected.st_dev, opened.st_ino == expected.st_ino,
              opened.st_mode & S_IFMT == expected.st_mode & S_IFMT,
              opened.st_flags & UInt32(SF_DATALESS) == 0 else {
            close(fd)
            errno = EINVAL
            return -1
        }
        return fd
    }

    private static func regularFile(_ fd: Int32, on device: dev_t) -> ArchiveTree.Node? {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == device, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        return ArchiveTree.Node(info, relative: "")
    }

    private static func parse(_ data: Data, control: ScanControl) throws -> [Entry] {
        var entries: [Entry] = []
        var seen: Set<Data> = []
        for (line, bytes) in data.split(separator: 10, omittingEmptySubsequences: false).enumerated() where !bytes.isEmpty {
            try ArchiveTree.check(control)
            guard entries.count < maximumFileCount, let entry = parseLine(Array(bytes)),
                  seen.insert(Data(entry.path.utf8)).inserted else {
                throw Failure.invalidLine(line + 1)
            }
            entries.append(entry)
        }
        guard !entries.isEmpty else { throw Failure.noChecksums }
        return entries
    }

    private static func parseLine(_ raw: [UInt8]) -> Entry? {
        var row = raw[...]
        let escaped = row.first == 92
        if escaped { row.removeFirst() }
        let name: ArraySlice<UInt8>
        let checksum: ArraySlice<UInt8>
        if row.starts(with: "SHA256 (".utf8) {
            if row.last == 13 { row.removeLast() }
            guard row.count > 76, row.dropLast(64).suffix(4).elementsEqual(") = ".utf8) else { return nil }
            name = row.dropFirst(8).dropLast(68)
            checksum = row.suffix(64)
        } else {
            guard row.count > 66, row.dropFirst(64).first == 32,
                  let mode = row.dropFirst(65).first, mode == 32 || mode == 42 else { return nil }
            name = row.dropFirst(66)
            checksum = row.prefix(64)
        }
        guard let digest = hexDigest(checksum), let decoded = decodeName(name, escaped: escaped) else { return nil }
        let relative = decoded.starts(with: "./".utf8) ? decoded.dropFirst(2) : decoded[...]
        guard !relative.isEmpty, !relative.contains(0), let path = String(validating: relative, as: UTF8.self) else { return nil }
        let components = relative.split(separator: 47, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return Entry(path: path, components: components, digest: digest)
    }

    private static func decodeName(_ bytes: ArraySlice<UInt8>, escaped: Bool) -> [UInt8]? {
        guard escaped else { return Array(bytes) }
        var result: [UInt8] = []
        var iterator = bytes.makeIterator()
        while let byte = iterator.next() {
            if byte != 92 { result.append(byte); continue }
            switch iterator.next() {
            case 92: result.append(92)
            case 110: result.append(10)
            case 114: result.append(13)
            default: return nil
            }
        }
        return result
    }

    private static func hexDigest(_ bytes: ArraySlice<UInt8>) -> Data? {
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        var result = Data()
        var iterator = bytes.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let upper = digit(high), let lower = digit(low) else { return nil }
            result.append(upper << 4 | lower)
        }
        return result.count == 32 ? result : nil
    }
}
