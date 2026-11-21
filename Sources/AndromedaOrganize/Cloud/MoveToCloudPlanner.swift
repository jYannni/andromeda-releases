import AndromedaCore
import Foundation

public struct MoveCandidate: Identifiable, Equatable, Sendable {
    public let id: URL
    /// Allocated bytes, as the large-items scan measured it.
    public let usesBytes: Int64
    /// Private bytes; nil means "can't be measured" (never the allocated figure).
    public let freesAtLeast: Int64?
    public let lastUse: LastUse

    public init(id: URL, usesBytes: Int64, freesAtLeast: Int64?, lastUse: LastUse) {
        self.id = id
        self.usesBytes = usesBytes
        self.freesAtLeast = freesAtLeast
        self.lastUse = lastUse
    }
}

/// Finds large, stale local items and builds a plan to move them into one cloud provider's folder.
/// Planning only: nothing here changes the disk.
public struct MoveToCloudPlanner {
    public typealias Scanner = (Int64) -> [LargeItem]

    private let env: ScanEnvironment
    private let cloudRoots: [CloudRoot]
    private let settings: OrganizeSettings
    private let now: Date
    private let lastUsed: LastUsedReader
    private let scanner: Scanner
    private let size: (URL) -> SizeResult
    private let deviceOf: (URL) -> Int32?

    public init(
        env: ScanEnvironment, cloudRoots: [CloudRoot], settings: OrganizeSettings, now: Date = Date(),
        lastUsed: LastUsedReader = LastUsedReader(),
        promptingPathsReadable: Bool = true,
        scanner: Scanner? = nil,
        size: @escaping (URL) -> SizeResult = { AllocatedSizer().size(of: $0) },  // fresh sizer per item
        deviceOf: @escaping (URL) -> Int32? = MoveToCloudPlanner.liveDevice
    ) {
        self.env = env
        self.cloudRoots = cloudRoots
        self.settings = settings
        self.now = now
        self.lastUsed = lastUsed
        self.scanner = scanner ?? { threshold in
            Self.homeWalk(
                env: env, cloudRoots: cloudRoots, threshold: threshold, promptingPathsReadable: promptingPathsReadable)
        }
        self.size = size
        self.deviceOf = deviceOf
    }

    /// What the home walk never enters: every cloud folder (O9: a provider's folder is walked only after its
    /// Check), the protected iCloud container folder, and the applications roots (like `ScanModel`'s walk).
    public static func walkExclusions(env: ScanEnvironment, cloudRoots: [CloudRoot]) -> [URL] {
        let library = env.home.appendingPathComponent("Library", isDirectory: true)
        return cloudRoots.map(\.url) + [
            library.appendingPathComponent("CloudStorage", isDirectory: true),
            library.appendingPathComponent("Mobile Documents", isDirectory: true),
        ] + env.applicationsRoots
    }

    /// The candidates walk of home (§4.1 step 1). `promptingPathsReadable` is `fda == .granted`, exactly as
    /// `ScanModel` passes it: without Full Disk Access, protected folders are never stat'ed or listed.
    public static func homeWalk(
        env: ScanEnvironment, cloudRoots: [CloudRoot], threshold: Int64, promptingPathsReadable: Bool
    ) -> [LargeItem] {
        LargeItemsScanner(env: env, threshold: threshold, promptingPathsReadable: promptingPathsReadable, root: env.home)
            .scan(excluding: walkExclusions(env: env, cloudRoots: cloudRoots)).items
    }

    public static func alreadyThereText(_ provider: CloudProvider) -> String {
        "Something with this name is already in \(provider.displayName)"
    }
    public static func fileInTheWayText(_ provider: CloudProvider) -> String {
        "A file is in the way in \(provider.displayName)"
    }
    public static func outsideText(_ provider: CloudProvider) -> String {
        "The destination is outside \(provider.displayName)"
    }
    public static let otherDiskText = "On another disk — not in this version"
    public static let unreadableText = "Couldn't be read"
    public static let insideItselfText = "The destination is inside this item"
    public static let containsCloudText = "Contains a cloud folder"
    public static let protectedProjectText = "This item is in or contains a protected project folder"

    /// The device of the item `url` resolves to (`stat`, so a symlinked cloud root reports its target's volume).
    public static func liveDevice(_ url: URL) -> Int32? {
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_dev : nil
    }

    /// Paths compare case-insensitively (case-insensitive APFS).
    private static func fold(_ path: String) -> String { path.lowercased() }
    private static func isInside(_ path: String, _ folder: String) -> Bool {
        let p = fold(path), f = fold(folder)
        return p == f || p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    public static func isProtectedProject(_ url: URL, folders: [String]) -> Bool {
        let path = url.standardizedFileURL.path
        return folders.contains { folder in
            let protected = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL.path
            return isInside(path, protected) || isInside(protected, path)
        }
    }

    private enum Probe { case missing, exists(isDirectory: Bool), unreadable }
    private static func probe(_ path: String) -> Probe {
        var st = stat()
        if lstat(path, &st) == 0 { return .exists(isDirectory: (st.st_mode & S_IFMT) == S_IFDIR) }
        // ENOTDIR: a file sits in the path; the ancestor walk names it.
        return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
    }

    // MARK: Candidates

    /// Why this item must never be moved to the cloud, or nil. Shared by `candidates()` and `plan()`.
    private func unsafeReason(_ url: URL, cache: OrganizeGuard.Cache) -> String? {
        let rootURLs = cloudRoots.map(\.url)
        let path = url.standardizedFileURL.path
        if Self.isProtectedProject(url, folders: settings.moveProtectedFolders) { return Self.protectedProjectText }
        if rootURLs.contains(where: { Self.isInside(path, $0.standardizedFileURL.path) }) {
            return OrganizeGuard.reasonText(.cloudRoot)
        }
        // An item holding a cloud root would move the root (or the destination) into itself.
        if rootURLs.contains(where: { Self.isInside($0.standardizedFileURL.path, path) }) {
            return Self.containsCloudText
        }
        if let e = OrganizeGuard.exclusion(for: url, env: env, cloudRoots: rootURLs, cache: cache) {
            return OrganizeGuard.reasonText(e)
        }
        if Self.hasSymlinkAncestor(url, below: env.home.standardizedFileURL) {
            return OrganizeGuard.reasonText(.symlink)
        }
        return nil
    }

    public func candidates() -> [MoveCandidate] {
        let cache = OrganizeGuard.Cache()
        var out: [MoveCandidate] = []
        for item in scanner(settings.moveMinBytes) where item.bytes >= settings.moveMinBytes {
            let url = item.url.standardizedFileURL
            if unsafeReason(url, cache: cache) != nil { continue }
            // P14: unknown age is never offered.
            guard let use = lastUsed.lastUse(of: url) else { continue }
            if now.timeIntervalSince(use.date) < settings.moveMinAge { continue }
            out.append(MoveCandidate(
                id: url, usesBytes: item.bytes, freesAtLeast: size(url).privateBytes, lastUse: use))
        }
        return out.sorted { a, b in
            switch (a.freesAtLeast, b.freesAtLeast) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if a.usesBytes != b.usesBytes { return a.usesBytes > b.usesBytes }
            return a.id.path < b.id.path
        }
    }

    /// Any symlink strictly between home and the item (the item itself is the guard's business).
    static func hasSymlinkAncestor(_ url: URL, below home: URL) -> Bool {
        var node = url.deletingLastPathComponent()
        while fold(node.path).hasPrefix(fold(home.path) + "/") {
            var st = stat()
            if lstat(node.path, &st) != 0 || (st.st_mode & S_IFMT) == S_IFLNK { return true }
            node = node.deletingLastPathComponent()
        }
        return false
    }

    // MARK: Plan

    public func plan(_ selected: [MoveCandidate], to root: CloudRoot) -> OrganizePlan {
        let base = settings.destination(for: root).standardizedFileURL
        let home = env.home.standardizedFileURL.path
        let cache = OrganizeGuard.Cache()
        let title = "Move to \(root.provider.displayName)"

        // Fail closed: without the cloud root's volume nothing can be checked.
        guard deviceOf(root.url) != nil else {
            return OrganizePlan(
                title: title, steps: [],
                leftAlone: selected.map { LeftAlone(url: $0.id.standardizedFileURL, reason: Self.unreadableText) })
        }

        var folders: [PlannedStep] = []
        // Folders planned in this run, with the device of the existing ancestor they will be created on.
        var made: [String: Int32] = [:]
        var moves: [PlannedStep] = []
        var left: [LeftAlone] = []

        for cand in selected {
            let src = cand.id.standardizedFileURL
            func skip(_ reason: String) { left.append(LeftAlone(url: src, reason: reason)) }

            guard Self.fold(src.path).hasPrefix(Self.fold(home) + "/") else {
                skip(OrganizeGuard.reasonText(.notInHome)); continue
            }
            if let reason = unsafeReason(src, cache: cache) { skip(reason); continue }

            let relative = String(src.path.dropFirst(home.count + 1))
            let dest = URL(fileURLWithPath: base.path + "/" + relative)
            guard Self.isInside(dest.path, root.url.standardizedFileURL.path) else {
                skip(Self.outsideText(root.provider)); continue
            }
            if Self.isInside(dest.path, src.path) { skip(Self.insideItselfText); continue }

            switch Self.probe(dest.path) {
            case .exists: skip(Self.alreadyThereText(root.provider)); continue
            case .unreadable: skip(Self.unreadableText); continue
            case .missing: break
            }
            guard let snapshot = ItemSnapshot.capture(src, bytes: cand.usesBytes) else {
                skip(Self.unreadableText); continue
            }

            // Walk up to the nearest existing ancestor, collecting what is missing.
            var missing: [URL] = []
            var existing: URL?
            var madeDevice: Int32?
            var problem: String?
            var node = dest.deletingLastPathComponent()
            while true {
                if let dev = made[Self.fold(node.path)] { madeDevice = dev; break }
                switch Self.probe(node.path) {
                case .exists(let isDirectory):
                    if isDirectory { existing = node } else { problem = Self.fileInTheWayText(root.provider) }
                case .unreadable: problem = Self.unreadableText
                case .missing: missing.append(node)
                }
                if problem != nil || existing != nil { break }
                let parent = node.deletingLastPathComponent()
                if parent.path == node.path { problem = Self.unreadableText; break }
                node = parent
            }
            if let problem { skip(problem); continue }
            // The volume that will actually receive the item: the nearest existing ancestor's, or the
            // one recorded for a folder planned earlier. Always checked; no device means unreadable.
            guard let srcDev = deviceOf(src) else { skip(Self.unreadableText); continue }
            let destDev: Int32?
            if let madeDevice { destDev = madeDevice } else if let existing { destDev = deviceOf(existing) } else { destDev = nil }
            guard let destDev else { skip(Self.unreadableText); continue }
            if srcDev != destDev { skip(Self.otherDiskText); continue }
            for folder in missing.reversed() where made[Self.fold(folder.path)] == nil {
                made[Self.fold(folder.path)] = destDev
                folders.append(PlannedStep(
                    action: .createFolder(folder), snapshot: nil,
                    catalogEntryID: OrganizeCatalogID.createFolder, provider: root.provider))
            }
            moves.append(PlannedStep(
                action: .move(from: src, to: dest), snapshot: snapshot,
                catalogEntryID: OrganizeCatalogID.cloudMove, provider: root.provider))
        }
        return OrganizePlan(title: title, steps: folders + moves, leftAlone: left)
    }
}
