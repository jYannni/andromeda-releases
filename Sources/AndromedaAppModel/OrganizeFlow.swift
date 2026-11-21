import AndromedaCore
import AndromedaOrganize
import Foundation
import Observation

/// One move in the review sheet: the item, its size, and from → to (home-relative).
public struct OrganizeReviewRow: Identifiable, Equatable, Sendable {
    /// The plan step's id.
    public let id: UUID
    public let name: String
    public let sizeText: String
    public let fromTo: String
    /// The name it will have (the same as `name` unless it is renamed).
    public var newName: String = ""
    /// Folder organize: the destination folder relative to the organized folder ("Images/2024").
    public var destination: String = ""
    /// Unticked rows stay out of the plan (§6.1 per-row control). Always true for a move to cloud.
    public var ticked: Bool = true
    /// An installer: the row links to Storage, where it can be trashed (Organize never trashes).
    public var canTrashInStorage: Bool = false
    /// Folder organize: the id of the group this move belongs to; nil outside groups.
    public var groupID: String? = nil
}

/// One group card in the review: a set of files that become a new folder, and why they belong together.
public struct OrganizeGroupCard: Equatable, Sendable, Identifiable {
    public let id: String
    /// The new folder's name.
    public let name: String
    /// The parent folder it goes inside, if any.
    public let parent: String?
    /// The reasons, as the card says them (`Copy.Organize.reason`).
    public let reasons: [String]
    /// The group's moves (files sent to Unsorted aren't counted).
    public let count: Int
    public let tickedCount: Int
    /// A suggestion: its rows start unticked.
    public let isSuggestion: Bool
    /// The user's folders (relative paths) the group could go into, when more than one matches; the card
    /// then offers them, and a new folder, through `FolderOrganizeModel.chooseDestination`. Empty otherwise.
    public var choices: [String] = []
    /// Single loose files going into one of the user's folders: not a name group, so it can't be renamed,
    /// kept together with another or nested.
    public var isYourFolder: Bool = false
    /// A saved rule's group: the rule's pattern, for display. Nil for every other group.
    public var ruleName: String? = nil
    /// Whether **Remember this** can make a rule from the group: a name group (same name, a shared word or a
    /// numbered series), not a rule's, the Move to… group or a your-folder group, and not undecided.
    public var canRemember: Bool = false
    /// Two or more of the user's folders match and none is chosen yet: its rows start unticked, and it can't be
    /// remembered until the user chooses where it goes.
    public var isUndecided: Bool = false

    /// A rule's group or the Move to… group: placed by the user's own choice, so not renamed, merged or left.
    public var isPlacedByYou: Bool { ruleName != nil || id == PlanGroup.movedID }
}

/// The user's own tick choices, by source path, carried across a re-plan of the same folder.
public struct TickState: Equatable, Sendable {
    public var ticked: Set<String> = []
    public var unticked: Set<String> = []

    public init(ticked: Set<String> = [], unticked: Set<String> = []) {
        self.ticked = ticked
        self.unticked = unticked
    }
}

/// One folder of the proposed tree, with how many ticked files go into it.
public struct OrganizeTreeFolder: Equatable, Sendable {
    /// Relative to the organized folder: "Images/2024".
    public let path: String
    public let count: Int
}

/// Something the plan leaves alone, and why.
public struct OrganizeLeftAloneRow: Equatable, Sendable {
    public let name: String
    public let reason: String
}

/// What the review sheet shows before anything moves (§4.1 step 3).
public struct OrganizeReview: Equatable, Sendable {
    public let plan: OrganizePlan
    public let provider: CloudProvider?
    public let title: String
    public let rows: [OrganizeReviewRow]
    public let leftAlone: [OrganizeLeftAloneRow]
    /// For a cloud move: the two §4.1 warnings, verbatim.
    public let warnings: [String]
    public let confirmTitle: String
    /// False when every item is left alone: there is nothing to confirm.
    public let canConfirm: Bool
    /// Always true: the sheet's default button is Cancel.
    public let cancelIsDefault: Bool
    /// Folder organize only: the organized folder's name; nil for a move to cloud.
    public var folderName: String? = nil
    /// Folder organize: "Unsorted — needs you".
    public var unsorted: [OrganizeLeftAloneRow] = []
    /// Folder organize: the proposed folders that ticked rows go into, in plan order.
    public var tree: [OrganizeTreeFolder] = []
    /// Folder organize: the name groups, in plan order.
    public var groups: [OrganizeGroupCard] = []
    /// Folder organize: suggested parent folders over several groups.
    public var parentSuggestions: [ParentSuggestion] = []
}

public struct OrganizeReceipt: Equatable, Sendable {
    public let batchID: UUID
    public let headline: String
    /// One per move step; created folders aren't listed.
    public let rows: [ReceiptRow]
    /// For a cloud move: the items still use space here until they upload.
    public let note: String?
    /// Set when the journal couldn't be written and the run stopped early.
    public let stoppedNote: String?
    /// Folder organize: "Undo this run" when something moved; nil for a move to cloud (Undo is in History).
    public var undoTitle: String? = nil
    /// Folder organize: the organized folder's name; nil for a move to cloud.
    public var folderName: String? = nil
    /// The external volume this run changed, if any.
    public var volume: PlanVolume? = nil
    /// Folder organize: the run's groups, each undoable on its own; empty for a move to cloud and for old runs.
    public var groups: [UndoableGroup] = []
    /// Folder organize: the group folders this run created (their `createFolder` is done), outermost only: a
    /// group's folder inside another created one (`Lessons/Unit 1`, a rule's `Archive/Clients`) moves with it.
    /// Your existing folders, shared parents and kind folders aren't here. Empty for a move to cloud.
    public var createdGroupFolders: [URL] = []
}

/// One folder of a run in the "Move some of these to the cloud…" sheet. Choosing is the sheet's; nothing here is ticked.
public struct CloudHandOffRow: Identifiable, Equatable, Sendable {
    public let id: URL
    public let name: String
    public let usesText: String
    public let freesText: String
    public let lastUsedText: String
    /// Over `OrganizeSettings.moveMinBytes` and not used for `moveMinAge`, as Move to cloud judges today.
    public let recommended: Bool

    public init(id: URL, name: String, usesText: String, freesText: String, lastUsedText: String, recommended: Bool) {
        self.id = id
        self.name = name
        self.usesText = usesText
        self.freesText = freesText
        self.lastUsedText = lastUsedText
        self.recommended = recommended
    }
}

/// How far a running apply or undo is: `done` of `total` files (created folders aren't counted).
public struct OrganizeProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// Plan → review → (export) → apply → receipt → undo, for any `OrganizePlan` (shared with folder
/// organize). Nothing changes on disk until `apply(planID:)`, which runs only the plan the user reviewed, once.
@MainActor @Observable
public final class OrganizeFlow {
    /// The plan under review as it will be applied and exported: the ticked moves and only the
    /// `createFolder` steps they need (ruling R-C12). nil when none is open.
    public private(set) var plan: OrganizePlan?
    /// Steps left out of the plan: the user's unticks, and folder suggestions not ticked. Set by every `prepare`.
    public private(set) var excluded: Set<UUID> = []
    /// The user's tick changes on the open folder plan, by source path (what `prepare(folder:carrying:)` takes
    /// back after a re-plan). Starts as the carried state; empty for a move to cloud.
    public private(set) var tickState = TickState()
    public private(set) var review: OrganizeReview?
    public private(set) var receipt: OrganizeReceipt?
    public private(set) var isApplying = false
    public private(set) var isUndoing = false
    /// Why the last undo didn't put everything back; cleared by the next undo.
    public private(set) var undoProblem: String?
    /// Why the last Apply ran nothing: the plan's drive isn't the volume mounted where it was planned now.
    /// Cleared by the next Apply.
    public private(set) var applyProblem: String?
    /// The last apply's or undo's progress, reset when the next one starts. Views show it only while
    /// `isApplying` or `isUndoing`.
    public private(set) var progress: OrganizeProgress?

    /// The batch `apply()` is writing right now; nil otherwise. History never calls it interrupted.
    public private(set) var applyingBatchID: UUID?
    /// The batch `undo(batchID:)` is putting back right now; nil otherwise. A drive mount never settles it.
    public private(set) var undoingBatchID: UUID?
    /// Waits for History's launch-time settle of interrupted runs. Set by `AppModel`.
    @ObservationIgnored var launchSettle: @MainActor () async -> Void = {}
    /// Test seam: runs on the apply thread once, after the first step is settled in the journal.
    @ObservationIgnored var afterFirstStep: (@Sendable () -> Void)?

    /// Test seams for the cloud hand-off: a folder's size, and when it was last used (a move resets
    /// "date added", so it's ignored).
    @ObservationIgnored var handOffSize: @Sendable (URL) -> SizeResult = { AllocatedSizer().size(of: $0) }
    @ObservationIgnored var handOffLastUse: @Sendable (URL) -> LastUse? = { LastUsedReader().lastUse(of: $0, ignoringAdded: true) }

    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private let journal: Journal?
    @ObservationIgnored private var appliedPlans: Set<UUID> = []
    /// The plan as prepared, before any unticking.
    @ObservationIgnored private var fullPlan: OrganizePlan?
    @ObservationIgnored private var provider: CloudProvider?
    /// Set for a folder organize plan.
    @ObservationIgnored private var folder: FolderPlanResult?
    /// R-C19: the plan ID for the plan as ticked. nil (the full plan's ID) until the first tick change;
    /// every tick change makes a new one, so an export and an applied batch with one ID always match.
    @ObservationIgnored private var tickedPlanID: UUID?
    /// The folder receipt a cloud hand-off's review replaced (`prepareHandOff`): Cancel brings it back.
    @ObservationIgnored private var receiptAside: OrganizeReceipt?

    /// `journal` is the one shared with removal and History; nil means nothing can be applied.
    init(deps: AppDependencies, journal: Journal?) {
        self.deps = deps
        self.journal = journal
    }

    // MARK: Review

    /// Opens the review sheet for `plan`. `provider` is set for a move to cloud. Refused while a plan is
    /// being applied: the sheet under apply stays as it is.
    public func prepare(_ plan: OrganizePlan, provider: CloudProvider?) {
        guard !isApplying else { return }
        folder = nil
        open(plan, provider: provider, excluded: [], ticks: TickState())
    }

    /// Opens the review for a folder organize plan (§6.1, boards 07–09). A move starts unticked when its
    /// source is in `carrying.unticked`, ticked when it is in `carrying.ticked`, and otherwise as its group
    /// starts (a suggestion's rows unticked); moves outside groups start ticked.
    public func prepare(folder result: FolderPlanResult, carrying: TickState = TickState()) {
        guard !isApplying else { return }
        folder = result
        let suggested = Set(result.groups.filter { !$0.startsTicked }.flatMap(\.stepIDs))
        var excluded: Set<UUID> = []
        for step in result.plan.steps {
            guard case .move(let from, _) = step.action else { continue }
            let path = Self.sourcePath(from)
            if carrying.unticked.contains(path) || (!carrying.ticked.contains(path) && suggested.contains(step.id)) {
                excluded.insert(step.id)
            }
        }
        open(result.plan, provider: nil, excluded: excluded, ticks: carrying)
    }

    /// The receipt's cloud hand-off: opens the move-to-cloud review for `plan` as `prepare` does, keeping the
    /// open folder receipt aside. Cancel puts it back; an apply shows the cloud run's receipt instead.
    public func prepareHandOff(_ plan: OrganizePlan, provider: CloudProvider) {
        guard !isApplying else { return }
        let kept = receipt?.folderName != nil ? receipt : nil
        prepare(plan, provider: provider)
        receiptAside = kept
    }

    private func open(_ plan: OrganizePlan, provider: CloudProvider?, excluded: Set<UUID>, ticks: TickState) {
        receiptAside = nil
        fullPlan = plan
        self.provider = provider
        self.excluded = excluded
        tickState = ticks
        tickedPlanID = nil
        receipt = nil
        rebuild()
    }

    /// Ticks or unticks one move. Unticking also drops any `createFolder` step no ticked move needs;
    /// the review, `plan` (what apply and export use) and `folderSummary` follow. Refused while applying.
    public func toggle(stepID: UUID) {
        guard !isApplying, let full = fullPlan,
              full.steps.contains(where: { $0.id == stepID && Self.isMove($0) }) else { return }
        setTicked(excluded.contains(stepID), stepIDs: [stepID], in: full)
    }

    /// Ticks every row of the group when any is unticked; unticks them all only when all are ticked.
    /// Refused while applying.
    public func toggleGroup(id: String) {
        guard !isApplying, let full = fullPlan, let group = folder?.groups.first(where: { $0.id == id }) else { return }
        let moves = Set(full.steps.filter(Self.isMove).map(\.id))
        let ids = group.stepIDs.filter(moves.contains)
        guard !ids.isEmpty else { return }
        setTicked(ids.contains(where: excluded.contains), stepIDs: ids, in: full)
    }

    /// Records the current tick of each of `stepIDs` (moves of the open folder plan) in `tickState`, as if
    /// the user had chosen it, so a re-plan that moves the file out of its group (or into another) keeps
    /// what the user sees. `onlyTicked`: pins only the ticked ones (unticked ones then follow their new
    /// group's default). The plan and its ID are unchanged.
    public func pinCurrentTicks(stepIDs: [UUID], onlyTicked: Bool = false) {
        guard !isApplying, folder != nil, let full = fullPlan else { return }
        let wanted = Set(stepIDs)
        for step in full.steps where wanted.contains(step.id) {
            guard case .move(let from, _) = step.action else { continue }
            let path = Self.sourcePath(from)
            if !excluded.contains(step.id) {
                tickState.unticked.remove(path)
                tickState.ticked.insert(path)
            } else if !onlyTicked {
                tickState.ticked.remove(path)
                tickState.unticked.insert(path)
            }
        }
    }

    /// Records `stepIDs` (moves of the open folder plan) as ticked in `tickState`, as if the user had ticked
    /// them, so the re-plan that follows starts them ticked. The plan and its ID are unchanged.
    public func pinTicked(stepIDs: [UUID]) {
        guard !isApplying, folder != nil, let full = fullPlan else { return }
        let wanted = Set(stepIDs)
        for step in full.steps where wanted.contains(step.id) {
            guard case .move(let from, _) = step.action else { continue }
            let path = Self.sourcePath(from)
            tickState.unticked.remove(path)
            tickState.ticked.insert(path)
        }
    }

    /// Ticks or unticks `stepIDs` (moves of `full`), records the choice by source path, and makes a new
    /// plan ID (R-C19).
    private func setTicked(_ on: Bool, stepIDs: [UUID], in full: OrganizePlan) {
        let sources = Dictionary(full.steps.compactMap { step -> (UUID, String)? in
            guard case .move(let from, _) = step.action else { return nil }
            return (step.id, Self.sourcePath(from))
        }, uniquingKeysWith: { a, _ in a })
        for id in stepIDs {
            if on { excluded.remove(id) } else { excluded.insert(id) }
            guard let path = sources[id] else { continue }
            if on {
                tickState.unticked.remove(path)
                tickState.ticked.insert(path)
            } else {
                tickState.ticked.remove(path)
                tickState.unticked.insert(path)
            }
        }
        tickedPlanID = UUID()
        rebuild()
    }

    private static func sourcePath(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Board 07's badges for the plan as it stands (ticked moves only); zeros when no folder plan is open.
    public var folderSummary: FolderSummary {
        guard let folder, let plan else {
            return FolderSummary(foldersToCreate: 0, filesToMove: 0, filesToRename: 0, leftForYou: 0)
        }
        var creates = 0, moves = 0, renames = 0
        for step in plan.steps {
            switch step.action {
            case .createFolder: creates += 1
            case .copy: break
            case .move(let from, let to):
                if from.deletingLastPathComponent().standardizedFileURL.path != to.deletingLastPathComponent().standardizedFileURL.path {
                    moves += 1
                }
                if from.lastPathComponent != to.lastPathComponent { renames += 1 }
            }
        }
        return FolderSummary(foldersToCreate: creates, filesToMove: moves, filesToRename: renames, leftForYou: folder.unsorted.count)
    }

    private static func isMove(_ step: PlannedStep) -> Bool {
        if case .move = step.action { return true }
        return false
    }

    /// The plan with only ticked moves, plus the `createFolder` steps on their destinations' parent
    /// chains, under `planID`. With nothing unticked, the plan's steps exactly as prepared.
    private static func filtered(_ plan: OrganizePlan, excluding excluded: Set<UUID>, planID: UUID) -> OrganizePlan {
        guard !excluded.isEmpty else {
            var same = OrganizePlan(planID: planID, title: plan.title, steps: plan.steps, leftAlone: plan.leftAlone,
                                    cloudOrganizeFolder: plan.cloudOrganizeFolder)
            same.volume = plan.volume
            return same
        }
        let moves = plan.steps.filter { isMove($0) && !excluded.contains($0.id) }
        let parents = moves.compactMap { step -> String? in
            guard case .move(_, let to) = step.action else { return nil }
            return to.deletingLastPathComponent().standardizedFileURL.path
        }
        let steps = plan.steps.filter { step in
            switch step.action {
            case .move, .copy: return !excluded.contains(step.id)
            case .createFolder(let url):
                let path = url.standardizedFileURL.path
                return parents.contains { $0 == path || $0.hasPrefix(path + "/") }
            }
        }
        var ticked = OrganizePlan(planID: planID, title: plan.title, steps: steps, leftAlone: plan.leftAlone,
                                  cloudOrganizeFolder: plan.cloudOrganizeFolder)
        ticked.volume = plan.volume
        return ticked
    }

    private func rebuild() {
        guard let full = fullPlan else { return }
        let home = deps.env.home
        func shown(_ url: URL) -> String { Copy.Scan.displayPath(url, home: home) }
        let folderPath = folder.flatMap { _ in Self.folderURL(full)?.standardizedFileURL.path }
        func relative(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            if let base = folderPath, path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
            return shown(url)
        }
        let trashable = folder?.canTrashInStorage ?? []
        var groupOf: [UUID: String] = [:]
        for g in folder?.groups ?? [] { for id in g.stepIDs { groupOf[id] = g.id } }
        let rows = full.steps.compactMap { step -> OrganizeReviewRow? in
            guard case .move(let from, let to) = step.action else { return nil }
            let size = step.snapshot.map { ByteFormat.string($0.bytes) } ?? Copy.Rows.sizeNotMeasured
            return OrganizeReviewRow(
                id: step.id, name: from.lastPathComponent, sizeText: size,
                fromTo: Copy.Organize.fromTo(shown(from.deletingLastPathComponent()), shown(to.deletingLastPathComponent())),
                newName: to.lastPathComponent, destination: relative(to.deletingLastPathComponent()),
                ticked: !excluded.contains(step.id), canTrashInStorage: trashable.contains(step.id),
                groupID: groupOf[step.id])
        }
        let ticked = rows.filter(\.ticked)
        let plan = Self.filtered(full, excluding: excluded, planID: tickedPlanID ?? full.planID)
        let left = plan.leftAlone.map { OrganizeLeftAloneRow(name: $0.url.lastPathComponent, reason: $0.reason) }
        var tree: [OrganizeTreeFolder] = []
        for row in ticked {
            if let i = tree.firstIndex(where: { $0.path == row.destination }) {
                tree[i] = OrganizeTreeFolder(path: row.destination, count: tree[i].count + 1)
            } else {
                tree.append(OrganizeTreeFolder(path: row.destination, count: 1))
            }
        }
        self.plan = plan
        let confirm: String
        if folder != nil {
            confirm = Copy.Organize.applyPlan
        } else {
            confirm = provider.map { Copy.Organize.confirmMove(ticked.count, provider: $0) }
                ?? Copy.Organize.confirmMove(ticked.count)
        }
        review = OrganizeReview(
            plan: plan, provider: provider, title: plan.title, rows: rows, leftAlone: left,
            warnings: provider.map { [Copy.Organize.uploadWarning($0), Copy.Organize.stillUsesSpace] } ?? [],
            confirmTitle: confirm, canConfirm: !ticked.isEmpty, cancelIsDefault: true,
            folderName: folder.map { _ in plan.title },
            unsorted: (folder?.unsorted ?? []).map { OrganizeLeftAloneRow(name: $0.url.lastPathComponent, reason: $0.reason) },
            tree: tree,
            groups: Self.cards(folder?.groups ?? [], rows: rows),
            parentSuggestions: folder?.parentSuggestions ?? [])
    }

    private static func cards(_ groups: [PlanGroup], rows: [OrganizeReviewRow]) -> [OrganizeGroupCard] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return groups.map { g in
            let mine = g.stepIDs.compactMap { byID[$0] }
            return OrganizeGroupCard(
                id: g.id, name: g.id == PlanGroup.movedID ? Copy.Organize.movedByYou : g.name, parent: g.parent,
                reasons: g.reasons.map(Copy.Organize.reason),
                count: mine.count, tickedCount: mine.filter(\.ticked).count, isSuggestion: !g.startsTicked,
                choices: g.choices, isYourFolder: g.isYourFolder,
                ruleName: g.reasons.lazy.compactMap { if case .rule(let p) = $0 { p } else { nil } }.first,
                canRemember: FolderOrganizeModel.canRemember(g), isUndecided: g.isUndecided)
        }
    }

    /// The organized folder: the parent of the plan's moved files (all are direct children).
    private static func folderURL(_ plan: OrganizePlan) -> URL? {
        for step in plan.steps {
            if case .move(let from, _) = step.action { return from.deletingLastPathComponent() }
        }
        return nil
    }

    /// Cancel: closes the sheet; nothing changed. Refused while the plan is being applied.
    public func cancel() {
        guard !isApplying else { return }
        plan = nil
        review = nil
        fullPlan = nil
        folder = nil
        excluded = []
        tickState = TickState()
        tickedPlanID = nil
        // A cancelled hand-off changed nothing: the folder's receipt it replaced comes back.
        if let aside = receiptAside {
            receipt = aside
            receiptAside = nil
        }
    }

    /// Saves the plan under review through the save panel (JSON or text). Never applies it.
    public func exportPlan(json: Bool) async -> Bool {
        guard let plan else { return false }
        let groups = folder?.groups ?? []
        let data: Data
        if json {
            guard let encoded = try? PlanExport.json(plan, groups: groups) else { return false }
            data = encoded
        } else {
            data = Data(PlanExport.text(plan, groups: groups).utf8)
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        let name = Copy.Organize.planFileName(date: format.string(from: Date()), json: json)
        return await deps.workspace.saveFile(suggestedName: name, contents: data)
    }

    // MARK: Apply

    /// Settles an abandoned automation batch before the caller observes or applies new work.
    func recoverAutomationHistory(_ history: FolderAutomationHistory, holding lease: FolderAutomationLease) async -> Bool {
        guard let journal else { return false }
        let trasher = deps.trasher, volumes = deps.volumes
        return await BackgroundWork.runNonThrowing("andromeda.organize.automation-recover") {
            guard (try? HistoryModel.settleInterruptedAutomation(journal: journal, trasher: trasher,
                    volumes: volumes, history: history, holding: lease)) != nil else { return false }
            return history.interruptedBatchIDs(in: journal)?.isEmpty == true
        }
    }

    /// Runs a previously enabled rule under the caller's automation lease.
    func applyAutomation(_ plan: OrganizePlan, control: ScanControl) async -> [StepResult] {
        guard plan.automationDirectories != nil, !plan.steps.isEmpty, let journal,
              !isApplying, !isUndoing, !control.isCancelled else { return [] }
        isApplying = true
        defer { isApplying = false; applyingBatchID = nil }
        let batch = UUID()
        applyingBatchID = batch
        let trasher = deps.trasher, env = deps.env
        return await BackgroundWork.runNonThrowing("andromeda.organize.automation-apply") {
            let results = PlanExecutor(journal: journal, automationEnvironment: env).apply(
                plan, batchID: batch, shouldContinue: { !control.isCancelled }, batchCopyReceipts: true)
            if control.isCancelled {
                try? BatchUndo(journal: journal, trasher: trasher).settleInterrupted(batchID: batch)
            }
            return results
        }
    }

    /// Runs the reviewed plan once, off the main actor, then shows the receipt. `planID` is the plan the
    /// user confirmed; it must be the open review's plan (another review may have replaced it). Returns []
    /// (and changes nothing) without that review, without a journal, or for a plan that already ran.
    /// `progress` follows the moves as they settle.
    public func apply(planID: UUID) async -> [StepResult] {
        guard let review, review.plan.planID == planID, review.canConfirm, let journal, !isApplying, !isUndoing,
              !appliedPlans.contains(planID), !appliedPlans.contains(fullPlan?.planID ?? planID) else { return [] }
        let plan = review.plan
        applyProblem = nil
        if review.provider != nil {
            let protected = deps.organizeSettings.load().moveProtectedFolders
            if !protected.isEmpty, plan.steps.contains(where: { step in
                guard case .move(let source, _) = step.action else { return false }
                return MoveToCloudPlanner.isProtectedProject(source, folders: protected)
            }) {
                applyProblem = "A project folder is now protected. Review the move again to leave it in place."
                return []
            }
        }
        // A plan on a drive runs only on that drive: the volume mounted at the planned mount point must still be
        // the planned UUID (a same-named drive swapped in while the review was open must not receive its folders).
        if let volume = plan.volume {
            let mounted = deps.volumes
            let supportsExclusiveRename = deps.driveSupportsExclusiveRename
            let (here, supportsMove) = await BackgroundWork.runNonThrowing("andromeda.organize.drive-check") {
                let here = mounted().first { $0.id == volume.uuid }
                guard let here, here.isOrganizable, here.url.standardizedFileURL.path == volume.mountPath
                else { return (here, nil as Bool?) }
                return (here, supportsExclusiveRename(here.url))
            }
            guard !Task.isCancelled, self.review?.plan == plan, self.review?.canConfirm == true,
                  !isApplying, !isUndoing, !appliedPlans.contains(planID),
                  !appliedPlans.contains(fullPlan?.planID ?? planID) else { return [] }
            guard let here, here.url.standardizedFileURL.path == volume.mountPath else {
                applyProblem = Copy.Drives.notConnected(volume.name ?? URL(fileURLWithPath: volume.mountPath).lastPathComponent)
                return []
            }
            guard here.isOrganizable else {
                applyProblem = here.kind == .timeMachine ? Copy.Drives.timeMachineNote : Copy.Drives.readOnlyNote
                return []
            }
            guard supportsMove != false else {
                applyProblem = Copy.Drives.organizeFormatNote
                return []
            }
        }
        appliedPlans.insert(plan.planID)
        if let full = fullPlan?.planID { appliedPlans.insert(full) }
        isApplying = true
        let total = plan.steps.filter(Self.isMove).count
        progress = OrganizeProgress(done: 0, total: total)
        // Interrupted runs found at launch are settled before anything new is journaled.
        await launchSettle()
        let batchID = UUID()
        applyingBatchID = batchID
        let hold = afterFirstStep
        // Only the newest tick waits for the main actor (T11 F1): an unbounded stream queued one element per
        // move, so the text trailed the disk and the receipt waited for the queue to drain.
        let (ticks, sink) = AsyncStream.makeStream(of: OrganizeProgress.self, bufferingPolicy: .bufferingNewest(1))
        let shown = Task { @MainActor [weak self] in
            for await tick in ticks { self?.progress = tick }
        }
        let results = await BackgroundWork.runNonThrowing("andromeda.organize.apply") {
            var first = true
            var done = 0
            let results = PlanExecutor(journal: journal).apply(plan, batchID: batchID) { result in
                if case .move = result.step.action {
                    done += 1
                    sink.yield(OrganizeProgress(done: done, total: total))
                }
                if first { first = false; hold?() }
            }
            sink.finish()
            return results
        }
        await shown.value
        // The final count, whatever the coalescing dropped: the moves the run reached.
        progress = OrganizeProgress(done: results.filter { Self.isMove($0.step) }.count, total: total)
        applyingBatchID = nil
        isApplying = false
        self.plan = nil
        self.review = nil
        fullPlan = nil
        folder = nil
        excluded = []
        tickState = TickState()
        tickedPlanID = nil
        receiptAside = nil
        var made = Self.receipt(review, results: results, batchID: batchID)
        if review.folderName != nil { made.groups = await loadGroups(batchID: batchID) }
        receipt = made
        return results
    }

    private static func receipt(_ review: OrganizeReview, results: [StepResult], batchID: UUID) -> OrganizeReceipt {
        let byStep = Dictionary(results.map { ($0.step.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [ReceiptRow] = []
        var moved = 0, skipped = 0, problems = 0
        for row in review.rows where row.ticked {
            guard let result = byStep[row.id] else {
                rows.append(ReceiptRow(title: row.name, outcomeText: Copy.Receipt.notMoved, ok: false, restorableEntryID: nil))
                skipped += 1
                continue
            }
            let text: String
            switch result.outcome {
            case .done:
                moved += 1
                text = review.provider.map(Copy.Organize.movedTo) ?? Copy.Organize.moved
            case .skipped:
                skipped += 1
                text = OutcomeText.text(for: result.outcome, reversible: true, appName: nil)
            case .failed(let message):
                problems += 1
                text = Copy.Organize.couldntMove(message)
            case .restored, .permanentlyDeleted, .planned:
                text = OutcomeText.text(for: result.outcome, reversible: true, appName: nil)
            }
            rows.append(ReceiptRow(title: row.name, outcomeText: text, ok: result.outcome == .done, restorableEntryID: nil))
        }
        // Folders a group needed that this run made (shared parents and kind folders have no group), outermost of
        // each chain only: handing over a folder takes what is inside it.
        let made: [URL] = review.folderName == nil ? [] : results.compactMap { result in
            guard result.step.groupID != nil, result.outcome == .done,
                  case .createFolder(let url) = result.step.action else { return nil }
            return url
        }
        let keys = made.map { NamingRules.key($0.standardizedFileURL.path) }
        let created = zip(made, keys).filter { _, key in !keys.contains { key.hasPrefix($0 + "/") } }.map(\.0)
        let headline = review.folderName.map {
            Copy.Organize.folderReceiptHeadline(folder: $0, moved: moved, skipped: skipped, problems: problems)
        } ?? Copy.Organize.receiptHeadline(moved: moved, provider: review.provider, skipped: skipped, problems: problems)
        return OrganizeReceipt(
            batchID: batchID,
            headline: headline,
            rows: rows,
            note: review.provider != nil && moved > 0 ? Copy.Organize.stillUsesSpace : nil,
            stoppedNote: results.contains { $0.journalError != nil } ? Copy.Organize.applyStopped : nil,
            undoTitle: review.folderName != nil && moved > 0 ? Copy.Organize.undoRun : nil,
            folderName: review.folderName,
            volume: review.plan.volume,
            createdGroupFolders: created)
    }

    public func closeReceipt() { receipt = nil }

    // MARK: Cloud hand-off

    /// The open receipt's new group folders with their size and last use, measured off the main actor. A folder
    /// whose last use can't be read (empty, or unreadable) is left out: Move to cloud couldn't plan it either.
    public func cloudHandOffRows() async -> [CloudHandOffRow] {
        guard let urls = receipt?.createdGroupFolders, !urls.isEmpty else { return [] }
        let settings = deps.organizeSettings.load()
        let measured = await measure(urls)
        let now = Date()
        return measured.map { candidate in
            let recommended = candidate.usesBytes >= settings.moveMinBytes
                && now.timeIntervalSince(candidate.lastUse.date) > settings.moveMinAge
            return CloudHandOffRow(
                id: candidate.id, name: candidate.id.lastPathComponent,
                usesText: Copy.Rows.uses(ByteFormat.string(candidate.usesBytes)),
                freesText: candidate.freesAtLeast.map { Copy.Organize.frees(ByteFormat.string($0)) } ?? Copy.Organize.freesUnknown,
                lastUsedText: Copy.Organize.lastUse(candidate.lastUse), recommended: recommended)
        }
    }

    /// `MoveCandidate`s for exactly `urls`, in order, sized and dated off the main actor.
    func measure(_ urls: [URL]) async -> [MoveCandidate] {
        let size = handOffSize, lastUse = handOffLastUse
        return await BackgroundWork.runNonThrowing("andromeda.organize.handoff") {
            urls.compactMap { url in
                guard let use = lastUse(url) else { return nil }
                let sized = size(url)
                return MoveCandidate(id: url, usesBytes: sized.bytes, freesAtLeast: sized.privateBytes, lastUse: use)
            }
        }
    }

    /// The batch's groups from the journal, read off the main actor; [] without a journal or on a read error.
    private func loadGroups(batchID: UUID) async -> [UndoableGroup] {
        guard let journal else { return [] }
        let trasher = deps.trasher, volumes = deps.volumes
        return await BackgroundWork.runNonThrowing("andromeda.organize.groups") {
            (try? BatchUndo(journal: journal, trasher: trasher, volumes: volumes).groups(batchID: batchID)) ?? []
        }
    }

    // MARK: Undo

    /// Puts an applied batch back (reverse order, journal and disk only), off the main actor.
    /// Anything that can't go back is left alone; `undoProblem` says how many of the items History
    /// lists couldn't go back (for a cloud move, its moves; created folders aren't counted). A folder
    /// Andromeda made that stays because something is still in it isn't counted either: the item that
    /// kept it is. `progress` follows the moves put back. Refused while applying.
    /// With `groupID`, only that group of the run goes back.
    public func undo(batchID: UUID, groupID: String? = nil, entryID: UUID? = nil) async {
        guard let journal, !isUndoing, !isApplying else { return }
        isUndoing = true
        undoingBatchID = batchID
        undoProblem = nil
        progress = nil
        let trasher = deps.trasher, volumes = deps.volumes
        let (ticks, sink) = AsyncStream.makeStream(of: OrganizeProgress.self, bufferingPolicy: .bufferingNewest(1))
        let shown = Task { @MainActor [weak self] in
            for await tick in ticks { self?.progress = tick }
        }
        // nil: the journal couldn't be read or written, so the undo stopped part-way.
        let problem: String? = await BackgroundWork.runNonThrowing("andromeda.organize.undo") {
            defer { sink.finish() }
            let lease: FolderAutomationLease?
            do {
                if try journal.load(batchID: batchID).entries.contains(where: {
                    $0.relatesTo == nil && $0.catalogEntryID == OrganizeCatalogID.automation
                }) {
                    guard let acquired = try FolderAutomationLease.tryAcquire(in: journal.directory) else {
                        return Copy.Organize.automationBusyUndo
                    }
                    lease = acquired
                } else {
                    lease = nil
                }
            } catch {
                return Copy.Organize.undoStopped
            }
            defer { lease?.release() }
            guard let results = try? BatchUndo(journal: journal, trasher: trasher, volumes: volumes).undo(
                      batchID: batchID, groupID: groupID, entryID: entryID,
                      progress: { done, total in sink.yield(OrganizeProgress(done: done, total: total)) }),
                  let entries = try? journal.load().entries else { return Copy.Organize.undoStopped }
            let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            let cloud = entries.contains { $0.batchID == batchID && $0.catalogEntryID == OrganizeCatalogID.cloudMove }
            let incomplete = results.filter { result in
                guard result.outcome != .restored else { return false }
                let action = byID[result.entryID]?.resolvedAction
                if action == .createFolder, result.outcome == .skipped(.notEmpty) { return false }
                return !cloud || action == .move
            }
            guard let first = incomplete.first else { return nil }
            if incomplete.allSatisfy({ $0.outcome == .skipped(.volumeNotConnected) }),
               let entry = byID[first.entryID], let uuid = entry.volumeUUID {
                let name = entry.volumeName
                    ?? entry.volumeMount.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? uuid
                return Copy.Drives.notConnected(name)
            }
            return Copy.Organize.undoIncomplete(incomplete.count)
        }
        await shown.value
        // The open receipt's group list follows the journal.
        if receipt?.batchID == batchID, receipt?.folderName != nil {
            let fresh = await loadGroups(batchID: batchID)
            receipt?.groups = fresh
        }
        isUndoing = false
        undoingBatchID = nil
        undoProblem = problem
    }
}
