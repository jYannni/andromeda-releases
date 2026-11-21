import AndromedaCore
import AndromedaOrganize
import Foundation
import Observation

/// Organize › Move to cloud: large, stale items from the Organize walk, one provider per plan
/// (§4.1). Picking and ticking change nothing; `review()` builds the plan and opens the review sheet
/// on `AppModel.organize`. Nothing is pre-ticked except an item sent here by **Organize these**.
@MainActor @Observable
public final class MoveToCloudModel {
    public private(set) var candidates: [MoveCandidate] = []
    public private(set) var ticked: Set<URL> = []
    public private(set) var isFinding = false
    /// True once a walk finished this launch.
    public private(set) var hasFound = false
    /// The cloud folder the plan goes to; one provider per plan.
    public private(set) var selectedRoot: CloudRoot?
    /// Set when **Organize these** sent an item the walk doesn't suggest.
    public private(set) var notSuggestedNote: String?

    @ObservationIgnored private let deps: AppDependencies
    /// Owns the settings, the cloud roots and the organize flow. Set by `AppModel.init`.
    @ObservationIgnored weak var app: AppModel?
    /// An item sent by **Organize these**, ticked once the walk has found it.
    @ObservationIgnored private var preselected: (url: URL, measuredBytes: Int64?)?

    init(deps: AppDependencies) { self.deps = deps }

    public var roots: [CloudRoot] { app?.organizeRoots ?? [] }

    /// **Organize these** on a large-item row: tick `url` here once candidates are known.
    public func preselect(_ url: URL, measuredBytes: Int64? = nil) {
        preselected = (url.standardizedFileURL, measuredBytes)
        notSuggestedNote = nil
        if hasFound { applyPreselection() }
    }

    /// The view opened: relist cloud folders (names only), keep or pick a destination, and walk for
    /// candidates once per launch, off the main actor.
    public func appear() async {
        guard let app else { return }
        app.refreshOrganizeRoots()
        if let current = selectedRoot, !app.organizeRoots.contains(current) { selectedRoot = nil }
        if selectedRoot == nil { selectedRoot = app.organizeRoots.first }
        if !hasFound { await find() } else { applyPreselection() }
    }

    /// **Look again**: walks again; ticks that are still candidates stay.
    public func findAgain() async { await find() }

    public func select(_ root: CloudRoot) {
        guard roots.contains(root) else { return }
        selectedRoot = root
    }

    public func toggle(_ url: URL) {
        guard candidates.contains(where: { $0.id == url }) else { return }
        if ticked.remove(url) == nil { ticked.insert(url) }
    }

    public var canReview: Bool { !ticked.isEmpty && selectedRoot != nil && app?.organize.isApplying == false }

    /// Builds the plan for the ticked items and the chosen provider (disk reads, off the main actor) and
    /// opens the review sheet. False when there is nothing to review.
    @discardableResult
    public func review() async -> Bool {
        guard let app, canReview, let root = selectedRoot else { return false }
        let chosen = candidates.filter { ticked.contains($0.id) }
        let env = deps.env
        let roots = app.organizeRoots
        let settings = app.organizeSettings
        let plan = await BackgroundWork.runNonThrowing("andromeda.organize.plan") {
            MoveToCloudPlanner(env: env, cloudRoots: roots, settings: settings, scanner: { _ in [] })
                .plan(chosen, to: root)
        }
        // An apply may have started while the plan was being built.
        guard canReview else { return false }
        app.organize.prepare(plan, provider: root.provider)
        return true
    }

    /// Whether the folder receipt offers **Move some of these to the cloud…**: the run made group folders
    /// and a cloud folder exists. The roots are those last listed (`AppModel.refreshOrganizeRoots`). Never for
    /// a run on a drive (plan 7): the cloud hand-off only moves folders in home.
    public var handOffAvailable: Bool {
        !(app?.organize.receipt?.createdGroupFolders.isEmpty ?? true) && !roots.isEmpty
            && !(app?.folderOrganize.isOnDrive ?? false)
    }

    /// The hand-off's **Review**: plans a move to `root` for exactly `urls` (nothing else, and nothing ticked
    /// for the user) and opens the same review sheet **Move to cloud** opens. False when nothing was chosen or
    /// an apply is running. The confirm sheet (default Cancel) still stands between this and any change.
    @discardableResult
    public func handOff(_ urls: [URL], to root: CloudRoot) async -> Bool {
        guard let app, !urls.isEmpty, roots.contains(root), !app.organize.isApplying else { return false }
        let chosen = await app.organize.measure(urls)
        guard !chosen.isEmpty else { return false }
        let env = deps.env
        let roots = app.organizeRoots
        let settings = app.organizeSettings
        let plan = await BackgroundWork.runNonThrowing("andromeda.organize.plan") {
            MoveToCloudPlanner(env: env, cloudRoots: roots, settings: settings, scanner: { _ in [] })
                .plan(chosen, to: root)
        }
        guard !app.organize.isApplying else { return false }
        app.organize.prepareHandOff(plan, provider: root.provider)
        return true
    }

    private func find() async {
        guard let app, !isFinding else { return }
        isFinding = true
        let env = deps.env
        let roots = app.organizeRoots
        let settings = app.organizeSettings
        let provider = deps.moveCandidates
        // As ScanModel: without Full Disk Access the walk never touches a protected folder (no TCC prompts).
        let readable = deps.fda() == .granted
        let found = await BackgroundWork.runNonThrowing("andromeda.organize.candidates") {
            provider(env, roots, settings, readable)
        }
        isFinding = false
        candidates = found
        hasFound = true
        ticked.formIntersection(found.map(\.id))
        applyPreselection()
    }

    private func applyPreselection() {
        guard let request = preselected else { return }
        preselected = nil
        let url = request.url
        // By path: a scan row's URL and the walk's may differ only in a trailing slash.
        if let match = candidates.first(where: { $0.id.standardizedFileURL.path == url.path }) {
            ticked.insert(match.id)
            notSuggestedNote = nil
        } else if let bytes = request.measuredBytes, let minimum = app?.organizeSettings.moveMinBytes, bytes < minimum {
            notSuggestedNote = Copy.Organize.belowMoveMinimum(url.lastPathComponent, minimum: ByteFormat.string(minimum))
        } else {
            notSuggestedNote = Copy.Organize.notSuggested(url.lastPathComponent)
        }
    }
}
