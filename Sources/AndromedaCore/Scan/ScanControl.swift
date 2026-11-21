import Foundation
import Synchronization

/// What a running scan stage has done so far. Counts are per stage.
public struct ScanProgress: Equatable, Sendable {
    public var itemsChecked: Int
    public var bytesMeasured: Int64
    /// The folder being read right now, when the stage walks folders.
    public var currentPath: URL?
    /// The catalog entry being looked at, during the catalog stage.
    public var currentEntry: String?
    /// Largest items found so far during a drive scan. Final ranking is available after the scan.
    public var driveLargeItems: [LargeItem] = []
    /// Top-level folders available to browse while the drive scan runs.
    public var driveFolders: [URL] = []
    /// Allocated sizes for browsable folders whose measurements are complete, by path.
    public var driveFolderSizes: [String: Int64] = [:]

    public init(itemsChecked: Int = 0, bytesMeasured: Int64 = 0, currentPath: URL? = nil, currentEntry: String? = nil) {
        self.itemsChecked = itemsChecked
        self.bytesMeasured = bytesMeasured
        self.currentPath = currentPath
        self.currentEntry = currentEntry
    }
}

/// Shared between a scan stage (on its own thread) and the app: the stage reports progress and checks
/// `isCancelled`; the app reads reports and calls `cancel()`. Reports are throttled to one per `interval`,
/// so the hot file loop costs a lock and a clock read, never a UI update.
public final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = ScanProgress()
    private var lastSent: UInt64?
    private var cancelled = false
    private var driveFolderPath: String?
    private let hasDriveFolderPriority = Atomic<Bool>(false)
    private let intervalNanos: UInt64
    private let now: @Sendable () -> UInt64
    private let onProgress: @Sendable (ScanProgress) -> Void

    /// `now` is a monotonic clock in nanoseconds (test seam).
    public init(
        interval: TimeInterval = 0.25,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) {
        self.intervalNanos = UInt64(max(0, interval) * 1_000_000_000)
        self.now = now
        self.onProgress = onProgress
    }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    public func prioritizeDriveFolder(_ url: URL, on root: URL) {
        let rootPath = root.path
        let canonicalPath = root.standardizedFileURL.path
        let prefix = canonicalPath.hasSuffix("/") ? canonicalPath : canonicalPath + "/"
        let folder = url.standardizedFileURL.path
        guard folder.hasPrefix(prefix), folder.count > prefix.count else { return }
        // Rebase the browser's validated path onto the spelling used by the walk.
        let walkPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = walkPrefix + folder.dropFirst(prefix.count)
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        driveFolderPath = path
        hasDriveFolderPriority.store(true, ordering: .relaxed)
    }

    func preferredDriveChild(in directory: String) -> String? {
        guard hasDriveFolderPriority.load(ordering: .relaxed) else { return nil }
        lock.lock()
        let target = cancelled ? nil : driveFolderPath
        lock.unlock()
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        guard let target, target.hasPrefix(prefix),
              let name = target.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first else { return nil }
        return String(name)
    }

    /// The latest counts, whether or not they were reported yet.
    public var snapshot: ScanProgress { lock.lock(); defer { lock.unlock() }; return progress }

    /// One regular file was sized.
    public func file(bytes: Int64) { files(count: 1, bytes: bytes) }

    var reportsEveryUpdate: Bool { intervalNanos == 0 }

    func files(count: Int, bytes: Int64) {
        update {
            $0.itemsChecked += count
            $0.bytesMeasured += bytes
        }
    }

    /// A folder is being read.
    public func entering(_ url: URL) { update { $0.currentPath = url } }

    /// The catalog stage moved on to another entry.
    public func entry(_ title: String) { update { $0.currentEntry = title; $0.currentPath = nil } }

    /// True when this call has delivered the first large-item preview.
    @discardableResult
    func foundDriveLargeItem(_ item: LargeItem) -> Bool {
        update(reportFirstDriveItem: true) {
            let limit = 5
            let items = $0.driveLargeItems
            let index = items.firstIndex { other in
                item.bytes == other.bytes ? item.url.path < other.url.path : item.bytes > other.bytes
            } ?? items.endIndex
            guard index < limit else { return }
            $0.driveLargeItems.insert(item, at: index)
            if $0.driveLargeItems.count > limit { $0.driveLargeItems.removeLast() }
        }
    }

    func foundDriveFolders(_ folders: [URL]) {
        guard !folders.isEmpty else { return }
        update(immediately: true) { $0.driveFolders = folders }
    }

    func measuredDriveFolder(_ folder: URL, bytes: Int64) {
        let path = folder.path
        lock.lock()
        guard !cancelled, progress.driveFolderSizes[path] == nil,
              progress.driveFolders.contains(where: { $0.path == path }) else {
            lock.unlock()
            return
        }
        // The browse list is bounded, so each completed row can be published as it becomes available.
        progress.driveFolderSizes[path] = bytes
        lastSent = now()
        let snapshot = progress
        lock.unlock()
        onProgress(snapshot)
    }

    /// Reports the current counts now, ignoring the throttle.
    public func flush() {
        lock.lock()
        lastSent = now()
        let p = progress
        lock.unlock()
        onProgress(p)
    }

    @discardableResult
    private func update(
        reportFirstDriveItem: Bool = false, immediately: Bool = false, _ change: (inout ScanProgress) -> Void
    ) -> Bool {
        lock.lock()
        let waitingForFirstDriveItem = reportFirstDriveItem && progress.driveLargeItems.isEmpty
        change(&progress)
        let t = now()
        let firstDriveItem = waitingForFirstDriveItem && !progress.driveLargeItems.isEmpty
        guard !cancelled, immediately || firstDriveItem || (lastSent.map({ t &- $0 >= intervalNanos }) ?? true) else {
            lock.unlock()
            return false
        }
        lastSent = t
        let p = progress
        lock.unlock()
        onProgress(p)  // outside the lock: the callback may call cancel()
        return firstDriveItem
    }
}
