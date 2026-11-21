import AndromedaCore
import AndromedaOrganize
import Foundation
import Observation

/// One item of an organize or move-to-cloud batch.
public struct MoveHistoryRow: Identifiable, Equatable, Sendable {
    /// The original journal entry's id.
    public let id: UUID
    public let title: String
    /// Sync status, move or undo result.
    public let outcomeText: String
    public let ok: Bool
    /// The provider's Finder hand-off, once the item is in the provider (Task 11 copy).
    public let handOff: String?
    public let handOffURL: URL?
    /// What undo does to this item (rev 2.4); set while it is still applied.
    public let undoNote: String?
    /// Why the last undo couldn't put it back (rev 4.10 audit note).
    public let undoProblem: String?
    /// The existing "shared" tag for an undone item that frees at least 0 (rev 3.6).
    public let sharedTag: String?
    public let undoAction: String?
    public let recordedSizeText: String?
}

/// One past batch, ready to show.
public struct HistoryBatchView: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Medium date and short time of the batch's start, in the user's locale.
    public let dateText: String
    /// "4 items · 3.2 GB"; no size when any size is unknown.
    public let summary: String
    /// Removal batches' rows; empty for organize kinds.
    public let rows: [ReceiptRow]
    /// True only while at least one item is still in the Trash and ours.
    public let canDeletePermanently: Bool
    public let kind: BatchKind
    /// Organize kinds' rows (created folders aren't listed for a move to cloud); empty for removals.
    public let moves: [MoveHistoryRow]
    /// **Undo this run** is offered: some item of an organize kind is still applied.
    public let canUndo: Bool
    /// Organize runs made since groups were journaled: each group that can be undone on its own; else empty.
    public var groups: [UndoableGroup] = []
    /// Set for a run the app stopped in the middle of.
    public let interruptedNote: String?
    /// "<name> isn't connected": the run was on a drive that isn't mounted now, so it can't be undone (plan 7).
    public var notConnectedNote: String? = nil
    public internal(set) var containsCopies = false
    public internal(set) var measurements: [CleanupSpaceMeasurement] = []
}

/// Past removal batches, with Restore per item and Delete permanently per batch (spec 6.1).
@MainActor @Observable
public final class HistoryModel {
    public private(set) var batches: [HistoryBatchView] = []
    /// "N line(s) of the history couldn't be read." Nil when every line was readable.
    public private(set) var unreadableNote: String?
    /// Set when there is no journal to read.
    public private(set) var recordUnavailableNote: String?
    /// Set when the last restore or delete didn't finish; cleared by the next action.
    public private(set) var actionProblem: String?

    /// False until the first `reload` (and the launch settle it waits for) has finished (T11 F2).
    public private(set) var hasLoaded = false

    /// True while the first load hasn't finished and there is a record to read: show `Copy.History.loading`.
    public var isLoading: Bool { !hasLoaded && recordUnavailableNote == nil }

    /// True when a finished load found a readable record with nothing in it: show the empty-history sentence.
    public var showsEmptyState: Bool { hasLoaded && batches.isEmpty && recordUnavailableNote == nil }

    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private let journal: Journal?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var busy = false
    /// Private-byte floors of each batch's still-restorable items, and whether any shares space with
    /// clones, for the second confirm (spec §7.1 rev 2).
    @ObservationIgnored private var restorableBytes: [UUID: (floors: [Int64?], shared: Bool)] = [:]
    /// The launch-time settle of interrupted organize runs; `reload` waits for it.
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var automationRetryTask: Task<Void, Never>?
    @ObservationIgnored private var deferredAutomation: Set<UUID> = []
    @ObservationIgnored private var plannedAutomation: Set<UUID> = []
    @ObservationIgnored private let automationHistory = FolderAutomationHistory()
    /// Organize batches found interrupted at launch, or when their drive came back (their `planned` rows are
    /// settled since).
    @ObservationIgnored private var interruptedAtLaunch: Set<UUID> = []
    /// The organize batch being applied right now: never shown as interrupted or undoable. Set by `AppModel`.
    @ObservationIgnored var applyingBatch: @MainActor () -> UUID? = { nil }
    /// The organize batch being undone right now: a drive mount never settles it meanwhile. Set by `AppModel`.
    @ObservationIgnored var undoingBatch: @MainActor () -> UUID? = { nil }

    /// Waits for launch settlement and retries automation runs deferred by another process.
    func waitForLaunchSettle() async {
        await settleTask?.value
        if let automationRetryTask { await automationRetryTask.value; return }
        let candidates = deferredAutomation.subtracting(activeBatches)
        guard !candidates.isEmpty, let journal else { return }
        let trasher = deps.trasher, volumes = deps.volumes, history = automationHistory
        let retry = Task { [weak self] in
            let settled = await BackgroundWork.runNonThrowing("andromeda.history.retry-automation") {
                Self.settleAutomation(candidates, journal: journal, trasher: trasher, volumes: volumes, history: history)
            }
            self?.record(settled)
            self?.automationRetryTask = nil
        }
        automationRetryTask = retry
        await retry.value
    }

    private var activeBatches: Set<UUID> { Set([applyingBatch(), undoingBatch()].compactMap { $0 }) }

    private struct Settlement: Sendable {
        var interrupted: Set<UUID> = []
        var checkedAutomation: Set<UUID> = []
        var deferredAutomation: Set<UUID> = []
    }

    private func record(_ settled: Settlement) {
        interruptedAtLaunch.formUnion(settled.interrupted)
        deferredAutomation.subtract(settled.checkedAutomation)
        deferredAutomation.formUnion(settled.deferredAutomation)
    }

    nonisolated private static func isAutomation(_ batch: HistoryBatch) -> Bool {
        batch.items.contains { $0.catalogEntryID == OrganizeCatalogID.automation }
    }

    nonisolated private static func settleAutomation(
        _ candidates: Set<UUID>, journal: Journal, trasher: any Trasher,
        volumes: @escaping @Sendable () -> [ExternalVolume], history: FolderAutomationHistory
    ) -> Settlement {
        guard !candidates.isEmpty else { return Settlement() }
        guard let lease = try? FolderAutomationLease.tryAcquire(in: journal.directory) else {
            return Settlement(deferredAutomation: candidates)
        }
        defer { lease.release() }
        guard let ids = try? settleInterruptedAutomation(journal: journal, trasher: trasher, volumes: volumes,
                                                        history: history, holding: lease, candidates: candidates) else {
            return Settlement(deferredAutomation: candidates)
        }
        return Settlement(interrupted: ids, checkedAutomation: candidates)
    }

    /// Runs checked automation recovery before a new rule decision. Call off the main actor with the
    /// journal's existing run lease, and keep that lease through the new decision and its writes.
    public nonisolated static func settleInterruptedAutomation(
        journal: Journal, trasher: any Trasher, volumes: @escaping @Sendable () -> [ExternalVolume],
        history: FolderAutomationHistory, holding lease: FolderAutomationLease
    ) throws -> Set<UUID> {
        try settleInterruptedAutomation(journal: journal, trasher: trasher, volumes: volumes,
                                        history: history, holding: lease, candidates: nil)
    }

    nonisolated private static func settleInterruptedAutomation(
        journal: Journal, trasher: any Trasher, volumes: @escaping @Sendable () -> [ExternalVolume],
        history: FolderAutomationHistory, holding lease: FolderAutomationLease, candidates: Set<UUID>?
    ) throws -> Set<UUID> {
        try withExtendedLifetime(lease) {
            // A previously busy runner may have finished normally. Recheck the current journal under the lease.
            guard let pending = history.interruptedBatchIDs(in: journal) else {
                throw JournalError.syscall("read automation history", errno: EIO)
            }
            let ids = candidates.map { pending.intersection($0) } ?? pending
            guard !ids.isEmpty else { return [] }
            let undo = BatchUndo(journal: journal, trasher: trasher, volumes: volumes)
            for id in ids { try undo.settleInterrupted(batchID: id) }
            return ids
        }
    }

    /// `journal` is the one shared with `RemovalFlow`; nil shows the empty state and a note.
    public init(deps: AppDependencies, journal: Journal?) {
        self.deps = deps
        self.journal = journal
        recordUnavailableNote = journal == nil ? Copy.History.recordUnavailable : nil
    }

    /// Settles every interrupted organize / move-to-cloud batch (`BatchUndo.settleInterrupted`) on a
    /// background thread, once per launch. Removal batches are never touched.
    func settleInterruptedOnLaunch() {
        guard settleTask == nil, let journal else { return }
        let trasher = deps.trasher, volumes = deps.volumes, history = automationHistory
        settleTask = Task { [weak self] in
            let settled = await BackgroundWork.runNonThrowing("andromeda.history.settle") { () -> Settlement in
                guard let entries = try? journal.load().entries else { return Settlement() }
                // A run on a drive that isn't connected keeps its `planned` rows until the drive is back.
                let undo = BatchUndo(journal: journal, trasher: trasher, volumes: volumes)
                var ordinary: Set<UUID> = [], automation: Set<UUID> = []
                for batch in JournalHistory.batches(entries: entries, restorable: [])
                where batch.interrupted && (batch.kind == .organize || batch.kind == .moveToCloud) {
                    if Self.isAutomation(batch) {
                        automation.insert(batch.id)
                        continue
                    }
                    ordinary.insert(batch.id)
                    // A failure leaves the rows `planned`: History still shows the run as interrupted.
                    try? undo.settleInterrupted(batchID: batch.id)
                }
                var settled = Self.settleAutomation(automation, journal: journal, trasher: trasher, volumes: volumes,
                                                    history: history)
                settled.interrupted.formUnion(ordinary)
                return settled
            }
            self?.record(settled)
        }
    }

    /// A drive was mounted: the interrupted runs shown on a drive that is connected now are settled (the launch
    /// settle left their rows `planned` while it was away), then History reloads. A run on a drive still away is
    /// left alone; the run being applied or undone is never touched.
    public func driveMounted() async {
        guard let journal, hasLoaded else { return }
        let candidates = Set(batches.filter { $0.kind != .removal && $0.interruptedNote != nil }.map(\.id))
            .union(plannedAutomation).subtracting(activeBatches)
        if !candidates.isEmpty {
            let trasher = deps.trasher, volumes = deps.volumes, history = automationHistory
            let settled = await BackgroundWork.runNonThrowing("andromeda.history.settle-drive") { () -> Settlement in
                guard let entries = try? journal.load().entries else { return Settlement() }
                let mounted = Set(volumes().map(\.id))
                let followUps = JournalHistory.followUps(entries: entries)
                var ids: Set<UUID> = []
                for e in entries where e.relatesTo == nil && candidates.contains(e.batchID) {
                    guard let uuid = e.volumeUUID, mounted.contains(uuid),
                          JournalHistory.resolve(e, followUps: followUps[e.id] ?? []).outcome == .planned else { continue }
                    ids.insert(e.batchID)
                }
                let undo = BatchUndo(journal: journal, trasher: trasher, volumes: volumes)
                let automation = Set(entries.lazy.filter {
                    $0.relatesTo == nil && ids.contains($0.batchID) && $0.catalogEntryID == OrganizeCatalogID.automation
                }.map(\.batchID))
                let ordinary = ids.subtracting(automation)
                // A failure leaves the rows `planned`: still shown as interrupted.
                for id in ordinary { try? undo.settleInterrupted(batchID: id) }
                var settled = Self.settleAutomation(automation, journal: journal, trasher: trasher, volumes: volumes,
                                                    history: history)
                settled.interrupted.formUnion(ordinary)
                return settled
            }
            record(settled)
        }
        await reload()
    }

    private struct Loaded: Sendable {
        let batches: [HistoryBatch]
        /// Sync state of moved-to-cloud items: at the destination while applied, at the original once undone.
        let cloud: [UUID: CloudItemState]
        let corrupt: Int
        let titles: [String: String]
        /// Items that can't be put back right now: the original path is taken or its folder is gone.
        let occupied: Set<UUID>
        /// Each organize batch's groups (empty for runs journaled before groups existed).
        let groups: [UUID: [UndoableGroup]]
        /// The load can see planned steps of a live app or worker run.
        let running: Set<UUID>
        let plannedAutomation: Set<UUID>
        let deferredAutomation: Set<UUID>
        /// Organize batches on a drive that isn't mounted now: batch id → the drive's last known name.
        let notConnected: [UUID: String]
        let measurements: [UUID: [CleanupSpaceMeasurement]]
    }

    public func reload() async {
        guard let journal else { return }
        await waitForLaunchSettle()
        generation += 1
        let mine = generation
        let deps = self.deps
        let applying = applyingBatch()
        let loaded: Loaded? = await BackgroundWork.runNonThrowing("andromeda.history") {
            let lease = try? FolderAutomationLease.tryAcquire(in: journal.directory)
            let snapshot = try? journal.load()
            lease?.release()
            guard let (entries, corrupt) = snapshot else { return nil }
            let volumes = deps.volumes()
            let restorable = TrashLedger(env: deps.env, journal: journal, volumes: { volumes }).restorable(from: entries)
            var occupied: Set<UUID> = []
            for e in restorable {
                guard let path = e.originalPath else { continue }
                if !Self.isFree(path) { occupied.insert(e.id) }
            }
            let titles = Dictionary(
                ((try? deps.catalog()) ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            let batches = JournalHistory.batches(entries: entries, restorable: restorable)
            let plannedAutomation = Set(batches.lazy.filter { $0.interrupted && Self.isAutomation($0) }.map(\.id))
            // A busy lease cannot distinguish the worker's live batch from an earlier interruption.
            // Hold the probe lease through the read so a newly started worker cannot change its meaning.
            let deferred = lease == nil ? plannedAutomation : []
            var running = deferred
            if let applying { running.insert(applying) }
            // Upload status is read only now, while History is open (decision 9).
            var cloud: [UUID: CloudItemState] = [:]
            for batch in batches where batch.kind == .moveToCloud {
                for item in batch.items where item.action == .move {
                    guard let provider = item.provider.flatMap(CloudProvider.init(rawValue:)) else { continue }
                    let path: String? = switch item.outcome {
                    case .done: item.destinationPath
                    case .restored: item.originalPath
                    default: nil
                    }
                    if let path { cloud[item.id] = deps.cloudInspect(URL(fileURLWithPath: path), provider) }
                }
            }
            // Every organize run's groups from the lines already read: one pass, never a read per run.
            let organize = Set(batches.filter { $0.kind == .organize && !running.contains($0.id) }.map(\.id))
            let groups = BatchUndo.groups(entries: entries).filter { organize.contains($0.key) }
            // Matched by volume UUID only, read now: a drive mounted since the last load re-enables Undo.
            let mounted = Set(volumes.map(\.id))
            let externalTrash = Set(batches.lazy.filter { $0.kind == .removal }.flatMap(\.items)
                .filter { $0.outcome == .done || $0.outcome == .planned }.map(\.id))
            var notConnected: [UUID: String] = [:]
            for e in entries where e.relatesTo == nil && notConnected[e.batchID] == nil {
                guard organize.contains(e.batchID) || externalTrash.contains(e.id) else { continue }
                guard let uuid = e.volumeUUID, !mounted.contains(uuid) else { continue }
                notConnected[e.batchID] = e.volumeName
                    ?? e.volumeMount.map { URL(fileURLWithPath: $0).lastPathComponent } ?? uuid
            }
            return Loaded(
                batches: batches, cloud: cloud,
                corrupt: corrupt, titles: titles, occupied: occupied,
                groups: groups, running: running, plannedAutomation: plannedAutomation, deferredAutomation: deferred,
                notConnected: notConnected,
                measurements: Dictionary(grouping: journal.cleanupMeasurements(), by: \.batchID))
        }
        guard mine == generation else { return }
        hasLoaded = true
        guard let loaded else {
            // The record exists but can't be read: say so, never show the empty state.
            batches = []
            restorableBytes = [:]
            unreadableNote = nil
            recordUnavailableNote = Copy.History.recordUnavailable
            return
        }
        recordUnavailableNote = nil
        plannedAutomation = loaded.plannedAutomation
        deferredAutomation.formUnion(loaded.deferredAutomation)
        apply(loaded)
    }

    /// Restore needs the original path free and its parent folder present.
    nonisolated static func isFree(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) != 0, errno == ENOENT else { return false }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return lstat(parent, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    private func apply(_ loaded: Loaded) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var bytes: [UUID: (floors: [Int64?], shared: Bool)] = [:]
        batches = loaded.batches.map { batch in
            if batch.kind != .removal { return organizeView(batch, loaded: loaded, formatter: formatter) }
            let perEntry = Dictionary(grouping: batch.items, by: \.catalogEntryID).mapValues(\.count)
            let rows = batch.items.map { item -> ReceiptRow in
                let isReviewedFile = !TrashLedger.allowsPermanentDeletion(item.catalogEntryID)
                let name = isReviewedFile
                    ? (item.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "File")
                    : (loaded.titles[item.catalogEntryID] ?? item.catalogEntryID)
                var title = name
                if !isReviewedFile,
                   (perEntry[item.catalogEntryID] ?? 0) > 1, let path = item.originalPath {
                    title = Copy.Confirm.itemTitle(name, URL(fileURLWithPath: path).lastPathComponent)
                }
                let reversible = item.command == nil
                return ReceiptRow(
                    title: title,
                    outcomeText: OutcomeText.text(for: item.outcome, reversible: reversible, appName: nil),
                    ok: item.outcome == .done || item.outcome == .restored || item.outcome == .permanentlyDeleted,
                    restorableEntryID: batch.restorableIDs.contains(item.id) && !loaded.occupied.contains(item.id) ? item.id : nil,
                    recordedSizeText: item.bytes.map { ByteFormat.string($0) })
            }
            let left = batch.items.filter { batch.restorableIDs.contains($0.id) }
            // A line written before clone figures were recorded has no floor: its size isn't stated.
            bytes[batch.id] = (left.map(\.privateBytes), left.contains { $0.clonesPresent == true })
            return HistoryBatchView(
                id: batch.id, dateText: formatter.string(from: batch.started),
                summary: Copy.History.summary(
                    items: batch.items.count, size: Self.knownSize(batch.items.map(\.bytes)).map { ByteFormat.string($0) },
                    shared: batch.items.contains { $0.clonesPresent == true }),
                rows: rows, canDeletePermanently: batch.items.contains {
                    batch.restorableIDs.contains($0.id) && TrashLedger.allowsPermanentDeletion($0.catalogEntryID)
                },
                kind: batch.kind, moves: [], canUndo: false,
                interruptedNote: batch.interrupted ? Copy.Receipt.interrupted : nil,
                notConnectedNote: loaded.notConnected[batch.id].map(Copy.Drives.notConnected),
                measurements: loaded.measurements[batch.id] ?? [])
        }
        restorableBytes = bytes
        unreadableNote = loaded.corrupt > 0 ? Copy.History.unreadable(loaded.corrupt) : nil
    }

    private func organizeView(_ batch: HistoryBatch, loaded: Loaded, formatter: DateFormatter) -> HistoryBatchView {
        let running = loaded.running.contains(batch.id)
        // The run is journalled up front: while it is still applying, steps it hasn't reached are `planned`
        // and aren't shown yet (they haven't happened, and they aren't interrupted).
        let shown = batch.items.filter {
            (batch.kind == .organize || $0.action == .move) && !(running && $0.outcome == .planned)
        }
        let moves = shown.map { row(for: $0, kind: batch.kind, state: loaded.cloud[$0.id]) }
        let interrupted = !running && (batch.interrupted || interruptedAtLaunch.contains(batch.id)
            || batch.items.contains { $0.outcome == .skipped(.interruptedNotMoved) })
        let applied = !running && batch.items.contains {
            $0.outcome == .done && (.move == $0.action || .copy == $0.action
                                   || (.createFolder == $0.action && !$0.isCloudOrganize))
        }
        let sized = shown.filter { $0.action == .move || $0.action == .copy }
        let containsCopies = batch.items.contains { $0.action == .copy }
        let drive = loaded.notConnected[batch.id]
        var groups = loaded.groups[batch.id] ?? []
        if drive != nil {
            // Nothing on a drive that isn't connected can go back: no group's Undo either.
            groups = groups.map {
                UndoableGroup(id: $0.id, folderName: $0.folderName, moves: $0.moves, canUndo: false, undone: $0.undone)
            }
        }
        return HistoryBatchView(
            id: batch.id, dateText: formatter.string(from: batch.started),
            summary: (Self.isAutomation(batch) ? "Folder Automation · " : "")
                + Copy.History.summary(items: sized.count, size: Self.knownSize(sized.map(\.bytes)).map { ByteFormat.string($0) }),
            rows: [], canDeletePermanently: false, kind: batch.kind, moves: moves, canUndo: applied && drive == nil,
            groups: groups,
            interruptedNote: interrupted
                ? (containsCopies ? "Andromeda stopped during this copy run. History shows which copies finished."
                   : Copy.Organize.interruptedNote)
                : nil,
            notConnectedNote: drive.map(Copy.Drives.notConnected), containsCopies: containsCopies)
    }

    private func row(for item: HistoryItem, kind: BatchKind, state: CloudItemState?) -> MoveHistoryRow {
        let title = item.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? item.catalogEntryID
        let provider = item.provider.flatMap(CloudProvider.init(rawValue:))
        var text: String
        var handOff: String?
        var handOffURL: URL?
        var undoNote: String?
        var shared: String?
        switch item.outcome {
        case .done where item.action == .createFolder:
            text = Copy.Organize.folderCreated
        case .done where item.action == .copy:
            text = "Copied"
        case .done:
            text = Copy.Organize.moved
            if kind == .moveToCloud, let provider {
                switch state?.sync {
                case .missing: text = Copy.Organize.notInProvider(provider)
                case .synced:
                    text = Copy.Organize.uploadedLocally(provider)
                    handOff = Copy.Organize.handOff(for: provider)
                    handOffURL = item.destinationPath.map { URL(fileURLWithPath: $0) }
                case .notDownloaded: text = Copy.Organize.onlineOnly(provider)
                case .conflict: text = Copy.Organize.uploadConflict
                case .stillSyncing, nil:
                    text = state?.isUploading == true ? Copy.Organize.uploading : Copy.Organize.uploadUnconfirmed
                }
                if state?.sync == .missing { break }
                let folder = item.originalPath.map {
                    Copy.Scan.displayPath(URL(fileURLWithPath: $0).deletingLastPathComponent(), home: deps.env.home)
                } ?? ""
                undoNote = Copy.Organize.undoNote(
                    originalFolder: folder, provider: provider, onlineOnly: state?.sync == .notDownloaded)
            }
        case .restored where item.action == .createFolder:
            text = Copy.Organize.folderTrashed
        case .restored where item.action == .copy:
            text = "Copy removed"
        case .restored:
            text = Copy.Organize.movedBack
            if state?.freesAtLeast == 0 { shared = Copy.Rows.frees(ByteFormat.string(0)) }
        case .failed(let message):
            // An organize move never goes to the Trash: never the removal wording.
            text = item.action == .copy ? "Couldn’t copy. \(message)" : Copy.Organize.couldntMove(message)
        case .skipped(.interruptedNotMoved) where item.action == .copy:
            text = "Copy interrupted before it finished"
        default:
            text = OutcomeText.text(for: item.outcome, reversible: true, appName: nil)
        }
        return MoveHistoryRow(
            id: item.id, title: title, outcomeText: text, ok: item.outcome == .done || item.outcome == .restored,
            handOff: handOff, handOffURL: handOffURL, undoNote: undoNote, undoProblem: item.undoProblem.map {
                if item.action == .copy, $0 == .skipped(.changedSinceScan) { return "The copy changed and was left in place." }
                return Copy.Organize.undoReason($0)
            },
            sharedTag: shared,
            undoAction: item.outcome == .done
                ? (item.action == .move ? "Put back" : item.action == .copy ? "Remove copy" : nil) : nil,
            recordedSizeText: item.bytes.map { ByteFormat.string($0) })
    }

    /// The total when every size is known and above zero; nil otherwise (never "0 KB").
    private static func knownSize(_ sizes: [Int64?]) -> Int64? {
        var total: Int64 = 0
        for s in sizes {
            guard let s else { return nil }
            total += s
        }
        return total > 0 ? total : nil
    }

    /// The second confirm the view asks before `deletePermanently`; nil when the batch has nothing
    /// left to delete.
    public func permanentDeleteConfirm(_ batchID: UUID) -> PermanentDeleteConfirm? {
        guard let batch = batches.first(where: { $0.id == batchID }), batch.canDeletePermanently else { return nil }
        let left = restorableBytes[batchID] ?? ([], false)
        let size = Self.knownSize(left.floors)
        return PermanentDeleteConfirm(
            title: Copy.Confirm.deletePermanentlyTitle(size.map { ByteFormat.string($0) }, atLeast: left.shared),
            body: Copy.Confirm.deletePermanentlyBody, cancelIsDefault: true)
    }

    /// Puts one item back where it was. A failure sets `actionProblem`.
    public func restore(_ itemID: UUID) async {
        guard let journal, !busy else { return }
        busy = true
        defer { busy = false }
        actionProblem = nil
        let deps = self.deps
        do {
            try await BackgroundWork.run("andromeda.history.restore") {
                try TrashLedger(env: deps.env, journal: journal, volumes: deps.volumes).restore(itemID)
            }
        } catch RestoreError.originalPathOccupied {
            actionProblem = Copy.History.restoreOccupied
        } catch RestoreError.originalParentMissing {
            actionProblem = Copy.History.restoreParentMissing
        } catch RestoreError.notRestorable {
            actionProblem = Copy.History.restoreGone
        } catch RestoreError.volumeNotConnected {
            actionProblem = Copy.History.restoreReconnect
        } catch {
            actionProblem = Copy.History.restoreFailed
        }
        await reload()
    }

    /// Deletes this batch's own items from the Trash and nothing else. The view asks first.
    public func deletePermanently(_ batchID: UUID) async {
        guard let journal, !busy,
              batches.first(where: { $0.id == batchID })?.canDeletePermanently == true else { return }
        busy = true
        defer { busy = false }
        actionProblem = nil
        let deps = self.deps
        do {
            _ = try await BackgroundWork.run("andromeda.history.delete") {
                try CleanupSpaceMeter(deps: deps).deleteFromTrash(batchID: batchID, journal: journal)
            }
        } catch {
            actionProblem = Copy.History.deleteFailed
        }
        await reload()
    }
}
