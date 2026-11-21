import Foundation

public struct FoundItem: Equatable, Sendable {
    public let url: URL
    /// Allocated bytes: what the item uses.
    public let bytes: Int64
    /// What removing it frees at least; nil when unknown. Never replaced by `bytes`.
    public let privateBytes: Int64?
    /// Some of its space is shared with clones, so `privateBytes` is an estimate.
    public let clonesPresent: Bool
    public let modified: Date

    public init(url: URL, bytes: Int64, privateBytes: Int64?, clonesPresent: Bool, modified: Date) {
        self.url = url
        self.bytes = bytes
        self.privateBytes = privateBytes
        self.clonesPresent = clonesPresent
        self.modified = modified
    }

    /// No clones: everything allocated is private.
    public init(url: URL, bytes: Int64, modified: Date) {
        self.init(url: url, bytes: bytes, privateBytes: bytes, clonesPresent: false, modified: modified)
    }
}

public struct Finding: Identifiable, Equatable, Sendable {
    public var id: String { entry.id }
    public let entry: CatalogEntry
    public let items: [FoundItem]
    public let snapshots: [LocalSnapshot]
    /// Allocated bytes ("uses"). nil when sizing is `snapshots` or `none`, or when every matched
    /// root was unreadable.
    public let bytes: Int64?
    /// Private bytes ("frees at least"). nil whenever `bytes` is nil or any readable root's private
    /// size is unknown. Never falls back to `bytes` (spec §7.1 rev 2).
    public let freeableBytes: Int64?
    /// Some item shares space with clones; the UI labels `freeableBytes` "shared, estimate".
    public let clonesPresent: Bool
    public let unreadable: [URL]
    public let verdict: Verdict
    /// The privileged helper tried to measure this root and was blocked too: its size is unknown,
    /// not zero. False from the scanner; true only from `applyingRootMeasurement`'s blocked case.
    public let rootMeasureBlocked: Bool

    init(
        entry: CatalogEntry, items: [FoundItem], snapshots: [LocalSnapshot], bytes: Int64?,
        freeableBytes: Int64?, clonesPresent: Bool, unreadable: [URL], verdict: Verdict,
        rootMeasureBlocked: Bool = false
    ) {
        self.rootMeasureBlocked = rootMeasureBlocked
        self.entry = entry
        self.items = items
        self.snapshots = snapshots
        self.bytes = bytes
        self.freeableBytes = freeableBytes
        self.clonesPresent = clonesPresent
        self.unreadable = unreadable
        self.verdict = verdict
    }
}

/// A measurement of a protected root taken by the privileged helper.
public struct RootMeasurement: Equatable, Sendable {
    public let bytes: Int64
    public let privateBytes: Int64?
    public let clonesPresent: Bool
    public let unreadableCount: Int
    /// Directories the helper's walk refused to enter (R21); their contents are not in `bytes`.
    public let skippedCount: Int
    public let truncated: Bool

    public init(
        bytes: Int64, privateBytes: Int64?, clonesPresent: Bool, unreadableCount: Int, skippedCount: Int = 0,
        truncated: Bool
    ) {
        self.bytes = bytes
        self.privateBytes = privateBytes
        self.clonesPresent = clonesPresent
        self.unreadableCount = unreadableCount
        self.skippedCount = skippedCount
        self.truncated = truncated
    }

    /// `bytes` is a lower bound: the walk was cut short, hit unreadable entries or refused subtrees.
    public var isLowerBound: Bool { truncated || unreadableCount > 0 || skippedCount > 0 }
}

extension Finding {
    /// Fills in a root the scan couldn't read. If the helper found nothing readable either
    /// (`unreadableCount > 0` and zero bytes), the size stays unknown, never zero. Otherwise
    /// `freeableBytes` is the helper's private figure, never the allocated size (spec §7.1 rev 2).
    public func applyingRootMeasurement(_ m: RootMeasurement) -> Finding {
        if m.unreadableCount > 0 && m.bytes == 0 {
            return Finding(
                entry: entry, items: items, snapshots: snapshots, bytes: nil, freeableBytes: nil,
                clonesPresent: false, unreadable: unreadable, verdict: verdict, rootMeasureBlocked: true)
        }
        return Finding(
            entry: entry, items: items, snapshots: snapshots, bytes: m.bytes, freeableBytes: m.privateBytes,
            clonesPresent: m.clonesPresent, unreadable: [], verdict: verdict, rootMeasureBlocked: false)
    }
}

/// Matches the catalog against the disk, sizes what exists and attaches a version-gated verdict.
public struct CatalogScanner {
    private let env: ScanEnvironment
    private let snapshots: SnapshotLister
    private let toolExists: @Sendable (String) -> Bool
    private let promptingPathsReadable: Bool
    private let sizer: AllocatedSizer

    /// `promptingPathsReadable` is `fda == .granted`. When false, protected folders (Desktop, Documents, app containers, ...) are never entered:
    /// a match inside one is reported in `Finding.unreadable` and left unsized.
    public init(
        env: ScanEnvironment,
        snapshots: SnapshotLister,
        toolExists: @escaping @Sendable (String) -> Bool = {
            #if ANDROMEDA_TRACE
            ScanTrace.note("tool-exists", path: $0)
            #endif
            return FileManager.default.isExecutableFile(atPath: $0)
        },
        promptingPathsReadable: Bool = true,
        sizer: AllocatedSizer = AllocatedSizer()
    ) {
        self.env = env
        self.snapshots = snapshots
        self.toolExists = toolExists
        self.promptingPathsReadable = promptingPathsReadable
        self.sizer = sizer
    }

    /// `catalog` must already be sorted most-specific-first so specific entries claim paths first.
    /// A cancelled `control` stops before the next entry; the caller discards the partial result.
    public func scan(_ catalog: [CatalogEntry], control: ScanControl? = nil) -> [Finding] {
        // This stage's own view: the scan's other stages may be using the shared sizer right now.
        let sizer = self.sizer.reporting(to: control)
        var claimed: [[String]] = []
        var allSnapshots: [LocalSnapshot]?
        var findings: [Finding] = []
        struct Planned { let entry: CatalogEntry; let matches: [URL]; let unlistable: [URL]; let snapshots: [LocalSnapshot] }
        var planned: [Planned] = []

        for entry in catalog {
            if let control {
                if control.isCancelled { return [] }
                control.entry(entry.title)
            }
            let promptingPathsReadable = self.promptingPathsReadable
            let excluded = entry.exclude.flatMap {
                PathExpander.expandReportingSkipped($0, env: env, promptingPathsReadable: promptingPathsReadable).urls
            }.map(Self.components)
            var matches: [URL] = []
            var unlistable: [URL] = []
            for pattern in entry.paths {
                let expanded = PathExpander.expandReportingSkipped(
                    pattern, env: env, promptingPathsReadable: promptingPathsReadable)
                for url in expanded.skipped where !unlistable.contains(where: { Self.components($0) == Self.components(url) }) {
                    unlistable.append(url)
                }
                for found in expanded.urls {
                    let s = Self.split(found, around: claimed, excluded: excluded)
                    for url in s.items {
                        let parts = Self.components(url)
                        if matches.contains(where: { Self.components($0) == parts }) { continue }
                        matches.append(url)
                    }
                    for url in s.unreadable where !unlistable.contains(where: { Self.components($0) == Self.components(url) }) {
                        unlistable.append(url)
                    }
                }
            }
            // Unlistable folders are claimed too, so a later, broader entry doesn't report them again.
            claimed.append(contentsOf: (matches + unlistable).map(Self.components))

            var entrySnapshots: [LocalSnapshot] = []
            if entry.sizing == .snapshots {
                if allSnapshots == nil { allSnapshots = (try? snapshots.localSnapshots()) ?? [] }
                let wanted: LocalSnapshot.Kind = entry.removal == .deleteLocalSnapshots ? .timeMachine : .osUpdate
                entrySnapshots = (allSnapshots ?? []).filter { $0.kind == wanted }
            }
            if matches.isEmpty && unlistable.isEmpty && entrySnapshots.isEmpty { continue }
            planned.append(Planned(entry: entry, matches: matches, unlistable: unlistable, snapshots: entrySnapshots))
        }

        // Sizing every matched folder is independent work: it runs in parallel on the shared, thread-safe
        // sizer (inode dedup across entries still holds). Matching above stays in catalog order, because
        // earlier, more specific entries claim paths first.
        let jobs = planned.indices.flatMap { i in
            planned[i].entry.sizing == .allocatedWalk ? planned[i].matches.map { (i, $0) } : []
        }
        let sized = SizeSlots(count: jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { j in
            if control?.isCancelled == true { return }
            sized.set(j, autoreleasepool { sizer.size(of: jobs[j].1, order: j) })
        }
        if control?.isCancelled == true { return [] }
        var sizes: [String: SizeResult] = [:]
        for (j, job) in jobs.enumerated() {
            var r = sized.value(j)
            let back = sizer.handedBack(order: j)
            r.bytes -= back.allocated
            r.privateBytes = r.privateBytes.map { $0 - back.privateBytes }
            sizes["\(job.0)|" + job.1.path] = r
        }

        for (index, plan) in planned.enumerated() {
            let entry = plan.entry
            let matches = plan.matches
            let unlistable = plan.unlistable
            let entrySnapshots = plan.snapshots
            var items: [FoundItem] = []
            var total: Int64 = 0
            var privateTotal: Int64? = 0
            var clones = false
            var unreadable: [URL] = unlistable
            var readableRoots = 0
            for url in matches {
                var r = SizeResult(bytes: 0, unreadable: [])
                if entry.sizing == .allocatedWalk {
                    r = sizes["\(index)|" + url.path] ?? SizeResult(bytes: 0, unreadable: [])
                    total += r.bytes
                    unreadable.append(contentsOf: r.unreadable)
                    let whole = r.bytes == 0 && r.unreadable.contains { Self.components($0) == Self.components(url) }
                    if !whole {
                        readableRoots += 1
                        privateTotal = privateTotal.flatMap { sum in r.privateBytes.map { sum + $0 } }
                        if r.clonesPresent { clones = true }
                    }
                }
                #if ANDROMEDA_TRACE
                ScanTrace.note("attrs-mtime", url)
                #endif
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                items.append(FoundItem(
                    url: url, bytes: r.bytes, privateBytes: r.privateBytes, clonesPresent: r.clonesPresent,
                    modified: modified))
            }

            let bytes: Int64?
            switch entry.sizing {
            case .allocatedWalk: bytes = readableRoots > 0 || (matches.isEmpty && unlistable.isEmpty) ? total : nil
            case .snapshots, .none: bytes = nil
            }

            findings.append(Finding(
                entry: entry, items: items, snapshots: entrySnapshots, bytes: bytes,
                freeableBytes: bytes == nil ? nil : privateTotal, clonesPresent: clones,
                unreadable: unreadable,
                verdict: Verdict.make(entry: entry, osMajor: env.osMajor, toolExists: toolExists)))
        }

        return findings.sorted {
            let (a, b) = ($0.bytes ?? 0, $1.bytes ?? 0)
            return a != b ? a > b : $0.entry.id < $1.entry.id
        }
    }

    /// Returns `url` unless it is claimed or excluded (dropped), or contains a claimed path. In that
    /// case it is replaced by its children, recursively, so a generic entry never re-counts a
    /// specific one. Symlinked children and children on another device are skipped, never followed.
    /// Folders that can't be listed, and children that can't be stat'ed, come back as `unreadable`.
    private static func split(
        _ url: URL, around claimed: [[String]], excluded: [[String]]
    ) -> (items: [URL], unreadable: [URL]) {
        let parts = components(url)
        if excluded.contains(where: { isPrefix($0, of: parts) }) { return ([], []) }
        if claimed.contains(where: { isPrefix($0, of: parts) }) { return ([], []) }
        guard claimed.contains(where: { $0.count > parts.count && isPrefix(parts, of: $0) }) else { return ([url], []) }

        var parent = stat()
        #if ANDROMEDA_TRACE
        ScanTrace.note("lstat", url)
        #endif
        guard lstat(url.path, &parent) == 0 else { return ([], [url]) }
        #if ANDROMEDA_TRACE
        ScanTrace.note("list", url)
        #endif
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        else { return ([], [url]) }
        var items: [URL] = []
        var unreadable: [URL] = []
        for name in names.sorted() {
            let child = url.appendingPathComponent(name)
            var st = stat()
            #if ANDROMEDA_TRACE
            ScanTrace.note("lstat", child)
            #endif
            guard lstat(child.path, &st) == 0 else { unreadable.append(child); continue }
            if st.st_mode & S_IFMT == S_IFLNK || st.st_dev != parent.st_dev { continue }
            let r = split(child, around: claimed, excluded: excluded)
            items.append(contentsOf: r.items)
            unreadable.append(contentsOf: r.unreadable)
        }
        return (items, unreadable)
    }

    /// Lowercased, because APFS is case-insensitive by default: `~/Library/Caches/Foo` and a
    /// wildcard match `~/Library/Caches/foo` are the same folder and must be claimed once.
    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents.map { $0.lowercased() }
    }

    private static func isPrefix(_ prefix: [String], of path: [String]) -> Bool {
        prefix.count <= path.count && Array(path.prefix(prefix.count)) == prefix
    }
}

/// One slot per parallel sizing job; each job writes only its own index.
private final class SizeSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [SizeResult?]

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ i: Int, _ value: SizeResult) { lock.lock(); slots[i] = value; lock.unlock() }

    func value(_ i: Int) -> SizeResult { lock.lock(); defer { lock.unlock() }; return slots[i] ?? SizeResult(bytes: 0, unreadable: []) }
}
