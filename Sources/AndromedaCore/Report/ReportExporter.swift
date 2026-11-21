import Foundation

public struct ReconciliationDTO: Codable, Equatable, Sendable {
    /// false when the volume provider failed; `used`, `unaccounted` and `overcount` are then null.
    public let usedKnown: Bool
    /// Rev G6: container used minus purgeable, as Storage settings shows it.
    public let used: Int64?
    /// Container capacity minus free (rev G6); null when `usedKnown` is false. Optional so older reports decode.
    public let containerUsed: Int64?
    public let measured: Int64
    /// Measured bytes per bucket, keyed by `AppleBucket` raw value; empty buckets are absent.
    public let byBucket: [String: Int64]
    /// null when not measurable.
    public let purgeable: Int64?
    public let unaccounted: Int64?
    /// Rev H: the figure in the `protectedAreas` line; null when `usedKnown` is false or in older reports.
    public let protectedRemainder: Int64?
    /// Rulings R9, R25: which `protectedAreas` copy applies; null in older reports (read as false, the neutral line).
    public let remainderIsProtected: Bool?
    public let overcount: Int64?
    /// Private bytes over actionable findings; null when unknown. Shown only when `hasActionable`.
    public let freesAtLeast: Int64?
    public let hasActionable: Bool
    /// Measured counts space shared between clones more than once.
    public let clonesPresent: Bool
    public let unreadableCount: Int
    public let reasons: [String]
}

public struct ItemDTO: Codable, Equatable, Sendable {
    public let path: String
    /// null when the finding itself has no measured size, or when this item couldn't be read.
    public let bytes: Int64?
    /// What removing it frees at least; null whenever `bytes` is null or the private size is unknown.
    public let freeableBytes: Int64?
    public let clonesPresent: Bool
    /// true when this root is in the finding's unreadable list; its size is then unknown.
    public let unreadable: Bool
}

public struct FindingDTO: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let tier: String
    public let bucket: String
    /// Allocated ("uses"). null renders as "not measurable".
    public let bytes: Int64?
    /// Private ("frees at least"). null when unknown; never the allocated figure.
    public let freeableBytes: Int64?
    /// The freeable figure is a shared estimate.
    public let clonesPresent: Bool
    public let unverifiedOnMacOS: Int?
    /// The catalog sizing rule (`allocated-walk`, `snapshots`, `none`).
    public let sizing: String
    public let snapshotCount: Int
    public let snapshotNames: [String]
    /// Largest first.
    public let items: [ItemDTO]
}

public struct LargeItemDTO: Codable, Equatable, Sendable {
    public let path: String
    public let bytes: Int64
    public let bucket: String
    public let clonesPresent: Bool
}

public struct ApplicationDTO: Codable, Equatable, Sendable {
    public let path: String
    public let bytes: Int64
}

/// Rev H: one folder outside the home folder. Report-only, so no freed figure.
public struct OutsideRowDTO: Codable, Equatable, Sendable {
    /// `OutsideRow` raw value.
    public let row: String
    public let bytes: Int64
    public let clonesPresent: Bool
    public let unreadableCount: Int
    /// Directories the helper's walk refused to enter (R21); 0 for a non-root figure.
    public let skippedCount: Int
    public let truncated: Bool
    public let bucket: String
}

/// Rev H: another account, by name only; never its UID or a path into its folder.
public struct OtherAccountDTO: Codable, Equatable, Sendable {
    public let name: String
    /// null when not measured.
    public let bytes: Int64?
    public let atLeast: Bool

    private enum CodingKeys: String, CodingKey { case name, bytes, atLeast }

    /// Writes `bytes` as an explicit null, so "not measured" reads as such rather than as a missing key.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(bytes, forKey: .bytes)
        try c.encode(atLeast, forKey: .atLeast)
    }
}

public struct ScanReport: Codable, Equatable, Sendable {
    public let osMajor: Int
    public let fda: String
    public let reconciliation: ReconciliationDTO
    public let findings: [FindingDTO]
    public let largeItems: [LargeItemDTO]
    /// Top-level entries of the Applications folders, largest first.
    public let applications: [ApplicationDTO]
    /// Rev H; empty in older reports.
    public let outside: [OutsideRowDTO]
    public let otherAccounts: [OtherAccountDTO]
    /// The helper was on for the scan, so the text rendering picks the same reason copy as the app.
    /// null in older reports (read as false).
    public let helperOn: Bool?
    /// The scan ran as a standard user, so the helper wouldn't size other accounts. null in older reports.
    public let standardUser: Bool?

    public init(
        osMajor: Int, fda: String, reconciliation: ReconciliationDTO, findings: [FindingDTO],
        largeItems: [LargeItemDTO], applications: [ApplicationDTO],
        outside: [OutsideRowDTO] = [], otherAccounts: [OtherAccountDTO] = [],
        helperOn: Bool? = nil, standardUser: Bool? = nil
    ) {
        self.osMajor = osMajor
        self.fda = fda
        self.reconciliation = reconciliation
        self.findings = findings
        self.largeItems = largeItems
        self.applications = applications
        self.outside = outside
        self.otherAccounts = otherAccounts
        self.helperOn = helperOn
        self.standardUser = standardUser
    }

    private enum CodingKeys: String, CodingKey {
        case osMajor, fda, reconciliation, findings, largeItems, applications, outside, otherAccounts
        case helperOn, standardUser
    }

    /// Reports from before rev H have no `outside`, `otherAccounts`, `helperOn` or `standardUser` keys and still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            osMajor: try c.decode(Int.self, forKey: .osMajor),
            fda: try c.decode(String.self, forKey: .fda),
            reconciliation: try c.decode(ReconciliationDTO.self, forKey: .reconciliation),
            findings: try c.decode([FindingDTO].self, forKey: .findings),
            largeItems: try c.decode([LargeItemDTO].self, forKey: .largeItems),
            applications: try c.decode([ApplicationDTO].self, forKey: .applications),
            outside: try c.decodeIfPresent([OutsideRowDTO].self, forKey: .outside) ?? [],
            otherAccounts: try c.decodeIfPresent([OtherAccountDTO].self, forKey: .otherAccounts) ?? [],
            helperOn: try c.decodeIfPresent(Bool.self, forKey: .helperOn),
            standardUser: try c.decodeIfPresent(Bool.self, forKey: .standardUser))
    }
}

/// What the reason copy depends on beyond the reason itself.
public struct ReasonContext: Sendable, Equatable {
    /// The `protectedAreas` figure (`Reconciliation.protectedRemainder`).
    public var remainder: Int64
    /// `Reconciliation.remainderIsProtected`: false when other reasons may explain part of the remainder.
    public var remainderIsProtected: Bool
    /// The helper is on, so it already measured what it can.
    public var helperOn: Bool
    /// The caller isn't an administrator, so the helper won't size other accounts.
    public var standardUser: Bool

    public init(
        remainder: Int64 = 0, remainderIsProtected: Bool = false, helperOn: Bool = false, standardUser: Bool = false
    ) {
        self.remainder = remainder
        self.remainderIsProtected = remainderIsProtected
        self.helperOn = helperOn
        self.standardUser = standardUser
    }
}

/// Plain, read-only rendering of a scan. Paths under home are shown as `~/…` in both formats.
public enum ReportExporter {
    static let maxItemsPerFinding = 3
    static let maxLargeItems = 20

    public static func make(
        env: ScanEnvironment, usage: VolumeUsage, findings: [Finding], largeItems: [LargeItem],
        reconciliation: Reconciliation, fda: FDAStatus, usedKnown: Bool = true,
        applications: [AppItem] = [], helperOn: Bool = false, standardUser: Bool = false
    ) -> ScanReport {
        let purgeable: Int64?
        if case .bytes(let b) = reconciliation.purgeable { purgeable = b } else { purgeable = nil }
        let rec = ReconciliationDTO(
            usedKnown: usedKnown,
            used: usedKnown ? reconciliation.used : nil,
            containerUsed: usedKnown ? reconciliation.containerUsed : nil,
            measured: reconciliation.measured,
            byBucket: Dictionary(uniqueKeysWithValues: reconciliation.byBucket.map { ($0.key.rawValue, $0.value) }),
            purgeable: purgeable,
            unaccounted: usedKnown ? reconciliation.unaccounted : nil,
            protectedRemainder: usedKnown ? reconciliation.protectedRemainder : nil,
            remainderIsProtected: reconciliation.remainderIsProtected,
            overcount: usedKnown ? reconciliation.overcount : nil,
            freesAtLeast: reconciliation.freesAtLeast,
            hasActionable: reconciliation.hasActionable,
            clonesPresent: reconciliation.clonesPresent,
            unreadableCount: reconciliation.unreadable.count,
            reasons: reconciliation.reasons.map(\.rawValue))
        let findingDTOs = findings.map { f in
            var unverified: Int?
            if case .unverified(let os)? = f.verdict.reason { unverified = os }
            let unreadable = Set(f.unreadable.map(pathKey))
            var items = f.items
                .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.url.path < $1.url.path }
                .map { item in
                    let locked = unreadable.contains(pathKey(item.url))
                    let unknown = f.bytes == nil || locked
                    return ItemDTO(
                        path: tilde(item.url, home: env.home),
                        bytes: unknown ? nil : item.bytes,
                        freeableBytes: unknown ? nil : item.privateBytes,
                        clonesPresent: item.clonesPresent,
                        unreadable: locked)
                }
            if f.rootMeasureBlocked && items.isEmpty {
                // The helper couldn't measure the root either: say so, instead of listing nothing.
                let paths = f.unreadable.isEmpty ? f.entry.paths : f.unreadable.map { tilde($0, home: env.home) }
                items = paths.map {
                    ItemDTO(path: $0, bytes: nil, freeableBytes: nil, clonesPresent: false, unreadable: true)
                }
            }
            return FindingDTO(
                id: f.entry.id, title: f.entry.title,
                tier: tierRaw(f.entry.tier), bucket: f.entry.bucket.rawValue,
                bytes: f.bytes, freeableBytes: f.freeableBytes, clonesPresent: f.clonesPresent,
                unverifiedOnMacOS: unverified, sizing: f.entry.sizing.rawValue,
                snapshotCount: f.snapshots.count, snapshotNames: f.snapshots.map(\.name),
                items: items)
        }
        let large = largeItems.map {
            LargeItemDTO(
                path: tilde($0.url, home: env.home), bytes: $0.bytes, bucket: $0.probableBucket.rawValue,
                clonesPresent: $0.clonesPresent)
        }
        let apps = applications.map { ApplicationDTO(path: tilde($0.url, home: env.home), bytes: $0.bytes) }
        let outside = reconciliation.outside.map {
            OutsideRowDTO(
                row: $0.row.rawValue, bytes: $0.bytes, clonesPresent: $0.clonesPresent,
                unreadableCount: $0.unreadableCount, skippedCount: $0.skippedCount, truncated: $0.truncated,
                bucket: $0.row.bucket.rawValue)
        }
        let accounts = reconciliation.otherAccounts.map {
            OtherAccountDTO(name: $0.name, bytes: $0.bytes, atLeast: $0.atLeast)
        }
        return ScanReport(
            osMajor: env.osMajor, fda: fdaString(fda), reconciliation: rec,
            findings: findingDTOs, largeItems: large, applications: apps,
            outside: outside, otherAccounts: accounts, helperOn: helperOn, standardUser: standardUser)
    }

    /// The report's `helperOn` and `standardUser` pick the reason copy, so text from JSON reads like the app.
    public static func text(_ r: ScanReport) -> String {
        var out: [String] = []
        out.append("Andromeda report — macOS \(r.osMajor) — Full Disk Access: \(r.fda)")
        out.append("")

        let rec = r.reconciliation
        out.append("Used: \(rec.used.map(ByteFormat.string) ?? "unknown")")
        out.append("Measured (sum of category allocations): \(ByteFormat.string(rec.measured))")
        if let p = rec.purgeable {
            out.append("Purgeable (estimate, not in used): \(ByteFormat.string(p))")
        } else {
            out.append("Purgeable: not measurable")
        }
        out.append("Not accounted for: \(rec.unaccounted.map(ByteFormat.string) ?? "unknown")")
        if let o = rec.overcount, o > 0 {
            out.append("Overcount: \(ByteFormat.string(o)) (category allocations exceed used space, which excludes estimated purgeable space)")
        }
        if rec.hasActionable {
            out.append("Frees at least: \(rec.freesAtLeast.map(ByteFormat.string) ?? "not measurable") (space comes back once the Trash is emptied)")
        }
        if rec.clonesPresent {
            out.append(rec.usedKnown
                ? "Some items share APFS storage. Measured can include the same disk space more than once, and Not accounted for may be low."
                : "Some items share APFS storage. Measured can include the same disk space more than once.")
        }
        // Snapshot and unsized entries are never walked, so they don't make Measured low.
        if r.findings.contains(where: { $0.bytes == nil && $0.sizing == Sizing.allocatedWalk.rawValue }) {
            out.append(rec.usedKnown
                ? "Some items couldn't be sized, so Measured may be low and Not accounted for may be high."
                : "Some items couldn't be sized, so Measured may be low.")
        }
        let reasons = rec.reasons.compactMap(UnaccountedReason.init(rawValue:))
        if rec.usedKnown && !reasons.isEmpty {
            let context = ReasonContext(
                remainder: rec.protectedRemainder ?? rec.unaccounted ?? 0,
                remainderIsProtected: rec.remainderIsProtected ?? false, helperOn: r.helperOn ?? false,
                standardUser: r.standardUser ?? false)
            out.append("")
            out.append("Why some space isn't accounted for:")
            for reason in reasons {
                out.append("  - \(explanation(for: reason, context: context))")
            }
        }
        out.append("")

        let sized = r.findings.filter { $0.bytes != nil }
        let unsized = r.findings.filter { $0.bytes == nil }
        for f in sized { appendFinding(f, to: &out) }
        if !unsized.isEmpty {
            if !sized.isEmpty { out.append("") }
            out.append("Couldn't be sized:")
            for f in unsized { appendFinding(f, to: &out) }
        }

        if !r.largeItems.isEmpty {
            out.append("")
            out.append("Large items not in the catalog")
            for item in r.largeItems.prefix(maxLargeItems) {
                let shared = item.clonesPresent ? "  (shared with copies, frees less)" : ""
                out.append("\(ByteFormat.string(item.bytes))  \(item.path)  probably \(bucketLabel(item.bucket))\(shared)")
            }
            if r.largeItems.count > maxLargeItems {
                out.append("…and \(r.largeItems.count - maxLargeItems) more")
            }
        }

        if !r.outside.isEmpty || !r.otherAccounts.isEmpty {
            out.append("")
            out.append("Outside your home folder")
            for row in r.outside {
                let atLeast = row.truncated || row.unreadableCount > 0 || row.skippedCount > 0 ? "at least " : ""
                let shared = row.clonesPresent ? "  (shared with copies)" : ""
                out.append("\(atLeast)\(ByteFormat.string(row.bytes))  \(outsideLabel(row.row))\(shared)")
            }
            for account in r.otherAccounts {
                let size = account.bytes.map { (account.atLeast ? "at least " : "") + ByteFormat.string($0) } ?? "not measured"
                out.append("Other user: \(account.name) — \(size)")
            }
        }

        if rec.unreadableCount > 0 {
            out.append("")
            let n = rec.unreadableCount
            let folders = n == 1 ? "1 folder" : "\(n) folders"
            if r.fda == "granted" {
                out.append(n == 1
                    ? "Couldn't read \(folders) even with Full Disk Access; macOS protects it. It's left out of the totals."
                    : "Couldn't read \(folders) even with Full Disk Access; macOS protects them. They're left out of the totals.")
            } else {
                out.append("Couldn't read \(folders). Turn on Full Disk Access for this tool in System Settings › Privacy & Security, and the next scan will include \(n == 1 ? "it" : "them").")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// An allowlist for reports intended to be shared. Detailed rows can contain personal names and paths.
    public static func redactedJSON(_ r: ScanReport) throws -> Data {
        struct SupportReport: Encodable {
            let osMajor: Int
            let fda: String
            let helperOn: Bool?
            let standardUser: Bool?
            let reconciliation: ReconciliationDTO
            let outside: [OutsideRowDTO]
        }
        return try encodeJSON(SupportReport(
            osMajor: r.osMajor, fda: r.fda, helperOn: r.helperOn, standardUser: r.standardUser,
            reconciliation: r.reconciliation, outside: r.outside))
    }

    public static func json(_ r: ScanReport) throws -> Data { try encodeJSON(r) }

    private static func encodeJSON(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// The default context: helper off, an administrator, no figure.
    /// `largeItemsShown` is kept for callers; rev G copy no longer differs by it.
    public static func explanation(for reason: UnaccountedReason, largeItemsShown: Bool = false) -> String {
        explanation(for: reason, context: ReasonContext())
    }

    /// Calm, plain-language copy for each reason; the single place the UI reuses.
    public static func explanation(for reason: UnaccountedReason, context: ReasonContext) -> String {
        switch reason {
        case .protectedAreas:
            // Rev H: one sized line for the remainder; the locked-folder list stays in the export.
            // R9, R25: when anything else may explain part of it, don't call it protected. Protected
            // requires the helper on, so only the neutral line can suggest turning it on.
            context.remainderIsProtected
                ? "About \(ByteFormat.string(context.remainder)) is in places macOS protects even from administrators, such as other accounts' mail and the Spotlight index. Andromeda can't measure them, so they stay as they are."
                : "About \(ByteFormat.string(context.remainder)) isn't measured yet. The other notes here say why."
                    + (context.helperOn ? "" : " Turning on the helper measures most of the rest.")
        case .otherUsers:
            context.standardUser
                ? "Another user account on this Mac has its own files. Only an administrator account can see their size."
                : "Another user account on this Mac has its own files. Turning on the helper shows the size of each account's folder."
        case .accountsUnknown:
            "Andromeda couldn't list the other accounts on this Mac, so their folders may be in the space that isn't measured."
        case .noFullDiskAccess:
            "Without Full Disk Access, some folders can't be read, so their size is missing. Granting Full Disk Access lets the next scan include them."
        case .otherVolumes:
            "Part of the space is in other volumes on this disk that Andromeda can't break down."
        case .purgeableNotMeasurable:
            "macOS can free some space on its own, and this version doesn't report how much. macOS usually frees it when space is needed."
        }
    }

    private static func appendFinding(_ f: FindingDTO, to out: inout [String]) {
        let size = f.bytes.map(ByteFormat.string) ?? "not measurable"
        var line = "\(size)  \(f.title)  [\(tierLabel(f.tier))]  probably \(bucketLabel(f.bucket))"
        if let os = f.unverifiedOnMacOS { line += " (not yet verified on macOS \(os))" }
        out.append(line)
        // A freed figure only where removal is offered; elsewhere it would read as an invitation.
        let removable = f.tier == Tier.safe.rawValue || f.tier == Tier.withCare.rawValue
        if f.bytes != nil {
            if !removable {
                if f.clonesPresent {
                    out.append("    shares storage with copies, so its size counts that space more than once")
                }
            } else if let freeable = f.freeableBytes {
                if f.clonesPresent {
                    out.append("    frees at least \(ByteFormat.string(freeable)) (shared, estimate): some of these files share storage with copies elsewhere, so removing them frees less than their size")
                }
            } else {
                out.append("    space freed: not measurable")
            }
        }
        if f.snapshotCount > 0 {
            out.append("    \(f.snapshotCount) \(f.snapshotCount == 1 ? "snapshot" : "snapshots")")
            for name in f.snapshotNames.prefix(maxItemsPerFinding) { out.append("      \(name)") }
            if f.snapshotNames.count > maxItemsPerFinding {
                out.append("      …and \(f.snapshotNames.count - maxItemsPerFinding) more")
            }
        }
        for item in f.items.prefix(maxItemsPerFinding) {
            if item.unreadable {
                out.append("    \(item.path)  (couldn't read)")
            } else if let b = item.bytes {
                out.append("    \(item.path)  (\(ByteFormat.string(b))\(item.clonesPresent ? ", shared" : ""))")
            } else {
                out.append("    \(item.path)")
            }
        }
        if f.items.count > maxItemsPerFinding {
            out.append("    …and \(f.items.count - maxItemsPerFinding) more")
        }
    }

    /// Row names as spec rev H §2.1 lists them.
    private static func outsideLabel(_ raw: String) -> String { OutsideRow(rawValue: raw)?.title ?? raw }

    private static func pathKey(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }

    /// `~` for home itself, `~/…` beneath it. Compares whole components, so `/Users/yankoX` is untouched.
    static func tilde(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.pathComponents
        let base = home.standardizedFileURL.pathComponents
        guard path.count >= base.count, Array(path.prefix(base.count)) == base else { return url.path }
        let rest = path.dropFirst(base.count)
        return rest.isEmpty ? "~" : "~/" + rest.joined(separator: "/")
    }

    private static func fdaString(_ s: FDAStatus) -> String {
        switch s {
        case .granted: "granted"
        case .denied: "denied"
        case .unknown: "unknown"
        }
    }

    private static func tierRaw(_ t: Tier) -> String { t.rawValue }

    private static func tierLabel(_ raw: String) -> String {
        switch Tier(rawValue: raw) {
        case .safe: "safe"
        case .withCare: "with care"
        case .leaveIt: "leave it"
        case .cantRemove: "can't remove"
        case nil: raw
        }
    }

    private static func bucketLabel(_ raw: String) -> String {
        switch AppleBucket(rawValue: raw) {
        case .systemData: "System Data"
        case .documents: "Documents"
        case .developer: "Developer"
        case .iosFiles: "iOS Files"
        case .mail: "Mail"
        case .messages: "Messages"
        case .photos: "Photos"
        case .icloudDrive: "iCloud Drive"
        case .macOS: "macOS"
        case .otherUsers: "Other Users"
        case .applications: "Applications"
        case nil: raw
        }
    }
}
