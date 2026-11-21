import AndromedaCore
import AndromedaHelperProtocol
import Foundation
import Observation

public enum ScanState: Equatable {
    case idle
    case scanning(ScanStage)
    case done(ScanResult)
    case failed(String)
}

@MainActor @Observable
public final class ScanModel {
    /// Entries only the helper can size.
    public static let rootMeasuredIDs = ["spotlight-index", "swap-and-sleepimage", "update-staging", "unified-log"]
    /// Folders outside home the helper measures whole, whatever the catalog found (ruling R6).
    public static let outsideRootIDs = ["outside-library", "outside-private", "system-hidden"]

    public private(set) var state: ScanState = .idle {
        didSet { onStateChange?(state) }
    }
    /// Called on every state change, on the main actor. For tests and diagnostics.
    @ObservationIgnored public var onStateChange: ((ScanState) -> Void)?

    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private let root: (any RootMeasuring)?
    /// The local user directory; nil when it couldn't be listed. Tests inject a failed query.
    @ObservationIgnored private let accountsSource: @Sendable () -> [DirectoryAccount]?
    @ObservationIgnored private let defaults: UserDefaults?
    private static let observedAppsKey = "diskplain.observedApplications.v1"
    private(set) var observedApplications: [String: ApplicationCleanup.ObservedApplication]
    /// The last finished scan, kept while a newer one runs or fails.
    public private(set) var lastResult: ScanResult?
    public let comparisonHistory: ScanComparisonHistory

    /// The running stage's counts and current folder or entry; nil between stages and when not scanning.
    public private(set) var progress: ScanProgress? {
        didSet { onProgressChange?(progress) }
    }
    /// Called on every progress change, on the main actor. For tests.
    @ObservationIgnored public var onProgressChange: ((ScanProgress?) -> Void)?
    /// When the running scan started; nil when not scanning.
    public private(set) var startedAt: Date?
    /// Cancel was pressed and the running stage hasn't stopped yet.
    public private(set) var isCancelling = false

    /// The stages this scan runs, in order. The helper stage only runs when the helper is on.
    public var stages: [ScanStage] {
        root == nil
            ? [.checkingAccess, .catalog, .largeItems, .applications, .outsideHome, .volume, .reconciling]
            : [.checkingAccess, .catalog, .helperMeasure, .largeItems, .applications, .outsideHome, .volume, .reconciling]
    }

    @ObservationIgnored private var control: ScanControl?
    /// The applications stage, running beside the home walk; cancelled with it.
    @ObservationIgnored private var appsAside: ScanControl?
    @ObservationIgnored private var cancelRequested = false
    /// Bumped per stage, so a report from an earlier stage that arrives late is dropped.
    @ObservationIgnored private var stageToken = 0

    public init(
        deps: AppDependencies, root: (any RootMeasuring)?,
        defaults: UserDefaults? = nil,
        accountsSource: @escaping @Sendable () -> [DirectoryAccount]? = { OtherAccounts.localDirectory() }
    ) {
        self.deps = deps
        self.root = root
        self.accountsSource = accountsSource
        self.defaults = defaults
        observedApplications = defaults?.data(forKey: Self.observedAppsKey)
            .flatMap { try? JSONDecoder().decode([String: ApplicationCleanup.ObservedApplication].self, from: $0) } ?? [:]
        comparisonHistory = ScanComparisonHistory(directory: deps.journalDirectory.deletingLastPathComponent())
    }

    /// Stops the running scan at the next check (between files, folders or catalog entries) and goes
    /// back to the previous result, or to idle. Nothing from the stopped scan is kept.
    public func cancel() {
        guard case .scanning = state, !cancelRequested, !comparisonHistory.isSaving else { return }
        cancelRequested = true
        isCancelling = true
        control?.cancel()
        appsAside?.cancel()
    }

    public func scan(onHomeWalkCompleted: () -> Void = {}) async {
        if case .scanning = state { return }
        cancelRequested = false
        isCancelling = false
        startedAt = Date()
        progress = nil
        state = .scanning(.checkingAccess)
        let deps = self.deps
        let accountsSource = self.accountsSource
        // One sizer for every stage: a hard link seen in two stages counts once. Each stage sizes through
        // its own view of it, so stages running at the same time don't share a progress control.
        let sizer = AllocatedSizer()
        do {
            let fda = deps.fda()
            if stopIfCancelled() { return }

            state = .scanning(.catalog)
            let catalogControl = beginStage()
            let (catalogFindings, snapshots) = try await BackgroundWork.run("andromeda.scan.catalog") {
                let catalog = try deps.catalog()
                let snapshots = try? deps.snapshots.localSnapshots()
                let findings = CatalogScanner(
                    env: deps.env, snapshots: CapturedSnapshots(list: snapshots ?? []),
                    promptingPathsReadable: fda == .granted, sizer: sizer
                ).scan(catalog, control: catalogControl)
                return (findings, snapshots)
            }
            var findings = catalogFindings
            if stopIfCancelled() { return }

            var truncated: Set<String> = []
            endStage()
            // Reads the local user directory, so off the main actor. nil: it couldn't be listed (R25).
            let listedAccounts = await BackgroundWork.runNonThrowing("andromeda.scan.accounts") {
                OtherAccounts.list(env: deps.env, source: accountsSource)
            }
            let accounts = listedAccounts ?? []
            var rootOutside: [String: RootMeasurement] = [:]
            var accountsAnswer = OtherAccountsAnswer.unavailable
            var helperOn = false
            if let root {
                state = .scanning(.helperMeasure)
                let present = findings.map(\.id).filter { Self.rootMeasuredIDs.contains($0) }
                // Asked only when there is someone to name: the walk can take the helper's whole budget.
                // Each outside walk can take 25 s: a cancel stops before the next one.
                let measured = await root.measureAll(
                    present + Self.outsideRootIDs, includingOtherAccounts: !accounts.isEmpty,
                    shouldContinue: { [weak self] in self.map { !$0.cancelRequested } ?? false })
                findings = findings.map { f in
                    guard present.contains(f.id), let m = measured.entries[f.id] else { return f }
                    if m.truncated { truncated.insert(f.id) }
                    return f.applyingRootMeasurement(m)
                }
                rootOutside = measured.entries.filter { Self.outsideRootIDs.contains($0.key) }
                accountsAnswer = measured.otherAccounts
                helperOn = measured.helperOn
            }

            if stopIfCancelled() { return }

            state = .scanning(.largeItems)
            let catalogClaimed = findings.flatMap { $0.items.map(\.url) }
            // ~/Applications is inside home: the applications stage owns it, so the home walk skips it.
            let claimed = catalogClaimed + deps.env.applicationsRoots
            let largeControl = beginStage()
            // The apps don't depend on the home walk (it skips the Applications folders), so they are
            // sized at the same time; the checklist still shows the stages in order.
            let appsControl = ScanControl { _ in }
            appsAside = appsControl
            async let appsAhead = BackgroundWork.runNonThrowing("andromeda.scan.applications") {
                // Catalog-claimed apps (macOS installers) are counted as findings, not here.
                let result = ApplicationsScanner(roots: deps.env.applicationsRoots, sizer: sizer)
                    .scan(excluding: catalogClaimed, control: appsControl)
                let observed = ApplicationCleanup.observeWithPaths(result.items + result.nestedItems,
                                                                   env: deps.env, control: appsControl)
                return (result, observed)
            }
            let large = await BackgroundWork.runNonThrowing("andromeda.scan.large") {
                LargeItemsScanner(env: deps.env, promptingPathsReadable: fda == .granted, sizer: sizer)
                    .scan(excluding: claimed, control: largeControl, comparisonDepth: 3, captureFolderPresence: true)
            }
            endStage()
            state = .scanning(.applications)
            let (apps, observedApps) = await appsAhead
            appsAside = nil
            if stopIfCancelled() { return }
            onHomeWalkCompleted()

            // After both walks: it skips what they claimed, and runs alone so its progress is the only one shown.
            state = .scanning(.outsideHome)
            let outsideClaimed = Self.outsideClaims(catalogItems: catalogClaimed, env: deps.env)
            let outsideControl = beginStage()
            let nonRoot = await BackgroundWork.runNonThrowing("andromeda.scan.outside") {
                OutsideHomeScanner(env: deps.env, sizer: sizer).scan(skipping: outsideClaimed, control: outsideControl)
            }
            endStage()
            if stopIfCancelled() { return }
            let outside = Self.combineOutside(nonRoot: nonRoot, root: rootOutside)
            let otherAccounts = Self.otherAccountSizes(accounts, answer: accountsAnswer)

            state = .scanning(.volume)
            let usageRead = await BackgroundWork.runNonThrowing("andromeda.scan.volume") {
                try? deps.volume.current()
            }
            let usage = usageRead
            let effective = usage ?? VolumeUsage(
                containerCapacity: 0, containerFree: 0, dataVolumeUsed: 0, purgeable: .notMeasurable)

            state = .scanning(.reconciling)
            let findingsNow = findings
            let helperWasOn = helperOn
            let accountsKnown = listedAccounts != nil
            let reconciliation = await BackgroundWork.runNonThrowing("andromeda.scan.reconcile") {
                Reconciler.reconcile(
                    usage: effective, findings: findingsNow, largeItems: large.items,
                    unlisted: large.unlisted, applications: apps.total,
                    unlistedClones: large.unlistedClones, applicationsClones: apps.clonesPresent,
                    unlistedCloneBuckets: large.unlistedCloneBuckets,
                    unreadable: large.unreadable + apps.unreadable, fda: fda,
                    outside: outside, otherAccounts: otherAccounts,
                    helperOn: helperWasOn, accountsKnown: accountsKnown)
            }

            let result = ScanResult(
                env: deps.env, findings: findings, largeItems: large.items, usage: usage,
                usedKnown: usage != nil, fda: fda, reconciliation: reconciliation,
                finishedAt: Date(), rootMeasureTruncated: truncated,
                appItems: apps.items, unlisted: large.unlisted,
                helperOn: helperOn, standardUser: accountsAnswer == .notPermitted, snapshots: snapshots,
                applicationIDsByPath: Dictionary(observedApps.map { ($0.url, $0.application.id) },
                                                 uniquingKeysWith: { first, _ in first }),
                nestedAppItems: apps.nestedItems)
            if stopIfCancelled() { return }
            // Compare the same unprivileged measurement on each scan. Helper readings may cover a different scope.
            await comparisonHistory.record(result, folders: large.folders, listedDirectories: large.listedDirectories,
                                           excluded: claimed + [deps.env.trash], catalogFindings: catalogFindings)
            rememberApplications(observedApps.map(\.application))
            lastResult = result
            finish(.done(result))
        } catch {
            if stopIfCancelled() { return }
            finish(.failed(String(describing: error)))
        }
    }

    func rememberApplications(_ observed: [ApplicationCleanup.ObservedApplication]) {
        var updated = observedApplications
        for app in observed { updated[app.id] = app }
        guard updated != observedApplications else { return }
        observedApplications = updated
        if let data = try? JSONEncoder().encode(updated) {
            defaults?.set(data, forKey: Self.observedAppsKey)
        }
    }

    /// A new control for a stage that reports progress. Reports hop to the main actor and are dropped
    /// once the stage has ended.
    private func beginStage() -> ScanControl {
        stageToken += 1
        let token = stageToken
        progress = nil
        let c = ScanControl { [weak self] p in
            Task { @MainActor in
                guard let self, self.stageToken == token, !self.cancelRequested else { return }
                self.progress = p
            }
        }
        control = c
        return c
    }

    private func endStage() {
        stageToken += 1
        control = nil
        progress = nil
    }

    private func stopIfCancelled() -> Bool {
        guard cancelRequested else { return false }
        finish(lastResult.map { .done($0) } ?? .idle)
        return true
    }

    private func finish(_ next: ScanState) {
        endStage()
        startedAt = nil
        cancelRequested = false
        isCancelling = false
        state = next
    }
}

extension ScanModel {
    /// What the outside pass skips; see `OutsideHomeScanner.claims`.
    public nonisolated static func outsideClaims(catalogItems: [URL], env: ScanEnvironment) -> [URL] {
        OutsideHomeScanner.claims(catalogItems: catalogItems, env: env)
    }

    /// One figure per outside row: the larger of the helper's and the non-root pass's, "at least" unless
    /// the one shown is complete. Neither is a superset of the other: the helper skips folders users own
    /// or can write to (R21), the non-root pass skips what it can't read (R23). `system-hidden` measures
    /// folders the non-root pass skips, so it adds to "Other folders on the system disk" instead.
    /// Rows cut short before anything was counted are left out.
    public nonisolated static func combineOutside(
        nonRoot: [OutsideMeasurement], root: [String: RootMeasurement]
    ) -> [OutsideMeasurement] {
        var rows = Dictionary(uniqueKeysWithValues: nonRoot.map { ($0.row, $0) })
        let compared: [(String, OutsideRow)] = [("outside-library", .library), ("outside-private", .privateFiles)]
        for (id, row) in compared {
            guard let m = root[id] else { continue }
            // A refused subtree (R21) makes the helper's figure a lower bound like an unreadable one.
            var rooted = OutsideMeasurement(
                row: row, bytes: m.bytes, clonesPresent: m.clonesPresent,
                unreadableCount: m.unreadableCount, skippedCount: m.skippedCount, truncated: m.truncated)
            guard let walked = rows[row] else { rows[row] = rooted; continue }
            if rooted.isLowerBound { rooted.unreadablePaths = walked.unreadablePaths }
            rooted.browsableRoots = walked.browsableRoots
            // On a tie, the complete figure, so the row doesn't say "at least" for nothing.
            if rooted.bytes > walked.bytes || (rooted.bytes == walked.bytes && !rooted.isLowerBound) {
                rows[row] = rooted
            }
        }
        if let m = root["system-hidden"] {
            let walked = rows[.otherSystemFolders] ?? OutsideMeasurement(row: .otherSystemFolders, bytes: 0)
            rows[.otherSystemFolders] = OutsideMeasurement(
                row: .otherSystemFolders, bytes: walked.bytes + m.bytes,
                clonesPresent: walked.clonesPresent || m.clonesPresent,
                unreadableCount: walked.unreadableCount + m.unreadableCount,
                skippedCount: walked.skippedCount + m.skippedCount, truncated: walked.truncated || m.truncated)
        }
        return OutsideRow.allCases.compactMap { rows[$0] }
            .filter { !($0.bytes == 0 && $0.truncated) && ($0.bytes > 0 || $0.unreadableCount > 0 || $0.skippedCount > 0) }
    }

    /// One size per listed account. One the helper didn't answer for stays unmeasured.
    public nonisolated static func otherAccountSizes(
        _ accounts: [(uid: uid_t, name: String)], answer: OtherAccountsAnswer
    ) -> [OtherAccountSize] {
        var replies: [UInt32: AccountSizeReply] = [:]
        if case .measured(let rows) = answer {
            for r in rows where replies[r.uid] == nil { replies[r.uid] = r }
        }
        return accounts.map { account in
            let r = replies[UInt32(account.uid)]
            return OtherAccountSize(
                uid: UInt32(account.uid), name: account.name, bytes: r?.bytes,
                atLeast: r?.isLowerBound ?? false)
        }
    }
}

private struct CapturedSnapshots: SnapshotLister {
    let list: [LocalSnapshot]
    func localSnapshots() -> [LocalSnapshot] { list }
}

extension BackgroundWork {
    /// For work that cannot throw.
    static func runNonThrowing<T: Sendable>(
        _ label: String, qos: QualityOfService = .userInitiated, _ body: @escaping @Sendable () -> T
    ) async -> T {
        // BackgroundWork.run only throws what `body` throws, so this cannot fail.
        (try? await run(label, qos: qos, body)) ?? { fatalError("BackgroundWork.run threw from a non-throwing body") }()
    }
}
