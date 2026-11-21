import Darwin
import AndromedaCore
import Foundation
import Synchronization

/// Reuse content hashes across repeated observations of unchanged files.
public final class AutomationDuplicateFingerprints: Sendable {
    private let fingerprints = Mutex([ArchiveTree.Node: Data]())

    public init() {}

    func matches(
        source: (folder: Int32, path: String, name: String, info: stat),
        destination: (folder: Int32, path: String, name: String, info: stat)
    ) -> Bool {
        guard destination.info.st_dev == source.info.st_dev, destination.info.st_size == source.info.st_size,
              destination.info.st_mode & S_IFMT == S_IFREG, destination.info.st_flags & UInt32(SF_DATALESS) == 0 else {
            return false
        }
        let left = ArchiveTree.Node(source.info, relative: "")
        let right = ArchiveTree.Node(destination.info, relative: "")
        guard let expected = fingerprint(source.path, node: left),
              fingerprint(destination.path, node: right) == expected else { return false }
        return Self.isCurrent(left, in: source.folder, name: source.name)
            && Self.isCurrent(right, in: destination.folder, name: destination.name)
    }

    private func fingerprint(_ path: String, node: ArchiveTree.Node) -> Data? {
        if let cached = fingerprints.withLock({ $0[node] }) { return cached }
        let control = ScanControl { _ in }
        guard let tree = try? ArchiveTree(at: path, control: control), tree.nodes == [node],
              let digest = try? tree.fingerprints(at: path, control: control, includeEntries: false,
                                                  verification: .mediaSource).mediaDigest else { return nil }
        fingerprints.withLock {
            if $0.count >= 2_048 { $0.removeAll(keepingCapacity: true) }
            $0[node] = digest
        }
        return digest
    }

    private static func isCurrent(_ node: ArchiveTree.Node, in directory: Int32, name: String) -> Bool {
        var current = stat()
        return fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && ArchiveTree.Node(current, relative: "") == node
    }
}
