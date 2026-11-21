import AndromedaCore
import Foundation
import Observation

public struct ConfirmRow: Equatable, Sendable {
    public let title: String
    public let sizeText: String
    public let howRemoved: String
    public let reversible: Bool
    public let location: String?

    init(title: String, sizeText: String, howRemoved: String, reversible: Bool, location: String? = nil) {
        self.title = title
        self.sizeText = sizeText
        self.howRemoved = howRemoved
        self.reversible = reversible
        self.location = location
    }
}

public struct ConfirmSummary: Equatable, Sendable {
    public let plan: RemovalPlan
    public let rows: [ConfirmRow]
    /// The button's label. Names the amount (the plan's own title), except for a Spotlight rebuild.
    public let confirmTitle: String
    /// Set when the plan contains anything that can't be undone.
    public let irreversibleNote: String?
    /// Display names of the plan's apps that are running right now.
    public let quitFirst: [String]
    /// The sentence the sheet shows for `quitFirst`; nil when nothing needs quitting.
    public let quitFirstLine: String?
    /// The scan result this summary was built from. `execute` refuses it once a newer result exists.
    public let scanStamp: Date
    /// Always true: the sheet's default button is Cancel.
    public let cancelIsDefault: Bool
    var appCleanupKeys: Set<IgnoredAppCleanupItem.Key> = []
}

public struct IgnoredAppCleanupItem: Codable, Equatable, Identifiable, Sendable {
    public enum Key: Codable, Hashable, Sendable {
        case installed(bundleID: String)
        case leftovers(bundleID: String)
        case leftoverFile(bundleID: String, path: String)
    }

    public let id: Key
    public let appName: String
}

public struct ReceiptRow: Equatable, Sendable {
    public let title: String
    public let outcomeText: String
    public let ok: Bool
    /// The journal entry to hand to `restore(_:)`; nil once put back, deleted or if it never moved.
    public let restorableEntryID: UUID?
    public var recordedSizeText: String? = nil
}

public struct ReceiptSummary: Equatable, Sendable {
    public let batchID: UUID
    public let headline: String
    public let rows: [ReceiptRow]
    /// States that items remain in the Trash and estimates future space using the known private allocation.
    /// Nil when nothing sits in the Trash.
    public let inTrashText: String?
    public let canDeletePermanently: Bool
    /// "Commands can't be undone." when a command ran.
    public let commandsNote: String?
    /// Set when the history couldn't be written and the batch stopped early.
    public let stoppedNote: String?
    public internal(set) var measurements: [CleanupSpaceMeasurement] = []
}

/// What the view shows before `deletePermanently()`: a second confirm, Cancel by default.
public struct PermanentDeleteConfirm: Equatable, Sendable {
    public let title: String
    public let body: String
    public let cancelIsDefault: Bool
}

public enum RemovalFlowError: Error, Equatable { case removalDisabled }

/// Select, confirm, execute, receipt (spec 6.1). Nothing here removes anything until `execute`.
@MainActor @Observable
public final class RemovalFlow {
    public static let disabledReason =
        "Andromeda can't keep its record of removals, so removal is off. Scanning still works."

    /// Set when the history folder can't be created. Scanning is unaffected.
    public let removalDisabledReason: String?
    /// The one journal for this directory, shared with History; nil when removal is off.
    public let journal: Journal?
    public private(set) var progress: (done: Int, total: Int)?
    public private(set) var receipt: ReceiptSummary?
    public private(set) var isExecuting = false
    /// Set when delete-permanently couldn't finish; cleared by the next action.
    public private(set) var actionProblem: String?

    private struct Override { var stamp: Date?; var ids: Set<String> }
    /// What one receipt row needs for later steps. Parallel to `receipt.rows`.
    /// `bytes` is the private floor (spec §7.1 rev 2); `shared` marks an item with clones.
    private struct Tracked {
        var entryID: UUID?
        var bytes: Int64?
        var shared = false
        var inTrash: Bool
        var permanentDeletionAllowed = true
    }

    private var override: Override?
    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private let scan: ScanModel
    @ObservationIgnored private let helper: HelperModel?
    @ObservationIgnored private let defaults: UserDefaults?
    private static let ignoredAppCleanupKey = "diskplain.ignoredAppCleanup.v1"
    public private(set) var ignoredAppCleanupItems: [IgnoredAppCleanupItem]
    @ObservationIgnored private var executedBatches: Set<UUID> = []
    @ObservationIgnored private var rowCache: (stamp: Date, helperReady: Bool, rows: [ItemRow])?
    @ObservationIgnored private var leftoverReviewCandidates: (stamp: Date, apps: [ApplicationCleanup.ObservedApplication])?
    @ObservationIgnored private var tracked: [Tracked] = []
    @ObservationIgnored private var busy = false

    public init(deps: AppDependencies, scan: ScanModel, helper: HelperModel?, defaults: UserDefaults? = nil) {
        self.deps = deps
        self.scan = scan
        self.helper = helper
        self.defaults = defaults
        ignoredAppCleanupItems = defaults?.data(forKey: Self.ignoredAppCleanupKey)
            .flatMap { try? JSONDecoder().decode([IgnoredAppCleanupItem].self, from: $0) } ?? []
        // Creating the folder is one cheap mkdir; the answer has to be known before any button shows.
        journal = try? Journal(directory: deps.journalDirectory)
        removalDisabledReason = journal == nil ? Self.disabledReason : nil
    }

    // MARK: Selection

    private var current: ScanResult? {
        if case .done(let r) = scan.state { r } else { nil }
    }

    private func rows(for result: ScanResult) -> [ItemRow] {
        let ready = helper?.isReady ?? false
        if let c = rowCache, c.stamp == result.finishedAt, c.helperReady == ready { return c.rows }
        let rows = Presentation.pages(result, helperReady: ready).flatMap(\.rows)
        rowCache = (result.finishedAt, ready, rows)
        return rows
    }

    /// Ticked row IDs for the current result: the safe, actionable rows until the user changes them.
    public var selected: Set<String> {
        get {
            guard let result = current else { return [] }
            let rows = rows(for: result)
            if let o = override, o.stamp == result.finishedAt {
                return o.ids.intersection(rows.filter(\.selectable).map(\.id))
            }
            return Set(rows.filter(\.startsSelected).map(\.id))
        }
        set { override = Override(stamp: current?.finishedAt, ids: newValue) }
    }

    /// False while a removal runs: checkboxes and "Rebuild…" are locked then (P24).
    public var canEditSelection: Bool { !isExecuting }

    /// No-op for rows that have no checkbox, and while a removal runs.
    public func toggle(_ id: String) {
        guard canEditSelection, let result = current, rows(for: result).contains(where: { $0.id == id && $0.selectable }) else { return }
        var now = selected
        if now.contains(id) { now.remove(id) } else { now.insert(id) }
        selected = now
    }

    public var reviewButtonTitle: String? {
        guard removalDisabledReason == nil else { return nil }
        let n = selected.count
        return n == 0 ? nil : Copy.Confirm.review(n)
    }

    // MARK: Confirm

    /// Builds the plan from the current scan's findings for the ticked rows. Nil while scanning,
    /// when removal is off, when nothing is ticked, or when the plan can't be built.
    public func prepareConfirm() -> ConfirmSummary? {
        prepareConfirm(ids: selected)
    }

    /// Review a scoped selection, leaving the existing page ticks alone.
    public func prepareConfirm(ids: Set<String>) -> ConfirmSummary? {
        guard removalDisabledReason == nil, let result = current else { return nil }
        let allowed = Set(rows(for: result).filter(\.selectable).map(\.id))
        let findings = result.findings.filter { ids.contains($0.id) && allowed.contains($0.id) }
        guard !findings.isEmpty, let plan = try? PlanBuilder.build(findings), !plan.removals.isEmpty else { return nil }
        return summary(plan, findings: findings, stamp: result.finishedAt)
    }

    public func prepareDuplicateConfirm(group: DuplicateScanner.Group, selected: Set<URL>) -> ConfirmSummary? {
        guard !isExecuting, removalDisabledReason == nil,
              let plan = PlanBuilder.buildDuplicateCleanup(group: group, selected: selected, env: deps.env)
        else { return nil }
        let rows = plan.removals.compactMap { removal -> ConfirmRow? in
            guard case .moveToTrash(let url) = removal.action, let keeper = removal.retainedDuplicate else { return nil }
            return ConfirmRow(title: url.path, sizeText: ByteFormat.string(group.logicalBytesPerFile),
                              howRemoved: "Keeping \(keeper.path)", reversible: true)
        }
        guard rows.count == plan.removals.count else { return nil }
        return ConfirmSummary(plan: plan, rows: rows, confirmTitle: "Move to Trash",
                              irreversibleNote: nil, quitFirst: [], quitFirstLine: nil,
                              scanStamp: .distantPast, cancelIsDefault: true)
    }

    public func prepareInstallerConfirm(_ entry: StorageBrowser.Entry) async -> ConfirmSummary? {
        await prepareInstallerConfirm([entry])
    }

    public func prepareSimilarImageConfirm(group: SimilarImageScanner.Group, selected: Set<URL>) async -> ConfirmSummary? {
        guard !isExecuting, removalDisabledReason == nil else { return nil }
        let env = deps.env
        guard let plan = await BackgroundWork.runNonThrowing("andromeda.similar-image.review", {
            PlanBuilder.buildSimilarImageCleanup(group: group, selected: selected, env: env)
        }), !Task.isCancelled, !isExecuting, removalDisabledReason == nil else { return nil }
        let rows = plan.removals.compactMap { removal -> ConfirmRow? in
            guard case .moveToTrash(let url) = removal.action, let keeper = removal.retainedSimilarImage else { return nil }
            let sizeText = removal.expectedBytes.map { Copy.Rows.uses(ByteFormat.string($0)) }
            return ConfirmRow(title: url.path, sizeText: sizeText ?? "", howRemoved: "Keeping \(keeper.path)",
                              reversible: true)
        }
        guard rows.count == plan.removals.count else { return nil }
        let count = rows.count
        let title = count == 1 ? "Move Photo to Trash" : "Move \(count.formatted()) Photos to Trash"
        return ConfirmSummary(plan: plan, rows: rows, confirmTitle: title,
                              irreversibleNote: nil, quitFirst: [], quitFirstLine: nil,
                              scanStamp: .distantPast, cancelIsDefault: true)
    }

    public func prepareInstallerConfirm(_ entries: [StorageBrowser.Entry]) async -> ConfirmSummary? {
        await prepareBrowserConfirm(entries, installer: true) { env in
            PlanBuilder.buildInstallerCleanup(entries, env: env)
        }
    }

    public func prepareBrowserFileConfirm(_ entries: [StorageBrowser.Entry], in folder: StorageBrowser.FolderReference) async -> ConfirmSummary? {
        await prepareBrowserConfirm(entries, installer: false) { env in
            PlanBuilder.buildBrowserFileCleanup(entries, in: folder, env: env)
        }
    }

    private func prepareBrowserConfirm(_ entries: [StorageBrowser.Entry], installer: Bool,
                                       build: @escaping @Sendable (ScanEnvironment) -> RemovalPlan?) async -> ConfirmSummary? {
        guard !isExecuting, removalDisabledReason == nil else { return nil }
        let env = deps.env
        guard let plan = await BackgroundWork.runNonThrowing("andromeda.browser.file-review", { build(env) }),
              !Task.isCancelled, !isExecuting, removalDisabledReason == nil else { return nil }
        let rows = entries.map { entry in
            ConfirmRow(title: entry.path, sizeText: Copy.Rows.uses(ByteFormat.string(entry.bytes)),
                       howRemoved: Copy.HowRemoved.trash, reversible: true)
        }
        let item = installer ? "Installer" : "File"
        let title = entries.count == 1 ? "Move \(item) to Trash" : "Move \(entries.count.formatted()) \(item)s to Trash"
        return ConfirmSummary(plan: plan, rows: rows, confirmTitle: title,
                              irreversibleNote: nil, quitFirst: [], quitFirstLine: nil,
                              scanStamp: .distantPast, cancelIsDefault: true)
    }

    public var applicationCleanupCandidates: [AppItem] {
        guard let current else { return [] }
        let keys = Set(ignoredAppCleanupItems.map(\.id))
        return (current.appItems + current.nestedAppItems).filter { app in
            guard ApplicationCleanup.isApplicationPath(app.url, env: deps.env) else { return false }
            return current.applicationIDsByPath[app.url].map { !keys.contains(.installed(bundleID: $0)) } ?? true
        }.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.url.path < $1.url.path
        }
    }

    public func canIgnoreInstalledApp(_ app: AppItem) -> Bool {
        current?.applicationIDsByPath[app.url] != nil
    }

    public func ignoreInstalledApp(_ app: AppItem) {
        guard let id = current?.applicationIDsByPath[app.url],
              applicationCleanupCandidates.contains(app) else { return }
        ignoreAppCleanupItem(.installed(bundleID: id), appName: app.url.deletingPathExtension().lastPathComponent)
    }

    public func ignoreLeftoverApp(_ app: ApplicationCleanup.ObservedApplication) {
        guard canReviewLeftovers(app) else { return }
        ignoreAppCleanupItem(.leftovers(bundleID: app.id), appName: app.name)
    }

    public func ignoreLeftoverFile(_ url: URL, from review: ApplicationCleanup.Leftovers) {
        guard canReviewLeftovers(review.application), review.items.contains(where: { $0.url == url }) else { return }
        ignoreAppCleanupItem(Self.leftoverFileKey(url, app: review.application), appName: review.application.name)
    }

    public func isLeftoverFileIgnored(_ url: URL, for app: ApplicationCleanup.ObservedApplication) -> Bool {
        let key = Self.leftoverFileKey(url, app: app)
        return ignoredAppCleanupItems.contains { $0.id == key }
    }

    public func showAppCleanupItemAgain(_ item: IgnoredAppCleanupItem) {
        saveIgnoredAppCleanupItems(ignoredAppCleanupItems.filter { $0.id != item.id })
    }

    private func ignoreAppCleanupItem(_ key: IgnoredAppCleanupItem.Key, appName: String) {
        guard !ignoredAppCleanupItems.contains(where: { $0.id == key }) else { return }
        saveIgnoredAppCleanupItems(ignoredAppCleanupItems + [.init(id: key, appName: appName)])
    }

    private func saveIgnoredAppCleanupItems(_ items: [IgnoredAppCleanupItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults?.set(data, forKey: Self.ignoredAppCleanupKey)
        ignoredAppCleanupItems = items
    }

    private static func leftoverFileKey(
        _ url: URL, app: ApplicationCleanup.ObservedApplication
    ) -> IgnoredAppCleanupItem.Key {
        .leftoverFile(bundleID: app.id, path: SafetyGuard.withoutSystemPathAlias(url.standardizedFileURL.path))
    }

    private var ignoredLeftoverPaths: [String: Set<String>] {
        var paths: [String: Set<String>] = [:]
        for item in ignoredAppCleanupItems {
            if case .leftoverFile(let id, let path) = item.id { paths[id, default: []].insert(path) }
        }
        return paths
    }

    public struct InstalledApplicationDetails: Sendable {
        public let lastOpened: Date?
        public let architecture: ApplicationCleanup.Architecture?
        public let signingTeam: ApplicationCleanup.SigningTeam?
        public let hasAppStoreHistory: Bool
    }

    public func installedApplicationDetails() async -> [URL: InstalledApplicationDetails] {
        let candidates = applicationCleanupCandidates
        let bundleIDs = current?.applicationIDsByPath ?? [:]
        let readDate = deps.applicationLastOpened
        let env = deps.env
        return await BackgroundWork.runNonThrowing("andromeda.removal.app-details") {
            let appStoreIDs = Set(ApplicationCleanup.observeAppStoreHistory(env: env).map(\.id))
            return Dictionary(candidates.map { app in
                let details = InstalledApplicationDetails(lastOpened: readDate(app.url),
                                                          architecture: ApplicationCleanup.architecture(of: app.url, env: env),
                                                          signingTeam: ApplicationCleanup.signingTeam(of: app.url, env: env),
                                                          hasAppStoreHistory: bundleIDs[app.url].map(appStoreIDs.contains) == true)
                return (app.url, details)
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    public func inspectApplication(_ url: URL) async -> ApplicationCleanup? {
        guard removalDisabledReason == nil, !isExecuting,
              applicationCleanupCandidates.contains(where: { $0.url == url }) else { return nil }
        let deps = deps
        return await BackgroundWork.runNonThrowing("andromeda.removal.inspect-app") {
            ApplicationCleanup.inspect(url, env: deps.env, includeContainers: deps.fda() == .granted)
        }
    }

    public func inspectApplications(_ urls: [URL]) async -> [ApplicationCleanup] {
        guard let stamp = current?.finishedAt, removalDisabledReason == nil, !isExecuting else { return [] }
        let candidates = Set(applicationCleanupCandidates.map(\.url))
        let eligible = urls.filter { candidates.contains($0) }
        guard !eligible.isEmpty else { return [] }
        let deps = deps
        let reviews = await BackgroundWork.runNonThrowing("andromeda.removal.inspect-apps") {
            ApplicationCleanup.inspectApplications(eligible, env: deps.env, includeContainers: deps.fda() == .granted)
        }
        guard !Task.isCancelled, !isExecuting, current?.finishedAt == stamp else { return [] }
        return reviews
    }

    public func prepareApplicationUninstallConfirm(_ reviews: [ApplicationCleanup], selected: Set<URL>) -> ConfirmSummary? {
        guard let current, !isExecuting, removalDisabledReason == nil else { return nil }
        let candidates = Set(applicationCleanupCandidates.map { $0.url.path })
        let cleanupKeys = Set(reviews.map { IgnoredAppCleanupItem.Key.installed(bundleID: $0.bundleIdentifier.lowercased()) })
        guard reviews.allSatisfy({ candidates.contains($0.app.url.path) }),
              cleanupKeys.isDisjoint(with: ignoredAppCleanupItems.map(\.id)),
              let plan = PlanBuilder.buildApplicationUninstall(reviews, selected: selected) else { return nil }
        let appsByPath = Dictionary(uniqueKeysWithValues: reviews.map { ($0.app.url, $0.app.url.deletingPathExtension().lastPathComponent) })
        let running = plan.removals.compactMap { removal -> String? in
            guard case .moveToTrash(let url) = removal.action, let name = appsByPath[url],
                  removal.appsMustBeQuit.contains(where: { deps.apps.isRunning(bundleID: $0) }) else { return nil }
            return name
        }
        let items = reviews.flatMap { [$0.app] + $0.related.filter { selected.contains($0.url) } }
        let quitLine = running.isEmpty ? nil : "Quit \(Copy.Confirm.list(running)) first. Running apps and their Library files will be skipped."
        return ConfirmSummary(plan: plan, rows: items.map(Self.applicationConfirmRow),
                              confirmTitle: reviews.count == 1 ? "Move App to Trash" : "Move \(reviews.count) Apps to Trash",
                              irreversibleNote: nil, quitFirst: running, quitFirstLine: quitLine,
                              scanStamp: current.finishedAt, cancelIsDefault: true, appCleanupKeys: cleanupKeys)
    }

    public func prepareApplicationConfirm(
        _ review: ApplicationCleanup, selected: Set<URL>, action: ApplicationCleanup.Action = .uninstall
    ) -> ConfirmSummary? {
        let key = IgnoredAppCleanupItem.Key.installed(bundleID: review.bundleIdentifier.lowercased())
        guard let current, !isExecuting, removalDisabledReason == nil,
              applicationCleanupCandidates.contains(where: { $0.url.path == review.app.url.path }),
              !ignoredAppCleanupItems.contains(where: { $0.id == key }),
              let plan = PlanBuilder.buildApplicationCleanup(review, selected: selected, action: action) else { return nil }
        let related = review.relatedItems(for: action).filter { selected.contains($0.url) }
        let items = action == .uninstall ? [review.app] + related : related
        let title = action == .uninstall ? "Move App to Trash" : "Move App Data to Trash"
        return applicationSummary(plan, items: items, appName: review.app.url.deletingPathExtension().lastPathComponent,
                                  title: title, stamp: current.finishedAt, appCleanupKeys: [key])
    }

    public func leftoverApplicationCandidates() async -> [ApplicationCleanup.ObservedApplication]? {
        guard let current, removalDisabledReason == nil, !isExecuting else { return nil }
        let deps = deps
        let observed = scan.observedApplications
        let ignored = ignoredAppCleanupItems
        let ignoredPaths = ignoredLeftoverPaths
        let (candidates, discovered) = await BackgroundWork.runNonThrowing("andromeda.removal.find-leftovers") {
            let protectedReadable = deps.fda() == .granted
            let trashed = protectedReadable ? ApplicationCleanup.observeTrashedApplications(env: deps.env) : []
            var known = observed
            for app in trashed where known[app.id] == nil { known[app.id] = app }
            for app in ApplicationCleanup.observeAppStoreHistory(env: deps.env) where known[app.id] == nil {
                known[app.id] = app
            }
            let candidates = ApplicationCleanup.leftoverCandidates(Array(known.values), env: deps.env,
                                                                  includeContainers: protectedReadable, ignoringPaths: ignoredPaths)
            let knownTrash = trashed.compactMap { known[$0.id] }
            let discovered = (knownTrash + (candidates ?? [])).filter { !$0.isLaunchAgentOnly && observed[$0.id] == nil }
            return (candidates, discovered)
        }
        guard current.finishedAt == self.current?.finishedAt, ignored == ignoredAppCleanupItems,
              !isExecuting, !Task.isCancelled else { return nil }
        scan.rememberApplications(discovered)
        let keys = Set(ignored.map(\.id))
        let visible = candidates?.filter { !keys.contains(.leftovers(bundleID: $0.id)) }
        leftoverReviewCandidates = visible.map { (current.finishedAt, $0) }
        return visible
    }

    public func inspectLeftovers(_ application: ApplicationCleanup.ObservedApplication) async -> ApplicationCleanup.Leftovers? {
        await inspectLeftovers([application]).first
    }

    public func inspectLeftovers(_ applications: [ApplicationCleanup.ObservedApplication]) async -> [ApplicationCleanup.Leftovers] {
        guard let stamp = current?.finishedAt, removalDisabledReason == nil, !isExecuting else { return [] }
        let eligible = applications.filter { canReviewLeftovers($0) }
        guard !eligible.isEmpty else { return [] }
        let deps = deps
        let ignored = ignoredAppCleanupItems
        let paths = ignoredLeftoverPaths
        let reviews = await BackgroundWork.runNonThrowing("andromeda.removal.inspect-leftovers") {
            ApplicationCleanup.inspectLeftovers(eligible, env: deps.env, includeContainers: deps.fda() == .granted,
                                                ignoringPaths: paths)
        }
        guard !Task.isCancelled, !isExecuting, stamp == current?.finishedAt, ignored == ignoredAppCleanupItems else { return [] }
        return reviews
    }

    public func prepareLeftoverConfirm(_ review: ApplicationCleanup.Leftovers, selected: Set<URL>) -> ConfirmSummary? {
        prepareLeftoverConfirm([review], selected: selected)
    }

    public func prepareLeftoverConfirm(_ reviews: [ApplicationCleanup.Leftovers], selected: Set<URL>) -> ConfirmSummary? {
        guard let current, removalDisabledReason == nil, !isExecuting,
              reviews.allSatisfy({ canReviewLeftovers($0.application) }),
              let plan = PlanBuilder.buildLeftoverCleanup(reviews, selected: selected) else { return nil }
        var items: [ApplicationCleanup.Item] = []
        var running: [String] = []
        var keys = Set<IgnoredAppCleanupItem.Key>()
        for review in reviews {
            let app = review.application
            let chosen = review.items.filter { selected.contains($0.url) }
            guard !chosen.isEmpty else { continue }
            items += chosen
            keys.insert(.leftovers(bundleID: app.id))
            keys.formUnion(chosen.map { Self.leftoverFileKey($0.url, app: app) })
            if deps.apps.isRunning(bundleID: app.bundleID) { running.append(app.name) }
        }
        guard keys.isDisjoint(with: ignoredAppCleanupItems.map(\.id)) else { return nil }
        let quitLine = running.isEmpty ? nil : "Quit \(Copy.Confirm.list(running)) first. Files for running apps will be skipped."
        return ConfirmSummary(plan: plan, rows: items.map(Self.applicationConfirmRow),
                              confirmTitle: "Move Files to Trash", irreversibleNote: nil, quitFirst: running,
                              quitFirstLine: quitLine, scanStamp: current.finishedAt, cancelIsDefault: true,
                              appCleanupKeys: keys)
    }

    private func canReviewLeftovers(_ app: ApplicationCleanup.ObservedApplication) -> Bool {
        guard !ignoredAppCleanupItems.contains(where: { $0.id == .leftovers(bundleID: app.id) }) else { return false }
        if scan.observedApplications[app.id] == app { return true }
        guard let candidates = leftoverReviewCandidates, candidates.stamp == current?.finishedAt else { return false }
        return candidates.apps.contains(app)
    }

    private func applicationSummary(
        _ plan: RemovalPlan, items: [ApplicationCleanup.Item], appName: String, title: String, stamp: Date,
        appCleanupKeys: Set<IgnoredAppCleanupItem.Key>
    ) -> ConfirmSummary {
        let running = plan.removals.first?.appsMustBeQuit.contains(where: { deps.apps.isRunning(bundleID: $0) }) == true
        return ConfirmSummary(plan: plan, rows: items.map(Self.applicationConfirmRow), confirmTitle: title,
                              irreversibleNote: nil, quitFirst: running ? [appName] : [],
                              quitFirstLine: running ? "Quit \(appName) before moving these items to Trash." : nil,
                              scanStamp: stamp, cancelIsDefault: true, appCleanupKeys: appCleanupKeys)
    }

    private static func applicationConfirmRow(_ item: ApplicationCleanup.Item) -> ConfirmRow {
        ConfirmRow(title: item.url.path, sizeText: ByteFormat.string(item.bytes), howRemoved: item.label, reversible: true)
    }

    /// For a row whose better action the helper can run (the Spotlight rebuild). Nil otherwise.
    public func prepareConfirm(betterActionFor id: String) -> ConfirmSummary? {
        guard removalDisabledReason == nil, let result = current,
              let finding = result.findings.first(where: { $0.id == id }),
              helper?.isReady == true,
              case .privileged(let plan) = PlanBuilder.betterAction(
                  for: finding, helperReady: true, osMajor: result.env.osMajor)
        else { return nil }
        return summary(plan, findings: [finding], stamp: result.finishedAt)
    }

    private func summary(_ plan: RemovalPlan, findings: [Finding], stamp: Date) -> ConfirmSummary {
        let byID = Dictionary(findings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let perEntry = Dictionary(grouping: plan.removals, by: \.catalogEntryID).mapValues(\.count)

        let rows = plan.removals.map { r -> ConfirmRow in
            let entry = byID[r.catalogEntryID]?.entry
            let name = entry?.title ?? r.catalogEntryID
            var title = name
            var how: String
            let location: String?
            switch r.action {
            case .moveToTrash(let url):
                if (perEntry[r.catalogEntryID] ?? 0) > 1 { title = Copy.Confirm.itemTitle(name, url.lastPathComponent) }
                how = Copy.HowRemoved.trash
                location = Copy.Scan.displayPath(url, home: deps.env.home)
            case .runTool(let exe, let args):
                how = Copy.HowRemoved.tool(exe.lastPathComponent, args)
                location = nil
            case .privileged:
                how = Copy.HowRemoved.helperRebuildsSpotlight
                location = nil
            }
            var sizeText = r.expectedBytes.map { ByteFormat.string($0) } ?? Copy.Rows.sizeNotMeasured
            // With clones the allocated figure is what it uses, never what comes back (§7.1 rev 2).
            if r.clonesPresent, let bytes = r.expectedBytes { sizeText = Copy.Rows.uses(ByteFormat.string(bytes)) }
            if case .moveToTrash = r.action {} else { sizeText = Copy.Confirm.commandSizeNotShown }
            return ConfirmRow(
                title: title, sizeText: sizeText,
                howRemoved: how, reversible: r.reversible, location: location)
        }

        var runningIDs: [String] = []
        var affected = 0
        for r in plan.removals {
            let running = r.appsMustBeQuit.filter { deps.apps.isRunning(bundleID: $0) }
            if !running.isEmpty { affected += 1 }
            for id in running where !runningIDs.contains(id) { runningIDs.append(id) }
        }
        let names = runningIDs.map { deps.appName($0) ?? $0 }

        let onlySpotlight = plan.removals.allSatisfy {
            if case .privileged(.rebuildSpotlightIndex) = $0.action { true } else { false }
        }
        return ConfirmSummary(
            plan: plan, rows: rows,
            confirmTitle: onlySpotlight ? Copy.Confirm.rebuildSpotlight : Self.confirmTitle(for: plan),
            irreversibleNote: plan.containsIrreversible ? Copy.Confirm.irreversibleNote : nil,
            quitFirst: names,
            quitFirstLine: names.isEmpty ? nil : Copy.Confirm.quitFirst(names: names, items: affected),
            scanStamp: stamp, cancelIsDefault: true)
    }

    /// Commands make no size promise: only Trash moves are named by size.
    private static func confirmTitle(for plan: RemovalPlan) -> String {
        var trashBytes: [Int64?] = []
        var commands = 0
        for r in plan.removals {
            if case .moveToTrash = r.action { trashBytes.append(r.expectedBytes) } else { commands += 1 }
        }
        if commands == 0 { return plan.confirmTitle }
        if trashBytes.isEmpty { return Copy.Confirm.runCommands(commands) }
        let known = trashBytes.compactMap { $0 }
        let sum = known.reduce(0, +)
        let size = known.count == trashBytes.count && sum > 0 ? ByteFormat.string(sum) : nil
        return Copy.Confirm.moveAndRun(size: size, commands: commands)
    }

    // MARK: Execute

    private struct RunResult: Sendable {
        let receipt: Receipt
        /// Original path to journal entry ID, for this batch's items proven restorable.
        let restorable: [String: UUID]
        /// Original paths that are taken or whose folder is gone.
        let occupied: Set<String>
        let measurement: CleanupSpaceMeasurement?
    }

    private func noteProgress(_ done: Int) {
        guard let p = progress else { return }
        progress = (max(p.done, done), p.total)
    }

    /// Runs the confirmed plan on a dedicated thread, builds the receipt, clears the ticks, drops the
    /// helper connection and starts a new scan. Does nothing while a scan runs or when removal is off.
    /// Returns false when the run was refused; then `receipt` is nil and `actionProblem` says why, so no
    /// earlier batch's receipt is ever shown for this one.
    @discardableResult
    public func execute(_ s: ConfirmSummary) async -> Bool {
        guard !isExecuting else { return false }
        func refuse(_ why: String) -> Bool {
            receipt = nil
            actionProblem = why
            return false
        }
        guard removalDisabledReason == nil, let journal else { return refuse(Self.disabledReason) }
        if case .scanning = scan.state { return refuse(Copy.Receipt.refusedScanning) }
        // A summary belongs to the scan it was built from and runs once.
        let browserCleanup = s.plan.removals.first.map {
            $0.retainedDuplicate != nil || $0.isBrowserFileCleanup || $0.retainedSimilarImage != nil
        } ?? false
        guard (browserCleanup || current?.finishedAt == s.scanStamp),
              !executedBatches.contains(s.plan.batchID) else { return refuse(Copy.Receipt.refusedStale) }
        guard s.appCleanupKeys.isDisjoint(with: ignoredAppCleanupItems.map(\.id)) else {
            return refuse("This review includes an item now ignored by App Cleanup. Review the files again.")
        }
        executedBatches.insert(s.plan.batchID)
        isExecuting = true
        actionProblem = nil
        receipt = nil
        let plan = s.plan
        progress = (0, plan.removals.count)
        let privileged = helper?.privilegedRunner()
        // While the helper carries out part of this plan, Settings can't remove or re-register it.
        let usesHelper = privileged != nil && plan.removals.contains {
            if case .privileged = $0.action { true } else { false }
        }
        if usesHelper { helper?.beginPrivilegedUse() }
        let deps = self.deps

        let run = await BackgroundWork.runNonThrowing("andromeda.removal") { [self] in
            let meter = CleanupSpaceMeter(deps: deps)
            let startupActions = meter.startupActions(plan)
            let before = startupActions.isEmpty ? nil : meter.read()
            let executor = Executor(
                env: deps.env, trasher: deps.trasher, tools: deps.tools, apps: deps.apps,
                journal: journal, privileged: privileged)
            var done = 0
            let receipt = executor.execute(plan) { _ in
                done += 1
                let n = done
                Task { @MainActor in self.noteProgress(n) }
            }
            let measurement = receipt.results.contains { $0.outcome == .done && startupActions.contains($0.removal.id) }
                ? meter.record(before, batchID: plan.batchID, operation: .cleanup, journal: journal) : nil
            var ids: [String: UUID] = [:]
            var occupied: Set<String> = []
            let restorable = (try? TrashLedger(env: deps.env, journal: journal, volumes: deps.volumes).restorable()) ?? []
            for e in restorable where e.batchID == plan.batchID {
                guard let path = e.originalPath else { continue }
                ids[path] = e.id
                if !HistoryModel.isFree(path) { occupied.insert(path) }
            }
            return RunResult(receipt: receipt, restorable: ids, occupied: occupied, measurement: measurement)
        }

        if usesHelper { helper?.endPrivilegedUse() }
        makeReceipt(s, run)
        progress = nil
        isExecuting = false
        if !browserCleanup {
            selected = []
            // The helper work is over; a new scan must not find a connection from this run.
            helper?.disconnect()
            await scan.scan()
        }
        return true
    }

    private func makeReceipt(_ s: ConfirmSummary, _ run: RunResult) {
        var rows: [ReceiptRow] = []
        var tracked: [Tracked] = []
        var moved = 0, ran = 0, skipped = 0, problems = 0, commandDone = false
        for (i, removal) in s.plan.removals.enumerated() {
            let title = s.rows[i].title
            guard let result = run.receipt.results.first(where: { $0.removal.id == removal.id }) else {
                rows.append(ReceiptRow(title: title, outcomeText: Copy.Receipt.notAttempted, ok: false, restorableEntryID: nil))
                tracked.append(Tracked(entryID: nil, bytes: nil, inTrash: false))
                skipped += 1
                continue
            }
            var entryID: UUID?
            var inTrash = false
            switch result.outcome {
            case .done:
                if case .moveToTrash(let url) = removal.action {
                    moved += 1
                    inTrash = true
                    entryID = run.restorable[url.path]
                } else {
                    ran += 1
                    commandDone = true
                }
            case .skipped: skipped += 1
            case .failed: problems += 1
            case .restored, .permanentlyDeleted, .planned: break
            }
            var shownID = entryID
            if case .moveToTrash(let url) = removal.action, run.occupied.contains(url.path) { shownID = nil }
            rows.append(ReceiptRow(
                title: title, outcomeText: text(for: result.outcome, removal: removal),
                ok: result.outcome == .done, restorableEntryID: shownID))
            tracked.append(Tracked(
                entryID: entryID, bytes: inTrash ? removal.privateBytes : nil,
                shared: inTrash && removal.clonesPresent, inTrash: inTrash,
                permanentDeletionAllowed: removal.allowsPermanentDeletion))
        }
        self.tracked = tracked
        publish(
            batchID: run.receipt.batchID,
            headline: Copy.Receipt.headline(moved: moved, ran: ran, skipped: skipped, problems: problems),
            rows: rows,
            commandsNote: commandDone ? Copy.Receipt.commandsNote : nil,
            stoppedNote: run.receipt.results.contains { $0.journalError != nil } ? Copy.Receipt.stopped : nil,
            measurements: run.measurement.map { [$0] } ?? [])
    }

    /// Rebuilds the receipt around `rows`, recomputing the Trash line and the delete button from `tracked`.
    private func publish(
        batchID: UUID, headline: String, rows: [ReceiptRow], commandsNote: String?, stoppedNote: String?,
        measurements: [CleanupSpaceMeasurement]
    ) {
        let inTrash = tracked.filter(\.inTrash)
        let size = Self.knownSize(inTrash)
        let atLeast = inTrash.contains(where: \.shared)
        receipt = ReceiptSummary(
            batchID: batchID, headline: headline, rows: rows,
            inTrashText: inTrash.isEmpty ? nil
                : size.map { Copy.Receipt.inTrash(ByteFormat.string($0), atLeast: atLeast) } ?? Copy.Receipt.inTrashNoSize,
            canDeletePermanently: tracked.contains { $0.inTrash && $0.entryID != nil && $0.permanentDeletionAllowed },
            commandsNote: commandsNote, stoppedNote: stoppedNote, measurements: measurements)
    }

    /// The total when every item's size is known and above zero; nil otherwise (never "0 KB").
    private static func knownSize(_ items: [Tracked]) -> Int64? {
        var total: Int64 = 0
        for item in items {
            guard let b = item.bytes else { return nil }
            total += b
        }
        return total > 0 ? total : nil
    }

    private func text(for outcome: Outcome, removal: PlannedRemoval) -> String {
        OutcomeText.text(for: outcome, reversible: removal.reversible, appName: {
            guard case .skipped(.appRunning) = outcome else { return nil }
            let id = removal.appsMustBeQuit.first { deps.apps.isRunning(bundleID: $0) } ?? removal.appsMustBeQuit.first
            return id.map { deps.appName($0) ?? $0 }
        }())
    }

    // MARK: After the receipt

    /// The second confirm for `deletePermanently()`; nil when the receipt has nothing to delete.
    public func permanentDeleteConfirm() -> PermanentDeleteConfirm? {
        guard let receipt, receipt.canDeletePermanently else { return nil }
        let items = tracked.filter { $0.inTrash && $0.entryID != nil }
        let size = Self.knownSize(items)
        return PermanentDeleteConfirm(
            title: Copy.Confirm.deletePermanentlyTitle(
                size.map { ByteFormat.string($0) }, atLeast: items.contains(where: \.shared)),
            body: Copy.Confirm.deletePermanentlyBody, cancelIsDefault: true)
    }

    /// Deletes the receipt's own items from the Trash and nothing else. The view asks first.
    public func deletePermanently() async {
        guard let journal, let current = receipt, current.canDeletePermanently, !busy else { return }
        busy = true
        defer { busy = false }
        actionProblem = nil
        let deps = self.deps
        let batchID = current.batchID
        do {
            let result = try await BackgroundWork.run("andromeda.delete") {
                try CleanupSpaceMeter(deps: deps).deleteFromTrash(batchID: batchID, journal: journal)
            }
            let deleted = Set(result.deleted)
            let skipped = Dictionary(result.skipped, uniquingKeysWith: { a, _ in a })
            var rows = current.rows
            for i in rows.indices {
                guard let id = tracked[i].entryID else { continue }
                if deleted.contains(id) {
                    rows[i] = ReceiptRow(title: rows[i].title, outcomeText: Copy.Receipt.deleted, ok: true, restorableEntryID: nil)
                    tracked[i].inTrash = false
                    tracked[i].entryID = nil
                } else if let reason = skipped[id] {
                    let text = reason == .alreadyGone ? Copy.Receipt.alreadyGone : Copy.Receipt.notOurs
                    rows[i] = ReceiptRow(title: rows[i].title, outcomeText: text, ok: false, restorableEntryID: nil)
                    tracked[i].inTrash = false
                    tracked[i].entryID = nil
                }
            }
            publish(
                batchID: batchID, headline: current.headline, rows: rows,
                commandsNote: current.commandsNote, stoppedNote: current.stoppedNote,
                measurements: current.measurements + (result.measurement.map { [$0] } ?? []))
        } catch {
            actionProblem = Copy.Receipt.deleteFailed
        }
    }

    /// Puts one trashed item back where it was, then marks its row.
    public func restore(_ journalEntryID: UUID) async throws {
        guard let journal else { throw RemovalFlowError.removalDisabled }
        let deps = self.deps
        try await BackgroundWork.run("andromeda.restore") {
            try TrashLedger(env: deps.env, journal: journal, volumes: deps.volumes).restore(journalEntryID)
        }
        actionProblem = nil
        guard let current = receipt, let i = tracked.firstIndex(where: { $0.entryID == journalEntryID }) else { return }
        var rows = current.rows
        rows[i] = ReceiptRow(title: rows[i].title, outcomeText: Copy.Receipt.putBack, ok: true, restorableEntryID: nil)
        tracked[i].inTrash = false
        tracked[i].entryID = nil
        publish(
            batchID: current.batchID, headline: current.headline, rows: rows,
            commandsNote: current.commandsNote, stoppedNote: current.stoppedNote,
            measurements: current.measurements)
    }
}
