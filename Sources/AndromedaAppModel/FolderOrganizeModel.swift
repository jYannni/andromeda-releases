import AndromedaCore
import AndromedaOrganize
import Foundation
import Observation

/// Organize › Organize a folder (§6.1, boards 07–09): pick Downloads, Desktop, a drive or any folder, see the
/// proposed plan, tick, apply, undo. Planning reads the disk off the main actor and changes nothing;
/// the plan opens on `AppModel.organize`, which applies, exports and undoes it.
///
/// No Full Disk Access gate (ruling R-C13): the user picked the folder, so macOS may ask once.
@MainActor @Observable
public final class FolderOrganizeModel {
    /// `drive` carries the volume's id (`ExternalVolume.id`).
    public enum Place: Equatable, Sendable { case downloads, desktop, drive(String), chosen }

    /// The folder being organized; nil until one is picked.
    public private(set) var folder: URL?
    /// The §6.1 naming toggles. Changing one plans the folder again.
    public private(set) var options = NamingOptions()
    public private(set) var isPlanning = false
    /// Set when the plan says the folder itself is left alone (R-C4); the reason is shown instead of a plan.
    public private(set) var refusedReason: String?
    /// The user's changes to this folder's groups. Picking another folder clears them.
    public private(set) var edits = GroupEdits()
    /// Whether files outside groups are sorted by kind, as the last plan did it.
    public private(set) var sortRestByKind = true

    /// The Sort the rest by kind choice for this folder: nil until the first plan, then the planner's
    /// automatic choice, until the user flips it.
    @ObservationIgnored private var sortRestChoice: Bool?
    /// The last plan opened for `folder` (nil after picking another): edits are checked against its groups.
    @ObservationIgnored private var last: FolderPlanResult?
    /// Set when a plan was asked for while one was running; the running one plans again when it finishes.
    @ObservationIgnored private var planAgain = false

    @ObservationIgnored private let deps: AppDependencies
    /// `deps.env` with the drives mounted when the folder was picked: organizable roots and refused ones.
    @ObservationIgnored private var env: ScanEnvironment
    /// Owns the cloud roots and the organize flow. Set by `AppModel.init`.
    @ObservationIgnored weak var app: AppModel?
    /// Test seam: the screen-capture lookup the classifier uses.
    @ObservationIgnored var isScreenCapture: @Sendable (URL) -> Bool = { KindClassifier.liveIsScreenCapture($0) }

    init(deps: AppDependencies) {
        self.deps = deps
        env = deps.env
    }

    /// The fixed sources' folders; a drive's mount point while it is mounted and organizable.
    public func url(for place: Place) -> URL? {
        switch place {
        case .downloads: deps.env.home.appendingPathComponent("Downloads", isDirectory: true)
        case .desktop: deps.env.home.appendingPathComponent("Desktop", isDirectory: true)
        case .drive(let id): drives.first { $0.id == id && $0.isOrganizable }?.url
        case .chosen: nil
        }
    }

    /// The flow's review, when it is this view's folder plan (not a move to cloud).
    public var review: OrganizeReview? {
        guard let review = app?.organize.review, review.folderName != nil else { return nil }
        return review
    }

    public var isOrganisingCloudFolder: Bool { last?.plan.cloudOrganizeFolder != nil }

    /// Downloads, Desktop, a drive, or **Choose…** (the open panel). Plans the folder and opens its review.
    /// False when nothing was planned (panel cancelled, apply running, a drive no longer organizable).
    @discardableResult
    public func pick(_ place: Place) async -> Bool {
        guard let app, !app.organize.isApplying else { return false }
        let picked: URL
        if let fixed = url(for: place) {
            picked = fixed
        } else {
            guard place == .chosen, let chosen = await deps.workspace.chooseFolder() else { return false }
            picked = chosen
        }
        return await pick(folderAt: picked)
    }

    /// Plans the folder at `url` (a drive page's large item, or a picked source) and opens its review. A folder
    /// on a read-only or Time Machine drive is refused with its reason before anything is read.
    @discardableResult
    public func pick(folderAt url: URL) async -> Bool {
        guard let app, !app.organize.isApplying else { return false }
        // Re-read the mounts, so a drive mounted a moment ago isn't "outside your home folder". A volume that
        // is home or holds it is left out: home is judged as home.
        await app.drives.refreshInBackground()
        guard !Task.isCancelled, !app.organize.isApplying else { return false }
        let volumes = drives
        env = deps.env
        env.organizableDriveRoots = volumes.filter(\.isOrganizable).map(\.url)
        env.readOnlyDriveRoots = volumes.filter { !$0.isOrganizable }.map(\.url)
        let next = url.standardizedFileURL
        // Another folder starts clean: no edits, the planner's toggle, each group's default ticks.
        if next != folder {
            edits = GroupEdits()
            sortRestChoice = nil
            last = nil
        }
        folder = next
        return await plan()
    }

    /// The mounted drives, less a volume that is home or holds it (home on an external disk), and less one
    /// mounted inside home: home is judged as home, so neither is a drive source.
    private var drives: [ExternalVolume] {
        let home = NamingRules.key(deps.env.home.standardizedFileURL.path)
        return (app?.drives.volumes ?? []).filter { v in
            let root = NamingRules.key(v.url.standardizedFileURL.path)
            return home != root && !home.hasPrefix(root + "/")
                && !DrivesModel.isMountedInsideHome(v, home: deps.env.home)
        }
    }

    /// Why a folder on a volume mounted inside home isn't organized: judged as home, its plan could carry no
    /// drive UUID, so its undo couldn't follow the drive. Nil for any other folder.
    private func insideHomeReason(for folder: URL) -> String? {
        let path = NamingRules.key(folder.standardizedFileURL.path)
        let inside = (app?.drives.volumes ?? []).contains { v in
            guard DrivesModel.isMountedInsideHome(v, home: deps.env.home) else { return false }
            let root = NamingRules.key(v.url.standardizedFileURL.path)
            return path == root || path.hasPrefix(root + "/")
        }
        return inside ? Copy.Drives.insideHomeNote : nil
    }

    /// Which source the folder on screen came from, for the picker's selected state. A folder below a
    /// drive's top level is `.chosen`.
    public var place: Place? {
        guard let folder else { return nil }
        if folder == url(for: .downloads)?.standardizedFileURL { return .downloads }
        if folder == url(for: .desktop)?.standardizedFileURL { return .desktop }
        if let drive = drives.first(where: { $0.isOrganizable && $0.url.standardizedFileURL.path == folder.path }) {
            return .drive(drive.id)
        }
        return .chosen
    }

    /// True when the picked folder is the home folder or a drive's top level: it is organized by groups only
    /// (decisions 8 and 6), so Sort the rest by kind is always off and the toggle is hidden.
    public var isTopLevel: Bool {
        guard let folder else { return false }
        return OrganizeGuard.isTopLevel(folder, env: env)
    }

    /// True when the picked folder is on an external drive (its top level or below).
    public var isOnDrive: Bool {
        guard let folder else { return false }
        return OrganizeGuard.driveRoot(containing: folder, env: env) != nil
    }

    /// The drive `folder` is on, for the plan's journal lines (undo matches it by UUID); nil on the startup disk.
    private func planVolume(for folder: URL) -> PlanVolume? {
        guard let root = OrganizeGuard.driveRoot(containing: folder, env: env).map({ NamingRules.key($0.standardizedFileURL.path) }),
              let drive = drives.first(where: { NamingRules.key($0.url.standardizedFileURL.path) == root }) else { return nil }
        return PlanVolume(uuid: drive.id, mountPath: drive.url.standardizedFileURL.path, name: drive.name)
    }

    /// Why nothing may be planned or remembered for `folder`: it is on a drive (as picked) whose volume is no longer
    /// mounted, so there is no UUID to stamp. Nil when it isn't on a drive, or the drive is there. Fails closed:
    /// never a startup-disk plan or rule for a drive folder.
    private func driveGoneReason(for folder: URL) -> String? {
        guard let root = OrganizeGuard.driveRoot(containing: folder, env: env), planVolume(for: folder) == nil
        else { return nil }
        return Copy.Drives.notConnected(root.lastPathComponent)
    }

    /// Whether Sort the rest by kind can be turned on for the picked folder (never at a top level).
    public var canSortRestByKind: Bool { !isTopLevel }

    /// The choice the planner gets: off at a top level, else the user's (nil: the planner decides).
    private var effectiveSortRestChoice: Bool? { isTopLevel ? false : sortRestChoice }

    public func setOptions(_ new: NamingOptions) async {
        guard new != options else { return }
        options = new
        if folder != nil { await plan() }
    }

    /// Sort the rest by kind, for this folder: plans it again.
    public func setSortRestByKind(_ on: Bool) async {
        sortRestChoice = on
        if folder != nil { await plan() }
    }

    // MARK: Group edits

    /// Renames a group's new folder. Returns why the name can't be used (and changes nothing), or nil.
    /// While a re-plan would be refused, returns `Copy.Organize.cantEditNow` and stores nothing.
    public func renameGroup(id: String, to name: String) async -> String? {
        guard canReplan else { return Copy.Organize.cantEditNow }
        guard let group = last?.groups.first(where: { $0.id == id }) else { return nil }
        if let problem = GroupRules.validFolderName(name) { return Copy.Organize.nameProblem(problem) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = NamingRules.key(trimmed)
        let others = groupNames.filter { $0.id != id }.map(\.name) + parentNames
        if others.contains(where: { NamingRules.key($0) == key }) { return Copy.Organize.nameInUse }
        let parent = edits.parents.first { $0.value.contains(id) }?.key ?? group.parent
        if let taken = onDisk((parent.map { [$0] } ?? []) + [trimmed]) { return taken }
        app?.organize.pinCurrentTicks(stepIDs: group.stepIDs)
        edits.names[id] = trimmed
        await plan()
        return nil
    }

    /// Not in this group: the row's file leaves its group and is planned with the rest. Its tick (and its
    /// group's) stays as it is shown: an unticked suggestion row doesn't become a ticked kind move.
    public func removeFromGroup(rowID: UUID) async {
        guard canReplan, let last, let group = last.groups.first(where: { $0.stepIDs.contains(rowID) }),
              let step = last.plan.steps.first(where: { $0.id == rowID }),
              case .move(let from, _) = step.action else { return }
        app?.organize.pinCurrentTicks(stepIDs: group.stepIDs)
        edits.removed.insert(NamingRules.key(from.lastPathComponent))
        await plan()
    }

    /// Keep together: the groups become one, with the first one's name. Ticked rows stay ticked; an
    /// unticked row the user didn't untick takes the merged group's default (a suggestion kept together
    /// with a ticked group is ticked).
    public func mergeGroups(_ ids: [String]) async {
        guard canReplan, ids.count > 1 else { return }
        app?.organize.pinCurrentTicks(stepIDs: stepIDs(of: ids), onlyTicked: true)
        edits.merges.append(ids)
        await plan()
    }

    /// Put these in one folder: the groups go inside folder `name`; a parent with that name already is
    /// joined (a group under another parent moves). Returns why the name can't be used (a group's name, or
    /// something already in the folder with that name; nothing changes), or nil. While a re-plan would be
    /// refused, returns `Copy.Organize.cantEditNow` and stores nothing.
    public func nest(_ ids: [String], under name: String) async -> String? {
        guard canReplan else { return Copy.Organize.cantEditNow }
        guard last != nil, !ids.isEmpty else { return nil }
        if let problem = GroupRules.validFolderName(name) { return Copy.Organize.nameProblem(problem) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = NamingRules.key(trimmed)
        if groupNames.contains(where: { NamingRules.key($0.name) == key }) { return Copy.Organize.nameInUse }
        if let taken = onDisk([trimmed]) { return taken }
        for g in groupNames where ids.contains(g.id) {
            if let taken = onDisk([trimmed, g.name]) { return taken }
        }
        app?.organize.pinCurrentTicks(stepIDs: stepIDs(of: ids))
        setParent(trimmed, of: ids)
        await plan()
        return nil
    }

    /// Accepts a suggested parent folder for its groups. Returns why it can't (a group already has that
    /// name, or something in the folder does; nothing changes), or nil.
    @discardableResult
    public func applyParentSuggestion(_ s: ParentSuggestion) async -> String? {
        guard canReplan else { return Copy.Organize.cantEditNow }
        let key = NamingRules.key(s.name)
        if groupNames.contains(where: { NamingRules.key($0.name) == key }) { return Copy.Organize.nameInUse }
        if let taken = onDisk([s.name]) { return taken }
        app?.organize.pinCurrentTicks(stepIDs: stepIDs(of: s.groupIDs))
        setParent(s.name, of: s.groupIDs)
        await plan()
        return nil
    }

    /// Choose where this goes: the group goes into its matching folder `path` (one of its `choices`), or into
    /// a new folder of its own for `""`. Plans again; the group's rows are ticked (the user decided where they
    /// go), every other tick stays. A path the group isn't offered changes nothing.
    public func chooseDestination(groupID: String, path: String) async {
        guard canReplan, let group = last?.groups.first(where: { $0.id == groupID }),
              path.isEmpty || group.choices.contains(path) else { return }
        app?.organize.pinTicked(stepIDs: group.stepIDs)
        edits.destinations[groupID] = path
        await plan()
    }

    // MARK: Move to… and Remember this (plan 6 Task 8)

    /// **Move to…**: the row's file goes into `destination` (picked in the open panel), as the user's own
    /// choice; its row is ticked, every other tick stays. With `remember`, a rule is saved first: the file's
    /// exact name (glob characters escaped), into that folder, only when this folder is organized.
    /// Returns why it can't (the destination guard's or the rule's problem; nothing changes), or nil.
    ///
    /// On a drive, the destination must be on that drive (`Copy.Drives.outsideDrive` otherwise) and the rule is
    /// the drive's: stamped with its UUID, its folders and scope relative to the drive root (plan 7 Task 7).
    public func moveRow(rowID: UUID, to destination: URL, remember: Bool) async -> String? {
        guard canReplan else { return Copy.Organize.cantEditNow }
        guard let app, let picked = folder, let step = last?.plan.steps.first(where: { $0.id == rowID }),
              case .move(let from, _) = step.action else { return nil }
        let dest = destination.standardizedFileURL
        let env = env
        guard let inHome = Self.components(of: dest, under: GroupPlanner.ruleBase(for: picked, env: env)) else {
            return isOnDrive ? Copy.Drives.outsideDrive : Copy.Organize.excluded(.notInHome)
        }
        // As the planner judges it: the picked folder itself is "already there", anything else must be usable.
        if Self.components(of: dest, under: picked) != [] {
            let verdict = DestinationGuard.check(
                dest, env: env, cloudRoots: app.organizeRoots, isUbiquitous: FolderPlanner.liveIsUbiquitous,
                deviceOf: MoveToCloudPlanner.liveDevice, pickedFolder: picked,
                withinCloudFolder: isOrganisingCloudFolder)
            if case .blocked(let why) = verdict { return why }
        }
        if remember {
            if let gone = driveGoneReason(for: picked) { return gone }
            guard let scope = GroupPlanner.rulePath(of: picked, env: env) else {
                return Copy.Organize.excluded(.notInHome)
            }
            // An absolute instruction, even into a folder inside the picked one.
            let rule = OrganizeRule(
                pattern: Self.literalPattern(from.lastPathComponent), destination: .inHome(inHome), scope: .folder(scope),
                volumeUUID: planVolume(for: picked)?.uuid)
            if let problem = app.rules.add(rule) { return problem }
        }
        app.organize.pinTicked(stepIDs: [rowID])
        edits.moves[NamingRules.key(from.lastPathComponent)] = dest.path
        await plan()
        return nil
    }

    /// **Remember this** on a group card: saves a rule for any folder that sends files named like the group's
    /// (`*<word>*` for a shared word, `<base name>.*` for one name, `<prefix>*` for a numbered series) where
    /// the group's folder goes now, then plans again with it. Returns why it can't be saved (nothing changes),
    /// or nil. A group that can't be remembered (`OrganizeGroupCard.canRemember` false) changes nothing; one two
    /// of the user's folders match, with neither chosen yet, returns `Copy.Organize.rememberUndecided` (its
    /// folder is only provisional).
    ///
    /// Into one of the user's existing folders the rule is `.inHome` (where that folder is below home), so a
    /// folder the user later deletes is never made again; a new folder of its own is `.relative`. On a drive the
    /// rule is stamped with the drive's UUID and `.inHome` is below the drive root (plan 7 Task 7).
    public func rememberGroup(id: String) async -> String? {
        guard canReplan else { return Copy.Organize.cantEditNow }
        guard let app, let picked = folder, let last, let group = last.groups.first(where: { $0.id == id }) else { return nil }
        if group.isUndecided { return Copy.Organize.rememberUndecided }
        guard Self.canRemember(group) else { return nil }
        let wanted = Set(group.stepIDs)
        let moves = last.plan.steps.compactMap { step -> (from: URL, to: URL)? in
            guard wanted.contains(step.id), case .move(let from, let to) = step.action else { return nil }
            return (from, to)
        }
        guard let first = moves.first, let pattern = Self.rememberPattern(group, fileName: first.from.lastPathComponent)
        else { return nil }
        let into = first.to.deletingLastPathComponent().standardizedFileURL
        let intoYours = group.reasons.contains { if case .intoYourFolder = $0 { true } else { false } }
        let destination: OrganizeRule.Destination
        if !intoYours, let inside = Self.components(of: into, under: picked), !inside.isEmpty {
            destination = .relative(inside)
        } else if let inHome = Self.components(of: into, under: GroupPlanner.ruleBase(for: picked, env: env)) {
            destination = .inHome(inHome)
        } else {
            return isOnDrive ? Copy.Drives.outsideDrive : Copy.Organize.excluded(.notInHome)
        }
        if let gone = driveGoneReason(for: picked) { return gone }
        let rule = OrganizeRule(
            pattern: pattern, destination: destination, scope: .anyFolder, volumeUUID: planVolume(for: picked)?.uuid)
        if let problem = app.rules.add(rule) {
            return problem
        }
        await plan()
        return nil
    }

    /// A name group (not a rule's, Move to…'s or a your-folder group) found by its name, a word or a series, whose
    /// destination is decided (not two of the user's folders with neither chosen).
    static func canRemember(_ g: PlanGroup) -> Bool {
        guard !g.isRule, g.id != PlanGroup.movedID, !g.isYourFolder, !g.isUndecided else { return false }
        return g.reasons.contains { r in
            switch r {
            case .sameName, .sharesToken, .series: true
            default: false
            }
        }
    }

    /// The rule pattern Remember this saves for `g`, from its first file's name.
    static func rememberPattern(_ g: PlanGroup, fileName: String) -> String? {
        // A shared word is letters only: no glob character to escape.
        for r in g.reasons { if case .sharesToken(let t) = r { return "*\(t)*" } }
        let base = baseName(fileName)
        if g.reasons.contains(.sameName) { return literalPattern(base) + ".*" }
        if g.reasons.contains(.series) {
            let prefix = String(base.prefix(while: \.isLetter))
            return prefix.isEmpty ? nil : literalPattern(prefix) + "*"
        }
        return nil
    }

    /// `name` as an `fnmatch` pattern that matches only itself: `\ * ? [ ]` escaped, backslash first.
    static func literalPattern(_ name: String) -> String {
        var out = name.replacingOccurrences(of: "\\", with: "\\\\")
        for c in ["*", "?", "[", "]"] { out = out.replacingOccurrences(of: c, with: "\\" + c) }
        return out
    }

    /// The name without its extension, split as the planner splits it (the text after the last dot, when
    /// neither side is empty).
    private static func baseName(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex
        else { return name }
        return String(name[..<dot])
    }

    /// `url`'s folder components below `base` (`[]` for `base` itself), compared as APFS compares names;
    /// nil when it isn't inside.
    static func components(of url: URL, under base: URL) -> [String]? {
        let parts = url.standardizedFileURL.pathComponents, prefix = base.standardizedFileURL.pathComponents
        guard parts.count >= prefix.count,
              zip(parts, prefix).allSatisfy({ NamingRules.key($0) == NamingRules.key($1) }) else { return nil }
        return Array(parts.dropFirst(prefix.count))
    }

    /// The last plan's move steps of the groups `ids`.
    private func stepIDs(of ids: [String]) -> [UUID] {
        (last?.groups ?? []).filter { ids.contains($0.id) }.flatMap(\.stepIDs)
    }

    /// Why a new folder at `parts` (under the organized folder) can't be made: a folder is there already
    /// (`FolderPlanner.folderExistsText`) or something else is (`nameTakenText`). Nil when nothing is.
    /// Without this the planner sends the group's files to Unsorted and its card disappears.
    private func onDisk(_ parts: [String]) -> String? {
        guard let folder else { return nil }
        let url = parts.reduce(folder) { $0.appendingPathComponent($1) }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT == S_IFDIR ? FolderPlanner.folderExistsText : FolderPlanner.nameTakenText
    }

    /// Whether `plan()` would open its result now: not while applying, nor over a move to cloud's review or
    /// receipt. Edits are only stored when it would, so none waits unseen for a later plan.
    private var canReplan: Bool {
        guard let app, folder != nil, !app.organize.isApplying else { return false }
        if let open = app.organize.review, open.folderName == nil { return false }
        if let open = app.organize.receipt, open.folderName == nil { return false }
        return true
    }

    /// The last plan's groups with renames not yet planned laid over, so two quick renames can't take one name.
    private var groupNames: [(id: String, name: String)] {
        (last?.groups ?? []).map { g in (g.id, edits.names[g.id] ?? g.name) }
    }

    /// Test seam: changes `edits` without planning, as a rename still being planned leaves them.
    func setEditsForTesting(_ change: (inout GroupEdits) -> Void) { change(&edits) }

    /// The parent folders in use: the edits' and the last plan's.
    private var parentNames: [String] {
        Array(edits.parents.keys) + (last?.groups.compactMap(\.parent) ?? [])
    }

    /// Puts `ids` under `parent`, out of any parent they were under (the planner keeps a group's first one).
    private func setParent(_ name: String, of ids: [String]) {
        // Joining a parent keeps its spelling.
        let parent = edits.parents.keys.first { NamingRules.key($0) == NamingRules.key(name) } ?? name
        for key in Array(edits.parents.keys) {
            edits.parents[key]?.removeAll { ids.contains($0) }
            if edits.parents[key]?.isEmpty == true { edits.parents[key] = nil }
        }
        edits.parents[parent, default: []] += ids.filter { !(edits.parents[parent] ?? []).contains($0) }
    }

    // MARK: Planning

    /// Plans `folder` with the current options, edits and toggle. Re-planning the folder already open keeps
    /// the user's ticks (by source path); a new folder starts from each group's default.
    @discardableResult
    public func plan() async -> Bool {
        guard let app, let first = folder, !app.organize.isApplying else { return false }
        guard !isPlanning else {
            planAgain = true
            return false
        }
        refusedReason = nil
        let env = env
        isPlanning = true
        app.refreshOrganizeRoots()
        let roots = app.organizeRoots
        let screenCapture = isScreenCapture
        var result: FolderPlanResult
        var folder = first
        var volume: PlanVolume?
        // A request made meanwhile (an edit, or another folder picked) plans again, with the folder as it is now.
        repeat {
            planAgain = false
            if let now = self.folder { folder = now }
            // The saved rules, read each plan (a small file), so a rule saved meanwhile is used; an unreadable
            // file plans with none.
            app.rules.reload()
            let folder = folder, options = options, edits = edits, sortRest = effectiveSortRestChoice
            let rules = app.rules.rules
            // The drive, read once per plan: it filters the rules (only this volume's apply; nil at home) and is
            // journaled with the plan, so its undo only ever runs on that drive. With no mounted drive to name (it
            // went away since the pick), nothing is planned: never startup-disk rules or undo for it.
            volume = planVolume(for: folder)
            if let reason = driveGoneReason(for: folder) ?? insideHomeReason(for: folder) {
                result = FolderPlanner.refused(folder, reason)
                continue
            }
            let plannedVolume = volume
            let supportsExclusiveRename = deps.driveSupportsExclusiveRename
            result = await BackgroundWork.runNonThrowing("andromeda.organize.folder-plan") {
                if let plannedVolume,
                   supportsExclusiveRename(URL(fileURLWithPath: plannedVolume.mountPath, isDirectory: true)) == false {
                    return FolderPlanner.refused(folder, Copy.Drives.organizeFormatNote)
                }
                return GroupPlanner(env: env, cloudRoots: roots, classifier: KindClassifier(isScreenCapture: screenCapture))
                    .plan(
                        folder: folder, options: options, edits: edits, sortRestByKind: sortRest, rules: rules,
                        volumeUUID: plannedVolume?.uuid, allowCloud: true)
            }
        } while planAgain
        isPlanning = false
        // An apply may have started, or another folder been picked, while the plan was being built.
        guard !app.organize.isApplying, self.folder == folder else { return false }
        // Nor may it replace a move-to-cloud review or receipt opened meanwhile (its sheet is up and its
        // confirm applies the current review): the plan is dropped; picking the folder again plans it.
        // This page's own folder receipt is replaced, as picking another folder from it means.
        if let open = app.organize.review, open.folderName == nil { return false }
        if let open = app.organize.receipt, open.folderName == nil { return false }
        if let volume { result.plan.volume = volume }
        if result.plan.steps.isEmpty, result.unsorted.isEmpty,
           let only = result.plan.leftAlone.first, result.plan.leftAlone.count == 1,
           only.url.standardizedFileURL.path == folder.path {
            refusedReason = only.reason
        }
        // The same folder planned again keeps the user's ticks; the open review must be this folder's.
        let reviewed = last != nil && app.organize.review?.folderName != nil
        last = result
        app.rules.blocked = result.blockedRules
        sortRestByKind = result.sortedRestByKind
        // The planner's automatic choice is made once per folder: later edits don't flip the toggle.
        if sortRestChoice == nil, refusedReason == nil, !isTopLevel { sortRestChoice = result.sortedRestByKind }
        app.organize.prepare(folder: result, carrying: reviewed ? app.organize.tickState : TickState())
        return true
    }

    public var receiptDisconnectedNote: String? {
        guard let app, let volume = app.organize.receipt?.volume,
              !app.drives.volumes.contains(where: { $0.id == volume.uuid }) else { return nil }
        return Copy.Drives.notConnected(volume.name ?? URL(fileURLWithPath: volume.mountPath).lastPathComponent)
    }

    /// The receipt's **Undo this group**: puts one group of the run back; the receipt stays open.
    public func undoGroup(id: String) async {
        guard let app, let receipt = app.organize.receipt, receiptDisconnectedNote == nil else { return }
        await app.undo(batchID: receipt.batchID, groupID: id)
    }

    /// The receipt's **Undo this run**: puts the batch back, reloads History, and plans the folder again
    /// when everything went back.
    public func undoRun() async {
        guard let app, let receipt = app.organize.receipt, receiptDisconnectedNote == nil else { return }
        await app.undo(batchID: receipt.batchID)
        if app.organize.undoProblem == nil {
            app.organize.closeReceipt()
            await plan()
        }
    }
}
