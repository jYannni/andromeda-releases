import AndromedaCore
import AndromedaOrganize
import Foundation

public struct SpacePlanProgress: Equatable, Sendable {
    public enum NextStep: Equatable, Sendable {
        case archive(UUID)
        case history(UUID)
        case cloudCopy(URL, CloudProvider, removeDownload: Bool, historyBatch: UUID?)
    }

    public let message: String
    public let nextStep: NextStep?
    let usesSavedEstimate: Bool
    let hasRecordedAction: Bool

    private init(
        _ message: String, nextStep: NextStep? = nil, usesSavedEstimate: Bool = false, hasRecordedAction: Bool = true
    ) {
        self.message = message
        self.nextStep = nextStep
        self.usesSavedEstimate = usesSavedEstimate
        self.hasRecordedAction = hasRecordedAction
    }

    static func check(
        _ items: [SpacePlanItem], since: Date, archives: [ArchiveRecord]?, journal: Journal?, deps: AppDependencies
    ) -> (rows: [String: Self], problem: String?) {
        guard !items.isEmpty else { return ([:], nil) }
        let needsJournal = items.contains {
            if case .cleanup = $0.action { return true }
            return $0.action == .moveToCloud
        }
        let loaded = needsJournal ? try? journal?.load() : nil
        let entries = loaded?.entries ?? []
        let followUps = JournalHistory.followUps(entries: entries)
        var moves: [String: JournalEntry] = [:]
        var trash: [String: [String: JournalEntry]] = [:]
        for entry in entries where entry.relatesTo == nil && entry.timestamp >= since {
            guard let path = entry.originalPath else { continue }
            let key = URL(fileURLWithPath: path).standardizedFileURL.path
            if entry.resolvedAction == .trash && entry.outcome == .done {
                if trash[entry.catalogEntryID]?[key]?.timestamp ?? .distantPast <= entry.timestamp {
                    trash[entry.catalogEntryID, default: [:]][key] = entry
                }
            }
            if entry.catalogEntryID == OrganizeCatalogID.cloudMove && entry.resolvedAction == .move {
                if moves[key]?.timestamp ?? .distantPast <= entry.timestamp { moves[key] = entry }
            }
        }

        let copies = Dictionary(
            (archives ?? []).filter { $0.copiedAt >= since && $0.additionalCopyOf == nil && $0.sourceVolumeName == nil }
                .sorted { $0.copiedAt > $1.copiedAt }
                .map { (URL(fileURLWithPath: $0.originalPath).standardizedFileURL.path, $0) },
            uniquingKeysWith: { latest, _ in latest })
        let hasAccess = deps.fda() == .granted
        let roots = items.contains { $0.action == .moveToCloud || isOnlineOnly($0.action) }
            ? CloudRootLocator.roots(env: deps.env) : []

        func cloud(_ url: URL, provider: CloudProvider, batch: UUID? = nil) -> Self {
            let step = batch.map(NextStep.history)
            let moved = batch != nil
            let allowed = (hasAccess || provider != .iCloudDrive)
                && roots.contains { $0.provider == provider && url.path.hasPrefix($0.url.standardizedFileURL.path + "/") }
            guard allowed else {
                return Self("Open \(provider.displayName) and check that this folder is available.",
                            nextStep: step, hasRecordedAction: moved)
            }
            let state = deps.cloudInspect(url, provider)
            switch state.sync {
            case .synced where !state.isUploading:
                return Self("Uploaded to \(provider.displayName). You can remove the local download in Finder.",
                            nextStep: .cloudCopy(url, provider, removeDownload: true, historyBatch: batch),
                            usesSavedEstimate: true, hasRecordedAction: moved)
            case .notDownloaded:
                return Self("Online-only in \(provider.displayName).",
                            nextStep: .cloudCopy(url, provider, removeDownload: false, historyBatch: batch))
            case .missing:
                return Self("The file or folder couldn’t be found in \(provider.displayName).",
                            nextStep: step, hasRecordedAction: moved)
            case .conflict:
                return Self("Resolve the sync conflict in \(provider.displayName) before removing the download.",
                            nextStep: step, hasRecordedAction: moved)
            case .stillSyncing, .synced:
                let message = state.isUploading ? "Upload to \(provider.displayName) is in progress."
                    : "\(provider.displayName) hasn’t confirmed the upload yet."
                return Self(message, nextStep: step, usesSavedEstimate: true, hasRecordedAction: moved)
            }
        }

        var rows: [String: Self] = [:]
        for item in items {
            let path = item.paths.first?.standardizedFileURL
            switch item.action {
            case .archive:
                if let record = path.flatMap({ copies[$0.path] }) {
                    rows[item.id] = archive(record, trashRoot: hasAccess ? deps.env.trash : nil)
                }
            case .cleanup(let id):
                let matches = item.paths.compactMap { trash[id]?[$0.standardizedFileURL.path] }
                let moved = matches.filter {
                    JournalHistory.resolve($0, followUps: followUps[$0.id] ?? []).outcome != .restored
                }
                guard let latest = moved.max(by: { $0.timestamp < $1.timestamp }) else { continue }
                let removed = moved.count {
                    switch JournalHistory.resolve($0, followUps: followUps[$0.id] ?? []).outcome {
                    case .permanentlyDeleted, .skipped(.alreadyGone): true
                    default: hasAccess && trashPathIsGone($0.trashPath, root: deps.env.trash)
                    }
                }
                let prefix = "\(moved.count.formatted()) of \(item.paths.count.formatted()) moved to Trash."
                let detail = removed == moved.count ? " Those items have since left Trash." : " Check Trash, then recheck free space."
                rows[item.id] = Self(prefix + detail, nextStep: .history(latest.batchID))
            case .onlineOnly(let provider):
                if let path { rows[item.id] = cloud(path, provider: provider) }
            case .moveToCloud:
                guard let move = path.flatMap({ moves[$0.path] }) else { continue }
                let outcome = JournalHistory.resolve(move, followUps: followUps[move.id] ?? []).outcome
                guard outcome != .restored else { continue }
                let step = NextStep.history(move.batchID)
                if outcome == .done, let provider = move.provider.flatMap(CloudProvider.init(rawValue:)),
                   let destination = move.destinationPath {
                    rows[item.id] = cloud(URL(fileURLWithPath: destination).standardizedFileURL, provider: provider,
                                          batch: move.batchID)
                } else if outcome == .planned {
                    rows[item.id] = Self("The cloud move hasn’t finished. Check its record in History.", nextStep: step)
                }
            case .keepLocal, .reviewFolder:
                break
            }
        }
        let unavailable = (needsJournal && (loaded == nil || (loaded?.corruptLines ?? 0) > 0))
            || (archives == nil && items.contains { $0.action == .archive })
        return (rows, unavailable ? "Some progress records couldn’t be read. Check again before continuing those steps." : nil)
    }

    private static func isOnlineOnly(_ action: SpacePlanItem.Action) -> Bool {
        if case .onlineOnly = action { return true }
        return false
    }

    private static func archive(_ record: ArchiveRecord, trashRoot: URL?) -> Self {
        let next = NextStep.archive(record.id)
        if record.integrityCheck?.outcome == .mismatch {
            return Self("The archive on \(record.driveName) failed its integrity check. Open its record to review it.",
                        nextStep: next)
        }
        switch record.state {
        case .copying, .sealed, .releasing:
            return Self("The archive on \(record.driveName) was interrupted. Open its record to check it.", nextStep: next)
        case .verified:
            return Self("Verified on \(record.driveName). The original is still on this Mac.",
                        nextStep: next, usesSavedEstimate: true)
        case .inTrash:
            if let trashRoot, trashPathIsGone(record.trashPath, root: trashRoot) {
                return Self("Verified on \(record.driveName). The original has left Trash.", nextStep: next)
            }
            return Self("Verified on \(record.driveName). The original was moved to Trash. Check Trash, then recheck free space.",
                        nextStep: next)
        case .restored:
            return Self("A copy was restored to the Mac. The archive is on \(record.driveName).", nextStep: next)
        }
    }

    private static func trashPathIsGone(_ path: String?, root: URL) -> Bool {
        guard let path, URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
        else { return false }
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }
}
