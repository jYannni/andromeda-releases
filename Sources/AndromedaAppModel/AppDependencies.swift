import AndromedaCore
import AppKit
import AndromedaHelperClient
import AndromedaOrganize
import Foundation

/// Every outside service the app model uses, in one value. Live in the app, fakes in tests.
public struct AppDependencies: Sendable {
    /// Offload suggestions for one cloud root. Walks the folder, so it runs off the main actor; stops
    /// early when the control is cancelled.
    public typealias OffloadRowsProvider =
        @Sendable (CloudRoot, OrganizeSettings, ScanEnvironment, ScanControl) -> [OffloadRow]
    /// Move-to-cloud candidates: the Organize view's own large-items walk of home (plan ruling 7).
    /// Walks the disk, so it runs off the main actor. The flag is `promptingPathsReadable` (`fda == .granted`).
    public typealias MoveCandidatesProvider =
        @Sendable (ScanEnvironment, [CloudRoot], OrganizeSettings, Bool) -> [MoveCandidate]
    /// Sync state of a moved item, for History's upload status. Local reads only; off the main actor.
    public typealias CloudInspect = @Sendable (URL, CloudProvider) -> CloudItemState

    public var env: ScanEnvironment
    public var catalog: @Sendable () throws -> [CatalogEntry]
    public var snapshots: any SnapshotLister
    public var volume: any VolumeUsageProvider
    public var apps: any RunningAppsProvider
    /// Bundle ID to display name.
    public var appName: @Sendable (String) -> String?
    /// Spotlight's last-opened date for an app bundle.
    public var applicationLastOpened: @Sendable (URL) -> Date? = { LastUsedReader.liveLastUsed($0) }
    public var trasher: any Trasher
    public var tools: any ToolRunner
    public var journalDirectory: URL
    public var fda: @Sendable () -> FDAStatus
    public var registration: any HelperRegistration
    public var helperConnect: @Sendable () -> NSXPCConnection
    public var workspace: any WorkspaceActions
    public var organizeSettings: any OrganizeSettingsStore
    /// The saved organize rules (plan 6). Tests pass a `TempTree` directory, never Application Support.
    public var ruleStore: any OrganizeRuleStore
    public var offloadRows: OffloadRowsProvider
    public var moveCandidates: MoveCandidatesProvider
    public var cloudInspect: CloudInspect
    /// Mounted external volumes (plan 7). Disk reads; the model calls it on the main actor only on refresh.
    public var volumes: @Sendable () -> [ExternalVolume]
    var driveSupportsExclusiveRename: @Sendable (URL) -> Bool? = { _ in nil }
    /// One drive's scan. Walks the drive, so it runs off the main actor.
    public var driveScan: @Sendable (ExternalVolume, ScanControl?) -> DriveScanOutcome
    var canRunAutomaticStorageWork: @Sendable () -> Bool = {
        let process = ProcessInfo.processInfo
        return AppDependencies.allowsAutomaticStorageWork(lowPower: process.isLowPowerModeEnabled,
                                                          thermal: process.thermalState)
    }
    var storageWorkRetryDelay: Duration = .seconds(60)

    static func allowsAutomaticStorageWork(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        guard !lowPower else { return false }
        switch thermal {
        case .nominal, .fair: return true
        case .serious, .critical: return false
        @unknown default: return false
        }
    }

    public init(
        env: ScanEnvironment,
        catalog: @escaping @Sendable () throws -> [CatalogEntry],
        snapshots: any SnapshotLister,
        volume: any VolumeUsageProvider,
        apps: any RunningAppsProvider,
        appName: @escaping @Sendable (String) -> String?,
        trasher: any Trasher,
        tools: any ToolRunner,
        journalDirectory: URL,
        fda: @escaping @Sendable () -> FDAStatus,
        registration: any HelperRegistration,
        helperConnect: @escaping @Sendable () -> NSXPCConnection,
        workspace: any WorkspaceActions,
        organizeSettings: any OrganizeSettingsStore,
        ruleStore: any OrganizeRuleStore,
        offloadRows: @escaping OffloadRowsProvider = AppDependencies.liveOffloadRows,
        moveCandidates: @escaping MoveCandidatesProvider = AppDependencies.liveMoveCandidates,
        cloudInspect: @escaping CloudInspect = { CloudItemInspector().inspect($0, provider: $1) },
        volumes: @escaping @Sendable () -> [ExternalVolume] = { [] },
        driveScan: @escaping @Sendable (ExternalVolume, ScanControl?) -> DriveScanOutcome = { _, _ in .cancelled }
    ) {
        self.env = env
        self.catalog = catalog
        self.snapshots = snapshots
        self.volume = volume
        self.apps = apps
        self.appName = appName
        self.trasher = trasher
        self.tools = tools
        self.journalDirectory = journalDirectory
        self.fda = fda
        self.registration = registration
        self.helperConnect = helperConnect
        self.workspace = workspace
        self.organizeSettings = organizeSettings
        self.ruleStore = ruleStore
        self.offloadRows = offloadRows
        self.moveCandidates = moveCandidates
        self.cloudInspect = cloudInspect
        self.volumes = volumes
        self.driveScan = driveScan
    }

    /// The real move-to-cloud planner's candidates (§4.1 step 1).
    public static func liveMoveCandidates(
        env: ScanEnvironment, roots: [CloudRoot], settings: OrganizeSettings, promptingPathsReadable: Bool
    ) -> [MoveCandidate] {
        MoveToCloudPlanner(
            env: env, cloudRoots: roots, settings: settings, promptingPathsReadable: promptingPathsReadable
        ).candidates()
    }

    /// The real recommender over a walk of `root` (decision 19a: suggestions only, nothing is evicted).
    /// `CloudModel` never calls it for iCloud Drive without Full Disk Access (`~/Library/Mobile Documents`
    /// is protected).
    public static func liveOffloadRows(
        root: CloudRoot, settings: OrganizeSettings, env: ScanEnvironment, control: ScanControl
    ) -> [OffloadRow] {
        OffloadRecommender(
            scanner: { root, min in
                let items = LargeItemsScanner(env: env, threshold: min, root: root.url)
                    .scan(excluding: [], control: control).items
                // Stopped during the walk: skip every per-item inspection that would follow.
                return control.isCancelled ? [] : items
            },
            inspector: CloudItemInspector(), lastUsed: LastUsedReader(), settings: settings, now: Date(), env: env
        ).rows(for: root)
    }

    public static func live() -> AppDependencies {
        let env = ScanEnvironment.live()
        let tools = LiveToolRunner()
        var dependencies = AppDependencies(
            env: env,
            catalog: { try BundledCatalog.load() },
            snapshots: LiveSnapshotLister(runner: tools),
            volume: LiveVolumeUsageProvider(runner: tools),
            apps: LiveRunningApps(),
            appName: { bundleID in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                      let bundle = Bundle(url: url) else { return nil }
                return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
            },
            trasher: LiveTrasher(),
            tools: tools,
            journalDirectory: Journal.liveDirectory(),
            fda: { FullDiskAccessProbe.check(env: env) },
            registration: LiveHelperRegistration(),
            helperConnect: { HelperClient.liveConnection() },
            workspace: LiveWorkspaceActions(),
            organizeSettings: UserDefaultsOrganizeSettingsStore(),
            ruleStore: FileOrganizeRuleStore(directory: Journal.liveDirectory().deletingLastPathComponent()),
            // Drive roots are only read for Time Machine markers with Full Disk Access (no unasked prompt).
            volumes: { VolumeDiscovery.mounted(probeRoots: FullDiskAccessProbe.check(env: env) == .granted) },
            driveScan: { v, c in
                DriveScanner(volume: v, isMounted: { VolumeDiscovery.isStillMounted(v) })
                    .scan(control: c)
            }
        )
        dependencies.driveSupportsExclusiveRename = { VolumeDiscovery.supportsExclusiveRename(at: $0) }
        return dependencies
    }
}
