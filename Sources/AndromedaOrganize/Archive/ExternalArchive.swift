import DiskArbitration
import AndromedaCore
import Foundation

public struct ArchivePreview: Sendable {
    public struct Destination: Identifiable, Sendable {
        public let id: UUID
        public let drive: ExternalVolume
        public let url: URL
        fileprivate let identity: FileIdentity
    }

    public let source: URL
    public let destinations: [Destination]
    public var drive: ExternalVolume { destinations[0].drive }
    public var destination: URL { destinations[0].url }
    public var requiredBytes: Int64 { tree.requiredBytes }
    public var fileCount: Int { tree.nodes.count(where: { !$0.folder }) }
    public var mediaSourceName: String? { media?.volume.name }
    public let previousVersionID: UUID?
    fileprivate let tree: ArchiveTree
    fileprivate let media: MediaArchiveSource?
}

fileprivate struct MediaArchiveSource: Sendable {
    let volume: ExternalVolume
    let identity: FileIdentity
}

public struct ArchiveOffloadResult: Identifiable, Sendable {
    public enum Outcome: Sendable {
        case verified(ArchiveRecord)
        case failed(String)
        case needsRecovery
        case sourceChanged
        case cancelled
    }

    public let destination: ArchivePreview.Destination
    public let outcome: Outcome
    public var id: UUID { destination.id }
    public var verifiedRecord: ArchiveRecord? {
        guard case .verified(let record) = outcome else { return nil }
        return record
    }
}

public struct ArchiveRecord: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case copying, sealed, verified, releasing, inTrash, restored
    }

    public struct IntegrityCheck: Codable, Equatable, Sendable {
        public enum Outcome: String, Codable, Sendable { case matched, mismatch }

        public struct Difference: Codable, Equatable, Sendable {
            public enum Kind: String, Codable, Sendable { case changed, missing, added }

            /// An empty path identifies the archive root, including a single-file archive.
            public let relativePath: String
            public let kind: Kind
        }

        public let outcome: Outcome
        public let date: Date
        /// Older checks and archives without a known-good item fingerprint have no details.
        public let differences: [Difference]?
    }

    public let id: UUID
    public let originalPath: String
    public let name: String
    public let driveID: String
    public let driveName: String
    public let copiedAt: Date
    public let requiredBytes: Int64
    public let fileCount: Int
    public fileprivate(set) var state: State
    public fileprivate(set) var trashPath: String?
    public fileprivate(set) var trashedAt: Date?
    public fileprivate(set) var restoredPath: String?
    public fileprivate(set) var restoredAt: Date?
    public fileprivate(set) var integrityCheck: IntegrityCheck?
    public fileprivate(set) var additionalCopyOf: UUID?
    public fileprivate(set) var sourceVolumeName: String?
    public fileprivate(set) var previousVersionID: UUID?
    public fileprivate(set) var reusedFileCount: Int?
    fileprivate var offloadID: UUID?
    fileprivate var fingerprint: Data?
    fileprivate var omitsSystemProvenance: Bool?
    fileprivate var checksumsSeal: ArchiveChecksums.Seal?
    // Records written before the rename omit this key. Keep resolving their original paths.
    fileprivate var usesAndromedaNames: Bool?
    fileprivate var stagingInode: UInt64?
    fileprivate var sourceInode: UInt64?

    fileprivate var hasPublishedCopy: Bool {
        [.verified, .releasing, .inTrash, .restored].contains(state)
    }

    fileprivate var verificationDate: Date { integrityCheck?.date ?? copiedAt }
    fileprivate var fingerprintMetadata: ArchiveTree.Metadata {
        omitsSystemProvenance == true ? .archiveCopy : .strict
    }
    fileprivate var containerName: String {
        usesAndromedaNames == true ? ExternalArchive.folderName : ExternalArchive.legacyFolderName
    }
    fileprivate var checksumName: String {
        ArchiveChecksums.name(beside: name, legacy: usesAndromedaNames != true)
    }
    fileprivate var archiveSetID: UUID { offloadID ?? additionalCopyOf ?? id }
    public var hasPortableChecksums: Bool { checksumsSeal != nil }
}

public struct ArchiveFileMatch: Sendable {
    public let archive: ArchiveRecord
    public let relativePath: String
}

public struct ArchiveFileSearch: Sendable {
    public let matches: [ArchiveFileMatch]
    public let hasMore: Bool
    public let missingCatalogs: Bool
}

/// An explicitly reviewed project or media folder copied to a writable APFS drive. Records live on the Mac
/// so they remain searchable while a drive is unplugged. Nothing writes to the source during a copy.
public struct ExternalArchive: Sendable {
    public static let folderName = "Andromeda Archives"
    fileprivate static let legacyFolderName = "Diskplain Archives"
    private let env: ScanEnvironment
    private let recordsDirectory: URL
    private let trasher: any Trasher
    private let volumes: @Sendable () -> [ExternalVolume]

    public init(
        env: ScanEnvironment, recordsDirectory: URL, trasher: any Trasher,
        volumes: @escaping @Sendable () -> [ExternalVolume]
    ) {
        self.env = env
        self.recordsDirectory = recordsDirectory
        self.trasher = trasher
        self.volumes = volumes
    }

    public static func supports(_ drive: ExternalVolume) -> Bool {
        drive.kind == .drive && !drive.isReadOnly && drive.containerID != nil && UUID(uuidString: drive.id) != nil
    }

    public static func couldArchive(_ source: URL, in env: ScanEnvironment) -> Bool {
        let path = source.standardizedFileURL.path
        let home = env.home.standardizedFileURL.path
        let parts = source.standardizedFileURL.pathComponents.dropFirst(env.home.standardizedFileURL.pathComponents.count)
        let forbidden = ["library", "applications", ".trash"]
        return path.hasPrefix(home + "/")
            && parts.first.map { !forbidden.contains($0.lowercased()) && !$0.hasPrefix(".") } == true
    }

    public func preview(source: URL, driveID: String, control: ScanControl) throws -> ArchivePreview {
        try preview(source: source, driveIDs: [driveID], control: control)
    }

    public func preview(source: URL, driveIDs: [String], control: ScanControl) throws -> ArchivePreview {
        try preview(source: source, driveIDs: driveIDs, previousVersionID: nil, control: control)
    }

    public func previewNewVersion(of id: UUID, control: ScanControl) throws -> ArchivePreview {
        let previous = try load(id)
        guard previous.hasPublishedCopy, previous.sourceVolumeName == nil,
              previous.additionalCopyOf == nil, previous.fingerprint != nil else { throw ArchiveFailure.notReady }
        return try preview(source: URL(fileURLWithPath: previous.originalPath), driveIDs: [previous.driveID],
                           previousVersionID: id, control: control)
    }

    private func preview(source: URL, driveIDs: [String], previousVersionID: UUID?,
                         control: ScanControl) throws -> ArchivePreview {
        guard !driveIDs.isEmpty else { throw ArchiveFailure.notReady }
        guard Set(driveIDs.map { $0.lowercased() }).count == driveIDs.count else { throw ArchiveFailure.sameArchiveDevice }
        let available = volumes()
        let selected = source.standardizedFileURL
        let media = try mediaSource(for: selected, on: available)
        let source = try media == nil ? checkedSource(selected) : selected
        let tree = try ArchiveTree(at: source.path, control: control)
        if let media, tree.nodes.first?.identity.dev != media.identity.dev { throw ArchiveFailure.mediaUnavailable }
        let mounts = try driveIDs.map { try mount($0, on: available) }
        let sourceContainer = Self.apfsContainer(source.path)
        if mounts.count > 1 || media != nil {
            let topology = try DiskTopology(Self.diskTopology())
            var used = try topology.sourceDisks(at: source.path)
            for mount in mounts {
                let disks = try topology.wholeDisks(for: mount.volume.containerID)
                guard used.isDisjoint(with: disks) else { throw ArchiveFailure.sameArchiveDevice }
                used.formUnion(disks)
            }
        }
        let destinations = try mounts.map { mount in
            try ArchiveTree.check(control)
            try Self.checkDestination(mount, for: tree, sourceContainer: sourceContainer)
            if previousVersionID == nil { try mount.requireSpace(tree.requiredBytes) }
            try mount.checkWritableContainer()
            let id = UUID()
            return ArchivePreview.Destination(id: id, drive: mount.volume,
                                              url: mount.payload(id, name: source.lastPathComponent), identity: mount.identity)
        }
        return ArchivePreview(source: source, destinations: destinations, previousVersionID: previousVersionID,
                              tree: tree, media: media)
    }

    public func copy(_ plan: ArchivePreview, control: ScanControl) throws -> ArchiveRecord {
        try withRecordLock {
            guard plan.destinations.count == 1, let destination = plan.destinations.first else {
                throw ArchiveFailure.notReady
            }
            let source = try reviewedSource(plan)
            let mount = try reviewedMount(destination)
            try Self.checkDestination(mount, for: plan.tree, sourceContainer: Self.apfsContainer(source.path))
            if plan.media != nil {
                let topology = try DiskTopology(Self.diskTopology())
                guard try topology.sourceDisks(at: source.path).isDisjoint(with: topology.wholeDisks(for: mount.volume.containerID))
                else { throw ArchiveFailure.sameArchiveDevice }
            }
            let current = try ArchiveTree(at: source.path, control: control)
            guard current == plan.tree else { throw ArchiveFailure.changed(source.path) }
            var record = initialRecord(for: destination, source: source, plan: plan, on: mount)
            if let id = plan.previousVersionID {
                let previous = try load(id)
                guard previous.hasPublishedCopy, previous.sourceVolumeName == nil, plan.media == nil,
                      previous.originalPath == source.path, Self.sameVolumeID(previous.driveID, mount.volume.id)
                else { throw ArchiveFailure.notReady }
                let sourceFingerprint = try current.fingerprints(at: source.path, control: control, includeEntries: true,
                                                                 metadata: .archiveCopy)
                let candidates = try reusableFiles(from: previous, on: mount, matching: sourceFingerprint, control: control)
                record.previousVersionID = id
                return try publishCopy(record, tree: current, from: source, on: mount, control: control,
                                       sourceDigest: sourceFingerprint.digest, reusing: candidates)
            }
            return try publishCopy(record, tree: current, from: source, on: mount, control: control, verifyMedia: plan.media != nil) {
                if let media = plan.media { try Self.checkMedia(media, at: source) }
            }
        }
    }

    private func reusableFiles(from previous: ArchiveRecord, on mount: Mount, matching source: ArchiveTree.Fingerprint,
                               control: ScanControl) throws -> [Data: ArchiveTree.ReusableFile] {
        guard let digest = previous.fingerprint, let baseline = loadFingerprint(for: previous.id, matching: digest),
              baseline.recordsLinkRoles == true else { return [:] }
        let payload = mount.volume.url.appendingPathComponent(previous.containerName, isDirectory: true)
            .appendingPathComponent(previous.id.uuidString, isDirectory: true).appendingPathComponent(previous.name).path
        guard let tree = try? ArchiveTree(at: payload, control: control),
              tree.nodes.first?.identity.dev == mount.identity.dev else {
            try ArchiveTree.check(control)
            return [:]
        }
        var expected: [Data: Data] = [:]
        for entry in baseline.entries where entry.firstLink == nil {
            try ArchiveTree.check(control)
            expected[Data(entry.path.utf8)] = entry.digest
        }
        var unchanged: [Data: Data] = [:]
        for entry in source.entries where entry.firstLink == nil {
            try ArchiveTree.check(control)
            let key = Data(entry.path.utf8)
            if expected[key] == entry.digest { unchanged[key] = entry.digest }
        }
        var candidates: [Data: ArchiveTree.ReusableFile] = [:]
        for node in tree.nodes where !node.folder {
            try ArchiveTree.check(control)
            let key = Data(node.relative.utf8)
            if let fingerprint = unchanged[key] {
                candidates[key] = .init(node: node, path: node.under(payload), fingerprint: fingerprint)
            }
        }
        return candidates
    }

    /// Each drive gets its own publication and receipt. Only a change to the reviewed source or
    /// cancellation stops subsequent destinations. The source is hashed once for the whole offload.
    public func offload(_ plan: ArchivePreview, control: ScanControl) throws -> [ArchiveOffloadResult] {
        try withRecordLock {
            guard plan.destinations.count > 1, let first = plan.destinations.first else { throw ArchiveFailure.notReady }
            let source = try reviewedSource(plan)
            let tree = try ArchiveTree(at: source.path, control: control)
            guard tree == plan.tree else { throw ArchiveFailure.changed(source.path) }
            let sourceContainer = Self.apfsContainer(source.path)
            let digest = try Self.sourceDigest(tree, at: source.path, control: control, media: plan.media != nil)
            let listing = try Self.diskTopology()
            let topology = try DiskTopology(listing)
            var usedDisks = try topology.sourceDisks(at: source.path)
            var primary: UUID?
            var sourceChanged = false
            return plan.destinations.enumerated().map { index, destination in
                let outcome: ArchiveOffloadResult.Outcome
                if control.isCancelled {
                    outcome = .cancelled
                } else if sourceChanged {
                    outcome = .sourceChanged
                } else {
                    control.entry("Drive \(index + 1) of \(plan.destinations.count) · \(destination.drive.name)")
                    control.flush()
                    do {
                        try ArchiveTree.check(control)
                        if let media = plan.media { try Self.checkMedia(media, at: source) }
                        guard try ArchiveTree(at: source.path, control: control) == tree else {
                            throw ArchiveFailure.changed(source.path)
                        }
                        let mount = try reviewedMount(destination)
                        try Self.checkDestination(mount, for: tree, sourceContainer: sourceContainer)
                        let disks = try topology.wholeDisks(for: mount.volume.containerID)
                        guard usedDisks.isDisjoint(with: disks) else { throw ArchiveFailure.sameArchiveDevice }
                        var record = initialRecord(for: destination, source: source, plan: plan, on: mount)
                        record.offloadID = first.id
                        record.additionalCopyOf = primary
                        let verified = try publishCopy(record, tree: tree, from: source, on: mount,
                                                       control: control, sourceDigest: digest, verifyMedia: plan.media != nil) {
                            if let media = plan.media { try Self.checkMedia(media, at: source) }
                        }
                        primary = primary ?? verified.id
                        usedDisks.formUnion(disks)
                        outcome = .verified(verified)
                    } catch {
                        let saved = try? load(destination.id)
                        if let saved, saved.state == .sealed || saved.hasPublishedCopy {
                            primary = primary ?? saved.id
                            if let disks = try? topology.wholeDisks(for: destination.drive.containerID) {
                                usedDisks.formUnion(disks)
                            }
                        }
                        if saved?.state == .sealed {
                            outcome = .needsRecovery
                        } else if control.isCancelled {
                            outcome = .cancelled
                        } else if (try? reviewedSource(plan)) == nil
                                    || (try? ArchiveTree(at: source.path, control: control)) != tree {
                            sourceChanged = true
                            outcome = .sourceChanged
                        } else {
                            outcome = .failed(error.localizedDescription)
                        }
                    }
                }
                return ArchiveOffloadResult(destination: destination, outcome: outcome)
            }
        }
    }

    private func initialRecord(for destination: ArchivePreview.Destination, source: URL, plan: ArchivePreview,
                               on mount: Mount) -> ArchiveRecord {
        var record = ArchiveRecord(
            id: destination.id, originalPath: source.path, name: source.lastPathComponent,
            driveID: mount.volume.id, driveName: mount.volume.name, copiedAt: Date(),
            requiredBytes: plan.requiredBytes, fileCount: plan.fileCount, state: .copying)
        record.sourceVolumeName = plan.media?.volume.name
        if plan.media == nil { record.sourceInode = plan.tree.nodes.first.map { UInt64($0.identity.ino) } }
        return record
    }

    /// Drives with a distinct APFS container and no published copy of this archive set.
    /// Physical device separation is verified immediately before copying.
    public static func additionalCopyDestinations(
        for source: ArchiveRecord, on drives: [ExternalVolume], records: [ArchiveRecord]
    ) -> [ExternalVolume] {
        guard source.hasPublishedCopy,
              let sourceDrive = drives.first(where: { sameVolumeID($0.id, source.driveID) }),
              supports(sourceDrive) else { return [] }
        let occupied = Set(records.filter {
            $0.archiveSetID == source.archiveSetID && ($0.hasPublishedCopy || $0.state == .sealed)
        }.map { $0.driveID.lowercased() })
        return drives.filter {
            supports($0) && $0.containerID != sourceDrive.containerID
                && !sameVolumeID($0.id, sourceDrive.id) && !occupied.contains($0.id.lowercased())
        }
    }

    /// Copies a saved archive to another device, even after the local original is gone.
    public func copyToAnotherDrive(_ id: UUID, driveID: String, control: ScanControl) throws -> ArchiveRecord {
        try withRecordLock {
            try ArchiveTree.check(control)
            let sourceRecord = try load(id)
            guard sourceRecord.hasPublishedCopy, let expected = sourceRecord.fingerprint else {
                throw ArchiveFailure.notReady
            }
            let sourceMount = try mount(for: sourceRecord)
            let destination = try mount(driveID)
            guard sourceMount.identity.dev != destination.identity.dev,
                  sourceMount.volume.containerID != destination.volume.containerID else {
                throw ArchiveFailure.sameArchiveDevice
            }
            guard Self.additionalCopyDestinations(for: sourceRecord, on: [sourceMount.volume, destination.volume],
                                                  records: try records()).contains(destination.volume) else {
                throw ArchiveFailure.archiveAlreadyOnDrive
            }
            try Self.checkSeparateDevices(sourceMount, destination)
            let sourceContainer = try sourceMount.openContainer(create: false)
            defer { close(sourceContainer) }
            let source = sourceMount.payload(id, name: sourceRecord.name)
            let tree = try ArchiveTree(at: source.path, control: control)
            guard tree.nodes.first?.identity.dev == sourceMount.identity.dev else { throw ArchiveFailure.driveUnavailable }
            if sourceRecord.fingerprintMetadata == .strict,
               try tree.fingerprint(at: source.path, control: control) != expected {
                throw ArchiveFailure.verification
            }
            try destination.checkWritableContainer()
            var record = ArchiveRecord(
                id: UUID(), originalPath: sourceRecord.originalPath, name: sourceRecord.name,
                driveID: destination.volume.id, driveName: destination.volume.name, copiedAt: Date(),
                requiredBytes: tree.requiredBytes, fileCount: sourceRecord.fileCount, state: .copying)
            record.additionalCopyOf = sourceRecord.additionalCopyOf ?? sourceRecord.id
            record.offloadID = sourceRecord.offloadID
            record.sourceVolumeName = sourceRecord.sourceVolumeName
            return try publishCopy(record, tree: tree, from: source, on: destination, control: control,
                                   matching: sourceRecord.fingerprintMetadata == .archiveCopy ? expected : nil) {
                try sourceMount.check(sourceContainer)
            }
        }
    }

    private func publishCopy(
        _ pending: ArchiveRecord, tree: ArchiveTree, from source: URL, on mount: Mount, control: ScanControl,
        matching expected: Data? = nil, sourceDigest: Data? = nil, verifyMedia: Bool = false,
        reusing candidates: [Data: ArchiveTree.ReusableFile] = [:],
        checkSource: () throws -> Void = {}
    ) throws -> ArchiveRecord {
        // A version may fit through APFS clones even when a full copy would not. Any failed
        // allocation leaves this attempt unverified and the earlier version available.
        if pending.previousVersionID == nil { try mount.requireSpace(tree.requiredBytes) }
        var record = pending
        record.omitsSystemProvenance = true
        record.usesAndromedaNames = true
        try save(record, new: true)

        let container = try mount.openContainer(create: true)
        defer { close(container) }
        let stagingName = ".partial-" + record.id.uuidString
        guard mkdirat(container, stagingName, 0o700) == 0 else {
            throw ArchiveFailure.system(stagingName, errno)
        }
        let staged = mount.container.appendingPathComponent(stagingName, isDirectory: true)
        let stageIdentity = FileIdentity(path: staged.path)
        var published = false
        defer {
            // Failed copies are disposable only while the same drive and staging directory are still present.
            if !published, record.state != .sealed, (try? mount.check(container)) != nil,
               let stageIdentity, FileIdentity(path: staged.path) == stageIdentity {
                _ = try? trasher.trash(staged)
            }
        }
        guard let stageIdentity, stageIdentity.dev == mount.identity.dev else {
            throw ArchiveFailure.changed(staged.path)
        }
        let stage = openat(container, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { throw ArchiveFailure.system(staged.path, errno) }
        defer { close(stage) }
        var stageInfo = stat()
        guard fstat(stage, &stageInfo) == 0,
              FileIdentity(dev: stageInfo.st_dev, ino: stageInfo.st_ino) == stageIdentity else {
            throw ArchiveFailure.changed(staged.path)
        }
        record.stagingInode = UInt64(stageIdentity.ino)
        try save(record)

        let payload = staged.appendingPathComponent(record.name)
        let checksumPath = staged.appendingPathComponent(record.checksumName).path
        let checksums = tree.nodes.contains(where: { !$0.folder })
            ? try ArchiveChecksums.Writer(directory: stage, path: checksumPath, payload: record.name) : nil
        try mount.check(container)
        let (fingerprint, reused) = try verifiedCopy(tree, from: source.path, to: payload.path, on: mount.identity.dev,
                                                     control: control, includeEntries: true, matching: expected, sourceDigest: sourceDigest,
                                                     verifyMedia: verifyMedia, reusing: candidates) { relativePath, digest in
            try checksums?.append(relativePath: relativePath, digest: digest)
        }
        if record.previousVersionID != nil { record.reusedFileCount = reused }
        if let seal = try checksums?.finish() {
            try ArchiveChecksums.verify(seal, directory: stage, filename: record.checksumName, device: stageIdentity.dev, control: control)
            record.checksumsSeal = seal
        }
        guard fsync(stage) == 0 else { throw ArchiveFailure.system(staged.path, errno) }
        try checkSource()
        try mount.check(container)
        guard FileIdentity(path: staged.path) == stageIdentity else {
            throw ArchiveFailure.changed(staged.path)
        }
        try ArchiveTree.check(control)
        record.state = .sealed
        record.fingerprint = fingerprint.digest
        try save(record)
        saveFingerprint(fingerprint, for: record.id)
        try Self.publish(from: stagingName, to: record.id.uuidString, directory: container)
        published = true
        try mount.check(container)
        guard fsync(container) == 0 else { throw ArchiveFailure.system(mount.container.path, errno) }
        record.state = .verified
        try save(record)
        saveFileCatalog(tree, for: record.id)
        return record
    }

    /// Recovers a verified payload published just before an interruption. Partial copies stay ineligible.
    public func recover(_ id: UUID, control: ScanControl) throws -> ArchiveRecord {
        try withRecordLock {
            var record = try load(id)
            guard record.state == .sealed else { throw ArchiveFailure.notReady }
            let mount = try mount(for: record)
            let container = try mount.openContainer(create: false)
            defer { close(container) }
            var info = stat()
            let tree: ArchiveTree
            if fstatat(container, record.id.uuidString, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                tree = try verifiedArchive(record, mount: mount, control: control)
                try verifyChecksums(record, in: record.id.uuidString, container: container, mount: mount, control: control)
            } else {
                guard errno == ENOENT else { throw ArchiveFailure.system(record.name, errno) }
                let stagedName = ".partial-" + record.id.uuidString
                let staged = mount.container.appendingPathComponent(stagedName, isDirectory: true)
                var expected = [record.name]
                if record.hasPortableChecksums { expected.append(record.checksumName) }
                guard let inode = record.stagingInode,
                      FileIdentity(path: staged.path) == FileIdentity(dev: mount.identity.dev, ino: ino_t(inode)),
                      Set(try FileManager.default.contentsOfDirectory(atPath: staged.path)) == Set(expected)
                else { throw ArchiveFailure.notReady }
                tree = try verifiedPayload(record, at: staged.appendingPathComponent(record.name), mount: mount, control: control)
                try verifyChecksums(record, in: stagedName, container: container, mount: mount, control: control)
                try mount.check(container)
                try ArchiveTree.check(control)
                try Self.publish(from: stagedName, to: record.id.uuidString, directory: container)
                guard fsync(container) == 0 else { throw ArchiveFailure.system(mount.container.path, errno) }
            }
            record.state = .verified
            try save(record)
            saveFileCatalog(tree, for: record.id)
            return record
        }
    }

    /// Called only after a separate user confirmation. Rechecks both copies against the sealed digest.
    public func trashOriginal(_ id: UUID, control: ScanControl) throws -> ArchiveRecord {
        try withRecordLock {
            var record = try load(id)
            guard record.state == .verified, record.additionalCopyOf == nil, record.sourceVolumeName == nil else {
                throw ArchiveFailure.notReady
            }
            let mount = try mount(for: record)
            let archive = try verifiedArchive(record, mount: mount, control: control)
            let original = try checkedSource(URL(fileURLWithPath: record.originalPath))
            let tree = try ArchiveTree(at: original.path, control: control)
            guard tree.nodes.first.map({ UInt64($0.identity.ino) }) == record.sourceInode,
                  try tree.fingerprint(at: original.path, control: control,
                                       metadata: record.fingerprintMetadata) == record.fingerprint else {
                throw ArchiveFailure.changed(original.path)
            }
            try mount.check()
            guard try ArchiveTree(at: original.path, control: control) == tree,
                  try ArchiveTree(at: mount.payload(record.id, name: record.name).path, control: control) == archive else {
                throw ArchiveFailure.changed(original.path)
            }
            try ArchiveTree.check(control)
            record.state = .releasing
            try save(record)
            let trashed: URL
            do {
                trashed = try trasher.trash(original)
            } catch {
                // An OS handoff can report an error after moving the item. Preserve an interrupted
                // receipt unless the original is still where we reviewed it.
                if let first = tree.nodes.first, FileIdentity(path: original.path) == first.identity {
                    record.state = .verified
                    try save(record)
                }
                throw error
            }
            record.trashPath = trashed.path
            record.trashedAt = Date()
            record.state = .inTrash
            try save(record)
            return record
        }
    }

    /// Restores another verified copy to the original path, leaving the archive available.
    public func restore(_ id: UUID, into folder: URL? = nil, control: ScanControl) throws -> ArchiveRecord {
        try withRecordLock {
            var record = try load(id)
            guard record.hasPublishedCopy else { throw ArchiveFailure.notReady }
            guard record.sourceVolumeName == nil || folder != nil else { throw ArchiveFailure.mediaRestoreDestination }
            let mount = try mount(for: record)
            let source = mount.payload(record.id, name: record.name)
            let tree = try verifiedArchive(record, mount: mount, control: control)
            let parent = folder ?? URL(fileURLWithPath: record.originalPath).deletingLastPathComponent()
            let destination = try restoreCopy(named: record.name, into: parent, tree: tree, mount: mount, control: control) {
                payload, device in
                let expected = record.fingerprintMetadata == .archiveCopy ? record.fingerprint : nil
                _ = try verifiedCopy(tree, from: source.path, to: payload, on: device, control: control, matching: expected)
            }
            record.restoredPath = destination.path
            record.restoredAt = Date()
            record.state = .restored
            try save(record)
            return record
        }
    }

    /// Restores just the selected file, checking it against the saved archive verification.
    public func restoreFile(_ match: ArchiveFileMatch, into folder: URL, control: ScanControl) throws -> URL {
        try withRecordLock {
            try ArchiveTree.check(control)
            let record = try load(match.archive.id)
            guard record.hasPublishedCopy, let expected = record.fingerprint else { throw ArchiveFailure.notReady }
            let mount = try mount(for: record)
            let source = try archivedFileURL(relativePath: match.relativePath, record: record, mount: mount)
            guard let baseline = loadFingerprint(for: record.id, matching: expected),
                  let entry = baseline.entries.first(where: { $0.path.utf8.elementsEqual(match.relativePath.utf8) }) else {
                throw ArchiveFailure.missingFileVerification
            }
            let tree = try ArchiveTree(at: source.path, control: control)
            guard let node = tree.nodes.first, !node.folder, node.identity.dev == mount.identity.dev else {
                throw ArchiveFailure.changed(source.path)
            }
            guard let basename = match.relativePath.utf8.split(separator: UInt8(ascii: "/")).last else {
                throw ArchiveFailure.notReady
            }
            let name = String(decoding: basename, as: UTF8.self)
            return try restoreCopy(named: name, into: folder, tree: tree, mount: mount, control: control) {
                payload, device in
                let firstLink = try verifiedLink(for: entry, legacy: baseline.recordsLinkRoles != true,
                                                 at: source.path, tree: tree, record: record,
                                                 mount: mount, control: control)
                let copyDigest = try record.fingerprintMetadata == .archiveCopy ? entry.digest
                    : tree.fileFingerprint(at: source.path, relative: entry.path, firstLink: firstLink,
                                           control: control, metadata: .archiveCopy)
                try tree.copy(from: source.path, to: payload, device: device, control: control)
                let staged = try ArchiveTree(at: payload, control: control)
                guard staged.nodes.first?.identity.dev == device,
                      try staged.fileFingerprint(at: payload, relative: entry.path, firstLink: firstLink,
                                                 control: control, metadata: .archiveCopy) == copyDigest else {
                    throw ArchiveFailure.verification
                }
                guard try ArchiveTree(at: source.path, control: control) == tree,
                      try ArchiveTree(at: payload, control: control) == staged else {
                    throw ArchiveFailure.changed(source.path)
                }
            }
        }
    }

    private func verifiedLink(
        for entry: ArchiveTree.Fingerprint.Entry, legacy: Bool, at source: String, tree: ArchiveTree, record: ArchiveRecord,
        mount: Mount, control: ScanControl
    ) throws -> String {
        let firstLink = entry.firstLink ?? entry.path
        if try tree.fileFingerprint(at: source, relative: entry.path, firstLink: firstLink,
                                    control: control, metadata: record.fingerprintMetadata) == entry.digest {
            return firstLink
        }
        // Old manifests recorded the digest but not which path first named a shared inode.
        if legacy {
            let archive: ArchiveTree
            do {
                archive = try verifiedArchive(record, mount: mount, control: control)
            } catch ArchiveFailure.verification {
                throw ArchiveFailure.archivedFileMismatch
            }
            if let first = archive.nodes.first(where: { $0.identity == tree.nodes.first?.identity }),
               try tree.fileFingerprint(at: source, relative: entry.path, firstLink: first.relative,
                                        control: control, metadata: record.fingerprintMetadata) == entry.digest {
                return first.relative
            }
        }
        throw ArchiveFailure.archivedFileMismatch
    }

    private func restoreCopy(
        named name: String, into parent: URL, tree: ArchiveTree, mount: Mount, control: ScanControl,
        verifyCopy: (String, dev_t) throws -> Void
    ) throws -> URL {
        let destination = try checkedSource(parent.appendingPathComponent(name), allowMissing: true)
        let parentPath = destination.deletingLastPathComponent().path
        let directory = ArchiveTree.openDirectory(parentPath)
        guard directory >= 0 else { throw ArchiveFailure.system(parent.path, errno) }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_dev != mount.identity.dev else { throw ArchiveFailure.notReady }
        let parentIdentity = FileIdentity(dev: info.st_dev, ino: info.st_ino)
        var occupied = stat()
        guard fstatat(directory, name, &occupied, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw ArchiveFailure.occupied
        }
        try Self.requireSpace(tree.requiredBytes, on: directory)
        let stage = ".andromeda-restore-" + UUID().uuidString
        let stagedPath = parentPath + "/" + stage
        // A private wrapper reserves a name before writing, for both file and folder restores.
        guard mkdirat(directory, stage, 0o700) == 0 else { throw ArchiveFailure.system(stagedPath, errno) }
        let stagedDirectory = openat(directory, stage, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stagedDirectory >= 0 else { throw ArchiveFailure.system(stagedPath, errno) }
        defer { close(stagedDirectory) }
        var stagedInfo = stat()
        guard fstat(stagedDirectory, &stagedInfo) == 0 else { throw ArchiveFailure.system(stagedPath, errno) }
        let identity = FileIdentity(dev: stagedInfo.st_dev, ino: stagedInfo.st_ino)
        defer {
            if tree.nodes.first?.folder == false { _ = unlinkat(stagedDirectory, name, 0) }
            var remaining = stat()
            if fstatat(directory, stage, &remaining, AT_SYMLINK_NOFOLLOW) == 0,
               FileIdentity(dev: remaining.st_dev, ino: remaining.st_ino) == identity,
               unlinkat(directory, stage, AT_REMOVEDIR) != 0,
               FileIdentity(path: stagedPath) == identity {
                _ = try? trasher.trash(URL(fileURLWithPath: stagedPath, isDirectory: true))
            }
        }
        guard FileIdentity(path: stagedPath) == identity else { throw ArchiveFailure.changed(stagedPath) }
        try verifyCopy(stagedPath + "/" + name, info.st_dev)
        guard FileIdentity(path: stagedPath) == identity else {
            throw ArchiveFailure.changed(stagedPath)
        }
        try ArchiveTree.check(control)
        try mount.check()
        let currentParent = ArchiveTree.openDirectory(parentPath)
        guard currentParent >= 0 else { throw ArchiveFailure.changed(parentPath) }
        defer { close(currentParent) }
        var currentInfo = stat()
        guard fstat(currentParent, &currentInfo) == 0,
              FileIdentity(dev: currentInfo.st_dev, ino: currentInfo.st_ino) == parentIdentity else {
            throw ArchiveFailure.changed(parentPath)
        }
        if renameatx_np(stagedDirectory, name, directory, name, UInt32(RENAME_EXCL)) != 0 {
            throw errno == EEXIST ? ArchiveFailure.occupied : ArchiveFailure.system(destination.path, errno)
        }
        return URL(fileURLWithPath: parentPath + "/" + name)
    }

    public func records() throws -> [ArchiveRecord] {
        var info = stat()
        if lstat(recordsDirectory.path, &info) != 0, errno == ENOENT { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: recordsDirectory.path)
            .compactMap { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            .compactMap(UUID.init(uuidString:))
            .map(load)
            .sorted { $0.copiedAt > $1.copiedAt }
    }

    /// Compares a published archive with its saved fingerprint without changing either copy.
    public func checkIntegrity(_ id: UUID, control: ScanControl) throws -> ArchiveRecord {
        try withRecordLock {
            try checkIntegrity(load(id), control: control)
        }
    }

    /// Selects only published copies on connected drives, with the oldest verification first.
    public func dueIntegrityChecks(on driveIDs: Set<String>, through date: Date) throws -> [ArchiveRecord] {
        try records().filter {
            $0.hasPublishedCopy && $0.fingerprint != nil && driveIDs.contains($0.driveID) && $0.verificationDate <= date
        }.sorted { $0.verificationDate < $1.verificationDate }
    }

    /// The archive may have been checked manually since the automatic queue was assembled.
    @discardableResult
    public func checkIntegrityIfDue(_ id: UUID, through date: Date, control: ScanControl) throws -> ArchiveRecord? {
        try withRecordLock {
            let record = try load(id)
            guard record.hasPublishedCopy, record.fingerprint != nil, record.verificationDate <= date else { return nil }
            return try checkIntegrity(record, control: control)
        }
    }

    private func checkIntegrity(_ savedRecord: ArchiveRecord, control: ScanControl) throws -> ArchiveRecord {
        var record = savedRecord
        guard record.hasPublishedCopy, let expected = record.fingerprint else { throw ArchiveFailure.notReady }
        try ArchiveTree.check(control)
        let mount = try mount(for: record)
        let container = try mount.openContainer(create: false)
        defer { close(container) }
        let path = mount.payload(record.id, name: record.name).path
        let tree = try ArchiveTree(at: path, control: control)
        guard tree.nodes.first?.identity.dev == mount.identity.dev else { throw ArchiveFailure.driveUnavailable }
        let actual = try tree.fingerprints(at: path, control: control, reportProgress: true, includeEntries: true,
                                           metadata: record.fingerprintMetadata)
        let baseline = loadFingerprint(for: record.id, matching: expected)
        let matches = actual.digest == expected
        let differences = matches ? nil : try baseline.flatMap { try Self.differences(from: $0, to: actual, control: control) }
        guard try ArchiveTree(at: path, control: control) == tree else { throw ArchiveFailure.changed(path) }
        try mount.check(container)
        try ArchiveTree.check(control)
        record.integrityCheck = .init(outcome: matches ? .matched : .mismatch, date: Date(), differences: differences)
        try save(record)
        if matches {
            if baseline?.recordsLinkRoles != true { saveFingerprint(actual, for: record.id) }
            saveFileCatalog(tree, for: record.id)
        }
        return record
    }

    private static func differences(
        from baseline: ArchiveTree.Fingerprint, to current: ArchiveTree.Fingerprint, control: ScanControl
    ) throws -> [ArchiveRecord.IntegrityCheck.Difference]? {
        var previous: [Data: ArchiveTree.Fingerprint.Entry] = [:]
        previous.reserveCapacity(baseline.entries.count)
        for entry in baseline.entries {
            try ArchiveTree.check(control)
            // Paths are hashed as exact UTF-8 bytes. Swift String equality normalizes Unicode.
            guard previous.updateValue(entry, forKey: Data(entry.path.utf8)) == nil else { return nil }
        }
        var differences: [ArchiveRecord.IntegrityCheck.Difference] = []
        for entry in current.entries {
            try ArchiveTree.check(control)
            if let earlier = previous.removeValue(forKey: Data(entry.path.utf8)) {
                if earlier.digest != entry.digest { differences.append(.init(relativePath: entry.path, kind: .changed)) }
            } else {
                differences.append(.init(relativePath: entry.path, kind: .added))
            }
        }
        differences.append(contentsOf: previous.values.map { .init(relativePath: $0.path, kind: .missing) })
        return differences.isEmpty ? nil : differences.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
    }

    /// Searches the relative file paths recorded at verification, including while the drive is absent.
    public func searchFiles(_ query: String, control: ScanControl) throws -> ArchiveFileSearch {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .init(matches: [], hasMore: false, missingCatalogs: false) }
        try ArchiveTree.check(control)
        var matches: [ArchiveFileMatch] = []
        var missingCatalogs = false
        let limit = 100
        for record in try records() where record.hasPublishedCopy {
            try ArchiveTree.check(control)
            guard let data = try? Data(contentsOf: fileCatalogURL(record.id)),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else {
                missingCatalogs = true
                continue
            }
            for path in paths {
                try ArchiveTree.check(control)
                guard path.localizedStandardContains(term) else { continue }
                if matches.count == limit {
                    return .init(matches: matches, hasMore: true, missingCatalogs: missingCatalogs)
                }
                matches.append(.init(archive: record, relativePath: path))
            }
        }
        return .init(matches: matches, hasMore: false, missingCatalogs: missingCatalogs)
    }

    /// Resolves a recorded path on the current mount and verifies that it still names a local regular file.
    public func archivedFileURL(_ match: ArchiveFileMatch) throws -> URL {
        let record = try load(match.archive.id)
        guard record.hasPublishedCopy else { throw ArchiveFailure.notReady }
        return try archivedFileURL(relativePath: match.relativePath, record: record, mount: mount(for: record))
    }

    private func archivedFileURL(relativePath: String, record: ArchiveRecord, mount: Mount) throws -> URL {
        let components = relativePath.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ part in
            let name = String(decoding: part, as: UTF8.self)
            return !name.isEmpty && name != "." && name != ".." && !part.contains(0)
        }) else {
            throw ArchiveFailure.notReady
        }
        let container = try mount.openContainer(create: false)
        defer { close(container) }
        let root = mount.payload(record.id, name: record.name)
        let path = root.path + "/" + relativePath
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_dev == mount.identity.dev else {
            throw ArchiveFailure.changed(path)
        }
        let fd = open(ArchiveTree.systemPath(path), O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveFailure.system(path, errno) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { throw ArchiveFailure.changed(path) }
        try mount.check(container)
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    /// A read-only Finder handoff bound to the recorded UUID, including after a remount under a new name.
    public func archiveURL(_ record: ArchiveRecord, on drive: ExternalVolume) -> URL? {
        guard drive.id == record.driveID, record.hasPublishedCopy
        else { return nil }
        return drive.url.appendingPathComponent(record.containerName, isDirectory: true)
            .appendingPathComponent(record.id.uuidString, isDirectory: true).appendingPathComponent(record.name)
    }

    public func archivedChecksumsURL(_ id: UUID, control: ScanControl) throws -> URL {
        let record = try load(id)
        guard record.hasPublishedCopy, record.hasPortableChecksums else { throw ArchiveFailure.notReady }
        let mount = try mount(for: record)
        let container = try mount.openContainer(create: false)
        defer { close(container) }
        let wrapper = record.id.uuidString
        try verifyChecksums(record, in: wrapper, container: container, mount: mount, control: control)
        return mount.container.appendingPathComponent(wrapper, isDirectory: true)
            .appendingPathComponent(record.checksumName)
    }

    private func verifyChecksums(
        _ record: ArchiveRecord, in wrapper: String, container: Int32, mount: Mount, control: ScanControl
    ) throws {
        guard let seal = record.checksumsSeal else { return }
        let directory = openat(container, wrapper, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ArchiveFailure.portableChecksumsMismatch }
        defer { close(directory) }
        var before = stat()
        guard fstat(directory, &before) == 0, before.st_dev == mount.identity.dev else {
            throw ArchiveFailure.portableChecksumsMismatch
        }
        try ArchiveChecksums.verify(seal, directory: directory, filename: record.checksumName, device: before.st_dev, control: control)
        var current = stat()
        guard fstatat(container, wrapper, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == before.st_dev, current.st_ino == before.st_ino else {
            throw ArchiveFailure.portableChecksumsMismatch
        }
        try mount.check(container)
    }

    private func mediaSource(for selected: URL, on available: [ExternalVolume]) throws -> MediaArchiveSource? {
        let path = ArchiveTree.systemPath(selected.path)
        let matching = available.filter { volume in
            let root = ArchiveTree.systemPath(volume.url.standardizedFileURL.path)
            return path == root || path.hasPrefix(root + "/")
        }.max { $0.url.path.count < $1.url.path.count }
        guard let volume = matching else { return nil }
        let root = ArchiveTree.systemPath(volume.url.standardizedFileURL.path)
        let first = path.dropFirst(root.count).split(separator: "/").first
        guard volume.kind == .drive, UUID(uuidString: volume.id) != nil,
              first?.hasPrefix(".") != true, first?.caseInsensitiveCompare(Self.folderName) != .orderedSame,
              first?.caseInsensitiveCompare(Self.legacyFolderName) != .orderedSame,
              !VolumeDiscovery.isTimeMachineDestination(volume),
              let identity = FileIdentity(path: root) else { throw ArchiveFailure.unsupportedSource(selected.path) }
        let source = MediaArchiveSource(volume: volume, identity: identity)
        try Self.checkMedia(source, at: selected)
        return source
    }

    private func reviewedSource(_ plan: ArchivePreview) throws -> URL {
        guard let media = plan.media else { return try checkedSource(plan.source) }
        try Self.checkMedia(media, at: plan.source)
        return plan.source
    }

    private static func checkMedia(_ source: MediaArchiveSource, at selected: URL) throws {
        let root = URL(fileURLWithPath: source.volume.url.path, isDirectory: true)
        let fd = ArchiveTree.openDirectory(root.path)
        guard fd >= 0 else { throw ArchiveFailure.mediaUnavailable }
        defer { close(fd) }
        var rootInfo = stat()
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeUUIDStringKey]
        guard fstat(fd, &rootInfo) == 0,
              FileIdentity(dev: rootInfo.st_dev, ino: rootInfo.st_ino) == source.identity,
              let values = try? root.resourceValues(forKeys: keys), values.volumeIsLocal == true,
              values.volumeUUIDString.map({ sameVolumeID($0, source.volume.id) }) == true else {
            throw ArchiveFailure.mediaUnavailable
        }
        let folder = ArchiveTree.openDirectory(selected.path)
        guard folder >= 0 else { throw ArchiveFailure.unsupportedSource(selected.path) }
        defer { close(folder) }
        var folderInfo = stat()
        guard fstat(folder, &folderInfo) == 0, folderInfo.st_dev == source.identity.dev else {
            throw ArchiveFailure.unsupportedSource(selected.path)
        }
    }

    private func checkedSource(_ input: URL, allowMissing: Bool = false) throws -> URL {
        let source = input.standardizedFileURL
        guard Self.couldArchive(source, in: env) else { throw ArchiveFailure.unsupportedSource(source.path) }
        let home = env.home.resolvingSymlinksInPath().standardizedFileURL
        let tail = source.pathComponents.dropFirst(env.home.standardizedFileURL.pathComponents.count)
        let canonical = tail.reduce(home) { $0.appendingPathComponent($1) }
        let cloud = CloudRootLocator.roots(env: env).map(\.url)
        let exclusions = cloud.map { $0.standardizedFileURL.path }
        let path = source.path
        guard !exclusions.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }),
              !(try Self.isICloudPath(canonical, in: home, allowMissing: allowMissing))
        else { throw ArchiveFailure.unsupportedSource(path) }
        let validation = allowMissing ? canonical.deletingLastPathComponent() : canonical
        guard validation.resolvingSymlinksInPath().path == validation.path,
              let device = FileIdentity(path: home.path)?.dev, FileIdentity(path: validation.path)?.dev == device else {
            throw ArchiveFailure.unsupportedSource(path)
        }
        // Top-level app libraries are managed by their apps. Regular project folders are supported.
        if !allowMissing, let exclusion = OrganizeGuard.exclusion(for: source, env: env, cloudRoots: cloud),
           case .appLibrary = exclusion { throw ArchiveFailure.unsupportedSource(path) }
        return canonical
    }

    private static func isICloudPath(_ url: URL, in home: URL, allowMissing: Bool) throws -> Bool {
        let item = allowMissing ? url.deletingLastPathComponent() : url
        if try item.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true { return true }
        guard url.pathComponents.count > home.pathComponents.count else { return false }
        let first = url.pathComponents[home.pathComponents.count]
        guard ["desktop", "documents"].contains(first.lowercased()) else { return false }
        return try home.appendingPathComponent(first, isDirectory: true)
            .resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true
    }

    private func verifiedArchive(_ record: ArchiveRecord, mount: Mount, control: ScanControl) throws -> ArchiveTree {
        let container = try mount.openContainer(create: false)
        defer { close(container) }
        let tree = try verifiedPayload(record, at: mount.payload(record.id, name: record.name), mount: mount, control: control)
        try mount.check(container)
        return tree
    }

    private func verifiedPayload(
        _ record: ArchiveRecord, at url: URL, mount: Mount, control: ScanControl
    ) throws -> ArchiveTree {
        guard let expected = record.fingerprint else { throw ArchiveFailure.notReady }
        let tree = try ArchiveTree(at: url.path, control: control)
        guard tree.nodes.first?.identity.dev == mount.identity.dev,
              try tree.fingerprint(at: url.path, control: control,
                                   metadata: record.fingerprintMetadata) == expected else { throw ArchiveFailure.verification }
        return tree
    }

    private func verifiedCopy(
        _ tree: ArchiveTree, from source: String, to destination: String, on device: dev_t, control: ScanControl,
        includeEntries: Bool = false, matching expected: Data? = nil, sourceDigest knownDigest: Data? = nil,
        verifyMedia: Bool = false, reusing candidates: [Data: ArchiveTree.ReusableFile] = [:],
        onFileDigest: ((String, Data) throws -> Void)? = nil
    ) throws -> (ArchiveTree.Fingerprint, Int) {
        let sourceDigest = try knownDigest ?? Self.sourceDigest(tree, at: source, control: control, media: verifyMedia)
        if let expected, sourceDigest != expected { throw ArchiveFailure.verification }
        let reused = try tree.copy(from: source, to: destination, device: device, control: control, metadata: .archiveCopy,
                                   reusing: candidates)
        guard try ArchiveTree(at: source, control: control) == tree else { throw ArchiveFailure.changed(source) }
        let copy = try ArchiveTree(at: destination, control: control)
        guard copy.nodes.first?.identity.dev == device else { throw ArchiveFailure.verification }
        let actual = try copy.fingerprints(at: destination, control: control, includeEntries: includeEntries,
                                           verification: verifyMedia ? .mediaDestination : .archive,
                                           metadata: .archiveCopy, onFileDigest: onFileDigest)
        guard (verifyMedia ? actual.mediaDigest : actual.digest) == sourceDigest else { throw ArchiveFailure.verification }
        guard try ArchiveTree(at: source, control: control) == tree,
              try ArchiveTree(at: destination, control: control) == copy else { throw ArchiveFailure.changed(source) }
        return (actual, reused)
    }

    private static func sourceDigest(_ tree: ArchiveTree, at path: String, control: ScanControl, media: Bool) throws -> Data {
        if !media { return try tree.fingerprint(at: path, control: control, metadata: .archiveCopy) }
        let fingerprint = try tree.fingerprints(at: path, control: control, includeEntries: false, verification: .mediaSource)
        guard let digest = fingerprint.mediaDigest else { throw ArchiveFailure.verification }
        return digest
    }

    private func mount(for record: ArchiveRecord) throws -> Mount {
        try mount(record.driveID, folderName: record.containerName)
    }

    private func mount(_ id: String, on available: [ExternalVolume]? = nil, folderName: String = Self.folderName) throws -> Mount {
        guard let volume = (available ?? volumes()).first(where: { Self.sameVolumeID($0.id, id) }), Self.supports(volume) else {
            throw ArchiveFailure.driveUnavailable
        }
        let mount = try Mount(volume, folderName: folderName)
        guard !VolumeDiscovery.isTimeMachineDestination(volume) else { throw ArchiveFailure.driveUnavailable }
        return mount
    }

    private func reviewedMount(_ destination: ArchivePreview.Destination) throws -> Mount {
        let mount = try mount(destination.drive.id)
        guard mount.volume.url.path == destination.drive.url.path, mount.identity == destination.identity,
              mount.volume.containerID == destination.drive.containerID else {
            throw ArchiveFailure.driveUnavailable
        }
        return mount
    }

    private static func checkDestination(_ mount: Mount, for tree: ArchiveTree, sourceContainer: String?) throws {
        guard let root = tree.nodes.first, root.identity.dev != mount.identity.dev,
              sourceContainer != mount.volume.containerID else { throw ArchiveFailure.driveUnavailable }
    }

    private static func sameVolumeID(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func checkSeparateDevices(_ source: Mount, _ destination: Mount) throws {
        try checkSeparateDevices([source.volume.containerID, destination.volume.containerID], listing: diskTopology())
        try source.check()
        try destination.check()
    }

    private static func diskTopology(shouldContinue: (() -> Bool)? = nil) throws -> Data {
        let listing = try? LiveToolRunner().run(URL(fileURLWithPath: "/usr/sbin/diskutil"), ["apfs", "list", "-plist"],
                                                shouldContinue: shouldContinue)
        guard let listing, listing.exitCode == 0 else { throw ArchiveFailure.archiveDiskTopologyUnavailable }
        return Data(listing.stdout.utf8)
    }

    static func isDiskImage(_ path: String) -> Bool? {
        guard let device = mountedFileSystem(path)?.device, device.hasPrefix("/dev/disk"),
              let session = DASessionCreate(kCFAllocatorDefault),
              let disk = device.withCString({ DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        let model = (description[kDADiskDescriptionDeviceModelKey as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transport = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        guard model != nil || transport != nil else { return nil }
        return model?.caseInsensitiveCompare("Disk Image") == .orderedSame
            || transport?.caseInsensitiveCompare("File") == .orderedSame
    }

    /// Only use whole drives explicitly reported as physical. Disk images and unknown mappings
    /// cannot establish that user-selected files are backed by separate hardware.
    static func physicalDrives(for paths: [String], control: ScanControl) -> [Set<String>]? {
        struct PhysicalListing: Decodable { let WholeDisks: [String] }
        let diskutil = URL(fileURLWithPath: "/usr/sbin/diskutil")
        let deadline = ContinuousClock.now + .seconds(8)
        let shouldContinue = { !control.isCancelled && ContinuousClock.now < deadline }
        guard shouldContinue(),
              let listing = try? LiveToolRunner().run(diskutil, ["list", "-plist", "physical"], shouldContinue: shouldContinue),
              listing.exitCode == 0,
              let physical = try? PropertyListDecoder().decode(PhysicalListing.self, from: Data(listing.stdout.utf8)),
              shouldContinue(), let topologyData = try? diskTopology(shouldContinue: shouldContinue),
              let topology = try? DiskTopology(topologyData) else { return nil }
        let whole = Set(physical.WholeDisks)
        let drives = paths.compactMap { try? topology.sourceDisks(at: $0) }
        return drives.count == paths.count && drives.allSatisfy { !$0.isEmpty && $0.isSubset(of: whole) } ? drives : nil
    }

    static func checkSeparateDevices(_ sourceID: String, _ destinationID: String, listing: Data) throws {
        try checkSeparateDevices([sourceID, destinationID], listing: listing)
    }

    static func checkSeparateDevices(_ containerIDs: [String?], listing: Data) throws {
        let topology = try DiskTopology(listing)
        var used: Set<String> = []
        for containerID in containerIDs {
            let disks = try topology.wholeDisks(for: containerID)
            guard used.isDisjoint(with: disks) else { throw ArchiveFailure.sameArchiveDevice }
            used.formUnion(disks)
        }
    }

    private struct DiskTopology {
        private struct Listing: Decodable {
            struct Container: Decodable {
                struct Store: Decodable { let DeviceIdentifier: String }
                let ContainerReference: String
                let PhysicalStores: [Store]
            }
            let Containers: [Container]
        }

        private let listing: Listing

        init(_ data: Data) throws {
            guard let listing = try? PropertyListDecoder().decode(Listing.self, from: data) else {
                throw ArchiveFailure.archiveDiskTopologyUnavailable
            }
            self.listing = listing
        }

        func wholeDisks(for containerID: String?) throws -> Set<String> {
            guard let containerID,
                  let stores = listing.Containers.first(where: { $0.ContainerReference == containerID })?.PhysicalStores,
                  !stores.isEmpty else { throw ArchiveFailure.archiveDiskTopologyUnavailable }
            let ids = stores.compactMap { $0.DeviceIdentifier.wholeMatch(of: /(disk\d+)(?:s\d+)*/).map { String($0.1) } }
            guard ids.count == stores.count else { throw ArchiveFailure.archiveDiskTopologyUnavailable }
            return Set(ids)
        }

        func sourceDisks(at path: String) throws -> Set<String> {
            guard let fs = mountedFileSystem(path) else { throw ArchiveFailure.archiveDiskTopologyUnavailable }
            if fs.format == "apfs" { return try wholeDisks(for: apfsContainer(path)) }
            guard let disk = fs.device.wholeMatch(of: /\/dev\/(disk\d+)(?:s\d+)*/).map({ String($0.1) }) else {
                throw ArchiveFailure.archiveDiskTopologyUnavailable
            }
            return [disk]
        }
    }

    private static func mountedFileSystem(_ path: String) -> (format: String, device: String)? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let format = withUnsafeBytes(of: fs.f_fstypename) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        let device = withUnsafeBytes(of: fs.f_mntfromname) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (format, device)
    }

    private static func apfsContainer(_ path: String) -> String? {
        guard let fs = mountedFileSystem(path), fs.format == "apfs" else { return nil }
        return fs.device.wholeMatch(of: /\/dev\/(disk\d+)s\d+/).map { String($0.1) }
    }

    private static func requireSpace(_ bytes: Int64, on fd: Int32) throws {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { throw ArchiveFailure.driveUnavailable }
        guard fs.f_bsize > 0, UInt64(bytes) / UInt64(fs.f_bsize) < fs.f_bavail else {
            throw ArchiveFailure.insufficientSpace
        }
    }

    private static func publish(from: String, to: String, directory: Int32) throws {
        if renameatx_np(directory, from, directory, to, UInt32(RENAME_EXCL)) != 0 {
            throw errno == EEXIST ? ArchiveFailure.occupied : ArchiveFailure.system(to, errno)
        }
    }

    private func withRecordLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
        let lockPath = recordsDirectory.appendingPathComponent(".lock").path
        let fd = open(lockPath, O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ArchiveFailure.system(lockPath, errno) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ArchiveFailure.notReady }
        return try body()
    }

    private func recordURL(_ id: UUID) -> URL {
        recordsDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func fileCatalogURL(_ id: UUID) -> URL {
        recordsDirectory.appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func fingerprintURL(_ id: UUID) -> URL {
        recordsDirectory.appendingPathComponent("fingerprints-v1", isDirectory: true)
            .appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func loadFingerprint(for id: UUID, matching digest: Data) -> ArchiveTree.Fingerprint? {
        guard let data = try? Data(contentsOf: fingerprintURL(id)),
              let fingerprint = try? JSONDecoder().decode(ArchiveTree.Fingerprint.self, from: data),
              fingerprint.digest == digest, !fingerprint.entries.isEmpty else { return nil }
        return fingerprint
    }

    private func saveFingerprint(_ fingerprint: ArchiveTree.Fingerprint, for id: UUID) {
        // A successful recheck can rebuild this baseline if local storage was unavailable.
        try? saveSidecar(fingerprint, at: fingerprintURL(id))
    }

    /// The archive remains usable if local catalog storage fails. A later successful integrity check can add it.
    private func saveFileCatalog(_ tree: ArchiveTree, for id: UUID) {
        let paths = tree.nodes.compactMap { !$0.folder && !$0.relative.isEmpty ? $0.relative : nil }
        try? saveSidecar(paths, at: fileCatalogURL(id))
    }

    private func saveSidecar(_ value: some Encodable, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func save(_ record: ArchiveRecord, new: Bool = false) throws {
        let url = recordURL(record.id)
        if new, FileManager.default.fileExists(atPath: url.path) { throw ArchiveFailure.occupied }
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    private func load(_ id: UUID) throws -> ArchiveRecord {
        let record = try JSONDecoder().decode(ArchiveRecord.self, from: Data(contentsOf: recordURL(id)))
        guard record.id == id, !record.name.isEmpty, !record.name.contains("/"),
              record.name != ".", record.name != ".." else { throw ArchiveFailure.notReady }
        return record
    }
}

private extension ExternalArchive {
    struct Mount {
        let volume: ExternalVolume
        let identity: FileIdentity
        private let folderName: String

        init(_ volume: ExternalVolume, folderName: String) throws {
            guard let identity = FileIdentity(path: volume.url.path) else { throw ArchiveFailure.driveUnavailable }
            self.volume = volume
            self.identity = identity
            self.folderName = folderName
            try check()
        }

        var container: URL { volume.url.appendingPathComponent(folderName, isDirectory: true) }

        func payload(_ id: UUID, name: String) -> URL {
            container.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(name)
        }

        func check(_ containerFD: Int32? = nil) throws {
            let url = URL(fileURLWithPath: volume.url.path, isDirectory: true)
            guard FileIdentity(path: url.path) == identity,
                  let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsReadOnlyKey]),
                  values.volumeUUIDString?.caseInsensitiveCompare(volume.id) == .orderedSame,
                  values.volumeIsReadOnly == false,
                  ExternalArchive.apfsContainer(url.path) == volume.containerID else {
                throw ArchiveFailure.driveUnavailable
            }
            if let fd = containerFD {
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_dev == identity.dev,
                      FileIdentity(path: container.path) == FileIdentity(dev: info.st_dev, ino: info.st_ino) else {
                    throw ArchiveFailure.driveUnavailable
                }
            }
        }

        func openContainer(create: Bool) throws -> Int32 {
            try check()
            let root = ArchiveTree.openDirectory(volume.url.path)
            guard root >= 0 else { throw ArchiveFailure.driveUnavailable }
            defer { close(root) }
            var info = stat()
            guard fstat(root, &info) == 0, FileIdentity(dev: info.st_dev, ino: info.st_ino) == identity
            else { throw ArchiveFailure.driveUnavailable }
            if create, mkdirat(root, folderName, 0o700) != 0, errno != EEXIST {
                throw ArchiveFailure.system(container.path, errno)
            }
            let fd = openat(root, folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ArchiveFailure.system(container.path, errno) }
            do {
                try check(fd)
                return fd
            } catch {
                close(fd)
                throw error
            }
        }

        func requireSpace(_ bytes: Int64) throws {
            try check()
            let fd = ArchiveTree.openDirectory(volume.url.path)
            guard fd >= 0 else { throw ArchiveFailure.driveUnavailable }
            defer { close(fd) }
            try ExternalArchive.requireSpace(bytes, on: fd)
        }

        func checkWritableContainer() throws {
            var info = stat()
            let location: URL
            if lstat(container.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_dev == identity.dev else {
                    throw ArchiveFailure.occupied
                }
                location = container
            } else {
                guard errno == ENOENT else { throw ArchiveFailure.system(container.path, errno) }
                location = volume.url
            }
            guard access(location.path, W_OK | X_OK) == 0 else { throw ArchiveFailure.system(location.path, errno) }
        }
    }
}
