import Darwin
import AndromedaCore
import Foundation

enum AutomationCopyPreparation {
    case finished(Outcome)
    case verified(VerifiedAutomationCopy)
}

/// Owns the private stage and its directory handles until publication or cancellation.
final class VerifiedAutomationCopy {
    let evidence: AutomationCopyEvidence
    private let publishVerified: (() -> Bool) throws -> Outcome
    private let cleanup: () -> Void

    init(evidence: AutomationCopyEvidence, publish: @escaping (() -> Bool) throws -> Outcome,
         cleanup: @escaping () -> Void) {
        self.evidence = evidence
        self.publishVerified = publish
        self.cleanup = cleanup
    }

    deinit { cleanup() }

    func publish(_ shouldContinue: () -> Bool) throws -> Outcome {
        try publishVerified(shouldContinue)
    }
}

extension AutomationDirectories {
    func copy(
        from: URL, to: URL, snapshot: ItemSnapshot, entryID: UUID, env: ScanEnvironment?,
        addingFinderTags: [String] = [], removingFinderTags: [String] = [],
        requiresSourceVerification: Bool = false,
        shouldContinue: () -> Bool, record: (AutomationCopyEvidence) throws -> Void
    ) throws -> (Outcome, AutomationCopyEvidence?) {
        switch try prepareCopy(from: from, to: to, snapshot: snapshot, entryID: entryID, env: env,
                               addingFinderTags: addingFinderTags, removingFinderTags: removingFinderTags,
                               requiresSourceVerification: requiresSourceVerification,
                               shouldContinue: shouldContinue, recordStage: record) {
        case .finished(let outcome):
            return (outcome, nil)
        case .verified(let copy):
            try record(copy.evidence)
            let outcome = try copy.publish(shouldContinue)
            return (outcome, outcome == .done ? copy.evidence : nil)
        }
    }

    func prepareCopy(
        from: URL, to: URL, snapshot: ItemSnapshot, entryID: UUID, env: ScanEnvironment?,
        addingFinderTags: [String], removingFinderTags: [String],
        requiresSourceVerification: Bool = false,
        shouldContinue: () -> Bool, recordStage: (AutomationCopyEvidence) throws -> Void
    ) throws -> AutomationCopyPreparation {
        guard source != destination, let name = Self.filename(from.path, inside: source),
              let target = destinationParts(to.path), let sourceFD = openSource() else {
            return .finished(.skipped(.changedSinceScan))
        }
        var retainedByCopy = false
        defer { if !retainedByCopy { close(sourceFD) } }
        let input = openat(sourceFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { return .finished(.skipped(.changedSinceScan)) }
        defer { if !retainedByCopy { close(input) } }
        var original = stat()
        guard fstat(input, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_uid == getuid(), original.st_flags & UInt32(SF_DATALESS) == 0,
              UInt64(original.st_ino) == snapshot.fileID, original.st_size == snapshot.identitySize,
              Self.date(original.st_mtimespec) == snapshot.modified,
              Self.date(original.st_ctimespec) == snapshot.changed else {
            return .finished(.skipped(.changedSinceScan))
        }
        guard nestedSourceIsUsable(env: env) else { return .finished(.skipped(.safetyViolation)) }
        let parent = to.deletingLastPathComponent()
        if !target.folders.isEmpty {
            guard let env, usableGeneratedFolder(parent, env: env) else { return .finished(.skipped(.safetyViolation)) }
        }
        guard let destinationFD = openDestination(target.folders, create: true) else {
            return .finished(.skipped(.originalParentMissing))
        }
        defer { if !retainedByCopy { close(destinationFD) } }
        let recordedParent: Folder?
        if target.folders.isEmpty {
            recordedParent = nil
        } else {
            guard let approved = Folder(parent), approved.matchesOpenedFolder(destinationFD) else {
                return .finished(.skipped(.safetyViolation))
            }
            recordedParent = approved
        }
        guard sourceBoundaryIsCurrent(), Self.isCurrent(sourceFD, at: source.path),
              Self.isCurrent(destinationFD, at: parent.path),
              Self.identity(destinationFD)?.dev == original.st_dev else { return .finished(.skipped(.safetyViolation)) }
        var occupied = stat()
        guard fstatat(destinationFD, target.name, &occupied, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            return .finished(.skipped(.destinationOccupied))
        }
        let stage = Self.stageName(entryID)
        guard mkdirat(destinationFD, stage, 0o700) == 0 else { return .finished(Self.copyFailure(errno)) }
        let stageFD = Self.openCopyStage(stage, below: destinationFD)
        guard stageFD >= 0, let stageIdentity = Self.identity(stageFD) else {
            if stageFD >= 0 { close(stageFD) }
            return .finished(.skipped(.safetyViolation))
        }
        defer { if !retainedByCopy { close(stageFD) } }
        let output = openat(stageFD, target.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0, let outputIdentity = Self.identity(output) else {
            if output >= 0 { close(output) }
            _ = unlinkat(destinationFD, stage, AT_REMOVEDIR)
            return .finished(.skipped(.safetyViolation))
        }
        defer { if !retainedByCopy { close(output) } }
        let pending = AutomationCopyEvidence(stageInode: UInt64(stageIdentity.ino), fileInode: UInt64(outputIdentity.ino),
                                             destinationParent: recordedParent)
        let removeStage = { Self.removeCopyStage(stage, file: target.name, below: destinationFD, evidence: pending) }
        defer { if !retainedByCopy { removeStage() } }
        try recordStage(pending)
        let control = ScanControl { _ in }
        let stagedPath = parent.path + "/" + stage + "/" + target.name
        let fingerprint: Data
        var sourceFingerprint: Data?
        let stagedTree: ArchiveTree
        do {
            let tree = try ArchiveTree(at: from.path, control: control)
            guard tree.nodes.first?.identity == FileIdentity(dev: original.st_dev, ino: original.st_ino),
                  shouldContinue() else { return .finished(.skipped(.interruptedNotMoved)) }
            let updatedTags = try AutomationFinderTags.change(adding: addingFinderTags, removing: removingFinderTags,
                                                             at: input, path: from.path)
            fingerprint = try tree.fileFingerprint(at: from.path, relative: "", firstLink: "",
                                                   control: control, changingFinderTags: updatedTags)
            if requiresSourceVerification {
                switch updatedTags {
                case .unchanged: break
                case .replace, .remove:
                    sourceFingerprint = try tree.fileFingerprint(at: from.path, relative: "", firstLink: "", control: control)
                }
            }
            guard shouldContinue() else { return .finished(.skipped(.interruptedNotMoved)) }
            guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                return .finished(Self.copyFailure(errno))
            }
            try AutomationFinderTags.apply(updatedTags, to: output, path: stagedPath)
            guard fsync(output) == 0 else { return .finished(Self.copyFailure(errno)) }
            stagedTree = try ArchiveTree(at: stagedPath, control: control)
            guard stagedTree.nodes.first?.identity == outputIdentity else {
                return .finished(.skipped(.changedSinceScan))
            }
            let stagedFingerprint = try stagedTree.fingerprint(at: stagedPath, control: control)
            guard try ArchiveTree(at: from.path, control: control) == tree else {
                return .finished(.skipped(.changedSinceScan))
            }
            var current = stat()
            guard fstat(input, &current) == 0, current.st_size == original.st_size,
                  Self.date(current.st_ctimespec) == snapshot.changed else {
                return .finished(.skipped(.changedSinceScan))
            }
            guard stagedFingerprint == fingerprint else {
                return .finished(.failed(ArchiveFailure.verification.localizedDescription))
            }
        } catch {
            return .finished(.failed(error.localizedDescription))
        }
        let prepared = AutomationCopyEvidence(stageInode: pending.stageInode, fileInode: pending.fileInode,
                                              fingerprint: fingerprint, sourceFingerprint: sourceFingerprint,
                                              destinationParent: pending.destinationParent)
        let sourceIdentity = FileIdentity(dev: original.st_dev, ino: original.st_ino)
        retainedByCopy = true
        let copy = VerifiedAutomationCopy(evidence: prepared, publish: { shouldContinue in
            guard shouldContinue() else { return .skipped(.interruptedNotMoved) }
            var current = stat()
            guard fstatat(sourceFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  FileIdentity(dev: current.st_dev, ino: current.st_ino) == sourceIdentity,
                  Self.date(current.st_ctimespec) == snapshot.changed else {
                return .skipped(.changedSinceScan)
            }
            guard sourceBoundaryIsCurrent(), Self.isCurrent(sourceFD, at: source.path),
                  Self.isCurrent(destinationFD, at: parent.path),
                  Self.isCurrent(stageFD, at: parent.path + "/" + stage),
                  nestedSourceIsUsable(env: env),
                  (try? ArchiveTree(at: stagedPath, control: control)) == stagedTree else {
                return .skipped(.safetyViolation)
            }
            if renameatx_np(stageFD, target.name, destinationFD, target.name, UInt32(RENAME_EXCL)) != 0 {
                return Self.copyFailure(errno)
            }
            // The prepared receipt lets History recover if the final result can't be recorded.
            if fsync(destinationFD) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return .done
        }, cleanup: {
            removeStage()
            close(output)
            close(stageFD)
            close(destinationFD)
            close(input)
            close(sourceFD)
        })
        return .verified(copy)
    }

    func copyReachedDestination(_ path: String, evidence: AutomationCopyEvidence) -> Bool {
        guard let target = destinationParts(path), let parent = openDestination(target.folders) else { return false }
        defer { close(parent) }
        if let recorded = evidence.destinationParent {
            guard Self.matchesRecordedParent(recorded, path: path, descriptor: parent),
                  Self.isCurrent(parent, at: recorded.path) else { return false }
        }
        return Self.copyMatches(path, name: target.name, below: parent, evidence: evidence)
    }

    func sourceMatchesBackup(_ path: String, inode: UInt64, evidence: AutomationCopyEvidence) -> Bool {
        guard let name = Self.filename(path, inside: source), let parent = openSource() else { return false }
        defer { close(parent) }
        return Self.matchesFingerprint(path, name: name, below: parent, inode: inode,
                                       fingerprint: evidence.sourceFingerprint ?? evidence.fingerprint)
    }

    func settleCopy(_ path: String, entryID: UUID, evidence: AutomationCopyEvidence?) -> Outcome {
        guard let target = destinationParts(path), let parent = openDestination(target.folders) else {
            return .skipped(.interruptedNotMoved)
        }
        defer { close(parent) }
        guard let evidence else { return .skipped(.interruptedNotMoved) }
        if let recorded = evidence.destinationParent {
            guard Self.matchesRecordedParent(recorded, path: path, descriptor: parent),
                  Self.isCurrent(parent, at: recorded.path) else { return .skipped(.notWhereWeLeftIt) }
        }
        Self.removeCopyStage(Self.stageName(entryID), file: target.name, below: parent, evidence: evidence)
        return Self.copyMatches(path, name: target.name, below: parent, evidence: evidence)
            ? .done : .skipped(.interruptedNotMoved)
    }

    func undoCopy(_ path: String, entryID: UUID, evidence: AutomationCopyEvidence, trasher: any Trasher) -> Outcome {
        guard let target = destinationParts(path), let parent = openDestination(target.folders) else {
            return .skipped(.notWhereWeLeftIt)
        }
        defer { close(parent) }
        let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if let recorded = evidence.destinationParent {
            guard Self.matchesRecordedParent(recorded, path: path, descriptor: parent) else {
                return .skipped(.notWhereWeLeftIt)
            }
        }
        guard Self.isCurrent(parent, at: parentPath) else { return .skipped(.notWhereWeLeftIt) }
        let stage = ".diskplain-copy-undo-" + entryID.uuidString
        var current = stat()
        let exists = fstatat(parent, target.name, &current, AT_SYMLINK_NOFOLLOW) == 0
        if exists {
            guard Self.copyMatches(path, name: target.name, below: parent, evidence: evidence) else {
                return .skipped(.changedSinceScan)
            }
            if mkdirat(parent, stage, 0o700) != 0, errno != EEXIST { return Self.copyFailure(errno) }
        } else if errno != ENOENT {
            return .skipped(.notWhereWeLeftIt)
        }
        let stageFD = Self.openCopyStage(stage, below: parent)
        guard stageFD >= 0 else {
            return !exists && errno == ENOENT ? .restored : .skipped(.notWhereWeLeftIt)
        }
        defer {
            close(stageFD)
            _ = unlinkat(parent, stage, AT_REMOVEDIR)
        }
        let stagedPath = parentPath + "/" + stage + "/" + target.name
        if exists, renameatx_np(parent, target.name, stageFD, target.name, UInt32(RENAME_EXCL)) != 0 {
            return Self.copyFailure(errno)
        }
        if !exists, fstatat(stageFD, target.name, &current, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT {
            return .restored
        }
        guard Self.isCurrent(stageFD, at: parentPath + "/" + stage),
              Self.copyMatches(stagedPath, name: target.name, below: stageFD, evidence: evidence) else {
            if exists { _ = renameatx_np(stageFD, target.name, parent, target.name, UInt32(RENAME_EXCL)) }
            return .skipped(.changedSinceScan)
        }
        do {
            _ = try trasher.trash(URL(fileURLWithPath: stagedPath))
            return .restored
        } catch {
            _ = renameatx_np(stageFD, target.name, parent, target.name, UInt32(RENAME_EXCL))
            return .failed(error.localizedDescription)
        }
    }

    private static func matchesRecordedParent(_ recorded: Folder, path: String, descriptor: Int32) -> Bool {
        recorded.path == URL(fileURLWithPath: path).deletingLastPathComponent().path
            && recorded.matchesOpenedFolder(descriptor)
    }

    private static func stageName(_ id: UUID) -> String { ".diskplain-copy-" + id.uuidString }

    private static func openCopyStage(_ name: String, below parent: Int32) -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd)
            errno = EPERM
            return -1
        }
        return fd
    }

    private static func removeCopyStage(_ stage: String, file: String, below parent: Int32, evidence: AutomationCopyEvidence) {
        let fd = openCopyStage(stage, below: parent)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard let identity = identity(fd), UInt64(identity.ino) == evidence.stageInode else { return }
        var info = stat()
        if fstatat(fd, file, &info, AT_SYMLINK_NOFOLLOW) == 0,
           info.st_mode & S_IFMT == S_IFREG, UInt64(info.st_ino) == evidence.fileInode {
            _ = unlinkat(fd, file, 0)
        }
        if fstatat(parent, stage, &info, AT_SYMLINK_NOFOLLOW) == 0,
           FileIdentity(dev: info.st_dev, ino: info.st_ino) == identity {
            _ = unlinkat(parent, stage, AT_REMOVEDIR)
        }
    }

    private static func copyMatches(
        _ path: String, name: String, below parent: Int32, evidence: AutomationCopyEvidence
    ) -> Bool {
        matchesFingerprint(path, name: name, below: parent, inode: evidence.fileInode, fingerprint: evidence.fingerprint)
    }

    private static func matchesFingerprint(
        _ path: String, name: String, below parent: Int32, inode: UInt64, fingerprint: Data?
    ) -> Bool {
        guard let fingerprint else { return false }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
              UInt64(info.st_ino) == inode else { return false }
        let control = ScanControl { _ in }
        guard let tree = try? ArchiveTree(at: path, control: control),
              tree.nodes.first?.identity == FileIdentity(dev: info.st_dev, ino: info.st_ino),
              (try? tree.fingerprint(at: path, control: control)) == fingerprint,
              (try? ArchiveTree(at: path, control: control)) == tree else { return false }
        return true
    }

    private static func identity(_ fd: Int32) -> FileIdentity? {
        var info = stat()
        return fstat(fd, &info) == 0 ? FileIdentity(dev: info.st_dev, ino: info.st_ino) : nil
    }

    static func isCurrent(_ fd: Int32, at path: String) -> Bool {
        guard let id = identity(fd) else { return false }
        let current = ArchiveTree.openDirectory(path)
        guard current >= 0 else { return false }
        defer { close(current) }
        return identity(current) == id
    }

    private static func copyFailure(_ code: Int32) -> Outcome {
        code == EEXIST ? .skipped(.destinationOccupied) : .failed(String(cString: strerror(code)))
    }
}
