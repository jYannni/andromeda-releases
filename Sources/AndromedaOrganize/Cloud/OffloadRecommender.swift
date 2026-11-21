import AndromedaCore
import Foundation

public enum AgeBucket: Equatable, Sendable { case overAYear, sixToTwelveMonths }

public enum RowStatus: Equatable, Sendable {
    case handOff  // offered: Show in Finder
    case keepsOwnCopy  // synced, freesAtLeast == 0: still offered for hand-off, ranks at 0
    case stillSyncing, conflict  // shown, not selectable
}

public struct OffloadRow: Identifiable, Equatable, Sendable {
    public let id: URL
    public let state: CloudItemState
    public let lastUse: LastUse
    public let bucket: AgeBucket
    public let status: RowStatus
    /// Always false while pin == .unknown (decision 6a / rev 4 item 6).
    public let preTicked: Bool
    /// Parent folder shared with at least one other row (ruling O6); nil otherwise.
    public let groupParent: URL?

    public init(
        id: URL, state: CloudItemState, lastUse: LastUse, bucket: AgeBucket, status: RowStatus,
        preTicked: Bool, groupParent: URL?
    ) {
        self.id = id
        self.state = state
        self.lastUse = lastUse
        self.bucket = bucket
        self.status = status
        self.preTicked = preTicked
        self.groupParent = groupParent
    }
}

/// Suggests large, stale, uploaded cloud items to make online-only. Hand-off only (decision 19a):
/// Andromeda never evicts. Returns values, no strings; copy lives in `Copy.Organize`.
public struct OffloadRecommender {
    public typealias Scanner = (CloudRoot, Int64) -> [LargeItem]

    private let scanner: Scanner
    private let inspector: CloudItemInspector
    private let lastUsed: LastUsedReader
    private let settings: OrganizeSettings
    private let now: Date
    private let env: ScanEnvironment

    public init(
        scanner: @escaping Scanner, inspector: CloudItemInspector, lastUsed: LastUsedReader,
        settings: OrganizeSettings, now: Date, env: ScanEnvironment
    ) {
        self.scanner = scanner
        self.inspector = inspector
        self.lastUsed = lastUsed
        self.settings = settings
        self.now = now
        self.env = env
    }

    public func rows(for root: CloudRoot) -> [OffloadRow] {
        var built: [OffloadRow] = []
        for item in scanner(root, settings.offloadMinBytes) {
            let url = item.url
            if isAppContainer(url) || SafetyGuard.isPackage(url) { continue }
            let state = inspector.inspect(url, provider: root.provider)
            if state.sync == .notDownloaded || state.sync == .missing || state.usesBytes < settings.offloadMinBytes { continue }
            guard let use = lastUsed.lastUse(of: url) else { continue }
            let age = now.timeIntervalSince(use.date)
            if age < settings.offloadMinAge { continue }
            let status: RowStatus
            switch state.sync {
            case .conflict: status = .conflict
            case .stillSyncing: status = .stillSyncing
            case .synced: status = state.freesAtLeast == 0 ? .keepsOwnCopy : .handOff
            case .notDownloaded, .missing: continue
            }
            let bucket: AgeBucket = age > 365 * OrganizeSettings.day ? .overAYear : .sixToTwelveMonths
            built.append(OffloadRow(
                id: url, state: state, lastUse: use, bucket: bucket, status: status,
                preTicked: false, groupParent: nil))
        }
        built.sort(by: Self.precedes)

        var perParent: [URL: Int] = [:]
        for row in built { perParent[row.id.deletingLastPathComponent(), default: 0] += 1 }
        return built.map { row in
            let parent = row.id.deletingLastPathComponent()
            guard perParent[parent, default: 0] >= 2 else { return row }
            return OffloadRow(
                id: row.id, state: row.state, lastUse: row.lastUse, bucket: row.bucket,
                status: row.status, preTicked: row.preTicked, groupParent: parent)
        }
    }

    private static func isOffered(_ s: RowStatus) -> Bool { s == .handOff || s == .keepsOwnCopy }

    private static func precedes(_ a: OffloadRow, _ b: OffloadRow) -> Bool {
        let (ao, bo) = (isOffered(a.status), isOffered(b.status))
        if ao != bo { return ao }
        if a.bucket != b.bucket { return a.bucket == .overAYear }
        // nil and 0 rank last within a bucket.
        let (af, bf) = (a.state.freesAtLeast ?? 0, b.state.freesAtLeast ?? 0)
        if af != bf { return af > bf }
        if a.state.usesBytes != b.state.usesBytes { return a.state.usesBytes > b.state.usesBytes }
        return a.id.path < b.id.path
    }

    /// Anything under `Mobile Documents/<x>/` where `<x>` is not `com~apple~CloudDocs`.
    private func isAppContainer(_ url: URL) -> Bool {
        let base = env.home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
            .standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        guard path.count > base.count, Array(path.prefix(base.count)) == base else { return false }
        return path[base.count] != "com~apple~CloudDocs"
    }
}
