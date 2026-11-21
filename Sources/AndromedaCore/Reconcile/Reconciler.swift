import Foundation

public enum UnaccountedReason: String, Sendable, CaseIterable {
    /// Rev H: the one sized line for what's left; it absorbs the old locked-folders reason.
    case protectedAreas, otherUsers
    /// R25: the local directory didn't answer, so other accounts can't be named or measured. Never shown with `otherUsers`.
    case accountsUnknown
    case noFullDiskAccess, purgeableNotMeasurable, otherVolumes
}

public struct Reconciliation: Equatable, Sendable {
    /// Rev G6: container used minus the purgeable estimate, as Storage settings counts it. Equals
    /// `containerUsed` when purgeable isn't measurable.
    public let used: Int64
    /// Container capacity minus container free (rev G).
    public let containerUsed: Int64
    /// Sum of `byBucket`.
    public let measured: Int64
    /// Measured bytes per Storage-settings bucket (rev G): findings, large items, unlisted home bytes,
    /// Applications, the macOS volumes, and (rev H) the outside rows and measured other accounts. Zero entries are absent.
    public let byBucket: [AppleBucket: Int64]
    public let purgeable: PurgeableEstimate
    public let unaccounted: Int64
    /// Rev H: the figure the `protectedAreas` line shows: `unaccounted`, minus what the other volumes hold
    /// when that reason is shown too (floored at 0).
    public let protectedRemainder: Int64
    /// Rulings R9, R25: nothing else can explain the remainder (Full Disk Access granted, purgeable measurable,
    /// accounts listed and every one measured in full, the helper on, no outside row a lower bound), so it can be
    /// called protected. Otherwise the line only says it isn't measured yet.
    public let remainderIsProtected: Bool
    /// Difference between the category sum and used space, which excludes estimated purgeable space.
    public let overcount: Int64
    /// Difference that remains even when all container usage, including purgeable space, is included.
    public var overcountBeyondPurgeable: Int64 { max(0, measured - containerUsed) }
    /// Private bytes over actionable, sized Trash-move findings ("frees at least"); nil when any of them is
    /// unknown. Never built from allocated bytes (spec §7.1 rev 2).
    public let freesAtLeast: Int64?
    /// Some Trash-move finding is actionable, so a "frees at least" total is worth showing.
    public let hasActionable: Bool
    /// Some finding, large item, unlisted home bytes, app or outside row shares space with clones, so `measured` counts shared space more
    /// than once and `unaccounted` may be low.
    public let clonesPresent: Bool
    public let unlistedCloneBuckets: Set<AppleBucket>
    public let unreadable: [URL]
    /// Rev H: one total per folder outside the home folder, as measured.
    public let outside: [OutsideMeasurement]
    public let otherAccounts: [OtherAccountSize]
    public let reasons: [UnaccountedReason]
}

/// Turns scan results into honest totals: measured, estimated purgeable, and the explained remainder.
public enum Reconciler {
    public static func reconcile(
        usage: VolumeUsage, findings: [Finding], largeItems: [LargeItem],
        unlisted: [AppleBucket: Int64] = [:], applications: Int64 = 0,
        unlistedClones: Bool = false, applicationsClones: Bool = false,
        unlistedCloneBuckets: Set<AppleBucket> = [],
        unreadable: [URL], fda: FDAStatus,
        outside: [OutsideMeasurement], otherAccounts: [OtherAccountSize],
        helperOn: Bool = false, accountsKnown: Bool = true
    ) -> Reconciliation {
        // Rev G: the whole container, so every volume has a place in `byBucket` (macOS volumes) or the remainder.
        // Rev G6: minus purgeable, which Storage settings counts as available on 26 and 27.
        let estimate: Int64
        if case .bytes(let b) = usage.purgeable { estimate = b } else { estimate = 0 }
        let used = max(0, usage.containerUsed - estimate)
        var byBucket: [AppleBucket: Int64] = [:]
        func add(_ bytes: Int64, to bucket: AppleBucket) {
            if bytes != 0 { byBucket[bucket, default: 0] += bytes }
        }
        for f in findings { add(f.bytes ?? 0, to: f.entry.bucket) }
        for item in largeItems { add(item.bytes, to: item.probableBucket) }
        for (bucket, bytes) in unlisted { add(bytes, to: bucket) }
        add(applications, to: .applications)
        for row in outside { add(row.bytes, to: row.row.bucket) }
        for account in otherAccounts { add(account.bytes ?? 0, to: .otherUsers) }
        add(usage.macOSVolumesUsed, to: .macOS)
        let measured = byBucket.values.reduce(0, +)
        let unaccounted = max(0, used - measured)
        let overcount = max(0, measured - used)

        // Spec rev A rule 1: only Trash moves promise freed space. Removals that run a command
        // (.tool, .deleteLocalSnapshots) show no "frees" figure, so they never enter this total.
        let actionable = findings.filter { $0.verdict.actionable && $0.entry.removal == .trash }
        // Unsized findings (snapshots, unreadable) aren't counted, just as they aren't in `measured`.
        let freesAtLeast = actionable.filter { $0.bytes != nil }
            .reduce(Int64?(0)) { sum, f in sum.flatMap { s in f.freeableBytes.map { s + $0 } } }
        let clonesPresent = findings.contains(where: \.clonesPresent) || largeItems.contains(where: \.clonesPresent)
            || unlistedClones || applicationsClones || !unlistedCloneBuckets.isEmpty || outside.contains(where: \.clonesPresent)

        var seen = Set<String>()
        let allUnreadable = (unreadable + findings.flatMap(\.unreadable) + outside.flatMap(\.unreadablePaths))
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }

        let otherVolumes = unaccounted > 0 && usage.unattributedContainerBytes > 1_000_000_000
        // The other-volumes line explains its own share, so the protected line doesn't claim it too.
        let protectedRemainder = otherVolumes ? max(0, unaccounted - usage.unattributedContainerBytes) : unaccounted
        // R25: any lower bound or unknown means part of the remainder may be ordinary, measurable space.
        let remainderIsProtected = fda == .granted && usage.purgeable != .notMeasurable && accountsKnown
            && !otherAccounts.contains { $0.bytes == nil || $0.atLeast } && helperOn
            && !outside.contains(where: \.isLowerBound)
        let reasons = UnaccountedReason.allCases.filter { reason in
            switch reason {
            // Equals `unaccounted > 0` unless the other volumes hold all of it; "About Zero KB" would mislead.
            case .protectedAreas: protectedRemainder > 0
            case .otherUsers: accountsKnown && otherAccounts.contains { $0.bytes == nil }
            case .accountsUnknown: !accountsKnown
            case .noFullDiskAccess: fda != .granted
            case .purgeableNotMeasurable: usage.purgeable == .notMeasurable
            case .otherVolumes: otherVolumes
            }
        }

        return Reconciliation(
            used: used, containerUsed: usage.containerUsed, measured: measured, byBucket: byBucket, purgeable: usage.purgeable,
            unaccounted: unaccounted, protectedRemainder: protectedRemainder,
            remainderIsProtected: remainderIsProtected, overcount: overcount,
            freesAtLeast: freesAtLeast, hasActionable: !actionable.isEmpty, clonesPresent: clonesPresent,
            unlistedCloneBuckets: unlistedCloneBuckets,
            unreadable: allUnreadable, outside: outside, otherAccounts: otherAccounts, reasons: reasons)
    }
}
