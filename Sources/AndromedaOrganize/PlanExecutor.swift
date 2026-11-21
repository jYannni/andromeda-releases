import Foundation
import AndromedaCore

public struct StepResult: Equatable, Sendable {
    public let step: PlannedStep
    public let outcome: Outcome
    /// The `planned` journal entry's id (fresh per apply; ruling R11).
    public let entryID: UUID
    /// Set when this step's journal write could not be confirmed. The batch stops.
    public let journalError: String?

    public var failedCopyVerification: Bool {
        guard case .copy = step.action else { return false }
        return outcome == .failed(ArchiveFailure.verification.localizedDescription)
    }

    public init(step: PlannedStep, outcome: Outcome, entryID: UUID, journalError: String? = nil) {
        self.step = step
        self.outcome = outcome
        self.entryID = entryID
        self.journalError = journalError
    }
}

/// Applies an `OrganizePlan`: the whole run is journaled first, and each step gets a settle follow-up.
/// Automation copies are staged and recorded before they are published. If the
/// journal can't be written, the batch stops: an unjournalled move could not be undone.
public final class PlanExecutor {
    private let journal: Journal
    private let automationEnvironment: ScanEnvironment?
    /// Test seam: called immediately before each `renamex_np`, after the `planned` entry is on disk.
    var beforeRename: ((PlannedStep) -> Void)?
    /// Test seam: called with a step's index right after its settle is appended. Returning true ends the run
    /// there the way a kill would: nothing more is run, journalled or reported.
    var killAfterStep: ((Int) -> Bool)?

    public init(journal: Journal, automationEnvironment: ScanEnvironment? = nil) {
        self.journal = journal
        self.automationEnvironment = automationEnvironment
    }

    /// Journals the whole run up front: every step's `planned` entry is on disk (one batched append, one sync)
    /// before the first step runs, so a run killed anywhere leaves the steps it didn't finish `planned` and
    /// History shows it interrupted (T11 F6). Then each step runs and only its settle is appended.
    ///
    /// `progress` is called once per step, in plan order, right after its settle append (also when an
    /// append failed, with `journalError` set). Steps the executor never reached get no call. If the
    /// up-front append fails, nothing runs: one result for the first step (`.skipped(.interruptedNotMoved)`
    /// with `journalError` set) is returned and reported.
    public func apply(
        _ plan: OrganizePlan, batchID: UUID = UUID(), progress: (StepResult) -> Void = { _ in }
    ) -> [StepResult] {
        apply(plan, batchID: batchID, shouldContinue: { true }, progress: progress)
    }

    /// Independent automation copies can group their verified receipts and final results.
    /// Each stage identity is still written before the stage receives any source data.
    public func apply(
        _ plan: OrganizePlan, batchID: UUID, shouldContinue: () -> Bool,
        batchCopyReceipts: Bool = false,
        progress: (StepResult) -> Void = { _ in }
    ) -> [StepResult] {
        guard shouldContinue(), let first = plan.steps.first else { return [] }
        let entryIDs = plan.steps.map { _ in UUID() }
        let requiredCopies = Set(plan.steps.compactMap(\.requiredCopyID))
        let copyEntries = Dictionary(zip(plan.steps.map(\.id), entryIDs).filter { requiredCopies.contains($0.0) },
                                     uniquingKeysWith: { first, _ in first })
        let planned = zip(plan.steps, entryIDs).map { step, id -> JournalEntry in
            var e = Self.entry(step, plan: plan, batchID: batchID, id: id, outcome: .planned)
            e.relatesTo = nil
            e.requiredCopyEntryID = step.requiredCopyID.flatMap { copyEntries[$0] }
            return e
        }
        do {
            try journal.append(contentsOf: planned)
        } catch {
            // Nothing was tried: it reads as not moved, never as a failure (P5).
            let result = StepResult(
                step: first, outcome: .skipped(.interruptedNotMoved), entryID: entryIDs[0],
                journalError: Self.stopMessage(error))
            progress(result)
            return [result]
        }

        // A plan on a drive runs only while that drive is mounted where it was when the run began (spec X3):
        // once it isn't, the run stops and writes nothing more, so the steps not reached stay `planned` and
        // History shows the run interrupted, never with skip lines the drive's absence caused.
        if batchCopyReceipts, plan.automationDirectories != nil, killAfterStep == nil,
           requiredCopies.isEmpty, plan.steps.allSatisfy({
               if case .copy = $0.action { return $0.snapshot != nil }
               return false
           }) {
            return applyIndependentCopies(plan, planned: planned, shouldContinue: shouldContinue, progress: progress)
        }
        let drive = plan.volume.map { MountIdentity(path: $0.mountPath) }
        var results: [StepResult] = []
        var completedCopies: [UUID: (from: URL, to: URL, dirs: AutomationDirectories,
                                     evidence: AutomationCopyEvidence, previous: UUID?)] = [:]
        func prerequisitesVerified(for step: PlannedStep) -> Bool {
            guard var required = step.requiredCopyID else { return true }
            let source: URL
            switch step.action {
            case .copy(let from, _):
                // Publication already verified this copy. Re-read every copy once before moving the original.
                return completedCopies[required]?.from == from && shouldContinue()
            case .move(let from, _): source = from
            default: return false
            }
            var checked = Set<UUID>()
            while shouldContinue(), checked.insert(required).inserted,
                  let copy = completedCopies[required], copy.from == source,
                  copy.dirs.copyReachedDestination(copy.to.path, evidence: copy.evidence) {
                guard let previous = copy.previous else { return shouldContinue() }
                required = previous
            }
            return false
        }
        for (index, (step, entryID)) in zip(plan.steps, entryIDs).enumerated() {
            guard shouldContinue() else { break }
            if let drive, !drive.isStillMounted() { break }
            var settle = Self.entry(step, plan: plan, batchID: batchID, id: UUID(), outcome: .planned)
            settle.relatesTo = entryID
            let automation = step.automationDirectories ?? plan.automationDirectories
            if !prerequisitesVerified(for: step) {
                settle.outcome = .skipped(.backupNotVerified)
            } else if case .copy(let from, let to) = step.action, let directories = automation,
               let snapshot = step.snapshot {
                do {
                    let (outcome, evidence) = try directories.copy(
                        from: from, to: to, snapshot: snapshot, entryID: entryID, env: automationEnvironment,
                        addingFinderTags: step.copyFinderTags, removingFinderTags: step.removedCopyTags,
                        requiresSourceVerification: requiredCopies.contains(step.id),
                        shouldContinue: shouldContinue
                    ) { evidence in
                        var pending = settle
                        pending.id = UUID()
                        pending.automationCopy = evidence
                        try journal.append(pending)
                    }
                    settle.outcome = outcome
                    settle.automationCopy = evidence
                    if requiredCopies.contains(step.id), outcome == .done, let evidence {
                        completedCopies[step.id] = (from, to, directories, evidence, step.requiredCopyID)
                    }
                } catch {
                    let message = Self.stopMessage(error)
                    let result = StepResult(step: step, outcome: .planned, entryID: entryID, journalError: message)
                    results.append(result)
                    progress(result)
                    break
                }
            } else {
                let (outcome, newFolderID) = run(step, automation: automation, cloudFolder: plan.cloudOrganizeFolder)
                settle.outcome = outcome
                if let newFolderID { settle.fileID = newFolderID }
            }
            let outcome = settle.outcome
            do {
                try journal.append(settle)
                let result = StepResult(step: step, outcome: outcome, entryID: entryID)
                results.append(result)
                progress(result)
                if killAfterStep?(index) == true { break }
            } catch {
                let result = StepResult(step: step, outcome: outcome, entryID: entryID, journalError: Self.stopMessage(error))
                results.append(result)
                progress(result)
                break
            }
        }
        return results
    }

    private func applyIndependentCopies(
        _ plan: OrganizePlan, planned: [JournalEntry], shouldContinue: () -> Bool, progress: (StepResult) -> Void
    ) -> [StepResult] {
        var results: [StepResult] = []
        func report(_ step: PlannedStep, _ entry: JournalEntry, error: Error? = nil) {
            let result = StepResult(step: step, outcome: entry.outcome, entryID: entry.relatesTo ?? entry.id,
                                    journalError: error.map(Self.stopMessage))
            results.append(result)
            progress(result)
        }

        let drive = plan.volume.map { MountIdentity(path: $0.mountPath) }
        // A verified copy retains its private stage and open descriptors until it is published or discarded.
        let groupSize = 16
        for start in stride(from: 0, to: planned.count, by: groupSize) {
            var ready: [(step: PlannedStep, settle: JournalEntry, copy: VerifiedAutomationCopy?)] = []
            var prepared: [JournalEntry] = []
            for index in start..<min(start + groupSize, planned.count) {
                guard shouldContinue(), drive?.isStillMounted() != false else { break }
                let step = plan.steps[index]
                let entry = planned[index]
                guard case .copy(let from, let to) = step.action, let snapshot = step.snapshot,
                      let directories = step.automationDirectories ?? plan.automationDirectories else { break }
                var settle = entry
                settle.id = UUID()
                settle.relatesTo = entry.id
                do {
                    let preparation = try directories.prepareCopy(
                        from: from, to: to, snapshot: snapshot, entryID: entry.id, env: automationEnvironment,
                        addingFinderTags: step.copyFinderTags, removingFinderTags: step.removedCopyTags,
                        shouldContinue: shouldContinue
                    ) { evidence in
                        var pending = settle
                        pending.id = UUID()
                        pending.automationCopy = evidence
                        try journal.append(pending)
                    }
                    switch preparation {
                    case .finished(let outcome):
                        settle.outcome = outcome
                        ready.append((step, settle, nil))
                    case .verified(let copy):
                        var receipt = settle
                        receipt.id = UUID()
                        receipt.automationCopy = copy.evidence
                        prepared.append(receipt)
                        ready.append((step, settle, copy))
                    }
                } catch {
                    report(step, settle, error: error)
                    return results
                }
            }
            guard let first = ready.first, shouldContinue(), drive?.isStillMounted() != false else { break }
            do {
                try journal.append(contentsOf: prepared)
            } catch {
                report(first.step, first.settle, error: error)
                return results
            }

            var finished: [(step: PlannedStep, settle: JournalEntry)] = []
            for index in ready.indices {
                guard shouldContinue(), drive?.isStillMounted() != false else { break }
                let candidate = ready[index]
                ready[index].copy = nil
                var settle = candidate.settle
                if let copy = candidate.copy {
                    do {
                        settle.outcome = try copy.publish(shouldContinue)
                        if settle.outcome == .done { settle.automationCopy = copy.evidence }
                    } catch {
                        for item in finished { report(item.step, item.settle, error: error) }
                        report(candidate.step, settle, error: error)
                        return results
                    }
                }
                finished.append((candidate.step, settle))
            }
            do {
                try journal.append(contentsOf: finished.map(\.settle))
                for item in finished { report(item.step, item.settle) }
            } catch {
                for item in finished { report(item.step, item.settle, error: error) }
                return results
            }
            if finished.count < ready.count { break }
        }
        return results
    }

    /// A drive's mount root as it is when the run begins: its device and volume UUID. Each check is one `lstat`
    /// and one volume-UUID read of the root (fresh, never a cached resource value); a root that is gone, now on
    /// another device, or another volume, is not mounted. No root at the start: nothing is mounted to run on.
    private struct MountIdentity {
        let path: String
        let start: (device: dev_t, uuid: String?)?

        init(path: String) {
            self.path = path
            start = Self.read(path)
        }

        func isStillMounted() -> Bool {
            guard let start, let now = Self.read(path) else { return false }
            return now.device == start.device && now.uuid == start.uuid
        }

        private static func read(_ path: String) -> (device: dev_t, uuid: String?)? {
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            let uuid = try? URL(fileURLWithPath: path, isDirectory: true)
                .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            return (st.st_dev, uuid)
        }
    }

    private static func stopMessage(_ error: Error) -> String {
        "Stopped: this result couldn't be saved to the history, so the remaining items were left "
            + "untouched. (\(FailureText.raw(error)))"
    }

    private static func entry(
        _ step: PlannedStep, plan: OrganizePlan, batchID: UUID, id: UUID, outcome: Outcome
    ) -> JournalEntry {
        var e = JournalEntry(
            id: id, batchID: batchID, catalogEntryID: step.catalogEntryID, outcome: outcome,
            planID: plan.planID, provider: step.provider?.rawValue, groupID: step.groupID,
            volumeUUID: plan.volume?.uuid, volumeMount: plan.volume?.mountPath, volumeName: plan.volume?.name)
        e.automationDirectories = step.automationDirectories ?? plan.automationDirectories
        e.cloudOrganizeFolder = plan.cloudOrganizeFolder
        switch step.action {
        case .createFolder(let url):
            e.action = .createFolder
            e.originalPath = url.path
        case .move(let from, let to):
            e.action = .move
            e.originalPath = from.path
            e.destinationPath = to.path
            e.fileID = step.snapshot?.fileID
            e.bytes = step.snapshot?.bytes
        case .copy(let from, let to):
            e.action = .copy
            e.originalPath = from.path
            e.destinationPath = to.path
            e.fileID = step.snapshot?.fileID
            e.bytes = step.snapshot?.bytes
            e.automationSourceChanged = step.snapshot?.changed?.timeIntervalSinceReferenceDate
        }
        return e
    }

    // MARK: - Steps

    private func run(_ step: PlannedStep, automation: AutomationDirectories?,
                     cloudFolder: AutomationDirectories.Folder?) -> (Outcome, UInt64?) {
        if let cloudFolder {
            let operations = CloudFolderOperations(folder: cloudFolder)
            switch step.action {
            case .createFolder(let url): return operations.create(url)
            case .move(let from, let to):
                guard let snapshot = step.snapshot else { return (.skipped(.changedSinceScan), nil) }
                beforeRename?(step)
                return (operations.move(from: from.path, to: to.path, fileID: snapshot.fileID, snapshot: snapshot), nil)
            case .copy: return (.skipped(.safetyViolation), nil)
            }
        }
        if let automation {
            guard case .move(let from, let to) = step.action, let snapshot = step.snapshot else {
                return (.skipped(.safetyViolation), nil)
            }
            return (automation.move(from: from.path, to: to.path, fileID: snapshot.fileID, snapshot: snapshot,
                                    env: automationEnvironment), nil)
        }
        switch step.action {
        case .createFolder(let url): return createFolder(url)
        case .move(let from, let to): return (move(step, from: from, to: to), nil)
        case .copy: return (.skipped(.safetyViolation), nil)
        }
    }

    private func createFolder(_ url: URL) -> (Outcome, UInt64?) {
        if mkdir(url.path, 0o755) != 0 {
            let code = errno
            switch code {
            case EEXIST: return (.skipped(.destinationOccupied), nil)  // not ours: undo never trashes it
            case ENOENT: return (.skipped(.originalParentMissing), nil)
            default: return (.failed(Self.describe(code, owned: true)), nil)
            }
        }
        var st = stat()
        return (.done, lstat(url.path, &st) == 0 ? UInt64(st.st_ino) : nil)
    }

    /// Checks, in order: source unchanged, destination parent exists, same volume. Then one exclusive rename.
    private func move(_ step: PlannedStep, from: URL, to: URL) -> Outcome {
        guard let snap = step.snapshot else { return .skipped(.changedSinceScan) }
        var src = stat()
        guard lstat(from.path, &src) == 0, src.st_mode & S_IFMT != S_IFLNK,
              UInt64(src.st_ino) == snap.fileID,
              Self.modified(src).timeIntervalSince(snap.modified).magnitude < 0.000001
        else { return .skipped(.changedSinceScan) }
        // Directories: inode + mtime only. Regular files must also match the snapshot's identity size.
        if src.st_mode & S_IFMT != S_IFDIR, snap.identitySize != Int64(src.st_size) {
            return .skipped(.changedSinceScan)
        }

        var parent = stat()
        guard lstat(to.deletingLastPathComponent().path, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR
        else { return .skipped(.originalParentMissing) }
        guard parent.st_dev == src.st_dev else { return .skipped(.crossVolume) }

        beforeRename?(step)
        // Re-read right before the rename to shrink the window after the checks above.
        var again = stat()
        guard lstat(from.path, &again) == 0, again.st_ino == src.st_ino, again.st_dev == src.st_dev,
              again.st_mode & S_IFMT != S_IFLNK
        else { return .skipped(.changedSinceScan) }

        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            if code == EEXIST { return .skipped(.destinationOccupied) }
            return .failed(Self.describe(code, owned: src.st_uid == getuid()))
        }
        return .done
    }

    private static func modified(_ st: stat) -> Date {
        Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
    }

    private static func describe(_ code: Int32, owned: Bool) -> String {
        let error = NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
        return FailureText.describe(error, ownedByCurrentUser: owned)
    }
}
