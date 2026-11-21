/// How far one root walk may go before it stops and reports itself truncated (R9).
public struct Budget: Equatable, Sendable {
    public var maxEntries: Int
    public var maxSeconds: Double

    public init(maxEntries: Int, maxSeconds: Double) {
        self.maxEntries = maxEntries
        self.maxSeconds = maxSeconds
    }

    /// The catalog-mirroring entries.
    public static let standard = Budget(maxEntries: 2_000_000, maxSeconds: 8)
    /// The outside-home entries: much larger trees (proposal §2.2).
    public static let outside = Budget(maxEntries: 3_000_000, maxSeconds: 25)
}

/// One compiled-in root of a table entry, with the subtrees the walk leaves out.
public struct MeasureRoot: Equatable, Sendable {
    public let path: String
    /// Absolute paths under `path`, skipped with their whole subtree.
    public let excluding: [String]
    /// Which directories under `path` the walk may enter (R12, R21).
    public let policy: DescentPolicy
    public let budget: Budget

    init(path: String, excluding: [String] = [], policy: DescentPolicy = .unrestricted, budget: Budget = .standard) {
        self.path = path
        self.excluding = excluding
        self.policy = policy
        self.budget = budget
    }
}

/// The fixed, compiled-in map from entry ID to the root-only paths the helper may measure.
/// Clients send an ID, never a path.
public struct MeasureTable: Sendable {
    let roots: [String: [MeasureRoot]]

    /// Test-only (through `@testable`). Production code uses `.production`.
    init(roots: [String: [MeasureRoot]]) { self.roots = roots }

    /// Test-only: plain paths with no exclusions and the standard budget.
    init(_ paths: [String: [String]]) {
        self.init(roots: paths.mapValues { $0.map { MeasureRoot(path: $0) } })
    }

    /// The first four are entries whose paths a non-root walk couldn't read on 2026-10-30
    /// (`.Spotlight-V100`, `/System/Volumes/VM` and `/Library/Updates` errored;
    /// `/private/var/db/diagnostics` was partly unreadable). Each maps to exactly its catalog
    /// JSON's paths.
    /// - `system-caches` is excluded (R8): `/Library/Caches` is world-writable.
    /// - `var-folders` is excluded: its unreadable remainder is other accounts' data.
    ///
    /// The last three measure what lies outside the home folder (H1). They have no catalog entry
    /// (H4), each excludes the catalog's paths under its root so nothing is counted twice, and
    /// they enter only system-owned directories that no non-administrator can write to (R12,
    /// R21: `.outside`). `/private/var/folders` is excluded whole (R13): the catalog counts the
    /// caller's own, and other accounts' are theirs.
    public static let production = MeasureTable(roots: [
        "spotlight-index": [MeasureRoot(path: "/System/Volumes/Data/.Spotlight-V100")],
        "swap-and-sleepimage": [MeasureRoot(path: "/System/Volumes/VM")],
        "update-staging": [MeasureRoot(path: "/Library/Updates")],
        "unified-log": [MeasureRoot(path: "/private/var/db/diagnostics")],
        "outside-library": [MeasureRoot(
            path: "/Library",
            excluding: ["/Library/Caches", "/Library/Updates", "/Library/Developer/CoreSimulator/Images"],
            policy: .outside, budget: .outside)],
        "outside-private": [MeasureRoot(
            path: "/private", excluding: ["/private/var/db/diagnostics", "/private/var/folders"],
            policy: .outside, budget: .outside)],
        "system-hidden": [
            MeasureRoot(path: "/System/Volumes/Data/.DocumentRevisions-V100", policy: .outside, budget: .outside),
            MeasureRoot(path: "/System/Volumes/Data/.fseventsd", policy: .outside, budget: .outside),
        ],
    ])

    public func roots(for id: EntryID) -> [MeasureRoot]? { roots[id.rawValue] }
}
