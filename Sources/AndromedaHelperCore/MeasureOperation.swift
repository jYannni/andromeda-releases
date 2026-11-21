import Foundation
import AndromedaHelperProtocol

/// `measure(entryID:)`: validate the raw ID, look it up in the fixed table, size only the
/// table's roots, and sum the results.
public struct MeasureOperation: Sendable {
    /// Sizes one root within the budget left for it.
    typealias SizeFn = @Sendable (_ root: MeasureRoot, _ budget: Budget) -> RootSize

    private let table: MeasureTable
    private let sizeFn: SizeFn
    private let now: @Sendable () -> Double

    public init(table: MeasureTable = .production) {
        self.init(table: table, sizeFn: { root, budget in
            RootSizer(budget: budget).size(ofPath: root.path, excluding: root.excluding, policy: root.policy)
        })
    }

    /// Test seam: inject the sizer and the clock (seconds).
    init(
        table: MeasureTable, sizeFn: @escaping SizeFn,
        now: @escaping @Sendable () -> Double = { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
    ) {
        self.table = table
        self.sizeFn = sizeFn
        self.now = now
    }

    /// `callerUID` is the XPC peer's UID. No current entry depends on it (R13 excludes all of
    /// `/private/var/folders`); it is plumbed through for per-caller operations (Task 5).
    public func run(entryIDRaw: String, callerUID: uid_t) -> Result<MeasureReply, HelperErrorCode> {
        // Validate first: a malformed ID never reaches the table or the filesystem.
        guard let id = EntryID(validating: entryIDRaw) else { return .failure(.invalidRequest) }
        guard let roots = table.roots(for: id) else { return .failure(.notFound) }

        // Each root's time budget counts from the start of the request, not from its own start, so
        // an entry never runs longer than its largest root budget (R9), however many roots it has.
        let start = now()
        var bytes: Int64 = 0
        var privateBytes: Int64? = 0
        var clones = false
        var unreadable = 0
        var skipped = 0
        var truncated = false
        for root in roots {
            let left = max(0, root.budget.maxSeconds - (now() - start))
            let budget = Budget(maxEntries: root.budget.maxEntries, maxSeconds: left)
            let s = sizeFn(root, budget)
            bytes += s.bytes
            privateBytes = privateBytes.flatMap { sum in s.privateBytes.map { sum + $0 } }
            clones = clones || s.clonesPresent
            unreadable += s.unreadable
            skipped += s.skipped
            truncated = truncated || s.truncated
        }
        return .success(MeasureReply(
            entryID: id.rawValue, bytes: bytes, privateBytes: privateBytes, clonesPresent: clones,
            unreadableCount: unreadable, skippedCount: skipped, truncated: truncated, measuredPaths: roots.map(\.path)))
    }
}
