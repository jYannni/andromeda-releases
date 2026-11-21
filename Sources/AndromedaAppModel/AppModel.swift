import AppKit
import Combine
import AndromedaCore
import AndromedaOrganize
import Foundation
import Observation

/// The root model: owns and wires every other model.
///
/// Helper laziness (spec §8.1): the `HelperModel` is created here but nothing calls its `refresh()` at
/// init, so no XPC happens at launch. `refresh()` runs only when (a) the user opens Settings or the
/// helper sheet (the view calls `helper.refresh()`), or (b) at the start of `scan()` when the
/// registration status is `.enabled` and the helper state is not yet settled (a status read only;
/// no XPC for any other status, and a dead/failed/outdated helper is not re-probed per scan).
/// Measuring through the helper happens only when `helper.isReady`.
///
/// Views call `scan()` here, never `scan.scan()`: it refuses while a removal is running.
@MainActor @Observable
public final class AppModel {
    public static let onboardedKey = "io.github.jyannni.diskplain.onboarded"
    private static let englishSpellingKey = "io.github.jyannni.diskplain.englishSpelling"
    private static let pinnedStorageFoldersKey = "io.github.jyannni.diskplain.pinnedStorageFolders"

    public let access: AccessModel
    public let helper: HelperModel
    public let scan: ScanModel
    public let removal: RemovalFlow
    public let history: HistoryModel
    /// Organize › Cloud.
    public let cloud: CloudModel
    /// Organize › Move to cloud: candidates, provider choice, ticks.
    public let moveToCloud: MoveToCloudModel
    /// Organize › Organize a folder: the picked folder, naming toggles, planning.
    public let folderOrganize: FolderOrganizeModel
    /// Review, export, apply, receipt and undo for organize plans.
    public let organize: OrganizeFlow
    /// Settings › Rules: the saved organize rules (plan 6).
    public let rules: RulesModel
    public let folderAutomation: FolderAutomationModel
    public let folderAutomationService: FolderAutomationServiceModel
    /// External drives: the list, per-drive scans and pages (plan 7).
    public let drives: DrivesModel
    public let archives: ArchivesModel
    public let spacePlanner: SpacePlannerModel
    public let storageMonitor: StorageMonitor
    public let homeStorageMap = StorageBrowserSession()
    public private(set) var pinnedStorageFolders: [StorageBrowser.FolderReference]

    public var hasCompletedOnboarding: Bool {
        didSet {
            defaults.set(hasCompletedOnboarding, forKey: Self.onboardedKey)
            if hasCompletedOnboarding, !driveSubscriptions.isEmpty { drives.startAutomaticScans() }
        }
    }
    public var englishSpelling: EnglishSpelling {
        didSet { defaults.set(englishSpelling.rawValue, forKey: Self.englishSpellingKey) }
    }
    /// Thresholds, destinations and checked providers. Saved on every change.
    public var organizeSettings: OrganizeSettings {
        didSet { if organizeSettings != oldValue { deps.organizeSettings.save(organizeSettings) } }
    }
    /// Set while `scan()` is checking the helper, before the scan model itself reports scanning.
    public private(set) var isPreparingScan = false

    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var driveSubscriptions: Set<AnyCancellable> = []

    public init(
        deps: AppDependencies, defaults: UserDefaults = .standard, helperTimeout: TimeInterval = 15,
        storageNotifications: (any StorageNotificationDelivery)? = nil
    ) {
        self.deps = deps
        self.defaults = defaults
        pinnedStorageFolders = defaults.data(forKey: Self.pinnedStorageFoldersKey)
            .flatMap { try? JSONDecoder().decode([StorageBrowser.FolderReference].self, from: $0) } ?? []
        hasCompletedOnboarding = defaults.bool(forKey: Self.onboardedKey)
        englishSpelling = defaults.string(forKey: Self.englishSpellingKey).flatMap(EnglishSpelling.init(rawValue:))
            ?? EnglishSpelling.preferred()
        organizeSettings = deps.organizeSettings.load()
        access = AccessModel(deps: deps)
        let helper = HelperModel(deps: deps, timeout: helperTimeout)
        self.helper = helper
        let scan = ScanModel(deps: deps, root: helper, defaults: defaults)
        self.scan = scan
        let removal = RemovalFlow(deps: deps, scan: scan, helper: helper, defaults: defaults)
        self.removal = removal
        storageMonitor = StorageMonitor(deps: deps, journal: removal.journal, defaults: defaults,
                                        comparisonHistory: scan.comparisonHistory,
                                        notifications: storageNotifications)
        let history = HistoryModel(deps: deps, journal: removal.journal)
        self.history = history
        cloud = CloudModel(deps: deps)
        organize = OrganizeFlow(deps: deps, journal: removal.journal)
        moveToCloud = MoveToCloudModel(deps: deps)
        rules = RulesModel(store: deps.ruleStore)
        let automation = FolderAutomationModel(env: deps.env, journal: removal.journal, defaults: defaults,
                                               notifications: storageNotifications)
        folderAutomation = automation
        folderAutomationService = FolderAutomationServiceModel(automation: automation)
        drives = DrivesModel(deps: deps, defaults: defaults)
        archives = ArchivesModel(deps: deps, defaults: defaults)
        spacePlanner = SpacePlannerModel(deps: deps, defaults: defaults, journal: removal.journal)
        folderOrganize = FolderOrganizeModel(deps: deps)
        cloud.app = self
        moveToCloud.app = self
        folderOrganize.app = self
        archives.app = self
        folderAutomation.app = self
        storageMonitor.canReadProtectedPaths = { [weak access] in access?.fda == .granted }
        // Organize runs the app was killed in the middle of are settled from the journal and the disk,
        // off the main actor, before History shows anything (`reload` waits for it).
        history.settleInterruptedOnLaunch()
        organize.launchSettle = { [weak history] in await history?.waitForLaunchSettle() }
        let flow = organize
        history.applyingBatch = { [weak flow] in flow?.applyingBatchID }
        history.undoingBatch = { [weak flow] in flow?.undoingBatchID }
    }

    /// Keep drive discovery and scan-on-connect active even when the main window is closed.
    public func startDriveMonitoring() async {
        guard driveSubscriptions.isEmpty else { return }
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.publisher(for: NSWorkspace.didMountNotification).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.drives.refreshInBackground()
                if self.history.hasLoaded { await self.history.driveMounted() }
                await self.archives.checkIfDue(on: self.drives.volumes)
            }
        }.store(in: &driveSubscriptions)
        notifications.publisher(for: NSWorkspace.didUnmountNotification).sink { [weak self] note in
            let url = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)
                ?? (note.userInfo?["NSDevicePath"] as? String).map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                guard let self else { return }
                if let url { self.drives.didUnmount(at: url) }
                await self.drives.refreshInBackground()
                if self.history.hasLoaded { await self.history.reload() }
            }
        }.store(in: &driveSubscriptions)
        if hasCompletedOnboarding { drives.startAutomaticScans() }
        await drives.refreshInBackground()
        archives.startAutomaticChecks()
    }

    /// History's **Undo this run**: puts the batch back, then reloads History.
    /// With `groupID`, History's **Undo this group**: only that group of the run goes back.
    public func undo(batchID: UUID, groupID: String? = nil, entryID: UUID? = nil) async {
        await organize.undo(batchID: batchID, groupID: groupID, entryID: entryID)
        await history.reload()
    }

    public func refreshSpacePlanProgress() async {
        await spacePlanner.refreshProgress { needsArchives in
            await history.waitForLaunchSettle()
            guard needsArchives else { return [] }
            return await archives.reload() ? archives.records : nil
        }
    }

    /// Cloud folders found at the last `refreshOrganizeRoots()`. Empty until then.
    public private(set) var organizeRoots: [CloudRoot] = []

    /// Lists the cloud folders (disk reads). Settings calls it when it opens, never from a view body.
    public func refreshOrganizeRoots() { organizeRoots = CloudRootLocator.roots(env: deps.env) }

    /// One row per cloud folder found on this Mac, for the Settings "Organize" section.
    /// Pure over the cached roots and settings; the folder listing happens only in `refreshOrganizeRoots()`.
    public var organizeDestinations: [OrganizeDestination] {
        organizeRoots.map {
            OrganizeDestination(provider: $0.provider, account: $0.account, path: organizeSettings.destination(for: $0).path)
        }
    }

    public var pages: [CategoryPage] {
        guard let result = scan.lastResult else { return [] }
        // Applications also leads to leftover review on Macs with no currently scanned apps.
        return Presentation.pages(result, helperReady: helper.isReady, showApplications: true)
    }

    public var overview: OverviewSummary? {
        guard let result = scan.lastResult else { return nil }
        return Presentation.overview(result, helperReady: helper.isReady, onlineOnly: cloud.onlineOnlyTotal)
    }

    /// Plain copy when the scan failed; ScanModel's raw error text is never shown.
    public var scanFailedText: String? {
        if case .failed = scan.state { return Copy.App.scanFailed }
        return nil
    }

    /// False while a removal runs, a scan is starting (helper check) or a scan is running (P18, P24).
    /// Views disable the Scan buttons with this.
    public var canScan: Bool {
        if removal.isExecuting || organize.isApplying || isPreparingScan { return false }
        if case .scanning = scan.state { return false }
        return true
    }

    /// The onboarding button: remembers that onboarding is done, then scans.
    public func completeOnboarding() async {
        hasCompletedOnboarding = true
        await scan()
    }

    /// Refuses (no-op) while a removal runs or another scan is starting or running.
    public func scan() async {
        guard canScan else { return }
        isPreparingScan = true
        access.recheck()
        if needsPreScanHelperCheck { await helper.refresh() }
        isPreparingScan = false
        guard !removal.isExecuting else { return }
        let previous = scan.comparisonHistory.snapshots.first?.id
        await scan.scan {
            // Reuse warm directory metadata and avoid walking the same home tree at the same time.
            // Build the map while Overview checks locations outside the home folder and reconciles totals.
            let refreshMap = !homeStorageMap.isScanning && (homeStorageMap.isStale || homeStorageMap.browser == nil)
            homeStorageMap.start(storageFolderScope(scanHome), refresh: refreshMap, watchFolder: scanHome, qos: .utility)
        }
        if let latest = scan.comparisonHistory.snapshots.first, latest.id != previous,
           scan.comparisonHistory.problem == nil {
            await storageMonitor.includeFollowUpScan(latest)
        }
    }

    /// Only an `.enabled` registration whose state we haven't settled yet. Never `.requiresApproval`
    /// (Settings and the helper sheet handle that), and a dead, failed or outdated helper is probed
    /// once, not on every scan, so a scan never waits on a silent helper more than once.
    private var needsPreScanHelperCheck: Bool {
        guard deps.registration.status == .enabled else { return false }
        switch helper.state {
        case .ready, .dead, .failed, .needsReapproval: return false
        case .off, .waitingForApproval, .checking: return true
        }
    }

    /// The home folder paths are shown relative to (`~/…`).
    public var scanHome: URL { deps.env.home }

    public func chooseStorageFolder() async -> URL? { await deps.workspace.chooseFolder() }
    public func chooseStorageFolder(startingAt directory: URL) async -> URL? {
        await deps.workspace.chooseFolder(startingAt: directory)
    }

    @discardableResult
    public func pinStorageFolder(_ folder: URL) async -> Bool {
        guard let reference = await BackgroundWork.runNonThrowing("andromeda.scan.pin-folder", {
            StorageBrowser.reference(forFolder: folder)
        }), !Task.isCancelled else { return false }
        var updated = pinnedStorageFolders.filter { $0.url.path != reference.url.path }
        updated.append(reference)
        updated.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        return savePinnedStorageFolders(updated)
    }

    public func unpinStorageFolder(_ reference: StorageBrowser.FolderReference) {
        _ = savePinnedStorageFolders(pinnedStorageFolders.filter { $0 != reference })
    }

    private func savePinnedStorageFolders(_ folders: [StorageBrowser.FolderReference]) -> Bool {
        guard let data = try? JSONEncoder().encode(folders) else { return false }
        defaults.set(data, forKey: Self.pinnedStorageFoldersKey)
        pinnedStorageFolders = folders
        return true
    }

    public func findDuplicates(in folder: URL, control: ScanControl) async -> DuplicateScanner.Result? {
        await findDuplicates(in: [folder], control: control)
    }

    public func chooseDuplicateFolders() async -> [URL] { await deps.workspace.chooseFolders() }

    public func findDuplicates(in folders: [URL], control: ScanControl) async -> DuplicateScanner.Result? {
        let env = deps.env
        let volumes = deps.volumes
        let scopes = duplicateScanScopes(folders)
        return await withTaskCancellationHandler {
            await BackgroundWork.runNonThrowing("andromeda.scan.duplicates") {
                DuplicateScanner.scan(scopes, env: env, volumes: volumes(), control: control)
            }
        } onCancel: {
            control.cancel()
        }
    }

    public func findSimilarImages(in folders: [URL], control: ScanControl) async -> SimilarImageScanner.Result? {
        let env = deps.env
        let scopes = duplicateScanScopes(folders)
        return await withTaskCancellationHandler {
            await BackgroundWork.runNonThrowing("andromeda.scan.similar-images") {
                SimilarImageScanner.scan(scopes, env: env, control: control)
            }
        } onCancel: {
            control.cancel()
        }
    }

    private func duplicateScanScopes(_ folders: [URL]) -> [DuplicateScanner.Scope] {
        let hasFullDiskAccess = access.fda == .granted
        return folders.map {
            DuplicateScanner.Scope(folder: $0, canReadProtectedPaths: hasFullDiskAccess || deps.env.isPromptingPath($0))
        }
    }

    public func storageFolderScope(
        _ folder: URL, reference: StorageBrowser.FolderReference? = nil
    ) -> StorageBrowseScope {
        StorageBrowseScope(folder: folder, env: deps.env, fda: access.fda, folderReference: reference)
    }

    public func savedFolderScope(_ folder: URL, reference: StorageBrowser.FolderReference?) -> StorageBrowseScope {
        StorageBrowseScope(folder: folder, env: deps.env, fda: access.fda,
                           explicitlyChosen: false, folderReference: reference)
    }

    public func reveal(_ url: URL) { deps.workspace.reveal(url) }

    public func open(handoff: BetterAction) {
        guard case .handoff(_, let url?) = handoff else { return }
        _ = deps.workspace.open(url)
    }

    public func copyCommand(_ c: String) { deps.workspace.copy(c) }

    /// Export needs a finished scan to report on.
    public var canExport: Bool { scan.lastResult != nil }

    /// Saves the last scan as text or JSON through the save panel. False when there is no scan or no save.
    public func exportReport(json: Bool) async -> Bool {
        await exportReport(json ? .json : .text)
    }

    public func exportSupportReport() async -> Bool { await exportReport(.redactedJSON) }

    private enum ReportFormat { case text, json, redactedJSON }

    private func exportReport(_ format: ReportFormat) async -> Bool {
        guard let r = scan.lastResult else { return false }
        let usage = r.usage ?? VolumeUsage(
            containerCapacity: 0, containerFree: 0, dataVolumeUsed: 0, purgeable: .notMeasurable)
        let report = ReportExporter.make(
            env: r.env, usage: usage, findings: r.findings, largeItems: r.largeItems,
            reconciliation: r.reconciliation, fda: r.fda, usedKnown: r.usedKnown,
            applications: r.appItems, helperOn: r.helperOn, standardUser: r.standardUser)
        let data: Data
        switch format {
        case .json:
            guard let encoded = try? ReportExporter.json(report) else { return false }
            data = encoded
        case .redactedJSON:
            guard let encoded = try? ReportExporter.redactedJSON(report) else { return false }
            data = encoded
        case .text:
            data = Data(ReportExporter.text(report).utf8)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())
        let title = format == .redactedJSON ? "Andromeda support report" : "Andromeda report"
        let name = "\(title) \(date).\(format == .text ? "txt" : "json")"
        return await deps.workspace.saveFile(suggestedName: name, contents: data)
    }
}
