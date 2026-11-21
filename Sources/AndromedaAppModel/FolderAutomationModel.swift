import AndromedaCore
import AndromedaOrganize
import Foundation
import Observation

@MainActor @Observable
public final class FolderAutomationModel {
    public private(set) var rules: [FolderAutomationRule] = []
    public private(set) var status: [UUID: String] = [:]
    public private(set) var settingsProblem: String?
    public private(set) var isAutomationPaused: Bool
    public var available: Bool { journal != nil && settingsProblem == nil }
    public var runsAfterQuit: Bool { snapshot?.mode == .afterQuit }
    public var hasAfterQuitEligibleRules: Bool { !eligibleBackgroundSources.isEmpty }
    public var backgroundTagMatchingNeedsOptIn: Bool {
        runsAfterQuit && snapshot?.matchesFinderTagsAfterQuit != true
            && eligibleBackgroundSources != FolderAutomationRunner.backgroundEligibleSources(
                for: rules, env: env, matchesFinderTags: true)
    }

    private struct Seen {
        let file: FolderAutomationRule.File
        let since: Date
        let waitsForStability: Bool

        var readyAt: Date { waitsForStability ? max(since, file.snapshot.modified).addingTimeInterval(4) : since }
    }

    private typealias Handled = FolderAutomationHistory.Handled

    private let env: ScanEnvironment
    private let journal: Journal?
    private let defaults: UserDefaults
    private let settings: FolderAutomationSettingsStore?
    private var snapshot: FolderAutomationSettingsStore.Snapshot?
    private var eligibleBackgroundSources: Set<AutomationDirectories.Folder> = []
    private let notifications: (any StorageNotificationDelivery)?
    private let duplicateFingerprints = AutomationDuplicateFingerprints()
    private let recognitionCache = AutomationRecognitionCache()
    private let handledHistory = FolderAutomationHistory()
    private var pausedSources: Set<AutomationDirectories.Folder> = []
    private struct ReplayRun {
        let rule: FolderAutomationRule
        let files: [FolderAutomationRule.File]
    }
    private struct ManualRun {
        let id = UUID()
        let source: AutomationDirectories.Folder
        var replay: ReplayRun?
        var observedAt: Date?
    }
    private var manualRun: ManualRun?
    @ObservationIgnored private var pendingReplayReview: UUID?
    @ObservationIgnored private var seen: [UUID: [String: Seen]] = [:]
    @ObservationIgnored private var ignored: [UUID: Set<Handled>] = [:]
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var scheduledCheck: ContinuousClock.Instant?
    @ObservationIgnored private var leaseRetryAt: ContinuousClock.Instant?
    @ObservationIgnored private var wakePending = false
    @ObservationIgnored var watchFolderChanges = FileChangeWatch.startFolder
    private struct Watch {
        let folder: AutomationDirectories.Folder
        let token: UUID
        let maximumDepth: Int?
        let stream: AnyObject?
    }
    @ObservationIgnored private var watches: [String: Watch] = [:]
    private struct PendingFile: Hashable {
        let ruleID: UUID
        let relativePath: String
    }
    private struct PendingWatch {
        let fileID: UInt64
        let token: UUID
        let stream: AnyObject
    }
    @ObservationIgnored private var pendingFileWatches: [PendingFile: PendingWatch] = [:]
    @ObservationIgnored private var activeRun: (source: AutomationDirectories.Folder, manualID: UUID?, control: ScanControl)?
    @ObservationIgnored private var activeLease: FolderAutomationLease?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored weak var app: AppModel?

    init(env: ScanEnvironment, journal: Journal?, defaults: UserDefaults,
         notifications: (any StorageNotificationDelivery)?) {
        self.env = env
        self.journal = journal
        self.defaults = defaults
        settings = journal.map { FolderAutomationSettingsStore(journalDirectory: $0.directory) }
        self.notifications = notifications
        let saved = FolderAutomationLegacySettings.load(from: defaults)
        rules = saved.rules
        pausedSources = saved.pausedSources
        isAutomationPaused = saved.isAutomationPaused
        settingsProblem = saved.problem
        updateBackgroundEligibility()
        do {
            if let persisted = try settings?.load() { adopt(persisted) }
        } catch {
            settingsProblem = Self.snapshotProblem
        }
    }

    public func runsInBackground(_ source: AutomationDirectories.Folder) -> Bool {
        runsAfterQuit && eligibleBackgroundSources.contains(source)
    }

    /// Call after macOS approves the worker to enable, or after the worker is stopped to return ownership to this app.
    @discardableResult
    public func setRunsAfterQuit(_ enabled: Bool) -> String? {
        guard available || (!enabled && runsAfterQuit && journal != nil) else { return Self.settingsUnavailable }
        if enabled && !runsAfterQuit && !hasAfterQuitEligibleRules {
            return "No enabled folders have rules that Andromeda can run after quitting."
        }
        return withSettingsLease(reuseActive: false) { store, current in
            guard enabled != (current?.mode == .afterQuit) else { return nil }
            let legacyPause = defaults.object(forKey: FolderAutomationLegacySettings.pausedKey)
            var updated = try current ?? FolderAutomationSettingsStore.importLegacy(from: defaults)
            guard !enabled || !FolderAutomationRunner.backgroundEligibleSources(
                for: updated.rules, env: env, matchesFinderTags: true).isEmpty else {
                return "No enabled folders have rules that Andromeda can run after quitting."
            }
            updated.mode = enabled ? .afterQuit : .whileAppIsOpen
            updated.matchesFinderTagsAfterQuit = enabled ? true : nil
            guard FolderAutomationLegacySettings.fenceRollback(in: defaults) else {
                if current == nil { restoreLegacyPause(legacyPause) }
                return "Andromeda couldn’t pause automation in older builds."
            }
            do {
                adopt(try store.save(updated, replacing: current?.revision))
                return nil
            } catch {
                // A write can fail after the rename. Check the authoritative mode before releasing the fence.
                let persisted = try store.load()
                if let persisted {
                    adopt(persisted)
                    if persisted.mode == updated.mode { return nil }
                } else if current == nil {
                    restoreLegacyPause(legacyPause)
                }
                return "Andromeda couldn’t change where folder automation runs. Try again."
            }
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        updateSchedule()
    }

    public func add(
        source: URL, destination: URL?, backup: URL? = nil, additionalBackups: [URL] = [], pattern: String,
        fileExtension: String? = nil,
        minimumBytes: Int64? = nil, maximumBytes: Int64? = nil,
        minimumAgeDays: Int? = nil, maximumAgeDays: Int? = nil, ageBasis: FolderAutomationRule.AgeBasis = .modified,
        fileKind: Kind? = nil, finderTag: String? = nil,
        excludedFinderTag: String? = nil, finderTags: [String] = [], excludedFinderTags: [String] = [],
        matchMode: FolderAutomationRule.MatchMode = .all, contentsContains: String? = nil, recognizesText: Bool = false,
        conditionGroups: [FolderAutomationRule.ConditionGroup] = [],
        renamePrefix: String? = nil,
        renameTemplate: AutomationFilenameTemplate? = nil, subfolderTemplate: AutomationSubfolderTemplate? = nil,
        ignoresMatches: Bool = false, copiesMatches: Bool = false, copyFinderTags: [String] = [],
        copyTagTemplates: [AutomationFinderTagTemplate] = [], removedCopyTags: [String] = [],
        skipsIdenticalCopies: Bool = false, copiesOnArrival: Bool = false,
        includesSubfolders: Bool = false, maximumSubfolderDepth: Int? = nil,
        preservesSubfolderStructure: Bool = false, folderStructure: FolderAutomationRule.FolderStructure? = nil,
        includedSubfolderPattern: String? = nil, excludedSubfolderPattern: String? = nil,
        collisionPolicy: FolderAutomationRule.CollisionPolicy = .leaveInPlace,
        numbersBackupConflicts: Bool = false,
        notifiesOnCompletion: Bool = false,
        editing id: UUID? = nil
    ) async -> String? {
        guard available else { return "Automation needs a writable History and readable settings." }
        guard !copiesOnArrival || copiesMatches else { return "Copying on arrival requires Copy to Folder." }
        guard FolderAutomationRule.isValidRenamePrefix(renamePrefix) else {
            return "Enter a filename prefix without a leading dot, slashes, colons, or control characters."
        }
        guard FolderAutomationRule.isValidFileExtension(fileExtension) else {
            return "Enter a single file extension, such as pdf."
        }
        guard FolderAutomationRule.isValidFinderTag(finderTag),
              FolderAutomationRule.isValidFinderTag(excludedFinderTag),
              (finderTags + excludedFinderTags + copyFinderTags + removedCopyTags).allSatisfy({ FolderAutomationRule.isValidFinderTag($0) }) else {
            return "Enter Finder tag names without line breaks or control characters."
        }
        let original = id.flatMap { key in rules.first { $0.id == key } }
        if id != nil, original == nil { return "The rule was removed." }
        let ruleID = id ?? UUID()
        let env = env
        let rule = await BackgroundWork.runNonThrowing("andromeda.organize.automation-rule") {
            FolderAutomationRule(id: ruleID, source: source, destination: destination, backup: backup,
                                 additionalBackups: additionalBackups, pattern: pattern,
                                 fileExtension: fileExtension,
                                 minimumBytes: minimumBytes, maximumBytes: maximumBytes,
                                 minimumAgeDays: minimumAgeDays, maximumAgeDays: maximumAgeDays, ageBasis: ageBasis,
                                 fileKind: fileKind, finderTag: finderTag,
                                 excludedFinderTag: excludedFinderTag, finderTags: finderTags, excludedFinderTags: excludedFinderTags,
                                 matchMode: matchMode, contentsContains: contentsContains, recognizesText: recognizesText,
                                 conditionGroups: conditionGroups,
                                 renamePrefix: renamePrefix, renameTemplate: renameTemplate, subfolderTemplate: subfolderTemplate,
                                 ignoresMatches: ignoresMatches, copiesMatches: copiesMatches, copyFinderTags: copyFinderTags,
                                 copyTagTemplates: copyTagTemplates, removedCopyTags: removedCopyTags,
                                 skipsIdenticalCopies: skipsIdenticalCopies, copiesOnArrival: copiesOnArrival,
                                 collisionPolicy: collisionPolicy, numbersBackupConflicts: numbersBackupConflicts,
                                 includesSubfolders: includesSubfolders,
                                 maximumSubfolderDepth: maximumSubfolderDepth,
                                 preservesSubfolderStructure: preservesSubfolderStructure, folderStructure: folderStructure,
                                 includedSubfolderPattern: includedSubfolderPattern, excludedSubfolderPattern: excludedSubfolderPattern,
                                 notifiesOnCompletion: notifiesOnCompletion, enabled: original?.enabled ?? true, env: env)
        }
        guard let rule else {
            if backup != nil || !additionalBackups.isEmpty {
                return "Choose separate local backup folders in your home folder. Keep backup, watched, and filing folders separate."
            }
            if preservesSubfolderStructure || folderStructure.map({ $0 != .flat }) == true {
                return "Choose two local folders in your home folder with separate paths, and enter at least one valid condition. Neither folder can be inside the other."
            }
            if ignoresMatches || subfolderTemplate != nil { return "Choose an approved local folder and enter at least one valid condition." }
            return destination == nil
                ? "Choose a local folder in your home folder, a filename prefix or template, and at least one valid condition."
                : "Choose two different local folders in your home folder and enter at least one valid condition."
        }
        if let id {
            guard let index = rules.firstIndex(where: { $0.id == id }), rules[index] == original else {
                return "The rule changed. Reopen it to edit the latest version."
            }
            var updated = rules
            updated[index] = rule
            return save(updated)
        }
        return save(rules + [rule])
    }

    public struct Preview: Sendable {
        public struct FocusedFile: Sendable {
            public let relativePath: String
            public let match: FolderAutomationRule.FileMatch
            public let conditionChecks: [FolderAutomationRule.ConditionCheck]
        }

        public let focusedFile: FocusedFile?
        public let names: [String]
        public let renamedNames: [String: String]
        public let destinationPaths: [String: String]
        public let backupCopyPaths: [String: [String]]
        public var backupPaths: [String: String] { backupCopyPaths.compactMapValues(\.first) }
        public let copyFinderTags: [String]
        public let renderedCopyTags: [String: [String]]
        public let removedCopyTags: [String]
        public let preservesSubfolderStructure: Bool
        public let matches: Int
        public let earlierRuleMatches: Int
        public let earlierRuleExamples: [FolderAutomationRule.EarlierRuleMatch]
        public let conflicts: Int
        public let backupConflicts: Int
        public let identicalCopies: Int
        public let namesTooLong: Int
        public let namesUnavailable: Int
        public let tagsUnavailable: Int
        public let destinationsUnavailable: Int
    }

    public func preview(
        source: URL, destination: URL?, backup: URL? = nil, additionalBackups: [URL] = [],
        pattern: String, fileExtension: String? = nil, minimumBytes: Int64?, maximumBytes: Int64? = nil,
        minimumAgeDays: Int?, maximumAgeDays: Int? = nil, ageBasis: FolderAutomationRule.AgeBasis = .modified,
        fileKind: Kind? = nil, finderTag: String? = nil,
        excludedFinderTag: String? = nil, finderTags: [String] = [], excludedFinderTags: [String] = [],
        matchMode: FolderAutomationRule.MatchMode = .all, contentsContains: String? = nil, recognizesText: Bool = false,
        conditionGroups: [FolderAutomationRule.ConditionGroup] = [],
        renamePrefix: String? = nil, renameTemplate: AutomationFilenameTemplate? = nil,
        subfolderTemplate: AutomationSubfolderTemplate? = nil, ignoresMatches: Bool = false, copiesMatches: Bool = false,
        copyFinderTags: [String] = [], copyTagTemplates: [AutomationFinderTagTemplate] = [], removedCopyTags: [String] = [],
        skipsIdenticalCopies: Bool = false, copiesOnArrival: Bool = false,
        includesSubfolders: Bool = false, maximumSubfolderDepth: Int? = nil,
        preservesSubfolderStructure: Bool = false, folderStructure: FolderAutomationRule.FolderStructure? = nil,
        includedSubfolderPattern: String? = nil, excludedSubfolderPattern: String? = nil,
        collisionPolicy: FolderAutomationRule.CollisionPolicy = .leaveInPlace, numbersBackupConflicts: Bool = false,
        editing id: UUID?, focusedFile: URL? = nil, focusedFileIdentity: FileIdentity? = nil
    ) async -> Preview? {
        guard let journal else { return nil }
        let env = env, rules = rules, revision = revision, handledHistory = handledHistory
        let recognitionCache = recognitionCache
        let result = await BackgroundWork.runNonThrowing("andromeda.organize.automation-preview") { () -> Preview? in
            guard let draft = FolderAutomationRule(id: id ?? UUID(), source: source, destination: destination, backup: backup,
                                                   additionalBackups: additionalBackups, pattern: pattern,
                                                   fileExtension: fileExtension,
                                                   minimumBytes: minimumBytes, maximumBytes: maximumBytes,
                                                   minimumAgeDays: minimumAgeDays, maximumAgeDays: maximumAgeDays, ageBasis: ageBasis,
                                                   fileKind: fileKind, finderTag: finderTag,
                                                   excludedFinderTag: excludedFinderTag, finderTags: finderTags,
                                                   excludedFinderTags: excludedFinderTags, matchMode: matchMode,
                                                   contentsContains: contentsContains, recognizesText: recognizesText,
                                                   conditionGroups: conditionGroups,
                                                   renamePrefix: renamePrefix,
                                                   renameTemplate: renameTemplate, subfolderTemplate: subfolderTemplate,
                                                   ignoresMatches: ignoresMatches, copiesMatches: copiesMatches,
                                                   copyFinderTags: copyFinderTags, copyTagTemplates: copyTagTemplates,
                                                   removedCopyTags: removedCopyTags, skipsIdenticalCopies: skipsIdenticalCopies,
                                                   copiesOnArrival: copiesOnArrival,
                                                   collisionPolicy: collisionPolicy, numbersBackupConflicts: numbersBackupConflicts,
                                                   includesSubfolders: includesSubfolders,
                                                   maximumSubfolderDepth: maximumSubfolderDepth,
                                                   preservesSubfolderStructure: preservesSubfolderStructure, folderStructure: folderStructure,
                                                   includedSubfolderPattern: includedSubfolderPattern,
                                                   excludedSubfolderPattern: excludedSubfolderPattern, env: env) else { return nil }
            var ordered = rules
            if let id {
                guard let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
                ordered[index] = draft
            } else {
                ordered.append(draft)
            }
            guard FolderAutomationSettingsStore.configurationProblem(ordered) == nil else { return nil }
            let siblings = ordered.filter { $0.enabled && $0.directories.source == draft.directories.source }
            let relativePath: String?
            if let focusedFile {
                let path = SafetyGuard.withoutSystemPathAlias(focusedFile.standardizedFileURL.path)
                let prefix = draft.directories.source.path + "/"
                guard focusedFile.isFileURL, path.hasPrefix(prefix), path.count > prefix.count else { return nil }
                relativePath = String(path.dropFirst(prefix.count))
            } else {
                relativePath = nil
            }
            guard let handled = focusedFile != nil || ignoresMatches ? [] : handledHistory.files(in: journal) else { return nil }
            let observations = FolderAutomationRule.observe(
                siblings, env: env, now: Date(), recognitionCache: recognitionCache,
                trackingEarlierMatchesFor: draft.id, previewingRelativePath: relativePath, previewingIdentity: focusedFileIdentity,
                excluding: { Handled($0, rule: draft).exists(in: handled) })
            guard let observation = observations[draft.id] else { return nil }
            let focused = relativePath.flatMap { path in
                observation.fileMatch.map {
                    Preview.FocusedFile(relativePath: path, match: $0, conditionChecks: observation.conditionChecks)
                }
            }
            let examples = observation.files.prefix(5)
            let renamedNames = Dictionary(uniqueKeysWithValues: examples.filter { $0.name != $0.destinationName }
                .map { ($0.relativePath, $0.destinationName) })
            let destinationPaths = Dictionary(uniqueKeysWithValues: examples.compactMap { file -> (String, String)? in
                if draft.backupFolder != nil {
                    return (file.relativePath, draft.directories.destination.url.appendingPathComponent(file.destinationRelativePath).path)
                }
                return file.relativePath == file.destinationRelativePath ? nil : (file.relativePath, file.destinationRelativePath)
            })
            let folders = draft.backupFolders
            let backupCopyPaths: [String: [String]] = folders.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: examples.map { file in
                let paths = zip(folders, file.backupRelativePaths).map { folder, path in
                    folder.url.appendingPathComponent(path).path
                }
                return (file.relativePath, paths)
            })
            let renderedTags = draft.copyTagTemplates.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: examples.map {
                ($0.relativePath, $0.renderedCopyTags)
            })
            return Preview(focusedFile: focused, names: ignoresMatches ? observation.ignoredExamples : examples.map(\.relativePath),
                           renamedNames: renamedNames, destinationPaths: destinationPaths, backupCopyPaths: backupCopyPaths,
                           copyFinderTags: draft.copyFinderTags, renderedCopyTags: renderedTags, removedCopyTags: draft.removedCopyTags,
                           preservesSubfolderStructure: draft.preservesSubfolderStructure,
                           matches: observation.ignoredCount + observation.files.count + observation.conflicts + observation.namesTooLong
                               + observation.namesUnavailable + observation.destinationsUnavailable + observation.identicalCopies
                               + observation.backupConflicts + observation.tagsUnavailable,
                           earlierRuleMatches: observation.earlierRuleMatches, earlierRuleExamples: observation.earlierRuleExamples,
                           conflicts: observation.conflicts, backupConflicts: observation.backupConflicts,
                           identicalCopies: observation.identicalCopies,
                           namesTooLong: observation.namesTooLong,
                           namesUnavailable: observation.namesUnavailable, tagsUnavailable: observation.tagsUnavailable,
                           destinationsUnavailable: observation.destinationsUnavailable)
        }
        return revision == self.revision ? result : nil
    }

    public func setEnabled(_ enabled: Bool, id: UUID) -> String? {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return nil }
        var updated = rules
        updated[index].enabled = enabled
        return save(updated)
    }

    public func isPaused(_ source: AutomationDirectories.Folder) -> Bool { pausedSources.contains(source) }

    @discardableResult
    public func setAutomationPaused(_ paused: Bool) -> String? {
        guard available else { return Self.settingsUnavailable }
        guard isAutomationPaused != paused else { return nil }
        if let problem = persist(rules: rules, pausedSources: pausedSources, isPaused: paused) { return problem }
        isAutomationPaused = paused
        revision += 1
        manualRun = nil
        activeRun?.control.cancel()
        seen.removeAll()
        ignored.removeAll()
        status.removeAll()
        updateSchedule()
        return nil
    }

    public func isRunningOnce(_ source: AutomationDirectories.Folder) -> Bool { manualRun?.source == source }

    public func isReapplying(_ ruleID: UUID) -> Bool { manualRun?.replay?.rule.id == ruleID }

    public func canRunOnce(_ source: AutomationDirectories.Folder) -> Bool {
        available && !isAutomationPaused && !runsInBackground(source) && app?.hasCompletedOnboarding == true && manualRun == nil
            && rules.contains { $0.enabled && $0.directories.source == source }
    }

    public func runOnce(_ source: AutomationDirectories.Folder) {
        guard canRunOnce(source) else { return }
        resetObservations(for: source)
        manualRun = ManualRun(source: source)
        updateSchedule()
    }

    public struct ReplayCandidate: Identifiable, Sendable {
        public var id: String { file.relativePath }
        public let source: URL
        public let destination: URL
        public let addedTags: [String]
        public let removedTags: [String]
        fileprivate let file: FolderAutomationRule.File
    }

    public struct ReplayReview: Sendable {
        public var ruleID: UUID { rule.id }
        public let candidates: [ReplayCandidate]
        public let totalCandidates: Int
        fileprivate let id: UUID
        fileprivate let rule: FolderAutomationRule
        fileprivate let revision: Int
    }

    public func canReviewReplay(ruleID: UUID) -> Bool {
        guard let rule = rules.first(where: { $0.id == ruleID }), rule.enabled, rule.copiesMatches else { return false }
        let source = rule.directories.source
        return isPaused(source) && canRunOnce(source)
    }

    public func reviewReplay(ruleID: UUID, matching query: String = "") async -> ReplayReview? {
        guard canReviewReplay(ruleID: ruleID), let rule = rules.first(where: { $0.id == ruleID }) else { return nil }
        let id = UUID(), revision = revision
        pendingReplayReview = id
        guard let files = await replayFiles(for: rule, now: Date()), !Task.isCancelled,
              pendingReplayReview == id, self.revision == revision, canReviewReplay(ruleID: ruleID) else { return nil }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = term.isEmpty ? files : files.filter { $0.relativePath.localizedStandardContains(term) }
        let candidates = matching.prefix(200).map { file in
            ReplayCandidate(source: rule.directories.source.url.appendingPathComponent(file.relativePath),
                            destination: rule.directories.destination.url.appendingPathComponent(file.destinationRelativePath),
                            addedTags: file.renderedCopyTags, removedTags: rule.removedCopyTags, file: file)
        }
        return ReplayReview(candidates: candidates, totalCandidates: matching.count, id: id, rule: rule, revision: revision)
    }

    public func reapply(_ review: ReplayReview, selectedIDs: Set<String>) -> Bool {
        guard !selectedIDs.isEmpty, pendingReplayReview == review.id, revision == review.revision,
              canReviewReplay(ruleID: review.ruleID), rules.contains(review.rule) else { return false }
        let files = review.candidates.filter { selectedIDs.contains($0.id) }.map(\.file)
        guard files.count == selectedIDs.count else { return false }
        pendingReplayReview = nil
        status[review.ruleID] = nil
        manualRun = ManualRun(source: review.rule.directories.source, replay: ReplayRun(rule: review.rule, files: files))
        updateSchedule()
        return true
    }

    private func replayFiles(for rule: FolderAutomationRule, now: Date) async -> [FolderAutomationRule.File]? {
        guard let journal else { return nil }
        let siblings = rules.filter { $0.enabled && $0.directories.source == rule.directories.source }
        let env = env, handledHistory = handledHistory
        let recognitionCache = recognitionCache, duplicateFingerprints = duplicateFingerprints
        return await BackgroundWork.runNonThrowing("andromeda.organize.automation-reapply-review") {
            guard let handled = handledHistory.files(in: journal) else { return nil }
            return FolderAutomationRule.observe(
                siblings, env: env, now: now, duplicateFingerprints: duplicateFingerprints,
                recognitionCache: recognitionCache,
                excluding: { !Handled($0, rule: rule).exists(in: handled) }
            )[rule.id]?.files
        }
    }

    public func cancelRunOnce(_ source: AutomationDirectories.Folder) {
        guard let manualRun, manualRun.source == source else { return }
        self.manualRun = nil
        if activeRun?.manualID == manualRun.id { activeRun?.control.cancel() }
        if let replay = manualRun.replay {
            status[replay.rule.id] = "Copy reapply cancelled."
        } else {
            resetObservations(for: source)
            for rule in rules where rule.enabled && rule.directories.source == source {
                status[rule.id] = "One-time run cancelled."
            }
        }
        updateSchedule()
    }

    private func resetObservations(for source: AutomationDirectories.Folder) {
        for rule in rules where rule.directories.source == source {
            seen[rule.id] = nil
            ignored[rule.id] = nil
            status[rule.id] = nil
        }
    }

    public func setPaused(_ paused: Bool, source: AutomationDirectories.Folder) -> String? {
        guard available else { return Self.settingsUnavailable }
        guard paused != isPaused(source) else { return nil }
        let siblings = rules.filter { $0.directories.source == source }
        guard !siblings.isEmpty else { return nil }
        var updated = pausedSources
        if paused { updated.insert(source) } else { updated.remove(source) }
        if let problem = persist(rules: rules, pausedSources: updated, isPaused: isAutomationPaused) { return problem }
        pausedSources = updated
        revision += 1
        if isRunningOnce(source) { manualRun = nil }
        if activeRun?.source == source { activeRun?.control.cancel() }
        resetObservations(for: source)
        updateSchedule()
        return nil
    }

    public func remove(id: UUID) -> String? { save(rules.filter { $0.id != id }) }

    @discardableResult
    public func duplicate(id: UUID) -> Result<FolderAutomationRule, RuleDuplicationError> {
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            return .failure(RuleDuplicationError(message: "The rule was removed."))
        }
        let copy = rules[index].disabledCopy()
        var updated = rules
        updated.insert(copy, at: index + 1)
        if let problem = save(updated) { return .failure(RuleDuplicationError(message: problem)) }
        return .success(copy)
    }

    public struct RuleDuplicationError: Error {
        public let message: String
    }

    public func canMove(id: UUID, earlier: Bool) -> Bool { adjacentRule(id: id, earlier: earlier) != nil }

    public func move(id: UUID, earlier: Bool) -> String? {
        guard let pair = adjacentRule(id: id, earlier: earlier) else { return nil }
        var updated = rules
        updated.swapAt(pair.0, pair.1)
        return save(updated)
    }

    private func adjacentRule(id: UUID, earlier: Bool) -> (Int, Int)? {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return nil }
        let folder = NamingRules.key(rules[index].directories.source.path)
        let siblings = rules.indices.filter { NamingRules.key(rules[$0].directories.source.path) == folder }
        guard let position = siblings.firstIndex(of: index) else { return nil }
        let target = position + (earlier ? -1 : 1)
        return siblings.indices.contains(target) ? (index, siblings[target]) : nil
    }

    private func save(_ updated: [FolderAutomationRule]) -> String? {
        guard available else { return Self.settingsUnavailable }
        if let problem = FolderAutomationSettingsStore.configurationProblem(updated) { return problem }
        let remainingPauses = pausedSources.intersection(updated.map(\.directories.source))
        if let problem = persist(rules: updated, pausedSources: remainingPauses, isPaused: isAutomationPaused) { return problem }
        pausedSources = remainingPauses
        let enabled = updated.filter(\.enabled)
        let enabledRulesChanged = enabled != rules.filter(\.enabled)
        rules = updated
        updateBackgroundEligibility()
        guard enabledRulesChanged else { return nil }
        revision += 1
        activeRun?.control.cancel()
        manualRun = nil
        let activeIDs = Set(enabled.map(\.id))
        seen = [:]
        ignored = [:]
        status = status.filter { activeIDs.contains($0.key) }
        updateSchedule()
        return nil
    }

    private static let settingsUnavailable = "Automation needs a writable History and readable settings."
    private static let snapshotProblem = "Saved folder automation settings couldn’t be read."

    private func updateBackgroundEligibility() {
        eligibleBackgroundSources = FolderAutomationRunner.backgroundEligibleSources(
            for: rules, env: env, matchesFinderTags: !runsAfterQuit || snapshot?.matchesFinderTagsAfterQuit == true)
    }

    private func adopt(_ persisted: FolderAutomationSettingsStore.Snapshot) {
        snapshot = persisted
        rules = persisted.rules
        pausedSources = persisted.pausedSources
        isAutomationPaused = persisted.isAutomationPaused
        settingsProblem = persisted.mode == .afterQuit && !defaults.bool(forKey: FolderAutomationLegacySettings.pausedKey)
            ? "Automation is suspended because older Andromeda builds aren’t paused."
            : nil
        updateBackgroundEligibility()
        invalidatePendingAutomation()
    }

    private func invalidatePendingAutomation() {
        revision += 1
        activeRun?.control.cancel()
        manualRun = nil
        seen.removeAll()
        ignored.removeAll()
        status.removeAll()
        updateSchedule()
    }

    private func suspendSettings() {
        settingsProblem = Self.snapshotProblem
        invalidatePendingAutomation()
    }

    private func restoreLegacyPause(_ previous: Any?) {
        if let previous { defaults.set(previous, forKey: FolderAutomationLegacySettings.pausedKey) }
        else { defaults.removeObject(forKey: FolderAutomationLegacySettings.pausedKey) }
        _ = defaults.synchronize()
    }

    private func withSettingsLease(reuseActive: Bool = true,
                                   _ action: (FolderAutomationSettingsStore, FolderAutomationSettingsStore.Snapshot?) throws -> String?) -> String? {
        guard let settings, let journal else { return Self.settingsUnavailable }
        let borrowed = reuseActive ? activeLease : nil
        let lease: FolderAutomationLease
        do {
            guard let held = try borrowed ?? FolderAutomationLease.tryAcquire(in: journal.directory) else {
                return "Folder automation is working. Try again in a moment."
            }
            lease = held
        } catch {
            return "Andromeda couldn’t coordinate access to folder automation settings."
        }
        defer { if borrowed == nil { lease.release() } }

        do {
            let current = try settings.load()
            guard current?.revision == snapshot?.revision else {
                if let current { adopt(current) } else { suspendSettings() }
                return "Folder automation settings changed. Review them and try again."
            }
            return try action(settings, current)
        } catch {
            suspendSettings()
            return Self.snapshotProblem
        }
    }

    private func persist(rules updated: [FolderAutomationRule], pausedSources sources: Set<AutomationDirectories.Folder>,
                         isPaused paused: Bool) -> String? {
        withSettingsLease { store, current in
            if var updatedSnapshot = current {
                updatedSnapshot.rules = updated
                updatedSnapshot.pausedSources = sources
                updatedSnapshot.isAutomationPaused = paused
                do {
                    snapshot = try store.save(updatedSnapshot, replacing: current?.revision)
                } catch {
                    guard let persisted = try store.load() else { throw FolderAutomationSettingsStore.Failure.invalidSnapshot }
                    if persisted.rules == updated && persisted.pausedSources == sources
                        && persisted.isAutomationPaused == paused && persisted.mode == updatedSnapshot.mode {
                        snapshot = persisted
                    } else {
                        if persisted.revision != snapshot?.revision { adopt(persisted) }
                        return "Andromeda couldn’t save the folder automation settings."
                    }
                }
            } else {
                if updated != rules {
                    guard let data = FolderAutomationLegacySettings.encode(updated) else { return "The rules couldn’t be saved." }
                    let pauses = try JSONEncoder().encode(sources)
                    defaults.set(data, forKey: FolderAutomationLegacySettings.defaultsKey)
                    defaults.set(pauses, forKey: FolderAutomationLegacySettings.pausedSourcesKey)
                } else if sources != pausedSources {
                    let data = try JSONEncoder().encode(sources)
                    defaults.set(data, forKey: FolderAutomationLegacySettings.pausedSourcesKey)
                }
                if paused != isAutomationPaused { defaults.set(paused, forKey: FolderAutomationLegacySettings.pausedKey) }
            }
            return nil
        }
    }

    private func refreshSettingsForRun() -> Bool {
        do {
            let current = try settings?.load()
            if let current {
                if current.revision != snapshot?.revision { adopt(current) }
                if current.mode == .afterQuit && !defaults.bool(forKey: FolderAutomationLegacySettings.pausedKey) {
                    settingsProblem = "Automation is suspended because older Andromeda builds aren’t paused."
                    invalidatePendingAutomation()
                }
            } else if snapshot != nil {
                suspendSettings()
            }
        } catch {
            suspendSettings()
        }
        return available
    }

    private var activeRules: [FolderAutomationRule] {
        rules.filter { $0.enabled && !runsInBackground($0.directories.source)
            && !isPaused($0.directories.source) && !isRunningOnce($0.directories.source) }
    }

    private var schedulerEnabled: Bool {
        started && available && !isAutomationPaused && (manualRun != nil || !activeRules.isEmpty)
    }

    private func updateSchedule() {
        guard schedulerEnabled else {
            scheduler?.cancel()
            scheduler = nil
            scheduledCheck = nil
            watches.removeAll()
            pendingFileWatches.removeAll()
            wakePending = false
            return
        }
        let rules = activeRules
        var folders: [String: (folder: AutomationDirectories.Folder, maximumDepth: Int?)] = [:]
        for rule in rules {
            let destination = rule.directories.destination
            let watchesNestedCopies = rule.skipsIdenticalCopies && rule.directories.allowsDestinationSubfolders
            if folders[destination.path] == nil || watchesNestedCopies {
                folders[destination.path] = (destination, watchesNestedCopies ? nil : 0)
            }
            for backup in rule.backupFolders where folders[backup.path] == nil || rule.includesSubfolders {
                folders[backup.path] = (backup, rule.includesSubfolders ? nil : 0)
            }
        }
        for (source, siblings) in Dictionary(grouping: rules, by: { $0.directories.source }) {
            let limits = siblings.map(\.watchedDepthLimit)
            let maximumDepth = limits.contains(nil) ? nil : limits.compactMap { $0 }.max()
            folders[source.path] = (source, maximumDepth)
        }
        watches = watches.filter { folders[$0.key]?.folder == $0.value.folder
            && folders[$0.key]?.maximumDepth == $0.value.maximumDepth }
        for (path, scope) in folders where watches[path] == nil {
            let token = UUID()
            let stream = watchFolderChanges(scope.folder, scope.maximumDepth) { [weak self] in
                Task { @MainActor in
                    guard let self, self.watches[path]?.token == token else { return }
                    self.scheduleCheck(after: .milliseconds(250))
                }
            }
            watches[path] = Watch(folder: scope.folder, token: token, maximumDepth: scope.maximumDepth, stream: stream)
        }
        refreshPendingFileWatches()
        scheduleCheck(after: .zero)
    }

    private func refreshPendingFileWatches() {
        let rules = activeRules
        let activeIDs = Set(rules.map(\.id))
        let now = Date()
        pendingFileWatches = pendingFileWatches.filter { key, watch in
            guard activeIDs.contains(key.ruleID), let item = seen[key.ruleID]?[key.relativePath] else { return false }
            return item.readyAt > now && item.file.snapshot.fileID == watch.fileID
        }
        // Limit open descriptors. Other candidates still use folder events and the scheduled check.
        let maximumWatches = 64
        for rule in rules {
            guard let files = seen[rule.id] else { continue }
            for (relativePath, item) in files {
                if pendingFileWatches.count >= maximumWatches { return }
                let key = PendingFile(ruleID: rule.id, relativePath: relativePath)
                guard item.readyAt > now, pendingFileWatches[key] == nil else { continue }
                let path = rule.directories.source.path + "/" + relativePath
                let fileID = item.file.snapshot.fileID
                let token = UUID()
                guard let stream = FileChangeWatch.startPendingFile(path: path, fileID: fileID, changed: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.pendingFileWatches[key]?.token == token else { return }
                        self.scheduleCheck(after: .milliseconds(250))
                    }
                }) else { continue }
                pendingFileWatches[key] = PendingWatch(fileID: fileID, token: token, stream: stream)
            }
        }
    }

    private func scheduleCheck(after delay: Duration) {
        guard schedulerEnabled else { return }
        if checking { wakePending = true; return }
        let deadline = max(ContinuousClock.now + delay, leaseRetryAt ?? .now)
        if let scheduledCheck, scheduledCheck <= deadline { return }
        scheduler?.cancel()
        scheduledCheck = deadline
        scheduler = Task { [weak self] in
            if deadline > .now {
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.scheduler = nil
            self.scheduledCheck = nil
            let wasBusy = self.app.map { !$0.canScan || $0.organize.isUndoing } ?? false
            await self.check()
            self.refreshPendingFileWatches()
            let wake = self.wakePending
            self.wakePending = false
            // The fallback also discovers time-based matches and recovers from missed notifications.
            if let retryAt = self.leaseRetryAt, retryAt > .now {
                self.scheduleCheck(after: .zero)
            } else {
                self.scheduleCheck(after: wake ? .milliseconds(250) : wasBusy ? .seconds(4) : self.nextCheckDelay())
            }
        }
    }

    private func nextCheckDelay() -> Duration {
        let now = Date()
        var delay = 30.0
        if let manualRun {
            delay = manualRun.observedAt.map { max(0, $0.addingTimeInterval(4).timeIntervalSince(now)) } ?? 0
        }
        for rule in activeRules {
            guard let files = seen[rule.id] else { continue }
            let kept = ignored[rule.id] ?? []
            for item in files.values where !kept.contains(Handled(item.file, rule: rule)) {
                let remaining = item.readyAt.timeIntervalSince(now)
                delay = min(delay, remaining > 0 ? remaining : 4)
            }
        }
        return .seconds(delay)
    }

    func check(now: Date = Date()) async {
        guard let app, let journal, available, !isAutomationPaused, app.hasCompletedOnboarding, app.canScan,
              !app.organize.isUndoing, !checking, !Task.isCancelled else { return }
        let began = ContinuousClock.now
        checking = true
        defer { checking = false }
        await app.history.waitForLaunchSettle()
        guard !isAutomationPaused, app.canScan, !app.organize.isUndoing, !Task.isCancelled else { return }
        let lease: FolderAutomationLease?
        do {
            lease = try await BackgroundWork.run("andromeda.organize.automation-lease") {
                try FolderAutomationLease.tryAcquire(in: journal.directory)
            }
        } catch {
            leaseRetryAt = .now + .seconds(4)
            if !Task.isCancelled {
                for rule in activeRules { status[rule.id] = "Folder automation couldn’t coordinate access to History." }
            }
            return
        }
        guard let lease else {
            // Keep a pending one-time run pending and avoid retaking the lock in a tight loop.
            leaseRetryAt = .now + .seconds(4)
            return
        }
        activeLease = lease
        defer {
            activeLease = nil
            lease.release()
        }
        leaseRetryAt = nil
        guard refreshSettingsForRun(), !isAutomationPaused, app.canScan, !app.organize.isUndoing, !Task.isCancelled else { return }
        let env = env
        let revision = revision
        let manual = manualRun.flatMap { run -> ManualRun? in
            if let observedAt = run.observedAt, now.timeIntervalSince(observedAt) < 4 { return nil }
            return run
        }
        let enabled = rules.filter { shouldCheck($0, manual: manual) }
        let mutating = enabled.filter { !$0.ignoresMatches } + (manual?.replay.map { [$0.rule] } ?? [])
        if !mutating.isEmpty {
            let ready = await app.organize.recoverAutomationHistory(handledHistory, holding: lease)
            guard revision == self.revision, app.canScan, !app.organize.isUndoing, !Task.isCancelled else { return }
            guard ready else {
                leaseRetryAt = .now + .seconds(4)
                for rule in mutating { status[rule.id] = "History couldn’t be checked. No files changed." }
                return
            }
        }
        defer {
            if let manual, manualRun?.id == manual.id, revision == self.revision, !Task.isCancelled {
                if manual.observedAt == nil {
                    // Allow the full settling interval after the first observation completes.
                    manualRun?.observedAt = now.addingTimeInterval(began.duration(to: .now) / .seconds(1))
                } else {
                    manualRun = nil
                    checking = false
                    updateSchedule()
                }
            }
        }
        if let manual, let replay = manual.replay {
            await checkReplay(replay, manual: manual, app: app, now: now, revision: revision)
        }
        guard !enabled.isEmpty else { return }
        let groups = Dictionary(grouping: enabled) { $0.directories.source.path }
        let duplicateFingerprints = duplicateFingerprints
        let recognitionCache = recognitionCache
        let handledHistory = handledHistory
        let observed = await BackgroundWork.runNonThrowing("andromeda.organize.automation-observe") {
            () -> ([UUID: FolderAutomationRule.Observation], Set<Handled>?) in
            let handled = enabled.contains(where: \.copiesMatches) ? handledHistory.files(in: journal) : nil
            var observations: [UUID: FolderAutomationRule.Observation] = [:]
            for siblings in groups.values {
                guard let first = siblings.first else { continue }
                let results = FolderAutomationRule.observe(
                    siblings, env: env, now: now, duplicateFingerprints: duplicateFingerprints,
                    recognitionCache: recognitionCache,
                    excluding: { file in
                        handled.map { Handled(file, rule: first).exists(in: $0) } ?? false
                    })
                observations.merge(results) { original, _ in original }
            }
            return (observations, handled)
        }
        for rule in enabled {
            let id = rule.id
            guard revision == self.revision, !Task.isCancelled else { break }
            guard shouldCheck(rule, manual: manual) else { continue }
            let finishingManual = manual?.source == rule.directories.source && manual?.observedAt != nil
            guard let observation = observed.0[id] else {
                status[id] = "One of the approved folders is unavailable."
                seen[id] = nil
                continue
            }
            if rule.ignoresMatches {
                let count = observation.ignoredCount
                status[id] = count == 1 ? "1 matching file left in place." : "\(count) matching files left in place."
                continue
            }
            let previous = seen[id] ?? [:]
            let skippedNames = observation.conflicts + observation.namesTooLong + observation.namesUnavailable
                + observation.destinationsUnavailable + observation.backupConflicts
            let identical = observation.identicalCopies
            let duplicateStatus = identical == 0 ? nil : identical == 1
                ? "1 identical copy skipped." : "\(identical) identical copies skipped."
            let tagStatus = observation.tagsUnavailable == 0 ? nil
                : "\(observation.tagsUnavailable) skipped because a Finder tag couldn’t be generated."
            let waitsForStability = !rule.copiesOnArrival || manual?.source == rule.directories.source
            let sampled = observation.files.map { file in
                let earlier = previous[file.relativePath]
                return Seen(file: file, since: earlier?.file == file ? earlier?.since ?? now : now,
                            waitsForStability: waitsForStability)
            }
            if !finishingManual {
                seen[id] = Dictionary(uniqueKeysWithValues: sampled.map { ($0.file.relativePath, $0) })
            }
            let kept = ignored[id] ?? []
            let stable = sampled.filter { $0.readyAt <= now }
            let ready = stable.map(\.file).filter { !kept.contains(Handled($0, rule: rule)) }
            let stillChanging = finishingManual ? sampled.count - stable.count : 0
            guard !ready.isEmpty else {
                if skippedNames > 0 || duplicateStatus != nil || tagStatus != nil {
                    let unavailable = skippedNames > 0 ? "\(skippedNames) left in place because their destinations were unavailable." : nil
                    status[id] = [unavailable, duplicateStatus, tagStatus].compactMap { $0 }.joined(separator: " ")
                }
                else if finishingManual {
                    status[id] = stillChanging > 0 ? "Files still changing were left in place." : "No new matches to process."
                }
                else if status[id] == nil || status[id] == "One of the approved folders is unavailable."
                    || status[id] == "Folder automation couldn’t coordinate access to History." {
                    status[id] = "Watching for matching files."
                }
                continue
            }
            let handled: Set<Handled>?
            if let checked = observed.1 { handled = checked } else {
                handled = await BackgroundWork.runNonThrowing("andromeda.organize.automation-history") {
                    handledHistory.files(in: journal)
                }
            }
            guard revision == self.revision, !Task.isCancelled else { break }
            guard shouldCheck(rule, manual: manual) else { continue }
            guard let handled else { status[id] = "History couldn’t be checked. No files changed."; continue }
            let currentHandled = Set(sampled.map { Handled($0.file, rule: rule) }.filter { $0.exists(in: handled) })
            ignored[id] = currentHandled
            let files = ready.filter { !currentHandled.contains(Handled($0, rule: rule)) }
            guard !files.isEmpty, app.canScan, !app.organize.isUndoing else {
                if finishingManual {
                    status[id] = files.isEmpty ? "No new matches to process." : "Another operation was active. Try again."
                }
                continue
            }
            let control = ScanControl { _ in }
            activeRun = (rule.directories.source, finishingManual ? manual?.id : nil, control)
            let batch = finishingManual ? files : Array(files.prefix(64))
            let results = await app.organize.applyAutomation(rule.plan(batch), control: control)
            activeRun = nil
            guard revision == self.revision, shouldCheck(rule, manual: manual), !results.isEmpty else { continue }
            let moved = results.filter { $0.outcome == .done }.count
            for result in results {
                if case .move(let from, _) = result.step.action {
                    let relativePath = String(from.path.dropFirst(rule.directories.source.path.count + 1))
                    seen[id]?[relativePath] = nil
                }
            }
            let historyFailed = results.contains { $0.journalError != nil }
            var completedFiles = moved
            // Nested copies can finish without an event in the watched destination's scope.
            if !historyFailed, !finishingManual, files.count > batch.count, moved > 0 {
                wakePending = true
            }
            if historyFailed {
                _ = setEnabled(false, id: id)
                status[id] = "Paused because History couldn’t record the change."
            } else if rule.backupFolder != nil {
                let filed = results.filter { result in
                    if case .move = result.step.action { return result.outcome == .done }
                    return false
                }.count
                let copiesOnly = moved - filed * (rule.backupFolders.count + 1)
                completedFiles = filed
                let left = batch.count - filed + skippedNames + stillChanging
                let verb = rule.renamesInPlace ? "renamed" : "moved"
                var messages = ["\(filed) backed up and \(verb)."]
                if copiesOnly > 0 { messages.append("\(copiesOnly) backup copies kept for files still in place.") }
                if left > 0 { messages.append("\(left) left in place.") }
                status[id] = messages.joined(separator: " ")
            } else {
                let left = results.count - moved + skippedNames + stillChanging
                let verb = rule.copiesMatches
                    ? (rule.changesCopyTags ? "copied with Finder tag rules" : "copied")
                    : rule.renamesInPlace ? "renamed" : "moved"
                let completed = "\(moved) \(verb)."
                let details = left > 0 ? "\(left) left in place." : "See History for details."
                status[id] = [completed, duplicateStatus, tagStatus, details].compactMap { $0 }.joined(separator: " ")
            }
            if app.history.hasLoaded { await app.history.reload() }
            if !historyFailed, completedFiles > 0, rule.notifiesOnCompletion, let notifications,
               await notifications.status() == .allowed, revision == self.revision, shouldCheck(rule, manual: manual) {
                await notifications.sendAutomationCompletion(fileCount: completedFiles)
            }
        }
    }

    private func checkReplay(_ replay: ReplayRun, manual: ManualRun, app: AppModel, now: Date, revision: Int) async {
        let rule = replay.rule
        let checked = await replayFiles(for: rule, now: now)
        guard manualRun?.id == manual.id, self.revision == revision, !Task.isCancelled else { return }
        let files = Dictionary(uniqueKeysWithValues: replay.files.map { ($0.relativePath, $0) })
        let current = checked?.filter { files[$0.relativePath] == $0 }
        guard current?.count == files.count else {
            rejectReplay(rule.id)
            return
        }
        guard let firstCheck = manual.observedAt else { return }
        guard replay.files.allSatisfy({ max(firstCheck, $0.snapshot.modified).addingTimeInterval(4) <= now }) else {
            rejectReplay(rule.id)
            return
        }
        guard app.canScan, !app.organize.isUndoing else {
            status[rule.id] = "Another operation was active. Review the copies again."
            return
        }
        let plan = rule.plan(replay.files)
        guard plan.steps.count == replay.files.count, zip(plan.steps, replay.files).allSatisfy({ step, file in
            guard case .copy(let from, let to) = step.action else { return false }
            return from.path == rule.directories.source.url.appendingPathComponent(file.relativePath).path
                && to.path == rule.directories.destination.url.appendingPathComponent(file.destinationRelativePath).path
                && step.snapshot == file.snapshot
        }) else {
            rejectReplay(rule.id)
            return
        }
        let control = ScanControl { _ in }
        activeRun = (manual.source, manual.id, control)
        let results = await app.organize.applyAutomation(plan, control: control)
        activeRun = nil
        if app.history.hasLoaded { await app.history.reload() }
        guard manualRun?.id == manual.id, self.revision == revision, !Task.isCancelled else { return }
        if results.contains(where: { $0.journalError != nil }) {
            _ = setEnabled(false, id: rule.id)
            status[rule.id] = "Paused because History couldn’t record the change."
            return
        }
        let copied = results.filter { $0.outcome == .done }.count
        let left = replay.files.count - copied
        status[rule.id] = left == 0 ? "\(copied) copied. See History for details."
            : "\(copied) copied. \(left) left in place. See History for details."
        if copied > 0, rule.notifiesOnCompletion, let notifications,
           await notifications.status() == .allowed, manualRun?.id == manual.id, self.revision == revision {
            await notifications.sendAutomationCompletion(fileCount: copied)
        }
    }

    private func rejectReplay(_ ruleID: UUID) {
        status[ruleID] = "The reviewed files or destinations changed. Review them again."
        manualRun = nil
        updateSchedule()
    }

    private func shouldCheck(_ rule: FolderAutomationRule, manual: ManualRun?) -> Bool {
        guard rule.enabled, !isAutomationPaused else { return false }
        let source = rule.directories.source
        guard !runsInBackground(source) else { return false }
        if let manual, manual.source == source { return manual.replay == nil && manualRun?.id == manual.id }
        return !isPaused(source) && !isRunningOnce(source)
    }
}
