import Foundation

public struct RemovalResult: Equatable, Sendable {
    public let removal: PlannedRemoval
    public let outcome: Outcome
    public let trashURL: URL?
    /// Set when the outcome could not be written to the journal. The outcome itself is still true
    /// (an item may already be in the Trash), but the executor stopped after this result.
    public let journalError: String?

    public init(removal: PlannedRemoval, outcome: Outcome, trashURL: URL?, journalError: String? = nil) {
        self.removal = removal
        self.outcome = outcome
        self.trashURL = trashURL
        self.journalError = journalError
    }
}

public struct Receipt: Equatable, Sendable {
    public let batchID: UUID
    public let results: [RemovalResult]

    /// Space now sitting in the Trash, not yet freed.
    public var bytesInTrash: Int64 {
        results.reduce(0) { sum, r in
            guard r.outcome == .done, case .moveToTrash = r.removal.action else { return sum }
            return sum + (r.removal.expectedBytes ?? 0)
        }
    }

    public init(batchID: UUID, results: [RemovalResult]) {
        self.batchID = batchID
        self.results = results
    }
}

/// Carries out a confirmed plan. Every item is re-checked right before it is touched, and every
/// outcome is journalled. If the journal can't be written, the batch stops: an unjournalled
/// removal could not be restored, so nothing further is attempted.
public final class Executor {
    private let env: ScanEnvironment
    private let trasher: Trasher
    private let tools: ToolRunner
    private let apps: RunningAppsProvider
    private let journal: Journal
    /// `nil` when the helper isn't available: privileged items are then skipped, not attempted.
    private let privileged: PrivilegedRunner?

    public init(
        env: ScanEnvironment, trasher: Trasher, tools: ToolRunner, apps: RunningAppsProvider, journal: Journal,
        privileged: PrivilegedRunner? = nil
    ) {
        self.env = env
        self.trasher = trasher
        self.tools = tools
        self.apps = apps
        self.journal = journal
        self.privileged = privileged
    }

    /// `progress` is called once per removal, in plan order, right after its journal append (also
    /// when that append failed, with `journalError` set). Items the executor never reached get no call.
    public func execute(_ plan: RemovalPlan, progress: (RemovalResult) -> Void = { _ in }) -> Receipt {
        var results: [RemovalResult] = []
        var movedApplications: Set<URL> = []
        batch: for removal in plan.removals {
            var entry = JournalEntry(
                batchID: plan.batchID, catalogEntryID: removal.catalogEntryID,
                bytes: removal.expectedBytes, privateBytes: removal.privateBytes,
                clonesPresent: removal.clonesPresent, outcome: .done)
            var trashURL: URL?
            var externalDestination: Result<URL, Error>?

            if case .removeOllamaModel(let model) = removal.action {
                entry.command = ["Ollama", "remove", model.name]
                entry.action = .command
                entry.outcome = .planned
            }
            if !removal.allowsPermanentDeletion, case .moveToTrash(let url) = removal.action {
                entry.originalPath = url.path
                entry.action = .trash
                entry.outcome = .planned
                if let check = removal.duplicateCheck, let volume = check.volume {
                    externalDestination = Result {
                        guard volume.stillMounted(), !VolumeDiscovery.hasTimeMachineMarker(atPath: volume.root.path),
                              !VolumeDiscovery.timeMachineDestinationUUIDs().contains(volume.uuid) else {
                            throw RestoreError.notOurs
                        }
                        return try volume.makeTrashDestination(for: url, id: entry.id)
                    }
                    if case .success(let destination) = externalDestination {
                        entry.volumeUUID = volume.uuid
                        entry.volumeMount = volume.root.path
                        entry.volumeName = volume.name
                        entry.trashPath = destination.path
                        entry.duplicateDigest = check.digestData
                    }
                }
            }
            if entry.outcome == .planned {
                do {
                    try journal.append(entry)
                } catch {
                    let message = "The planned action couldn’t be saved to History."
                    let result = RemovalResult(removal: removal, outcome: .failed(message), trashURL: nil,
                                               journalError: Self.describe(error))
                    results.append(result)
                    progress(result)
                    break batch
                }
            }

            if case .related(let appURL) = removal.applicationCheck?.role, !movedApplications.contains(appURL) {
                entry.outcome = .skipped(.applicationNotMoved)
            } else if removal.appsMustBeQuit.contains(where: { apps.isRunning(bundleID: $0) }) {
                entry.outcome = .skipped(.appRunning)
                switch removal.action {
                case .moveToTrash(let url): entry.originalPath = url.path; entry.action = .trash
                case .runTool(let exe, let args): entry.command = [exe.path] + args; entry.action = .command
                case .removeOllamaModel(let model): entry.command = ["Ollama", "remove", model.name]; entry.action = .command
                case .privileged(let op): entry.command = op.journalCommand; entry.action = .command
                }
            } else {
                switch removal.action {
                case .moveToTrash(let url):
                    entry.originalPath = url.path
                    entry.action = .trash
                    let r: (outcome: Outcome, trashURL: URL?, fileID: UInt64?, directoryInode: UInt64?)
                    if let destination = externalDestination, let check = removal.duplicateCheck {
                        let moved = moveExternalDuplicate(check, to: destination)
                        r = (moved.outcome, moved.trashURL, moved.fileID, nil)
                    } else {
                        r = moveToTrash(url, removal: removal)
                    }
                    entry.outcome = r.outcome
                    if let landed = r.trashURL {
                        trashURL = landed
                        entry.trashPath = landed.path
                        entry.trashFileID = r.fileID
                        entry.cleanedDirectoryInode = r.directoryInode
                    }
                case .runTool(let exe, let args):
                    entry.command = [exe.path] + args
                    entry.action = .command
                    entry.outcome = runTool(exe, args)
                case .privileged(let op):
                    entry.command = op.journalCommand
                    entry.action = .command
                    entry.outcome = privileged?.run(op) ?? .skipped(.helperUnavailable)
                case .removeOllamaModel(let model):
                    entry.outcome = OllamaLocalModels.delete(model, using: tools)
                }
            }

            do {
                try journal.append(entry)
                if entry.outcome == .done, let check = removal.applicationCheck, check.role == .application {
                    movedApplications.insert(check.item.url)
                }
                let result = RemovalResult(removal: removal, outcome: entry.outcome, trashURL: trashURL)
                results.append(result)
                progress(result)
            } catch {
                let message = "Stopped: this result couldn't be saved to the history, so the remaining "
                    + "items were left untouched. (\(Self.describe(error)))"
                let result = RemovalResult(
                    removal: removal, outcome: entry.outcome, trashURL: trashURL, journalError: message)
                results.append(result)
                progress(result)
                break batch
            }
        }
        return Receipt(batchID: plan.batchID, results: results)
    }

    private func moveExternalDuplicate(
        _ check: DuplicateScanner.TrashCheck, to destination: Result<URL, Error>
    ) -> (outcome: Outcome, trashURL: URL?, fileID: UInt64?) {
        guard let volume = check.volume, volume.stillMounted() else {
            return (.skipped(.volumeNotConnected), nil, nil)
        }
        guard let target = check.verifiedTarget(env: env) else { return (.skipped(.changedSinceScan), nil, nil) }
        do {
            let url = try destination.get()
            let landed = try volume.rename(check.targetURL, to: url) {
                $0.st_ino == target.st_ino && $0.st_size == target.st_size
                    && DuplicateScanner.unchanged(target, $0)
            }
            return (.done, url, landed.map { UInt64($0.st_ino) })
        } catch RestoreError.notOurs {
            return (.skipped(.safetyViolation), nil, nil)
        } catch {
            return (.failed(FailureText.describe(error, ownedByCurrentUser: target.st_uid == getuid())), nil, nil)
        }
    }

    /// Checks, in order: safety, existence, not a symlink, unchanged since scan. Only then trashes,
    /// and always the exact URL that was checked.
    private func moveToTrash(
        _ url: URL, removal: PlannedRemoval
    )
        -> (outcome: Outcome, trashURL: URL?, fileID: UInt64?, directoryInode: UInt64?) {
        // The scan read resource values through this same URL; drop any cached copies so the
        // re-measure below sees the disk as it is now.
        var target = url
        target.removeAllCachedResourceValues()

        if SafetyGuard.checkRemovable(target, env: env) != nil { return (.skipped(.safetyViolation), nil, nil, nil) }

        var st = stat()
        if lstat(target.path, &st) != 0 {
            let code = errno
            if code == ENOENT { return (.skipped(.alreadyGone), nil, nil, nil) }
            return (.failed("Couldn't check the item: \(String(cString: strerror(code)))"), nil, nil, nil)
        }
        // A folder replaced by a symlink after the scan must never be followed.
        if st.st_mode & S_IFMT == S_IFLNK { return (.skipped(.safetyViolation), nil, nil, nil) }

        if let applicationCheck = removal.applicationCheck {
            guard applicationCheck.item.url == url, applicationCheck.verify(env: env) else {
                return (.skipped(.changedSinceScan), nil, nil, nil)
            }
        } else if let duplicateCheck = removal.duplicateCheck {
            guard duplicateCheck.targetURL == url, duplicateCheck.verify(env: env) else {
                return (.skipped(.changedSinceScan), nil, nil, nil)
            }
        } else if let browserFileCheck = removal.browserFileCheck {
            guard browserFileCheck.url == url, browserFileCheck.matches(st, env: env) else {
                return (.skipped(.changedSinceScan), nil, nil, nil)
            }
        } else if let imageCheck = removal.similarImageCheck {
            guard imageCheck.url == url, imageCheck.verify(st, env: env) else {
                return (.skipped(.changedSinceScan), nil, nil, nil)
            }
        } else if let check = removal.toolCleanupCheck {
            guard check.url == url, check.verify(st: st) else { return (.skipped(.changedSinceScan), nil, nil, nil) }
        } else {
            guard let expectation = removal.expectation else { return (.skipped(.changedSinceScan), nil, nil, nil) }
            let now = AllocatedSizer().size(of: target)
            let modified = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            // Any unreadable entry means we can't vouch for it.
            guard now.bytes == expectation.bytes, now.unreadable.isEmpty, modified == expectation.modified else {
                return (.skipped(.changedSinceScan), nil, nil, nil)
            }
        }

        let landed: URL
        do {
            landed = try trasher.trash(target)
        } catch {
            return (.failed(FailureText.describe(error, ownedByCurrentUser: st.st_uid == getuid())), nil, nil, nil)
        }
        var trashed = stat()
        let fileID = lstat(landed.path, &trashed) == 0 ? UInt64(trashed.st_ino) : nil
        let directoryInode = st.st_mode & S_IFMT == S_IFDIR ? UInt64(st.st_ino) : nil
        return (.done, landed, fileID, directoryInode)
    }

    private func runTool(_ executable: URL, _ arguments: [String]) -> Outcome {
        // Defence in depth: PlanBuilder and the catalog loader already enforce this.
        guard Self.isRunnable(executable) else { return .failed("Refused to run \(executable.relativePath)") }
        do {
            let result = try tools.run(executable, arguments)
            if result.exitCode == 0 { return .done }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if stderr.isEmpty { return .failed("Exited with code \(result.exitCode)") }
            return .failed(String(stderr.prefix(500)))
        } catch {
            return .failed(Self.describe(error))
        }
    }

    /// An absolute file URL that is not a shell (checked as written and with symlinks resolved).
    private static func isRunnable(_ executable: URL) -> Bool {
        guard executable.isFileURL, executable.baseURL == nil,
              executable.relativePath == executable.path, executable.path.hasPrefix("/")
        else { return false }
        let shells = CatalogLoader.shellExecutables
        let spellings = [
            executable.path,
            executable.standardizedFileURL.path,
            executable.resolvingSymlinksInPath().path,
        ]
        return !spellings.contains { shells.contains($0.lowercased()) }
    }

    private static func describe(_ error: Error) -> String { FailureText.raw(error) }
}
