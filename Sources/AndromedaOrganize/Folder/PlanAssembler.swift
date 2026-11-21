import AndromedaCore
import Foundation

/// One file and where it goes: `parts` are folder components under `base`.
struct Placement {
    let file: ScannedFile
    let parts: [String]
    /// false: an existing folder at any prefix of `parts` blocks the file instead of being reused.
    let reuseExisting: Bool
    /// The `PlanGroup.id` of the group this file was placed by; nil for kind placements.
    var groupID: String? = nil
    /// The folder `parts` start from; nil is the picked folder. Any other base is outside the picked folder
    /// (a rule's or a Move to…'s destination below home), and every folder of its chain goes through
    /// `DestinationGuard`. A base whose chain leads inside the picked folder is planned as the picked folder's own.
    var base: URL? = nil
}

/// The assembly stage of planning: destination checks, name clashes (R-C10) and the plan's steps.
/// Destination folders, their spellings, taken names and created folders are all keyed by absolute path,
/// compared as APFS compares names (`NamingRules.key`).
enum PlanAssembler {
    /// `path`'s components below `root`, compared as APFS compares names (`NamingRules.key`): `[]` when they are
    /// the same folder, nil when `path` isn't inside `root`. The remainder keeps `path`'s own spelling.
    static func components(of path: String, under root: String) -> [String]? {
        let p = path.split(separator: "/").map(String.init), r = root.split(separator: "/").map(String.init)
        guard p.count >= r.count, zip(p, r).allSatisfy({ NamingRules.key($0) == NamingRules.key($1) }) else { return nil }
        return Array(p.dropFirst(r.count))
    }

    static func assemble(
        folder: URL, placements: [Placement], leftAlone: [LeftAlone], unsorted: [LeftAlone],
        options: NamingOptions, env: ScanEnvironment, cloudRoots: [CloudRoot],
        isUbiquitous: @escaping (URL) -> Bool = FolderPlanner.liveIsUbiquitous,
        deviceOf: @escaping (URL) -> Int32? = MoveToCloudPlanner.liveDevice
    ) -> FolderPlanResult {
        assembleReportingBlocked(
            folder: folder, placements: placements, leftAlone: leftAlone, unsorted: unsorted, options: options,
            env: env, cloudRoots: cloudRoots, isUbiquitous: isUbiquitous, deviceOf: deviceOf).result
    }

    /// As `assemble`, plus why each file whose destination folder is unusable went to Unsorted (name clashes
    /// aren't included: the folder itself is fine).
    static func assembleReportingBlocked(
        folder: URL, placements: [Placement], leftAlone: [LeftAlone], unsorted: [LeftAlone],
        options: NamingOptions, env: ScanEnvironment, cloudRoots: [CloudRoot],
        isUbiquitous: @escaping (URL) -> Bool, deviceOf: @escaping (URL) -> Int32?
    ) -> (result: FolderPlanResult, blocked: [URL: String]) {
        let folder = folder.standardizedFileURL
        let cache = OrganizeGuard.Cache()
        let rootURLs = cloudRoots.map { $0.url.standardizedFileURL }
        var unsorted = unsorted
        var blockedFiles: [URL: String] = [:]

        /// A destination: the folder its parts start from, and the parts.
        struct Target: Hashable {
            let base: URL
            let parts: [String]
            var isOutside: Bool
            /// The absolute path of the folder `n` parts down (0 is `base`).
            func path(_ n: Int) -> String {
                n == 0 ? base.path : base.path + "/" + parts.prefix(n).joined(separator: "/")
            }
            var dir: String { path(parts.count) }
            /// `path(n)` as APFS compares it: one key per folder, whatever the spelling.
            func key(_ n: Int) -> String { NamingRules.key(path(n)) }
            var dirKey: String { key(parts.count) }
            /// The folder `n` parts down, without a trailing slash: compares like the move URLs.
            func url(_ n: Int) -> URL { n == 0 ? base : base.appendingPathComponent(parts.prefix(n).joined(separator: "/")) }
            func prefix(_ n: Int) -> Target { Target(base: base, parts: Array(parts.prefix(n)), isOutside: isOutside) }
        }
        // An outside chain that leads into the picked folder is the picked folder's own (one set of checks
        // per absolute path: no folder is ever judged both ways).
        func target(_ p: Placement) -> Target {
            let base = (p.base ?? folder).standardizedFileURL
            guard base.path != folder.path else { return Target(base: folder, parts: p.parts, isOutside: false) }
            // Re-based onto the picked folder's own spelling, plus the remaining parts.
            let full = ([base.path] + p.parts).joined(separator: "/")
            if let rest = components(of: full, under: folder.path) {
                return Target(base: folder, parts: rest, isOutside: false)
            }
            return Target(base: base, parts: p.parts, isOutside: true)
        }

        // Check each destination folder once: usable (existing or to create), or why not.
        enum Dest { case usable(existingNames: [String]), blocked(String) }
        var destCache: [String: Dest] = [:]
        func dest(_ t: Target, reuse: Bool = true) -> Dest {
            let key = t.dir
            let cacheKey = (reuse ? "" : "\u{0}") + t.dirKey
            if let hit = destCache[cacheKey] { return hit }
            let result: Dest
            if t.parts.count > 1, case .blocked(let why) = dest(t.prefix(t.parts.count - 1), reuse: reuse) {
                result = .blocked(why)
            } else if t.isOutside, case .blocked(let why) = DestinationGuard.check(
                t.url(t.parts.count), env: env, cloudRoots: cloudRoots, isUbiquitous: isUbiquitous,
                deviceOf: deviceOf, pickedFolder: folder)
            {
                result = .blocked(why)
            } else {
                let url = URL(fileURLWithPath: key, isDirectory: true)
                switch FolderPlanner.node(url.path) {
                case .missing: result = .usable(existingNames: [])
                case .other:
                    result = .blocked(
                        reuse ? FolderPlanner.fileInTheWayText(t.parts.last ?? url.lastPathComponent)
                            : FolderPlanner.nameTakenText)
                case .unreadable, .directory(dataless: true): result = .blocked(FolderPlanner.unreadableText)
                case .directory(dataless: false):
                    // Outside, the home folder itself may be a destination; it is not "outside home".
                    let exclusion = t.isOutside
                        ? OrganizeGuard.folderExclusion(for: url, env: env, cloudRoots: rootURLs, cache: cache)
                        : OrganizeGuard.exclusion(for: url, env: env, cloudRoots: rootURLs, cache: cache)
                    if !reuse {
                        result = .blocked(FolderPlanner.folderExistsText)
                    } else if let e = exclusion {
                        result = .blocked(OrganizeGuard.reasonText(e))
                    } else if let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
                        result = .usable(existingNames: names)
                    } else {
                        result = .blocked(FolderPlanner.unreadableText)
                    }
                }
            }
            destCache[cacheKey] = result
            return result
        }

        // One spelling per destination folder: APFS compares names case- and normalization-insensitively, so
        // "Notes" and "notes" are one folder. Every folder takes the first spelling the placements use, and all
        // checks below (created folders, taken names, R-C10 clashes) then see it once.
        var spelling: [String: String] = [:]  // keyed absolute path -> first spelling of its last component
        func canonical(_ t: Target) -> Target {
            var out: [String] = []
            for part in t.parts {
                let key = NamingRules.key(([t.base.path] + out + [part]).joined(separator: "/"))
                if spelling[key] == nil { spelling[key] = part }
                out.append(spelling[key]!)
            }
            return Target(base: t.base, parts: out, isOutside: t.isOutside)
        }

        // Group by destination, keeping name order within each.
        var placed: [(c: ScannedFile, to: Target, newName: String, groupID: String?)] = []
        for p in placements {
            let c = p.file
            let to = canonical(target(p))
            if case .blocked(let why) = dest(to, reuse: p.reuseExisting) {
                unsorted.append(LeftAlone(url: c.url, reason: why))
                blockedFiles[c.url] = why
                continue
            }
            let newName = NamingRules.proposedName(for: c.name, kind: c.kind, dateTaken: c.date, options: options) ?? c.name
            placed.append((c, to, newName, p.groupID))
        }

        // Names taken in each destination: its full current listing, plus subfolders this plan creates in it
        // (R-C3, APFS comparison). Any name wanted twice, or already taken, sends the files to Unsorted.
        var taken: [String: Set<String>] = [:]
        var listed: Set<String> = []
        for to in Set(placed.map(\.to)) {
            // The destination and the new folders on its way; the base only when it is the destination.
            for n in (to.parts.isEmpty ? 0 : 1)...to.parts.count {
                let sub = to.key(n)
                if !listed.contains(sub) {
                    listed.insert(sub)
                    if case .usable(let names) = dest(to.prefix(n)) {
                        taken[sub, default: []].formUnion(names.map(NamingRules.key))
                    }
                }
                if n > 0 {
                    taken[to.key(n - 1), default: []].insert(NamingRules.key(to.parts[n - 1]))
                }
            }
        }
        // R-C10, two passes in the stable name order. Pass 1: every file wants its proposed name; a name already
        // taken, or wanted twice in one destination, clashes. Names that don't clash are reserved first.
        // Pass 2: each clashing file falls back to its current name and takes it if nothing holds it yet
        // (taken, a pass-1 name, or an earlier fallback); otherwise it goes to Unsorted.
        // Keyed by folder key and name key: one APFS slot per name, whatever the spellings.
        func slot(_ dirKey: String, _ name: String) -> String { dirKey + "/" + NamingRules.key(name) }
        var wanted: [String: Int] = [:]
        for p in placed { wanted[slot(p.to.dirKey, p.newName), default: 0] += 1 }
        var reserved: Set<String> = []
        for (dir, names) in taken { for k in names { reserved.insert(dir + "/" + k) } }
        var clashes: [Bool] = []
        for p in placed {
            let key = slot(p.to.dirKey, p.newName)
            let clash = reserved.contains(key) || wanted[key, default: 0] > 1
            clashes.append(clash)
        }
        for (p, clash) in zip(placed, clashes) where !clash { reserved.insert(slot(p.to.dirKey, p.newName)) }
        var finalName: [String?] = []
        for (p, clash) in zip(placed, clashes) {
            if !clash { finalName.append(p.newName); continue }
            let key = slot(p.to.dirKey, p.c.name)
            if reserved.contains(key) { finalName.append(nil); continue }
            reserved.insert(key)
            finalName.append(p.c.name)
        }

        // A created folder carries a group's id only when every file placed through it is in that one group;
        // a shared parent or a kind folder has none. nil in the set marks a file with no group.
        var passing: [String: Set<String?>] = [:]
        for (p, name) in zip(placed, finalName) where name != nil {
            for n in 0...p.to.parts.count { passing[p.to.key(n), default: []].insert(p.groupID) }
        }
        func folderGroupID(_ sub: String) -> String? {
            guard let ids = passing[sub], ids.count == 1, let only = ids.first else { return nil }
            return only
        }

        var folderSteps: [PlannedStep] = []
        var created: Set<String> = []
        var moveSteps: [PlannedStep] = []
        var installers: Set<UUID> = []
        for (p, name) in zip(placed, finalName) {
            guard let name else {
                unsorted.append(LeftAlone(url: p.c.url, reason: FolderPlanner.nameTakenText)); continue
            }
            for n in stride(from: 1, through: p.to.parts.count, by: 1) {
                let sub = p.to.key(n)
                if created.contains(sub) { continue }
                let url = p.to.url(n)
                if case .missing = FolderPlanner.node(url.path) {
                    created.insert(sub)
                    folderSteps.append(PlannedStep(
                        action: .createFolder(url), snapshot: nil,
                        catalogEntryID: OrganizeCatalogID.createFolder, provider: nil, groupID: folderGroupID(sub)))
                }
            }
            let dir = p.to.parts.isEmpty
                ? p.to.base : p.to.base.appendingPathComponent(p.to.parts.joined(separator: "/"), isDirectory: true)
            let to = dir.appendingPathComponent(name)
            let step = PlannedStep(
                action: .move(from: p.c.url, to: to), snapshot: p.c.snapshot,
                catalogEntryID: OrganizeCatalogID.move, provider: nil, groupID: p.groupID)
            if p.c.kind == .installers { installers.insert(step.id) }
            moveSteps.append(step)
        }

        unsorted = FolderPlanner.byName(unsorted)
        let summary = FolderSummary(
            foldersToCreate: folderSteps.count,
            filesToMove: moveSteps.filter { FolderPlanner.changes({ $0.deletingLastPathComponent() }, $0) }.count,
            filesToRename: moveSteps.filter { FolderPlanner.changes({ $0.lastPathComponent }, $0) }.count,
            leftForYou: unsorted.count)
        let result = FolderPlanResult(
            plan: OrganizePlan(title: folder.lastPathComponent, steps: folderSteps + moveSteps, leftAlone: leftAlone),
            unsorted: unsorted, summary: summary, canTrashInStorage: installers)
        return (result, blockedFiles)
    }
}
