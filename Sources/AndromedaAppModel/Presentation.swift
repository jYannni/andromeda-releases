import AndromedaCore
import Foundation

public enum VerdictKind: Equatable, Sendable { case safe, withCare, leaveIt, cantRemove, reportOnly }

public struct ItemRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// The catalog explanation, plus a note when macOS blocked even the helper.
    public let detail: String
    /// What happens afterwards (the catalog consequence).
    public let afterwards: String
    public let sizeText: String
    public let freesText: String?
    public let sharedNote: String?
    /// Set for command-based removals, which make no size promise.
    public let commandSizeNote: String?
    public let verdictLabel: String
    public let verdictKind: VerdictKind
    public let howRemoved: String
    public let selectable: Bool
    public let startsSelected: Bool
    public let notVerifiedNote: String?
    /// Set when the tool the removal needs isn't installed.
    public let toolMissingNote: String?
    /// Unreadable without Full Disk Access.
    public let couldntCheck: Bool
    public let betterAction: BetterAction
    /// True when the helper isn't ready but could carry out this row's better action (ruling P25).
    public let helperCanDoThis: Bool
}

public struct LargeItemRow: Identifiable, Equatable, Sendable {
    public let id: URL
    public let name: String
    /// Home-relative with `~`, never the absolute home path.
    public let path: String
    public let sizeText: String
    public let sharedNote: String?
    /// False for the "Other apps" summary row, which stands for many paths and has nothing to reveal.
    public var revealable: Bool = true
}

/// "Other files in your home folder": allocated bytes no row lists one by one. Read-only.
public struct UnlistedRow: Equatable, Sendable {
    public let title: String
    public let note: String
    public let sizeText: String
    /// Where "Show in Finder" opens.
    public let revealURL: URL
}

/// A read-only line for space Andromeda measures but doesn't list (the macOS system volumes).
public struct VolumeRow: Equatable, Sendable {
    public let title: String
    public let sizeText: String
}

/// Rev H: a read-only line for a folder outside the home folder, or another account's folder.
public struct OutsideLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// nil when the size isn't known; `note` then says why.
    public let sizeText: String?
    public let note: String?
    /// Where "Show in Finder" opens; nil for other accounts and for the catch-all row.
    public let revealURL: URL?
    /// Another account's folder rather than a folder on the disk.
    public var isAccount = false

    /// "Other user: tester — 12.3 GB" for VoiceOver, then the note when there is one, so a size's
    /// caveat ("shares space") is read too.
    public var accessibilityLabel: String {
        let line = Copy.Outside.line(title, sizeText ?? note ?? "")
        guard sizeText != nil, let note else { return line }
        return "\(line). \(note)"
    }
}

public struct CategoryPage: Identifiable, Equatable, Sendable {
    public let id: AppleBucket
    public let title: String
    public let rows: [ItemRow]
    public let largeItems: [LargeItemRow]
    public let unlistedRow: UnlistedRow?
    /// Applications only: the top 50 apps, then an "Other apps" summary row.
    public let appRows: [LargeItemRow]
    /// macOS only: "macOS system volumes".
    public let volumeRow: VolumeRow?
    /// Over `outsideLines`; nil when they need no heading.
    public let outsideHeading: String?
    /// System Data: folders outside home, largest first. Other Users & Shared: the shared folder, then each account.
    public let outsideLines: [OutsideLine]

    /// Whether this category contributes any items to Andromeda’s cleanup selection.
    public var hasSelectableCleanup: Bool { rows.contains(where: \.selectable) }
}

public struct BarSegment: Identifiable, Equatable, Sendable {
    public enum Kind: Hashable, Sendable { case bucket(AppleBucket), unaccounted }
    public var id: Kind { kind }
    public let kind: Kind
    public let label: String
    public let bytes: Int64
    /// Share of the bar, 0...1. The bar is as wide as the larger of the disk's used space and the
    /// parts, so an overcount never spills past the end. Purgeable isn't in the bar (rev G6).
    public let fraction: Double
    private let showsCategoryAllocation: Bool

    /// Public so a drive page can draw its one "used" segment (plan 7).
    public init(kind: Kind, label: String, bytes: Int64, fraction: Double, showsCategoryAllocation: Bool = false) {
        self.kind = kind
        self.label = label
        self.bytes = bytes
        self.fraction = fraction
        self.showsCategoryAllocation = showsCategoryAllocation
    }

    /// "<Title>, <size>, <percent> of used" for VoiceOver.
    public var accessibilityLabel: String {
        let pct = fraction * 100
        let percent = pct < 1 ? Copy.Overview.lessThanOnePercent : "\(Int(pct.rounded()))%"
        return Copy.Overview.segmentAccessibility(label, size: ByteFormat.string(bytes), percent: percent,
                                                  showsCategoryAllocation: showsCategoryAllocation)
    }
}

/// The disk at a glance, for the Overview's headline: what is used, of how much, and what is left.
public struct DiskGauge: Equatable, Sendable {
    public let used: String
    public let ofCapacity: String
    public let available: String
    /// Used over capacity, 0...1: how much of the bar's track the categories fill.
    public let usedFraction: Double
}

public struct SpaceBreakdown: Equatable, Sendable {
    public let unexplainedBytes: Int64
    public let unreadablePaths: [String]
    public let fullDiskAccess: FDAStatus
    public let purgeable: PurgeableEstimate
    public let snapshots: [LocalSnapshot]?
    public let otherVolumes: [OtherVolume]
    public let notes: [String]
    public let sharedAllocationLocations: [String]
    public let overcountDetail: String?
}

public struct OverviewSummary: Equatable, Sendable {
    public let usedText: String?
    public var gauge: DiskGauge? = nil
    /// How much the scan attributed, shown separately from physical use when allocations may overlap.
    public let foundText: String?
    public let allocationNote: String?
    public let bar: [BarSegment]
    /// Rev G6: "Plus X purgeable (estimate)…", under the bar. Nil when purgeable is zero or not measurable.
    public let purgeableText: String?
    public let totalsUnknownNote: String?
    public let unaccountedText: String?
    public let spaceBreakdown: SpaceBreakdown?
    public let quickWins: [ItemRow]
    /// "Could be online-only: …" for the cloud providers already checked (ruling P8). Nil when none
    /// is checked or they suggest nothing. Never one of the quick wins (ruling V1 keeps those to Trash moves).
    public let onlineOnlyText: String?
    public let cards: [ExplainerCard]
    public let couldntCheck: [ItemRow]
}

/// Turns a `ScanResult` into every string and flag the UI shows. Pure; views decide nothing.
public enum Presentation {
    public static func pages(_ r: ScanResult, helperReady: Bool, showApplications: Bool = false) -> [CategoryPage] {
        let sized = r.findings.map { (finding: $0, row: row($0, r, helperReady)) }
        return AppleBucket.displayOrder.compactMap { bucket in
            let rows = sized.filter { $0.finding.entry.bucket == bucket }
                .sorted(by: ranksBefore).map(\.row)
            let large = r.largeItems.filter { $0.probableBucket == bucket }
                .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.url.path < $1.url.path }
                .map { largeRow($0, home: r.env.home) }
            var unlistedRow: UnlistedRow?
            if let bytes = r.unlisted[bucket], bytes > 0 {
                unlistedRow = UnlistedRow(
                    title: Copy.Rows.unlistedTitle, note: Copy.Rows.unlistedNote,
                    sizeText: ByteFormat.string(bytes), revealURL: unlistedRevealURL(bucket, home: r.env.home))
            }
            let appRows = bucket == .applications ? applicationRows(r) : []
            var volumeRow: VolumeRow?
            if bucket == .macOS, let usage = r.usage, usage.macOSVolumesUsed > 0 {
                volumeRow = VolumeRow(
                    title: Copy.Rows.macOSVolumes, sizeText: ByteFormat.string(usage.macOSVolumesUsed))
            }
            let outside = outsideLines(bucket, r)
            guard !rows.isEmpty || !large.isEmpty || unlistedRow != nil || !appRows.isEmpty
                || volumeRow != nil || !outside.isEmpty || (r.reconciliation.byBucket[bucket] ?? 0) > 0
                || (bucket == .applications && showApplications)
            else { return nil }
            return CategoryPage(
                id: bucket, title: Copy.Buckets.title(bucket), rows: rows, largeItems: large,
                unlistedRow: unlistedRow, appRows: appRows, volumeRow: volumeRow,
                outsideHeading: bucket == .systemData && !outside.isEmpty ? Copy.Outside.heading : nil,
                outsideLines: outside)
        }
    }

    /// `onlineOnly` is the summed "frees at least" of the checked cloud providers (`CloudModel.onlineOnlyTotal`).
    public static func overview(_ r: ScanResult, helperReady: Bool, onlineOnly: Int64? = nil) -> OverviewSummary {
        let sized = r.findings.map { (finding: $0, row: row($0, r, helperReady)) }
        let quickWins = sized.filter {
            guard case .trash = $0.finding.entry.removal else { return false }  // ruling V1: commands promise no size
            return $0.row.selectable && ($0.finding.bytes ?? 0) > 0
        }
            .sorted(by: ranksBefore).prefix(3).map(\.row)
        let couldntCheck = sized.filter(\.row.couldntCheck).sorted(by: ranksBefore).map(\.row)

        var usedText: String?
        var foundText: String?
        var allocationNote: String?
        var unaccountedText: String?
        var purgeableText: String?
        var bar: [BarSegment] = []
        var spaceBreakdown: SpaceBreakdown?
        var unknownNote: String?
        var gauge: DiskGauge?
        if r.usedKnown, let usage = r.usage {
            let rec = r.reconciliation
            if usage.containerCapacity > 0 {
                gauge = DiskGauge(
                    used: ByteFormat.string(rec.used),
                    ofCapacity: Copy.Overview.ofCapacity(ByteFormat.string(usage.containerCapacity)),
                    available: Copy.Overview.available(ByteFormat.string(max(0, usage.containerCapacity - rec.used))),
                    usedFraction: min(1, max(0, Double(rec.used) / Double(usage.containerCapacity))))
            }
            usedText = Copy.Overview.used(
                ByteFormat.string(rec.used), of: ByteFormat.string(usage.containerCapacity))
            let showsCategoryAllocation = rec.overcount > 0 || rec.clonesPresent
            foundText = showsCategoryAllocation
                ? Copy.Overview.scannedAllocation(ByteFormat.string(rec.measured))
                : Copy.Overview.found(ByteFormat.string(rec.measured), of: ByteFormat.string(rec.used))
            if showsCategoryAllocation { allocationNote = Copy.Overview.allocationNote }
            if rec.unaccounted > 0 {
                unaccountedText = Copy.Overview.unaccounted(ByteFormat.string(rec.unaccounted))
            } else if rec.overcount > 0 {
                unaccountedText = Copy.Overview.overcount(ByteFormat.string(rec.overcount))
            } else {
                unaccountedText = Copy.Overview.nothingUnaccounted
            }
            if case .bytes(let b) = rec.purgeable, b > 0 {
                purgeableText = Copy.Overview.purgeableNote(ByteFormat.string(b))
            }
            // Rev G: one segment per category in Storage settings' order, then the rest. Rev G6: "used"
            // excludes purgeable, so purgeable is a note under the bar, not a segment.
            var parts: [(BarSegment.Kind, String, Int64)] = AppleBucket.displayOrder.map {
                (.bucket($0), Copy.Buckets.title($0), rec.byBucket[$0] ?? 0)
            }
            parts.append((.unaccounted, Copy.Overview.barUnaccounted, rec.unaccounted))
            parts = parts.filter { $0.2 > 0 }
            let total = max(rec.used, parts.reduce(0) { $0 + $1.2 })
            bar = parts.map {
                BarSegment(kind: $0.0, label: $0.1, bytes: $0.2, fraction: Double($0.2) / Double(max(total, 1)),
                           showsCategoryAllocation: showsCategoryAllocation)
            }
            let context = ReasonContext(helperOn: r.helperOn, standardUser: r.standardUser)
            let notes = rec.reasons.filter { [.otherUsers, .accountsUnknown, .otherVolumes].contains($0) }
                .map { ReportExporter.explanation(for: $0, context: context) }
            let unreadable = rec.unreadable.map { Copy.Scan.displayPath($0, home: r.env.home) }
            spaceBreakdown = SpaceBreakdown(
                unexplainedBytes: rec.unaccounted, unreadablePaths: unreadable, fullDiskAccess: r.fda,
                purgeable: rec.purgeable, snapshots: r.snapshots,
                otherVolumes: usage.otherVolumes.filter { $0.roles.isEmpty && $0.used > 0 },
                notes: notes, sharedAllocationLocations: sharedAllocationLocations(r),
                overcountDetail: overcountDetail(rec))
        } else {
            unknownNote = Copy.Overview.totalsUnknown
        }

        return OverviewSummary(
            usedText: usedText, gauge: gauge, foundText: foundText, allocationNote: allocationNote,
            bar: bar, purgeableText: purgeableText, totalsUnknownNote: unknownNote, unaccountedText: unaccountedText,
            spaceBreakdown: spaceBreakdown, quickWins: Array(quickWins),
            onlineOnlyText: onlineOnly.flatMap { $0 > 0 ? Copy.Organize.couldBeOnlineOnly(ByteFormat.string($0)) : nil },
            cards: cards(r), couldntCheck: couldntCheck)
    }

    private static func sharedAllocationLocations(_ result: ScanResult) -> [String] {
        let rec = result.reconciliation
        var locations: Set<String> = []
        for finding in result.findings where finding.clonesPresent {
            let paths = finding.items.filter { $0.clonesPresent && $0.bytes > 0 }
                .map { Copy.Scan.displayPath($0.url, home: result.env.home) }
            let category = Copy.Buckets.title(finding.entry.bucket)
            if paths.isEmpty {
                locations.insert("\(category) — \(finding.entry.title)")
            } else {
                locations.formUnion(paths.map { "\(category) — \($0)" })
            }
        }
        for item in result.largeItems where item.clonesPresent {
            let path = Copy.Scan.displayPath(item.url, home: result.env.home)
            locations.insert("\(Copy.Buckets.title(item.probableBucket)) — \(path)")
        }
        for row in rec.outside where row.clonesPresent {
            locations.insert("\(Copy.Buckets.title(row.row.bucket)) — \(row.row.title)")
        }
        for bucket in rec.unlistedCloneBuckets {
            locations.insert("\(Copy.Buckets.title(bucket)) — Smaller files and folders")
        }
        for app in result.appItems where app.clonesPresent {
            let path = Copy.Scan.displayPath(app.url, home: result.env.home)
            locations.insert("\(Copy.Buckets.title(.applications)) — \(path)")
        }
        return locations.sorted()
    }

    private static func overcountDetail(_ rec: Reconciliation) -> String? {
        guard rec.overcount > 0 else { return nil }
        let difference: String
        if rec.overcountBeyondPurgeable > 0 {
            let excess = ByteFormat.string(rec.overcountBeyondPurgeable)
            difference = "The category sum is still \(excess) higher when compared with all occupied space, including purgeable space."
        } else {
            difference = "The difference falls within macOS’s estimate for purgeable space."
        }
        return difference + " Andromeda couldn’t verify which files explain the full difference."
    }

    // MARK: Cards

    private static func cards(_ r: ScanResult) -> [ExplainerCard] {
        let ids = Set(r.findings.map(\.id))
        var out: [ExplainerCard] = []
        // §7.4: these two explanations are specific to macOS 27.
        if r.env.osMajor >= 27 {
            out.append(.purgeable)
            if ids.contains("apple-intelligence-models") { out.append(.appleIntelligence) }
        }
        if ids.contains("orphaned-simulator-runtimes") { out.append(.orphanedRuntimes) }
        if ids.contains("macos-update-snapshots") || ids.contains("update-staging") { out.append(.pendingUpdate) }
        return out
    }

    // MARK: Rows

    private static func ranksBefore(
        _ a: (finding: Finding, row: ItemRow), _ b: (finding: Finding, row: ItemRow)
    ) -> Bool {
        switch (a.finding.bytes, b.finding.bytes) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.finding.entry.title < b.finding.entry.title
        }
    }

    private static func row(_ f: Finding, _ r: ScanResult, _ helperReady: Bool) -> ItemRow {
        let e = f.entry
        let removable = e.tier == .safe || e.tier == .withCare
        let better = PlanBuilder.betterAction(for: f, helperReady: helperReady, osMajor: r.env.osMajor)

        let selectable: Bool
        switch e.removal {
        case .trash, .tool, .deleteLocalSnapshots: selectable = f.verdict.actionable
        default: selectable = false
        }

        var notVerified: String?
        var toolMissing: String?
        switch f.verdict.reason {
        case .unverified(let os)?: notVerified = Copy.Rows.notVerified(os)
        case .toolMissing(let tool)?:
            toolMissing = Copy.Rows.toolMissing(URL(fileURLWithPath: tool).lastPathComponent)
        default: break
        }

        var (size, frees, shared) = sizes(f, removable: removable, truncated: r.rootMeasureTruncated.contains(f.id))

        var commandNote: String?
        switch e.removal {
        case .tool, .deleteLocalSnapshots:
            // The folder's private bytes are not a floor for a partial command.
            if removable, f.bytes != nil, !f.rootMeasureBlocked {
                frees = nil
                commandNote = Copy.Rows.commandSizeNote
            }
        default: break
        }

        return ItemRow(
            id: f.id, title: e.title,
            detail: f.rootMeasureBlocked ? e.explanation + Copy.Rows.blockedSuffix : e.explanation,
            afterwards: e.consequence, sizeText: size, freesText: frees, sharedNote: shared, commandSizeNote: commandNote,
            verdictLabel: notVerified == nil ? label(e.tier) : "Report only",
            verdictKind: notVerified == nil ? kind(e.tier) : .reportOnly,
            howRemoved: howRemoved(e.removal, better: better),
            selectable: selectable, startsSelected: selectable && e.tier == .safe,
            notVerifiedNote: notVerified, toolMissingNote: toolMissing,
            couldntCheck: !f.unreadable.isEmpty && r.fda != .granted,
            betterAction: better,
            helperCanDoThis: !helperReady && PlanBuilder.helperCanRebuildSpotlight(e, osMajor: r.env.osMajor))
    }

    /// §7.1 rev 2: one figure without clones; "uses" and "frees at least" with them, and the freeable
    /// figure only where removal is offered (core's `freeableBytes` is not tier-gated).
    private static func sizes(_ f: Finding, removable: Bool, truncated: Bool) -> (String, String?, String?) {
        if f.rootMeasureBlocked { return (Copy.Rows.cantMeasure, nil, nil) }
        guard let bytes = f.bytes else {
            if !f.snapshots.isEmpty { return (Copy.Rows.snapshots(f.snapshots.count), nil, nil) }
            if !f.unreadable.isEmpty { return (Copy.Rows.couldntRead, nil, nil) }
            return (Copy.Rows.sizeNotMeasured, nil, nil)
        }
        var size = ByteFormat.string(bytes)
        if truncated { size = Copy.Rows.atLeast(size) }

        if !removable {
            return (size, nil, f.clonesPresent ? Copy.Rows.sharedNote : nil)
        }
        if let freeable = f.freeableBytes {
            if !f.clonesPresent { return (size, nil, nil) }
            return (Copy.Rows.uses(size), Copy.Rows.frees(ByteFormat.string(freeable)), nil)
        }
        return (Copy.Rows.uses(size), Copy.Rows.freesUnknown, nil)
    }

    private static func howRemoved(_ removal: Removal, better: BetterAction) -> String {
        switch removal {
        case .trash: return Copy.HowRemoved.trash
        case .tool(let executable, let arguments):
            return Copy.HowRemoved.tool(URL(fileURLWithPath: executable).lastPathComponent, arguments)
        case .deleteLocalSnapshots: return Copy.HowRemoved.snapshots
        case .handoff(let instructions, _): return instructions
        case .terminalCommand(let command):
            if case .privileged = better { return Copy.HowRemoved.helperRebuildsSpotlight }
            return Copy.HowRemoved.copyCommand(command)
        case .restart: return Copy.HowRemoved.restart
        case .none: return Copy.HowRemoved.nothing
        }
    }

    private static func label(_ t: Tier) -> String {
        switch t {
        case .safe: Copy.Verdicts.safe
        case .withCare: Copy.Verdicts.withCare
        case .leaveIt: Copy.Verdicts.leaveIt
        case .cantRemove: Copy.Verdicts.cantRemove
        }
    }

    private static func kind(_ t: Tier) -> VerdictKind {
        switch t {
        case .safe: .safe
        case .withCare: .withCare
        case .leaveIt: .leaveIt
        case .cantRemove: .cantRemove
        }
    }

    // MARK: Outside the home folder

    private static func outsideLines(_ bucket: AppleBucket, _ r: ScanResult) -> [OutsideLine] {
        let rows = r.reconciliation.outside.filter { $0.row.bucket == bucket }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.row.rawValue < $1.row.rawValue }
            .map { m in
                let size = ByteFormat.string(m.bytes)
                return OutsideLine(
                    id: "outside:\(m.row.rawValue)", title: Copy.Outside.title(m.row),
                    sizeText: m.isLowerBound ? Copy.Rows.atLeast(size) : size,
                    note: m.clonesPresent ? Copy.Rows.sharedNote : nil, revealURL: m.row.revealPath)
            }
        guard bucket == .otherUsers else { return rows }
        // Report-only and nothing to open: the helper's totals carry no names or paths.
        let accounts = r.reconciliation.otherAccounts.map { a in
            var size: String?
            var note: String?
            if let bytes = a.bytes {
                size = a.atLeast ? Copy.Rows.atLeast(ByteFormat.string(bytes)) : ByteFormat.string(bytes)
            } else if r.standardUser {
                note = Copy.Outside.adminOnly
            } else if r.helperOn {
                note = Copy.Rows.sizeNotMeasured
            } else {
                note = Copy.Outside.sizeNeedsHelper
            }
            return OutsideLine(
                id: "account:\(a.uid)", title: Copy.Outside.otherUser(a.name), sizeText: size, note: note, revealURL: nil,
                isAccount: true)
        }
        return rows + accounts
    }

    // MARK: Unlisted and Applications

    private static func unlistedRevealURL(_ bucket: AppleBucket, home: URL) -> URL {
        switch bucket {
        case .systemData: home.appendingPathComponent("Library")
        case .icloudDrive: home.appendingPathComponent("Library/Mobile Documents")
        default: home
        }
    }

    private static let appRowLimit = 50

    private static func applicationRows(_ r: ScanResult) -> [LargeItemRow] {
        var rows = r.appItems.prefix(appRowLimit).map {
            LargeItemRow(
                id: $0.url, name: $0.url.lastPathComponent, path: tilde($0.url, home: r.env.home),
                sizeText: ByteFormat.string($0.bytes), sharedNote: nil)
        }
        let rest = r.appItems.dropFirst(appRowLimit)
        if !rest.isEmpty {
            rows.append(LargeItemRow(
                id: URL(string: "diskplain:other-apps")!, name: Copy.Rows.otherApps,
                path: Copy.Rows.otherAppsDetail(rest.count),
                sizeText: ByteFormat.string(rest.reduce(0) { $0 + $1.bytes }), sharedNote: nil, revealable: false))
        }
        return rows
    }

    // MARK: Large items

    private static func largeRow(_ item: LargeItem, home: URL) -> LargeItemRow {
        LargeItemRow(
            id: item.url, name: item.url.lastPathComponent, path: tilde(item.url, home: home),
            sizeText: ByteFormat.string(item.bytes), sharedNote: item.clonesPresent ? Copy.Rows.sharedNote : nil)
    }

    /// `~` for home itself, `~/…` beneath it, compared by whole path components.
    private static func tilde(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.pathComponents
        let base = home.standardizedFileURL.pathComponents
        guard path.count >= base.count, Array(path.prefix(base.count)) == base else { return url.path }
        let rest = path.dropFirst(base.count)
        return rest.isEmpty ? "~" : "~/" + rest.joined(separator: "/")
    }
}
