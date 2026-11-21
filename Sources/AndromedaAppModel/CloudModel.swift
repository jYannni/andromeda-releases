import AndromedaCore
import AndromedaOrganize
import Foundation
import Observation

extension OffloadRow {
    /// Only rows offered for hand-off can be ticked; still-syncing and conflicted rows are shown, not offered.
    public var isSelectable: Bool { status == .handOff || status == .keepsOwnCopy }
}

/// One cloud folder in the Cloud view. A provider with two accounts has two sections.
public struct ProviderSection: Identifiable, Equatable, Sendable {
    public let root: CloudRoot
    /// The user pressed Check for this provider once (remembered in `OrganizeSettings.checkedProviders`).
    public internal(set) var checked: Bool
    /// The last finished check's rows, best first. Empty until a check finishes this session.
    public internal(set) var rows: [OffloadRow] = []
    /// Known "frees at least" summed over the rows offered for hand-off; rows that can't be measured add
    /// nothing. Nil until a check finishes this session.
    public internal(set) var totalFreesAtLeast: Int64?

    public var id: URL { root.url }
    public var title: String { Copy.Organize.sectionTitle(root.provider, account: root.account) }

    /// The rows by age bucket. Within a bucket, rows sharing a parent folder (ruling O6) sit together
    /// under that folder, at the place of its best row.
    public var groups: [CloudRowGroup] {
        [AgeBucket.overAYear, .sixToTwelveMonths].compactMap { bucket in
            let inBucket = rows.filter { $0.bucket == bucket }
            guard !inBucket.isEmpty else { return nil }
            var entries: [CloudRowEntry] = []
            var placed: Set<URL> = []
            for row in inBucket {
                guard let parent = row.groupParent else { entries.append(.row(row)); continue }
                guard placed.insert(parent).inserted else { continue }
                let members = inBucket.filter { $0.groupParent == parent }
                entries.append(members.count >= 2 ? .folder(parent, members) : .row(row))
            }
            // "Opened" only when every row's date is a last-opened date (spec §3.4).
            let kind: LastUse.Kind = inBucket.allSatisfy { $0.lastUse.kind == .opened } ? .opened : .changed
            return CloudRowGroup(bucket: bucket, header: Copy.Organize.bucketHeader(bucket, kind: kind), entries: entries)
        }
    }
}

public struct CloudRowGroup: Identifiable, Equatable, Sendable {
    public let bucket: AgeBucket
    public let header: String
    public let entries: [CloudRowEntry]
    public var id: String { header }
}

public enum CloudRowEntry: Identifiable, Equatable, Sendable {
    case row(OffloadRow)
    /// A parent folder and its rows; its header ticks all the selectable ones.
    case folder(URL, [OffloadRow])

    public var id: URL {
        switch self {
        case .row(let r): r.id
        case .folder(let url, _): url
        }
    }
}

/// Organize › Cloud: per-provider offload suggestions, handed off to Finder (decision 19a: Andromeda
/// never evicts). A provider's folder is never walked until the user presses Check for it once (O9);
/// after that, opening the view rechecks it once per launch. Nothing is pre-ticked.
@MainActor @Observable
public final class CloudModel {
    public private(set) var providers: [ProviderSection] = []
    public private(set) var ticked: Set<URL> = []
    /// Providers with a check running.
    public private(set) var scanning: Set<CloudProvider> = []
    /// Providers whose folder is protected and isn't checked without Full Disk Access: iCloud Drive
    /// (`~/Library/Mobile Documents`). Refreshed when the view opens and before every check.
    public private(set) var needsAccess: Set<CloudProvider> = []
    private var banners: [CloudProvider: String] = [:]

    @ObservationIgnored private let deps: AppDependencies
    /// Owns the settings and the cached cloud roots. Set by `AppModel.init`.
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var controls: [CloudProvider: ScanControl] = [:]
    @ObservationIgnored private var checkedThisLaunch: Set<CloudProvider> = []

    init(deps: AppDependencies) { self.deps = deps }

    /// The view opened: relist the cloud folders (names only), then recheck providers checked on an
    /// earlier launch that haven't been checked since this one started.
    public func appear() async {
        guard let app else { return }
        app.refreshOrganizeRoots()
        let checked = app.organizeSettings.checkedProviders
        providers = app.organizeRoots.map { root in
            var section = providers.first { $0.root == root } ?? ProviderSection(root: root, checked: false)
            section.checked = checked.contains(root.provider)
            return section
        }
        dropStaleTicks()
        refreshAccess()
        for provider in CloudProvider.allCases
        where checked.contains(provider) && !checkedThisLaunch.contains(provider) && has(provider) {
            // The view's `.task` was cancelled (it went away): don't start more walks.
            if Task.isCancelled { return }
            await run(provider)
        }
    }

    /// The **Check <provider>** button: remembers the provider, then walks its folders off the main actor.
    public func check(_ provider: CloudProvider) async {
        guard let app, has(provider), !scanning.contains(provider) else { return }
        app.organizeSettings.checkedProviders.insert(provider)
        for i in providers.indices where providers[i].root.provider == provider { providers[i].checked = true }
        await run(provider)
    }

    /// **Check again**: recomputes the provider's rows and total. Claims nothing about what changed.
    public func rescan(_ provider: CloudProvider) async {
        guard providers.contains(where: { $0.root.provider == provider && $0.checked }),
              !scanning.contains(provider) else { return }
        banners[provider] = nil
        await run(provider)
    }

    /// Stops a running check; the stopped check's rows are discarded and the previous ones kept.
    public func cancel(_ provider: CloudProvider) { controls[provider]?.cancel() }

    public func isScanning(_ provider: CloudProvider) -> Bool { scanning.contains(provider) }

    /// A checked provider can be refreshed after changes made outside Andromeda.
    public func canCheckAgain(_ provider: CloudProvider) -> Bool {
        !scanning.contains(provider)
            && !needsAccess.contains(provider)
            && providers.contains { $0.root.provider == provider && $0.checked }
    }

    /// Only rows offered for hand-off can be ticked; still-syncing and conflicted rows can't.
    public func toggle(_ id: URL) {
        guard let row = providers.lazy.flatMap(\.rows).first(where: { $0.id == id }), row.isSelectable else { return }
        if ticked.remove(id) == nil { ticked.insert(id) }
    }

    public func preselectForHandoff(_ id: URL) {
        guard providers.lazy.flatMap(\.rows).contains(where: { $0.id == id && $0.isSelectable }) else { return }
        ticked = [id]
    }

    /// A folder header: ticks all its selectable rows, or unticks them when all are ticked.
    public func toggleGroup(_ parent: URL) {
        let children = groupChildren(parent)
        guard !children.isEmpty else { return }
        if children.allSatisfy(ticked.contains) { ticked.subtract(children) } else { ticked.formUnion(children) }
    }

    public func isGroupTicked(_ parent: URL) -> Bool {
        let children = groupChildren(parent)
        return !children.isEmpty && children.allSatisfy(ticked.contains)
    }

    public func canShowInFinder(_ provider: CloudProvider) -> Bool { !tickedURLs(provider).isEmpty }

    /// Selects exactly the provider's ticked rows in one Finder window, then shows what to click there.
    public func showInFinder(_ provider: CloudProvider) {
        let urls = tickedURLs(provider)
        guard !urls.isEmpty else { return }
        deps.workspace.revealMany(urls)
        banners[provider] = Copy.Organize.handOff(for: provider)
    }

    /// Why the provider's folder isn't checked (no Full Disk Access); nil when it can be.
    public func accessText(for provider: CloudProvider) -> String? {
        needsAccess.contains(provider) ? Copy.Organize.iCloudNeedsAccess : nil
    }

    /// The hand-off banner after **Show in Finder**, until **Check again**.
    public func handOffText(for provider: CloudProvider) -> String? { banners[provider] }

    /// The Storage overview's "Could be online-only" figure: checked providers only. Nil when none has a result.
    public var onlineOnlyTotal: Int64? {
        let totals = providers.filter(\.checked).compactMap(\.totalFreesAtLeast)
        return totals.isEmpty ? nil : totals.reduce(0, +)
    }

    // MARK: Private

#if ANDROMEDA_DIRECT_EVICT
    /// Direct eviction (decision 19a), flagged builds only, no UI. Pin-guarded: Organize 1 never reads pin
    /// state, so this refuses every real item until a public pin read exists.
    public func evictDirect(_ state: CloudItemState, batchID: UUID = UUID()) -> Evictor.Outcome {
        guard let journal = try? Journal(directory: deps.journalDirectory) else {
            return .failed("The journal isn't available.")
        }
        return Evictor(journal: journal).evict(state, batchID: batchID)
    }
#endif

    /// Same rule as `ScanModel`: without Full Disk Access a protected folder is never walked (no TCC prompts).
    private func refreshAccess() {
        needsAccess = deps.fda() == .granted ? [] : [.iCloudDrive]
    }

    private func has(_ provider: CloudProvider) -> Bool { providers.contains { $0.root.provider == provider } }

    private func groupChildren(_ parent: URL) -> [URL] {
        providers.flatMap(\.rows).filter { $0.groupParent == parent && $0.isSelectable }.map(\.id)
    }

    private func tickedURLs(_ provider: CloudProvider) -> [URL] {
        providers.filter { $0.root.provider == provider }.flatMap(\.rows).map(\.id).filter(ticked.contains)
    }

    /// Keeps only ticks on rows that are still offered: a row that went back to still syncing (or into
    /// conflict) loses its tick, so it can't be shown in Finder.
    private func dropStaleTicks() {
        ticked.formIntersection(providers.flatMap { $0.rows.filter(\.isSelectable).map(\.id) })
    }

    /// Walks every folder of `provider` on a background thread, like `ScanModel`'s stages.
    /// One walk per provider at a time: a second request while one runs is a no-op, so the running
    /// walk keeps its control (Stop reaches it) and its spinner.
    private func run(_ provider: CloudProvider) async {
        guard let app, !scanning.contains(provider) else { return }
        refreshAccess()
        guard !needsAccess.contains(provider) else { return }
        let roots = providers.filter { $0.root.provider == provider }.map(\.root)
        let control = ScanControl { _ in }
        controls[provider] = control
        scanning.insert(provider)
        let settings = app.organizeSettings
        let env = deps.env
        let rowsFor = deps.offloadRows
        let found = await BackgroundWork.runNonThrowing("andromeda.cloud.\(provider.rawValue)") {
            roots.map { root in (root.url, control.isCancelled ? [] : rowsFor(root, settings, env, control)) }
        }
        controls[provider] = nil
        scanning.remove(provider)
        guard !control.isCancelled else { return }
        checkedThisLaunch.insert(provider)
        for (url, rows) in found {
            guard let i = providers.firstIndex(where: { $0.root.url == url }) else { continue }
            providers[i].rows = rows
            providers[i].totalFreesAtLeast = rows.filter(\.isSelectable).reduce(0) { $0 + ($1.state.freesAtLeast ?? 0) }
        }
        dropStaleTicks()
    }
}
