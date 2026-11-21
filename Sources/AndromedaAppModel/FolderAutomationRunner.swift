import Darwin
import AndromedaCore
import AndromedaOrganize
import Foundation

/// One bounded, synchronous check for a separately authorized automation worker. Its owner schedules checks.
struct FolderAutomationRunner {
    typealias Snapshot = FolderAutomationSettingsStore.Snapshot
    private typealias Handled = FolderAutomationHistory.Handled
    private static let verificationRetryDelay: TimeInterval = 5 * 60

    enum State: Equatable {
        case checked, paused, notAuthorized, busy, settingsUnavailable, leaseUnavailable, historyNeedsReview, stopped
    }

    enum SourceProblem: Equatable {
        case unsupportedRule, unavailableFolder, unsupportedPlan
    }

    enum WatchDepth: Equatable, Sendable {
        case bounded(Int), unlimited
    }

    struct Report: Equatable {
        var state: State
        var copied = 0
        var recovered = 0
        var sourceProblems: [AutomationDirectories.Folder: SourceProblem] = [:]
        var nextCheck: Date?
    }

    private struct Seen {
        let file: FolderAutomationRule.File
        let since: Date
        var retryAfter: Date? = nil

        var readyAt: Date { max(since, file.snapshot.modified).addingTimeInterval(4) }
    }

    private let env: ScanEnvironment
    private let settings: FolderAutomationSettingsStore
    private let journalDirectory: URL
    private let journal: Journal
    private let trasher: any Trasher
    private let history = FolderAutomationHistory()
    private let duplicateFingerprints = AutomationDuplicateFingerprints()
    private var observedRevision: UUID?
    private var seen: [UUID: [String: Seen]] = [:]

    init(env: ScanEnvironment, settings: FolderAutomationSettingsStore, journalDirectory: URL,
         trasher: any Trasher) throws {
        self.env = env
        self.settings = settings
        self.journalDirectory = journalDirectory
        self.journal = try Journal(directory: journalDirectory)
        self.trasher = trasher
    }

    /// The grant must establish worker ownership for this particular revision. A production owner must
    /// coordinate snapshot changes with this same lease. The grant is also checked during copy publication.
    mutating func check(now: Date = Date(), authorizes: (Snapshot) -> Bool,
                        shouldContinue: () -> Bool = { true }) -> Report {
        let started = ContinuousClock.now
        guard shouldContinue() else { return stop(.stopped) }
        let lease: FolderAutomationLease
        do {
            guard let acquired = try FolderAutomationLease.tryAcquire(in: journalDirectory) else {
                return Report(state: .busy, nextCheck: now.addingTimeInterval(1))
            }
            lease = acquired
        } catch {
            return stop(.leaseUnavailable)
        }
        defer { lease.release() }

        let snapshot: Snapshot
        do {
            guard let saved = try settings.load(), authorizes(saved) else { return stop(.notAuthorized) }
            snapshot = saved
        } catch {
            return stop(.settingsUnavailable)
        }
        guard !snapshot.isAutomationPaused else { return stop(.paused) }
        guard shouldContinue() else { return stop(.stopped) }
        if observedRevision != snapshot.revision {
            seen.removeAll()
            observedRevision = snapshot.revision
        }
        let active = snapshot.rules.filter { $0.enabled && !snapshot.pausedSources.contains($0.directories.source) }
        guard !active.isEmpty else { return Report(state: .checked) }

        var stopped = false
        func canContinue() -> Bool {
            if !stopped { stopped = !shouldContinue() || !authorizes(snapshot) }
            return !stopped
        }
        guard canContinue() else { return stop(.stopped) }
        var report = Report(state: .checked, nextCheck: now.addingTimeInterval(30))
        do {
            report.recovered = try settleInterruptedCopies(shouldContinue: canContinue)
        } catch HistoryFailure.stopped {
            return stop(.stopped, report: report)
        } catch {
            return stop(.historyNeedsReview, report: report)
        }
        guard let handled = history.files(in: journal) else { return stop(.historyNeedsReview, report: report) }

        var groups = Dictionary(grouping: active, by: { $0.directories.source })
        for rule in active {
            let source = rule.directories.source
            guard let siblings = groups.removeValue(forKey: source) else { continue }
            guard canContinue() else { return stop(.stopped, report: report) }
            guard siblings.allSatisfy({ Self.supports($0, matchesFinderTags: snapshot.matchesFinderTagsAfterQuit == true) }) else {
                mark(.unsupportedRule, source: source, rules: siblings, report: &report)
                continue
            }
            guard siblings.allSatisfy({
                Self.folderIsUsable($0.directories.source, env: env) && Self.folderIsUsable($0.directories.destination, env: env)
            }) else {
                mark(.unavailableFolder, source: source, rules: siblings, report: &report)
                continue
            }

            let observations = FolderAutomationRule.observe(
                siblings, env: env, now: now, duplicateFingerprints: duplicateFingerprints, requiresVerifiedFinderTags: true,
                excluding: { Handled($0, rule: rule).exists(in: handled) }
            )
            // A missing earlier rule may still take priority. Wait for the entire group to become available.
            guard siblings.allSatisfy({ observations[$0.id] != nil }) else {
                mark(.unavailableFolder, source: source, rules: siblings, report: &report)
                continue
            }
            for sibling in siblings where sibling.copiesMatches {
                guard let observation = observations[sibling.id] else { continue }
                let ready = readyFiles(for: sibling, after: observation, now: now, report: &report)
                guard !ready.isEmpty else { continue }
                let batch = Array(ready.prefix(64))
                let plan = sibling.plan(batch)
                guard sibling.validatesBackgroundCopy(plan, for: batch) else {
                    mark(.unsupportedPlan, source: source, rules: siblings, report: &report)
                    break
                }
                do {
                    guard try settings.load()?.revision == snapshot.revision, canContinue() else {
                        return stop(.stopped, report: report)
                    }
                } catch {
                    return stop(.settingsUnavailable, report: report)
                }
                let id = UUID()
                let results = PlanExecutor(journal: journal, automationEnvironment: env)
                    .apply(plan, batchID: id, shouldContinue: canContinue, batchCopyReceipts: true)
                report.copied += results.filter { $0.outcome == .done }.count
                if results.contains(where: { $0.journalError != nil }) {
                    return stop(.historyNeedsReview, report: report)
                }
                if !canContinue() || results.count != plan.steps.count {
                    // Only this batch can have unrecorded work while we hold the lease.
                    do {
                        try BatchUndo(journal: journal, trasher: trasher).settleInterrupted(batchID: id)
                        guard let remaining = history.interruptedBatchIDs(in: journal), !remaining.contains(id) else {
                            return stop(.historyNeedsReview, report: report)
                        }
                    } catch {
                        return stop(.historyNeedsReview, report: report)
                    }
                    return stop(.stopped, report: report)
                }
                var canAdvance = results.contains { $0.outcome == .done }
                let elapsed = started.duration(to: .now).components
                let finishedAt = now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                let retryAfter = finishedAt.addingTimeInterval(Self.verificationRetryDelay)
                for (file, result) in zip(batch, results) where result.failedCopyVerification {
                    seen[sibling.id]?[file.relativePath]?.retryAfter = retryAfter
                    canAdvance = true
                }
                if ready.count > batch.count, canAdvance {
                    report.nextCheck = now
                }
            }
        }
        return report
    }

    private mutating func readyFiles(for rule: FolderAutomationRule, after observation: FolderAutomationRule.Observation,
                                     now: Date, report: inout Report) -> [FolderAutomationRule.File] {
        let prior = seen[rule.id] ?? [:]
        let items = observation.files.map { file in
            if let previous = prior[file.relativePath], previous.file == file { return previous }
            return Seen(file: file, since: now)
        }
        seen[rule.id] = Dictionary(uniqueKeysWithValues: items.map { ($0.file.relativePath, $0) })
        return items.compactMap { item in
            if let retryAfter = item.retryAfter, retryAfter > now { return nil }
            if rule.copiesOnArrival || item.readyAt <= now { return item.file }
            report.nextCheck = min(report.nextCheck ?? item.readyAt, item.readyAt)
            return nil
        }
    }

    private mutating func stop(_ state: State, report: Report? = nil) -> Report {
        observedRevision = nil
        seen.removeAll()
        var output = report ?? Report(state: state)
        output.state = state
        output.nextCheck = nil
        return output
    }

    private mutating func mark(_ problem: SourceProblem, source: AutomationDirectories.Folder,
                               rules: [FolderAutomationRule], report: inout Report) {
        report.sourceProblems[source] = problem
        for rule in rules { seen[rule.id] = nil }
    }

    private static func folderIsUsable(_ folder: AutomationDirectories.Folder, env: ScanEnvironment) -> Bool {
        guard Self.pathIsEligible(folder, env: env) else { return false }
        let home = SafetyGuard.withoutSystemPathAlias(env.home.standardizedFileURL.path)
        guard let homeIdentity = FileIdentity(path: home), let fd = folder.openCurrent() else { return false }
        defer { close(fd) }
        var info = stat()
        var filesystem = statfs()
        guard fstat(fd, &info) == 0, info.st_dev == homeIdentity.dev,
              fstatfs(fd, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { return false }
        return withUnsafeBytes(of: filesystem.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) == "apfs"
        }
    }

    static func watchableScopes(_ snapshot: Snapshot, env: ScanEnvironment) -> [AutomationDirectories.Folder: WatchDepth] {
        guard snapshot.mode == .afterQuit, !snapshot.isAutomationPaused else { return [:] }
        let groups = backgroundEligibleGroups(for: snapshot.rules, env: env,
                                              matchesFinderTags: snapshot.matchesFinderTagsAfterQuit == true)
        return groups.reduce(into: [:]) { scopes, group in
            let (source, siblings) = group
            guard !snapshot.pausedSources.contains(source), folderIsUsable(source, env: env) else { return }
            let depths = siblings.compactMap(\.watchedDepthLimit)
            scopes[source] = depths.count == siblings.count ? .bounded(depths.max() ?? 0) : .unlimited
        }
    }

    /// Ownership stays with the same engine if a folder temporarily becomes unreadable or disappears.
    static func backgroundEligibleSources(for rules: [FolderAutomationRule], env: ScanEnvironment, matchesFinderTags: Bool)
        -> Set<AutomationDirectories.Folder> {
        Set(backgroundEligibleGroups(for: rules, env: env, matchesFinderTags: matchesFinderTags).keys)
    }

    private static func backgroundEligibleGroups(for rules: [FolderAutomationRule], env: ScanEnvironment, matchesFinderTags: Bool)
        -> [AutomationDirectories.Folder: [FolderAutomationRule]] {
        let groups = Dictionary(grouping: rules.filter(\.enabled), by: { $0.directories.source })
        return groups.filter { source, siblings in
            pathIsEligible(source, env: env) && siblings.allSatisfy { rule in
                supports(rule, matchesFinderTags: matchesFinderTags) && pathIsEligible(rule.directories.destination, env: env)
            }
        }
    }

    private static func pathIsEligible(_ folder: AutomationDirectories.Folder, env: ScanEnvironment) -> Bool {
        let home = SafetyGuard.withoutSystemPathAlias(env.home.standardizedFileURL.path)
        let prefix = home + "/"
        guard folder.path.hasPrefix(prefix) else { return false }
        let components = folder.path.dropFirst(prefix.count).split(separator: "/")
        guard let first = components.first, !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        return !restrictedHomeFolders.contains(NamingRules.key(String(first)))
    }

    private static let restrictedHomeFolders: Set<String> = [
        "applications", "desktop", "documents", "downloads", "library", "movies", "music", "pictures", "public"
    ]

    private static func supports(_ rule: FolderAutomationRule, matchesFinderTags: Bool) -> Bool {
        guard rule.copiesMatches || rule.ignoresMatches, rule.backupFolders.isEmpty, rule.subfolderTemplate == nil,
              rule.folderStructure != .immediateParent, rule.directories.sourceBoundary == nil,
              rule.directories.allowsDestinationSubfolders == rule.preservesSubfolderStructure,
              !rule.notifiesOnCompletion, matchesFinderTags || rule.excludedFinderTags.isEmpty else { return false }
        return supports(rule.conditionGroup, matchesFinderTags: matchesFinderTags)
    }

    private static func supports(_ group: FolderAutomationRule.ConditionGroup, matchesFinderTags: Bool) -> Bool {
        let ageUsesMetadata = (group.minimumAgeDays != nil || group.maximumAgeDays != nil) && group.ageBasis != .modified
        return !ageUsesMetadata && (matchesFinderTags || group.finderTags.isEmpty) && group.contentsContains == nil
            && group.groups.allSatisfy { supports($0, matchesFinderTags: matchesFinderTags) }
    }

    private enum HistoryFailure: Error { case unsafe, stopped }

    private func settleInterruptedCopies(shouldContinue: () -> Bool) throws -> Int {
        guard let interrupted = history.interruptedBatchIDs(in: journal) else { throw HistoryFailure.unsafe }
        guard !interrupted.isEmpty else { return 0 }
        let ids = interrupted.sorted { $0.uuidString < $1.uuidString }
        for id in ids {
            let batch = try journal.load(batchID: id)
            let originals = batch.entries.filter { $0.relatesTo == nil }
            guard batch.corruptLines == 0, let first = originals.first?.automationDirectories,
                  originals.allSatisfy({ canSettleCopy($0, sameRootsAs: first) }) else {
                throw HistoryFailure.unsafe
            }
        }
        let undo = BatchUndo(journal: journal, trasher: trasher)
        for id in ids {
            guard shouldContinue() else { throw HistoryFailure.stopped }
            try undo.settleInterrupted(batchID: id)
        }
        guard let stillInterrupted = history.interruptedBatchIDs(in: journal), stillInterrupted.isEmpty else {
            throw HistoryFailure.unsafe
        }
        return ids.count
    }

    private func canSettleCopy(_ entry: JournalEntry, sameRootsAs batch: AutomationDirectories) -> Bool {
        guard entry.catalogEntryID == OrganizeCatalogID.automation, entry.resolvedAction == .copy,
              entry.requiredCopyEntryID == nil, entry.volumeUUID == nil, entry.provider == nil,
              let directories = entry.automationDirectories, directories.destination == batch.destination,
              let from = entry.originalPath, let to = entry.destinationPath,
              Self.folderIsUsable(directories.source, env: env), Self.folderIsUsable(directories.destination, env: env),
              let sourceParts = Self.components(from, below: directories.source.path), sourceParts.count == 1,
              let targetParts = Self.components(to, below: directories.destination.path)
        else { return false }
        let root = directories.sourceBoundary ?? directories.source
        guard root == (batch.sourceBoundary ?? batch.source) else { return false }
        if let boundary = directories.sourceBoundary {
            guard Self.folderIsUsable(boundary, env: env),
                  let relativeParent = Self.components(directories.source.path, below: boundary.path),
                  relativeParent.allSatisfy({ !$0.hasPrefix(".") }) else { return false }
            if directories.allowsDestinationSubfolders { return targetParts.dropLast().elementsEqual(relativeParent) }
        }
        return !directories.allowsDestinationSubfolders && targetParts.count == 1
    }

    private static func components(_ path: String, below root: String) -> [Substring]? {
        let prefix = root + "/"
        guard path.hasPrefix(prefix), path.utf8.count < PATH_MAX else { return nil }
        let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) })
        else { return nil }
        return parts
    }
}
