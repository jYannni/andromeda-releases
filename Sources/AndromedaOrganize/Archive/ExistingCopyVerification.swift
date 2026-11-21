import AndromedaCore
import Foundation

/// A point-in-time, read-only comparison of two explicitly chosen files.
public struct ExistingCopyVerification: Sendable {
    public enum Contents: Equatable, Sendable { case match, differ }
    public enum Location: Equatable, Sendable { case sameFile, sameFolder, sameVolume, sharedDrive, separateDrives, unknown }

    public let first: URL
    public let second: URL
    public let contents: Contents
    public let location: Location
    public let checkedAt: Date

    public struct FolderResult: Sendable {
        public struct Difference: Equatable, Sendable {
            public enum Kind: Equatable, Sendable { case firstOnly, secondOnly, type, data }
            public let relativePath: String
            public let kind: Kind
        }

        public let first: URL
        public let second: URL
        public let matchingFiles: Int
        public let differenceCount: Int
        public let differences: [Difference]
        public let location: Location
        public let checkedAt: Date
    }

    public static func verify(_ first: URL, _ second: URL, control: ScanControl) throws -> Self {
        try verify(first, second, control: control) { paths in
            ExternalArchive.physicalDrives(for: paths, control: control)
        }
    }

    static func verify(
        _ first: URL, _ second: URL, control: ScanControl,
        isDiskImage: (String) -> Bool? = ExternalArchive.isDiskImage,
        physicalDrives: ([String]) -> [Set<String>]?
    ) throws -> Self {
        try ArchiveTree.check(control)
        let first = try OpenedFile(first)
        defer { close(first.descriptor) }
        let second = try OpenedFile(second)
        defer { close(second.descriptor) }

        func hash(_ file: OpenedFile) throws -> Data {
            control.entry(file.url.lastPathComponent)
            let digest = try ArchiveTree.dataForkSHA256(file.descriptor, control: control)
            control.file(bytes: file.snapshot.bytes)
            return digest
        }
        let firstDigest = try hash(first)
        let secondDigest = try hash(second)
        try ArchiveTree.check(control)

        let location = classifyLocation((first.path, first.snapshot.identity), (second.path, second.snapshot.identity),
                                        isDiskImage: isDiskImage, physicalDrives: physicalDrives)

        try ArchiveTree.check(control)
        try first.verifyUnchanged()
        try second.verifyUnchanged()
        try ArchiveTree.check(control)
        return Self(first: first.url, second: second.url, contents: firstDigest == secondDigest ? .match : .differ,
                    location: location, checkedAt: Date())
    }

    public static func verifyFolders(_ first: URL, _ second: URL, control: ScanControl) throws -> FolderResult {
        try verifyFolders(first, second, control: control) { paths in
            ExternalArchive.physicalDrives(for: paths, control: control)
        }
    }

    static func verifyFolders(
        _ first: URL, _ second: URL, control: ScanControl,
        isDiskImage: (String) -> Bool? = ExternalArchive.isDiskImage,
        physicalDrives: ([String]) -> [Set<String>]?
    ) throws -> FolderResult {
        try ArchiveTree.check(control)
        let first = try OpenedFolder(first, control: control)
        defer { close(first.descriptor) }
        let second = try OpenedFolder(second, control: control)
        defer { close(second.descriptor) }

        var secondPaths: [Data: ArchiveTree.Node] = [:]
        secondPaths.reserveCapacity(second.tree.nodes.count)
        for node in second.tree.nodes.dropFirst() {
            try ArchiveTree.check(control)
            guard secondPaths.updateValue(node, forKey: Data(node.relative.utf8)) == nil else {
                throw ArchiveFailure.changed(second.path)
            }
        }
        var matchingFiles = 0
        var differenceCount = 0
        var differences: [FolderResult.Difference] = []
        func difference(_ node: ArchiveTree.Node, _ kind: FolderResult.Difference.Kind) {
            differenceCount += 1
            if differences.count < 200 {
                differences.append(.init(relativePath: node.relative, kind: kind))
            }
        }
        func hash(_ node: ArchiveTree.Node, in folder: OpenedFolder) throws -> Data {
            control.entry(node.relative)
            let digest = try ArchiveTree.dataForkSHA256(of: node, under: folder.path, control: control)
            control.file(bytes: node.bytes)
            return digest
        }
        for node in first.tree.nodes.dropFirst() {
            try ArchiveTree.check(control)
            guard let counterpart = secondPaths.removeValue(forKey: Data(node.relative.utf8)) else {
                difference(node, .firstOnly)
                continue
            }
            guard node.folder == counterpart.folder else {
                difference(node, .type)
                continue
            }
            if node.folder { continue }
            if node.bytes == counterpart.bytes,
               try hash(node, in: first) == hash(counterpart, in: second) {
                matchingFiles += 1
            } else {
                difference(node, .data)
            }
        }
        for node in second.tree.nodes.dropFirst() {
            try ArchiveTree.check(control)
            if secondPaths[Data(node.relative.utf8)] != nil { difference(node, .secondOnly) }
        }

        let location = classifyLocation((first.path, first.identity), (second.path, second.identity),
                                        sameItem: .sameFolder, isDiskImage: isDiskImage, physicalDrives: physicalDrives)
        try first.verifyUnchanged(control: control)
        try second.verifyUnchanged(control: control)
        try ArchiveTree.check(control)
        try first.verifyRootUnchanged()
        try second.verifyRootUnchanged()
        try ArchiveTree.check(control)
        return FolderResult(first: first.url, second: second.url, matchingFiles: matchingFiles,
                            differenceCount: differenceCount, differences: differences, location: location, checkedAt: Date())
    }

    private static func classifyLocation(
        _ first: (path: String, identity: FileIdentity), _ second: (path: String, identity: FileIdentity),
        sameItem: Location = .sameFile,
        isDiskImage: (String) -> Bool?, physicalDrives: ([String]) -> [Set<String>]?
    ) -> Location {
        if first.identity == second.identity { return sameItem }
        if first.identity.dev == second.identity.dev { return .sameVolume }
        guard isDiskImage(first.path) == false, isDiskImage(second.path) == false,
              let drives = physicalDrives([first.path, second.path]), drives.count == 2,
              !drives[0].isEmpty, !drives[1].isEmpty else { return .unknown }
        return drives[0].isDisjoint(with: drives[1]) ? .separateDrives : .sharedDrive
    }

    struct OpenedFolder {
        let url: URL
        let path: String
        let descriptor: Int32
        let tree: ArchiveTree
        let identity: FileIdentity
        private let maximumNodes: Int?
        private let allowsPath: (String) -> Bool

        init(_ url: URL, control: ScanControl, maximumNodes: Int? = nil,
             allowsPath: @escaping (String) -> Bool = { _ in true }) throws {
            let path = ArchiveTree.systemPath(url.standardizedFileURL.path)
            let host = url.host()?.lowercased() ?? ""
            let failure = Failure.unavailableFolder(path)
            guard url.isFileURL, host.isEmpty || host == "localhost", allowsPath(path) else { throw failure }
            let descriptor = ArchiveTree.openDirectory(path)
            guard descriptor >= 0 else { throw failure }
            do {
                var info = stat()
                var volume = statfs()
                guard fstat(descriptor, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0,
                      fstatfs(descriptor, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw failure }
                let tree: ArchiveTree
                do {
                    tree = try ArchiveTree(at: path, control: control, preparingCopy: false,
                                           maximumNodes: maximumNodes, allowsPath: allowsPath)
                }
                catch ArchiveFailure.unsupportedSource(let item) { throw Failure.unavailableFolder(item) }
                let root = ArchiveTree.Node(info, relative: "")
                guard tree.nodes.first == root else { throw ArchiveFailure.changed(path) }
                self.url = url.standardizedFileURL
                self.path = path
                self.descriptor = descriptor
                self.tree = tree
                identity = root.identity
                self.maximumNodes = maximumNodes
                self.allowsPath = allowsPath
            } catch {
                close(descriptor)
                throw error
            }
        }

        func verifyUnchanged(control: ScanControl) throws {
            let current = try OpenedFolder(url, control: control, maximumNodes: maximumNodes, allowsPath: allowsPath)
            defer { close(current.descriptor) }
            guard current.tree == tree else { throw ArchiveFailure.changed(path) }
        }

        func verifyRootUnchanged() throws {
            let current = ArchiveTree.openDirectory(path)
            guard current >= 0 else { throw ArchiveFailure.changed(path) }
            defer { close(current) }
            var info = stat()
            guard fstat(current, &info) == 0, ArchiveTree.Node(info, relative: "") == tree.nodes.first else {
                throw ArchiveFailure.changed(path)
            }
        }
    }

    private enum Failure: LocalizedError {
        case unavailable(String)
        case unavailableFolder(String)
        case changed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let name): "Couldn’t open \(name) as a regular local file. Choose an available copy."
            case .unavailableFolder(let path): "Couldn’t verify \(path). Choose local folders with readable files and no symbolic links, online-only files, or nested volumes."
            case .changed(let name): "\(name) changed during verification. Choose the file again."
            }
        }
    }

    private struct OpenedFile {
        let url: URL
        let path: String
        let descriptor: Int32
        let snapshot: ArchiveTree.Node

        init(_ url: URL) throws {
            let standardized = url.standardizedFileURL
            let path = SafetyGuard.withoutSystemPathAlias(standardized.path)
            let failure = Failure.unavailable(url.lastPathComponent)
            let host = url.host()?.lowercased() ?? ""
            guard url.isFileURL, host.isEmpty || host == "localhost" else { throw failure }
            var info = stat()
            guard lstat(path, &info) == 0, Self.isRegularLocalCandidate(info) else { throw failure }
            let before = ArchiveTree.Node(info, relative: "")
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw failure }
            var volume = statfs()
            guard fstat(fd, &info) == 0, Self.isRegularLocalCandidate(info), ArchiveTree.Node(info, relative: "") == before,
                  fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
                close(fd)
                throw failure
            }
            self.url = standardized
            self.path = path
            descriptor = fd
            snapshot = before
        }

        func verifyUnchanged() throws {
            let name = url.lastPathComponent
            var info = stat()
            guard fstat(descriptor, &info) == 0, Self.isRegularLocalCandidate(info),
                  ArchiveTree.Node(info, relative: "") == snapshot else { throw Failure.changed(name) }
            let current: OpenedFile
            do { current = try OpenedFile(url) }
            catch { throw Failure.changed(name) }
            defer { close(current.descriptor) }
            guard current.snapshot == snapshot else { throw Failure.changed(name) }
        }

        private static func isRegularLocalCandidate(_ info: stat) -> Bool {
            info.st_mode & S_IFMT == S_IFREG && info.st_flags & UInt32(SF_DATALESS) == 0
        }
    }
}
