import AndromedaCore
import Foundation

/// A portable, read-only inventory of the main file data in a selected local folder.
public struct PortableChecksumSnapshot: Sendable {
    public let data: Data
    public let fileCount: Int

    private enum Failure: LocalizedError {
        case empty

        var errorDescription: String? {
            "The selected folder contains no files to check."
        }
    }

    public static func create(
        _ folder: URL, env: ScanEnvironment, canReadProtectedPaths: Bool, control: ScanControl
    ) throws -> Self {
        try ArchiveTree.check(control)
        let maximumFiles = PortableChecksumVerification.maximumFileCount
        let selected = try ExistingCopyVerification.OpenedFolder(
            folder, control: control, maximumNodes: 2 * maximumFiles + 1
        ) { path in
            canReadProtectedPaths || !env.isPromptingPath(URL(fileURLWithPath: path, isDirectory: false))
        }
        defer { close(selected.descriptor) }

        var data = Data()
        var fileCount = 0
        for node in selected.tree.nodes where !node.folder {
            try ArchiveTree.check(control)
            guard fileCount < maximumFiles else { throw ArchiveFailure.checksumSnapshotTooLarge }
            control.entry(node.relative)
            let digest = try ArchiveTree.dataForkSHA256(of: node, under: selected.path, control: control)
            ArchiveChecksums.appendTaggedLine(relativePath: "./" + node.relative, digest: digest, to: &data)
            guard data.count <= PortableChecksumVerification.maximumManifestBytes else {
                throw ArchiveFailure.checksumSnapshotTooLarge
            }
            fileCount += 1
            control.file(bytes: node.bytes)
        }
        guard fileCount > 0 else { throw Failure.empty }
        // A fresh listing catches missing or newly added paths as well as edits to paths already hashed.
        try selected.verifyUnchanged(control: control)
        try selected.verifyRootUnchanged()
        try ArchiveTree.check(control)
        return Self(data: data, fileCount: fileCount)
    }
}
