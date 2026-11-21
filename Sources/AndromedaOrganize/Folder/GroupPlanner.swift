import AndromedaCore
import Foundation

/// The user's changes to the found groups, applied in this order: `removed`, `merges`, `names`, `parents`.
/// `moves` come before everything else: a moved file is in no group.
public struct GroupEdits: Equatable, Sendable {
    /// Group id → new folder name. A name `GroupRules.validFolderName` rejects is ignored here.
    public var names: [String: String] = [:]
    /// `NamingRules.key` of file names taken out of their group; they become leftovers.
    public var removed: Set<String> = []
    /// Each list merges its groups into the first one present, keeping that group's name.
    public var merges: [[String]] = []
    /// Parent folder name → the ids of the groups that go inside it.
    public var parents: [String: [String]] = [:]
    /// Group id → the user's folder it goes into (a relative path, one of its `PlanGroup.choices` or its one
    /// match), or `""` for a new folder of its own (3a). A path the group doesn't match is ignored.
    public var destinations: [String: String] = [:]
    /// Move to…: `NamingRules.key` of a file's name → the absolute path of the folder it goes into. A path
    /// outside home, or one `DestinationGuard` refuses, sends the file to Unsorted with the reason.
    public var moves: [String: String] = [:]

    public init(
        names: [String: String] = [:], removed: Set<String> = [], merges: [[String]] = [],
        parents: [String: [String]] = [:], destinations: [String: String] = [:], moves: [String: String] = [:]
    ) {
        self.names = names
        self.removed = removed
        self.merges = merges
        self.parents = parents
        self.destinations = destinations
        self.moves = moves
    }
}

/// A group as planned: the folder it becomes and the move steps of its files.
public struct PlanGroup: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// The parent folder the group's folder goes inside, if any.
    public let parent: String?
    public let reasons: [GroupReason]
    /// False for suggestions: the UI shows them unticked.
    public let startsTicked: Bool
    /// The move steps of the group's files (files sent to Unsorted have none).
    public let stepIDs: [UUID]
    /// The user's folders (relative paths) the group's name matches, when more than one does; the user picks
    /// one through `GroupEdits.destinations`. Empty otherwise.
    public var choices: [String] = []
    /// Where a rule group's files go (an absolute folder path); nil for every other group.
    public var destination: URL? = nil
    /// Two or more of the user's folders match and none is picked yet: the files go into the first choice for now,
    /// unticked, until the user chooses (`GroupEdits.destinations`).
    public var isUndecided: Bool = false

    /// The id prefix of the groups made for single loose files that match one of the user's folders.
    public static let yourFolderPrefix = "folder:"
    /// A group of single loose files going into one of the user's folders (not a name group).
    public var isYourFolder: Bool { id.hasPrefix(Self.yourFolderPrefix) }
    /// The id prefix of a saved rule's group: the prefix plus the rule's id.
    public static let rulePrefix = "rule:"
    /// The one group holding every Move to… row.
    public static let movedID = "moved"
    /// The moved group's name in the planner's output (the app shows `Copy.Organize.movedByYou`).
    public static let movedName = "Moved by you"
    public var isRule: Bool { id.hasPrefix(Self.rulePrefix) }
}

/// Plans organizing one folder's loose files into name groups (each a new folder) and, with Sort the rest
/// by kind on, the rest by kind like `FolderPlanner`. Planning only: nothing here changes the disk.
///
/// Each file is placed by the first of: the user's Move to…, the first saved rule (in store order) whose
/// scope matches, a name group, one of the user's folders, its kind (Sort the rest by kind).
public struct GroupPlanner {
    private let env: ScanEnvironment
    private let cloudRoots: [CloudRoot]
    private let classifier: KindClassifier
    private let isUbiquitous: (URL) -> Bool
    private let isOnlineOnly: (URL) -> Bool
    private let deviceOf: (URL) -> Int32?

    public init(
        env: ScanEnvironment, cloudRoots: [CloudRoot], classifier: KindClassifier = KindClassifier(),
        isUbiquitous: @escaping (URL) -> Bool = FolderPlanner.liveIsUbiquitous,
        deviceOf: @escaping (URL) -> Int32? = MoveToCloudPlanner.liveDevice,
        isOnlineOnly: @escaping (URL) -> Bool = FolderPlanner.liveIsOnlineOnly
    ) {
        self.env = env
        self.cloudRoots = cloudRoots
        self.classifier = classifier
        self.isUbiquitous = isUbiquitous
        self.deviceOf = deviceOf
        self.isOnlineOnly = isOnlineOnly
    }

    /// `sortRestByKind` nil: on unless the files that start ticked (in groups, rules and Move to…) are more
    /// than half the scanned files. A top level (home, a drive root) is planned by groups only (decisions 8, 6):
    /// `sortRestByKind` is off there, whatever is passed; rules still apply there, ticked (plan 6 decision 1).
    /// Rules never run on their own: they only shape this plan, which still goes through review. A rule applies
    /// only on the volume it was made on: `volumeUUID` is the picked folder's drive (`OrganizePlan.volume`), nil
    /// for the startup disk; any other volume's rule is left out, neither used nor reported (plan 7 decision 7).
    public func plan(
        folder: URL, options: NamingOptions, edits: GroupEdits, sortRestByKind requested: Bool?,
        rules: [OrganizeRule] = [], volumeUUID: String? = nil, allowCloud: Bool = false
    ) -> FolderPlanResult {
        let folder = folder.standardizedFileURL
        let cloud = allowCloud && FolderPlanner.isCloudFolder(folder, home: env.home, roots: cloudRoots, isUbiquitous: isUbiquitous)
        let onDrive = OrganizeGuard.driveRoot(containing: folder, env: env) != nil
        let sortRestByKind = OrganizeGuard.isTopLevel(folder, env: env) ? false : requested
        // Name groups supersede R-C20 here; the rule is applied to the leftovers below.
        func scan(reuseKindFolders: Bool) -> ScanResult {
            FolderScan.scan(
                folder: folder, env: env, cloudRoots: cloudRoots, classifier: classifier,
                isUbiquitous: isUbiquitous, reuseKindFolders: reuseKindFolders, detectProjects: false,
                allowCloud: cloud, isOnlineOnly: isOnlineOnly)
        }
        var files: [ScannedFile], leftAlone: [LeftAlone], unsorted: [LeftAlone], userFolders: [URL]
        switch scan(reuseKindFolders: sortRestByKind ?? true) {
        case .refused(let result): return result
        case .scanned(let f, let l, let u, let uf): (files, leftAlone, unsorted, userFolders) = (f, l, u, uf)
        }
        // The user's own folders, listed once per plan (rev 4.4 as reworded by 5.3). A second scan below only
        // adds kind folders to `userFolders`, and the index never enters those.
        let index = UserFolderIndex.build(
            folder: folder, topLevel: userFolders, env: env, cloudRoots: cloudRoots,
            isUbiquitous: { !cloud && isUbiquitous($0) })

        // 1–2. Move to… and saved rules take their files first; the rest is grouped as before.
        let taken = Self.claims(
            files, folder: folder, edits: edits, rules: rules.filter { $0.volumeUUID == volumeUUID }, env: env)
        let claims = taken.claims
        var blockedRules = taken.blocked
        var free = files.filter { claims[NamingRules.key($0.name)] == nil }
        // Where each claimed file goes, judged once per destination: placed (below the picked folder, else
        // below home), already there, or blocked with the guard's reason.
        var verdicts: [String: DestinationVerdict] = [:]
        var outcomes: [String: ClaimOutcome] = [:]
        for (key, claim) in claims {
            let dest = claim.destination
            guard let (base, parts) = Self.basedParts(dest, folder: folder, env: env) else {
                outcomes[key] = .blocked(onDrive ? DestinationGuard.outsideDriveText : OrganizeGuard.reasonText(.notInHome))
                continue
            }
            if base == nil, parts.isEmpty { outcomes[key] = .alreadyThere; continue }
            let verdict = verdicts[NamingRules.key(dest.path)] ?? DestinationGuard.check(
                dest, env: env, cloudRoots: cloudRoots, isUbiquitous: isUbiquitous, deviceOf: deviceOf,
                pickedFolder: folder, withinCloudFolder: cloud)
            verdicts[NamingRules.key(dest.path)] = verdict
            switch verdict {
            case .usable:
                // An .inHome rule only ever sends files to a folder that exists: a deleted one is never made
                // again (Review Focus 1). A .relative rule makes its chain; Move to… always names an existing one.
                if case .inHome = claim.rule?.destination, !Self.exists(dest) {
                    outcomes[key] = .blocked(FolderPlanner.ruleFolderGoneText)
                } else {
                    outcomes[key] = .placed(base: base, parts: parts)
                }
            case .blocked(let why): outcomes[key] = .blocked(why)
            }
        }

        let found = GroupFinder.find(free.map { GroupFile(name: $0.name, kind: $0.kind, birth: $0.birth) })
        let groups = Self.applying(edits, to: found.groups)
        let into = Self.yourFolders(for: groups, index: index, destinations: edits.destinations)

        let sortRest: Bool
        if let explicit = sortRestByKind {
            sortRest = explicit
        } else {
            let grouped = groups.filter { !$0.isSuggestion && !into.undecided.contains($0.id) }
                .reduce(0) { $0 + $1.files.count }
            // Files Move to… and rules place count as grouped: they start ticked too.
            let placedClaims = outcomes.values.filter { if case .placed = $0 { true } else { false } }.count
            sortRest = (grouped + placedClaims) * 2 <= files.count
            // The toggle decides whether kind folders are reused; the first scan assumed it on.
            if !sortRest {
                switch scan(reuseKindFolders: false) {
                case .refused(let result): return result
                case .scanned(let f, let l, let u, _): (files, leftAlone, unsorted) = (f, l, u)
                }
                free = files.filter { claims[NamingRules.key($0.name)] == nil }
            }
        }

        // Each grouped file's destination, by name key; nil when its group can't have a folder of its own.
        // A group going into one of the user's folders reuses it; the others each get a new folder (3a).
        let shared = Self.sharedFolderGroups(groups.filter { into.target[$0.id] == nil }, sortRestByKind: sortRest)
        var groupParts: [String: (parts: [String], reuse: Bool)?] = [:]
        var groupIDByName: [String: String] = [:]
        for g in groups {
            let dest: (parts: [String], reuse: Bool)?
            if let path = into.target[g.id] {
                dest = (Self.components(path), true)
            } else {
                dest = shared.contains(g.id) ? nil : ((g.parent.map { [$0] } ?? []) + [g.name], false)
            }
            for name in g.files {
                groupParts[NamingRules.key(name)] = .some(dest)
                groupIDByName[NamingRules.key(name)] = g.id
            }
        }

        // Placements in listing order, as FolderPlanner makes them: moved and ruled files first.
        var placements: [Placement] = []
        // The files the moved group and each rule group placed, by group id, in listing order.
        var claimed: [(claim: Claim, files: [String])] = []
        for f in files {
            let key = NamingRules.key(f.name)
            guard let claim = claims[key], let outcome = outcomes[key] else { continue }
            let base: URL?, parts: [String]
            switch outcome {
            case .alreadyThere:
                // No step, and nothing else plans it; it is listed so it never vanishes from the plan.
                leftAlone.append(LeftAlone(url: f.url, reason: FolderPlanner.alreadyThereText)); continue
            case .blocked(let why):
                unsorted.append(LeftAlone(url: f.url, reason: why))
                if let rule = claim.rule, blockedRules[rule.id] == nil { blockedRules[rule.id] = why }
                continue
            case .placed(let b, let p): (base, parts) = (b, p)
            }
            placements.append(Placement(file: f, parts: parts, reuseExisting: true, groupID: claim.groupID, base: base))
            if let i = claimed.firstIndex(where: { $0.claim.groupID == claim.groupID }) {
                claimed[i].files.append(f.name)
            } else {
                claimed.append((claim, [f.name]))
            }
        }
        var leftovers: [ScannedFile] = []
        // Single loose files that match exactly one of the user's folders, by its relative path (Decision 2).
        var single: [(path: String, files: [String])] = []
        for f in free {
            if let entry = groupParts[NamingRules.key(f.name)] {
                if let dest = entry {
                    placements.append(Placement(
                        file: f, parts: dest.parts, reuseExisting: dest.reuse, groupID: groupIDByName[NamingRules.key(f.name)]))
                } else {
                    // Its folder would be another group's, a parent's or a kind folder.
                    unsorted.append(LeftAlone(url: f.url, reason: FolderPlanner.folderExistsText))
                }
            } else if !edits.removed.contains(NamingRules.key(f.name)),
                      case let hits = index.matches(fileName: f.name).map(\.relativePath).filter({ !$0.isEmpty }),
                      !hits.isEmpty {
                // A file the user took out of a group stays out. A path is never empty: a file is never
                // "moved" into the folder it is already in.
                guard hits.count == 1, let path = hits.first else {
                    // Two or more match: it stays where it is, listed with them; neither is ticked for it.
                    leftAlone.append(LeftAlone(url: f.url, reason: FolderPlanner.matchesYourFoldersText(hits)))
                    continue
                }
                placements.append(Placement(
                    file: f, parts: Self.components(path), reuseExisting: true, groupID: PlanGroup.yourFolderPrefix + path))
                if let i = single.firstIndex(where: { $0.path == path }) {
                    single[i].files.append(f.name)
                } else {
                    single.append((path, [f.name]))
                }
            } else {
                leftovers.append(f)
            }
        }
        if sortRest {
            // R-C20 over the leftovers, as Organize 2 applies it to the whole folder.
            let project = FolderPlanner.projectTokens(leftovers.map { ($0.name, $0.kind) })
            var rest: [ScannedFile] = []
            for (i, f) in leftovers.enumerated() {
                if let (token, n) = project[i] {
                    leftAlone.append(LeftAlone(url: f.url, reason: FolderPlanner.projectText(token, files: n)))
                } else {
                    rest.append(f)
                }
            }
            let (kindPlacements, unknown) = FolderPlanner.kindPlacements(rest)
            placements += kindPlacements
            unsorted += unknown
        } else {
            leftAlone += leftovers.map { LeftAlone(url: $0.url, reason: FolderPlanner.notInAGroupText) }
        }

        let assembled = PlanAssembler.assembleReportingBlocked(
            folder: folder, placements: placements, leftAlone: FolderPlanner.byName(leftAlone), unsorted: unsorted,
            options: options, env: env, cloudRoots: cloudRoots, isUbiquitous: isUbiquitous, deviceOf: deviceOf)
        var result = assembled.result
        if cloud {
            guard let boundary = AutomationDirectories.Folder(folder) else {
                return FolderPlanner.refused(folder, FolderPlanner.unreadableText)
            }
            result.plan.cloudOrganizeFolder = boundary
        }
        let blockedFiles = assembled.blocked
        // A rule whose destination the assembler refused (a file in the way, an unreadable folder, …).
        for f in files {
            guard let rule = claims[NamingRules.key(f.name)]?.rule, blockedRules[rule.id] == nil,
                  let why = blockedFiles[f.url] else { continue }
            blockedRules[rule.id] = why
        }

        var stepBySource: [URL: UUID] = [:]
        for s in result.plan.steps { if case .move(let from, _) = s.action { stepBySource[from] = s.id } }
        let urlByKey = Dictionary(files.map { (NamingRules.key($0.name), $0.url) }, uniquingKeysWith: { a, _ in a })
        func steps(_ names: [String]) -> [UUID] {
            names.compactMap { urlByKey[NamingRules.key($0)].flatMap { stepBySource[$0] } }
        }
        // Moved and rule groups first, as they were placed first; they start ticked, in home too.
        result.groups = claimed.compactMap { c -> PlanGroup? in
            guard let rule = c.claim.rule else {
                return PlanGroup(
                    id: PlanGroup.movedID, name: PlanGroup.movedName, parent: nil, reasons: [.movedByYou],
                    startsTicked: true, stepIDs: steps(c.files))
            }
            // A rule the assembler refused has no group: its files are in Unsorted with the reason.
            guard blockedRules[rule.id] == nil else { return nil }
            return PlanGroup(
                id: c.claim.groupID, name: c.claim.destination.lastPathComponent, parent: nil,
                reasons: [.rule(rule.pattern)], startsTicked: true, stepIDs: steps(c.files),
                destination: c.claim.destination)
        }
        result.groups += groups.map { g in
            let target = into.target[g.id]
            return PlanGroup(
                id: g.id, name: g.name, parent: g.parent,
                // An undecided group's target is provisional: its card offers the choices instead.
                reasons: g.reasons
                    + (target.flatMap { into.undecided.contains(g.id) ? nil : [.intoYourFolder($0)] } ?? []),
                startsTicked: !g.isSuggestion && !into.undecided.contains(g.id),
                stepIDs: steps(g.files), choices: into.choices[g.id] ?? [], isUndecided: into.undecided.contains(g.id))
        }
        result.groups += single.map { s in
            PlanGroup(
                id: PlanGroup.yourFolderPrefix + s.path, name: Self.components(s.path).last ?? s.path, parent: nil,
                reasons: [.matchesYourFolder(s.path)], startsTicked: false, stepIDs: steps(s.files))
        }
        let ids = Set(groups.map(\.id))
        result.parentSuggestions = found.parents.compactMap { p in
            let kept = p.groupIDs.filter(ids.contains)
            return kept.isEmpty ? nil : ParentSuggestion(name: p.name, groupIDs: kept)
        }
        result.sortedRestByKind = sortRest
        result.blockedRules = blockedRules
        result.userFoldersCapped = index.capped
        return result
    }

    /// Whether anything is at `url` (lstat: a link counts as there; a file there is judged by the assembler).
    private static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    // MARK: Move to… and rules

    enum ClaimOutcome {
        case placed(base: URL?, parts: [String])
        case alreadyThere
        case blocked(String)
    }

    struct Claim {
        /// The absolute folder the file goes into.
        let destination: URL
        /// The rule that placed it; nil for Move to….
        let rule: OrganizeRule?
        var groupID: String { rule.map { PlanGroup.rulePrefix + $0.id.uuidString } ?? PlanGroup.movedID }
    }

    /// The files Move to… and the saved rules take, by name key, and the rules that can't be used: an invalid
    /// rule is skipped (never applied) and reported with its problem. `rules` are this volume's only; their
    /// `.inHome` folders and `.folder` scope start at `ruleBase` (the drive root on a drive).
    static func claims(
        _ files: [ScannedFile], folder: URL, edits: GroupEdits, rules: [OrganizeRule], env: ScanEnvironment
    ) -> (claims: [String: Claim], blocked: [UUID: String]) {
        var blocked: [UUID: String] = [:]
        let here = rulePath(of: folder, env: env).map(NamingRules.key)
        let top = ruleBase(for: folder, env: env)
        let usable = rules.filter { rule in
            if let problem = RuleValidator.validate(rule) {
                blocked[rule.id] = RuleValidator.problemText(problem)
                return false
            }
            switch rule.scope {
            case .anyFolder: return true
            case .folder(let p):
                let scope = p.split(separator: "/").joined(separator: "/")
                return here == NamingRules.key(scope)
            }
        }
        // Each destination in its on-disk spelling (one lookup per destination): the guard's checks and the move
        // URLs then see `~/library` as `~/Library`, and `docs` as the existing `Docs`.
        var spelled: [String: URL] = [:]
        func onDisk(_ url: URL) -> URL {
            let key = NamingRules.key(url.path)
            if let hit = spelled[key] { return hit }
            let resolved = DestinationGuard.onDiskSpelling(url, home: top)
            spelled[key] = resolved
            return resolved
        }
        var out: [String: Claim] = [:]
        for f in files {
            let key = NamingRules.key(f.name)
            if let path = edits.moves[key] {
                out[key] = Claim(destination: onDisk(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL), rule: nil)
            } else if let rule = usable.first(where: { $0.matches(fileName: f.name, kind: f.kind) }) {
                let (base, parts): (URL, [String]) = switch rule.destination {
                case .relative(let c): (folder, c)
                case .inHome(let c): (top, c)
                }
                let dest = base.appendingPathComponent(parts.joined(separator: "/"), isDirectory: true).standardizedFileURL
                out[key] = Claim(destination: onDisk(dest), rule: rule)
            }
        }
        return (out, blocked)
    }

    /// Where a rule's `.inHome` folders and `.folder` scope start for a folder: the root of the drive it is on,
    /// else home (plan 7 Task 7). Move to… and rule destinations from a drive folder stay below it.
    public static func ruleBase(for folder: URL, env: ScanEnvironment) -> URL {
        (OrganizeGuard.driveRoot(containing: folder, env: env) ?? env.home).standardizedFileURL
    }

    /// The picked folder's path relative to `ruleBase` (`""` for home or the drive root itself), as a rule's
    /// `.folder` scope names it; nil outside home (and off a drive).
    public static func rulePath(of folder: URL, env: ScanEnvironment) -> String? {
        if let drive = OrganizeGuard.driveRoot(containing: folder, env: env) {
            return PlanAssembler.components(of: folder.standardizedFileURL.path, under: drive.standardizedFileURL.path)?
                .joined(separator: "/")
        }
        let path = folder.standardizedFileURL.path, home = env.home.standardizedFileURL.path
        if path == home { return "" }
        return path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : nil
    }

    /// A destination as the assembler takes it: below the picked folder (base nil; `[]` is the folder itself),
    /// else below home (the drive root, for a folder on a drive); nil outside it. Compared as APFS compares
    /// names, so `~/work/Docs` is inside `~/Work`.
    static func basedParts(_ dest: URL, folder: URL, env: ScanEnvironment) -> (base: URL?, parts: [String])? {
        let path = dest.standardizedFileURL.path
        if let rest = PlanAssembler.components(of: path, under: folder.standardizedFileURL.path) { return (nil, rest) }
        let top = ruleBase(for: folder, env: env)
        guard let rest = PlanAssembler.components(of: path, under: top.path) else { return nil }
        return (top, rest)
    }

    // MARK: Your folders

    /// Where name groups go among the user's folders. `target`: group id → the relative path it goes into.
    /// `choices`: the paths, when two or more match. `undecided`: groups with choices and no valid pick yet;
    /// they go into the first choice and start unticked.
    static func yourFolders(
        for groups: [EditedGroup], index: UserFolderIndex, destinations: [String: String]
    ) -> (target: [String: String], choices: [String: [String]], undecided: Set<String>) {
        var target: [String: String] = [:]
        var choices: [String: [String]] = [:]
        var undecided: Set<String> = []
        for g in groups {
            var hits = index.matches(groupName: g.name).map(\.relativePath).filter { !$0.isEmpty }
            if hits.count > 1 {
                // Name matches are ranked by evidence: a folder that also holds the shape of one of the group's
                // files beats those matched by name only. Exactly one such folder is a clear answer.
                let shaped = g.files.reduce(into: Set<String>()) { $0.formUnion(index.shapeMatches(fileName: $1)) }
                let strong = hits.filter(shaped.contains)
                if strong.count == 1 { hits = strong }
            }
            if hits.count > 1 { choices[g.id] = hits }
            // The user's pick: "" is a new folder of its own; any other path must be one the group matches.
            if let picked = destinations[g.id], picked.isEmpty || hits.contains(picked) {
                if !picked.isEmpty { target[g.id] = picked }
                continue
            }
            // A group the user put inside a parent folder gets its new folder there.
            guard g.parent == nil, let first = hits.first else { continue }
            target[g.id] = first
            if hits.count > 1 { undecided.insert(g.id) }
        }
        return (target, choices, undecided)
    }

    /// A relative path's folder components ("Work/Clients/Acme" → three).
    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    // MARK: Folder sharing

    /// Ids of groups whose new folder would be shared (compared as APFS does, by `NamingRules.key`): with an
    /// earlier group's folder, with an earlier group's parent (or the reverse), or, sorting the rest by kind,
    /// with a kind folder. 3a gives every group a new folder of its own; the earlier group keeps the name.
    static func sharedFolderGroups(_ groups: [EditedGroup], sortRestByKind: Bool) -> Set<String> {
        let kindKeys = Set(Kind.allCases.map { NamingRules.key($0.folderName) })
        var folders: Set<String> = []  // group folder paths, keyed
        var parents: Set<String> = []  // parent folder paths, keyed
        var out: Set<String> = []
        for g in groups {
            let parent = g.parent.map(NamingRules.key)
            let components = [parent, NamingRules.key(g.name)].compactMap { $0 }
            let path = components.joined(separator: "/")
            let clash =
                folders.contains(path) || parents.contains(path) || parent.map(folders.contains) == true
                || (sortRestByKind && components.contains(where: kindKeys.contains))
            if clash {
                out.insert(g.id)
                continue
            }
            folders.insert(path)
            if let parent { parents.insert(parent) }
        }
        return out
    }

    // MARK: Edits

    struct EditedGroup {
        let id: String
        var name: String
        var parent: String?
        var reasons: [GroupReason]
        let isSuggestion: Bool
        var files: [String]
    }

    static func applying(_ edits: GroupEdits, to found: [FoundGroup]) -> [EditedGroup] {
        var groups = found.map {
            EditedGroup(id: $0.id, name: $0.name, parent: nil, reasons: $0.reasons, isSuggestion: $0.isSuggestion, files: $0.files)
        }
        // 1. Removed files; a group left empty disappears.
        for g in groups.indices { groups[g].files.removeAll { edits.removed.contains(NamingRules.key($0)) } }
        groups.removeAll { $0.files.isEmpty }

        // 2. Merges, into the first group present.
        for merge in edits.merges {
            let present = merge.filter { id in groups.contains { $0.id == id } }
            guard let target = present.first, let t = groups.firstIndex(where: { $0.id == target }) else { continue }
            for other in present.dropFirst() where other != target {
                guard let o = groups.firstIndex(where: { $0.id == other }) else { continue }
                groups[t].files += groups[o].files
                for r in groups[o].reasons where !groups[t].reasons.contains(r) { groups[t].reasons.append(r) }
                groups.remove(at: o)
            }
            if let t = groups.firstIndex(where: { $0.id == target }) {
                groups[t].files.sort { a, b in
                    let ka = NamingRules.key(a), kb = NamingRules.key(b)
                    return ka != kb ? ka < kb : a < b
                }
            }
        }

        // 3. Names; the model layer validates and reports, so an invalid one is just ignored.
        for g in groups.indices {
            if let name = edits.names[groups[g].id], GroupRules.validFolderName(name) == nil {
                groups[g].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 4. Parents, in name order; a group keeps the first parent that claims it.
        for parent in edits.parents.keys.sorted() where GroupRules.validFolderName(parent) == nil {
            let name = parent.trimmingCharacters(in: .whitespacesAndNewlines)
            for id in edits.parents[parent] ?? [] {
                if let g = groups.firstIndex(where: { $0.id == id }), groups[g].parent == nil { groups[g].parent = name }
            }
        }
        return groups
    }
}
