import AndromedaCore
import Foundation
import Observation

public struct StorageReading: Codable, Identifiable, Equatable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let free: Int64
    let capacity: Int64
    let volume: String?
}

public struct WatchedStorageFolder: Codable, Equatable, Identifiable, Sendable {
    public struct Reading: Codable, Equatable, Identifiable, Sendable {
        public var id: Date { date }
        public let date: Date
        public let bytes: Int64
    }

    public let id: UUID
    public let reference: StorageBrowser.FolderReference
    public fileprivate(set) var limitMB: Int
    public fileprivate(set) var readings: [Reading] = []
    public fileprivate(set) var unavailable = false
    fileprivate var wasAboveLimit = false
    var limitBytes: Int64 { Int64(limitMB) * 1_000_000 }
}

public struct WatchedFolderComparison: Identifiable, Equatable, Sendable {
    public var id: UUID { folder.id }
    public let folder: WatchedStorageFolder
    public let earlier: WatchedStorageFolder.Reading
    public let later: WatchedStorageFolder.Reading
    public var bytes: Int64 { later.bytes - earlier.bytes }
}

public struct StorageAlert: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case lowSpace, folderReturned, rapidDrop, watchedFolderLimit }
    public struct FolderGrowth: Codable, Equatable, Sendable {
        public let path: String
        public let bytes: Int64
        public let earlierScan: UUID
        public let laterScan: UUID
        public let earlierDate: Date
        public let laterDate: Date
        public let catalogTitle: String?
    }

    struct RapidDropContext: Codable, Equatable, Sendable {
        let baseline: StorageReading
        let observed: StorageReading
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let bytes: Int64
    public let path: String?
    public fileprivate(set) var folderGrowth: FolderGrowth?
    let rapidDropContext: RapidDropContext?

    init(id: UUID, date: Date, kind: Kind, bytes: Int64, path: String?, folderGrowth: FolderGrowth? = nil,
         rapidDropContext: RapidDropContext? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.bytes = bytes
        self.path = path
        self.folderGrowth = folderGrowth
        self.rapidDropContext = rapidDropContext
    }
}

public enum StorageNotificationStatus: Sendable { case unavailable, needsPermission, denied, allowed }

@MainActor public protocol StorageNotificationDelivery: AnyObject {
    func status() async -> StorageNotificationStatus
    func requestPermission() async
    func send(_ alert: StorageAlert) async
    func sendAutomationCompletion(fileCount: Int) async
}

public struct StorageMonitoringSettings: Codable, Equatable, Sendable {
    public enum Interval: Int, Codable, CaseIterable, Identifiable, Sendable {
        case hourly = 1, threeHours = 3, sixHours = 6, daily = 24
        public var id: Self { self }
        public var title: String {
            switch self {
            case .hourly: "Hourly"
            case .threeHours: "Every 3 hours"
            case .sixHours: "Every 6 hours"
            case .daily: "Daily"
            }
        }
    }

    public var automaticChecks = false
    public var interval: Interval = .hourly
    public var lowSpaceAlerts = true
    public var lowSpaceGB = 20
    private var savedRapidDropAlerts: Bool?
    public var rapidDropAlerts: Bool {
        get { savedRapidDropAlerts ?? false }
        set { savedRapidDropAlerts = newValue }
    }
    public var regrowthAlerts = true
    public var regrowthMB = 500
    public var systemNotifications = false
    var lowSpaceBytes: Int64 { Int64(min(max(lowSpaceGB, 1), 500)) * 1_000_000_000 }
    var regrowthBytes: Int64 { Int64(min(max(regrowthMB, 100), 10_000)) * 1_000_000 }
}

@MainActor @Observable
public final class StorageMonitor {
    private struct LowEpisode: Codable, Sendable {
        let threshold: Int64
        let capacity: Int64
        let volume: String?

        func matches(_ reading: StorageReading, threshold: Int64) -> Bool {
            self.threshold == threshold && capacity == reading.capacity && volume == reading.volume
        }
    }

    private struct Record: Codable, Sendable {
        var readings: [StorageReading] = []
        var alerts: [StorageAlert] = []
        var lowEpisode: LowEpisode?
        var lastRapidDrop: StorageReading?
        var reportedFolders: [UUID: Date] = [:]
        var watchedFolders: [WatchedStorageFolder]?
        var cleanupCursor: CleanupCursor?
    }

    private struct CleanupCursor: Codable, Comparable, Sendable {
        let timestamp: Date
        let id: UUID

        init(_ entry: JournalEntry) {
            timestamp = entry.timestamp
            id = entry.id
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.timestamp == rhs.timestamp ? lhs.id.uuidString < rhs.id.uuidString : lhs.timestamp < rhs.timestamp
        }
    }

    private struct StartupSeries: Hashable {
        let capacity: Int64
        let volume: String?
    }

    private static let settingsKey = "io.github.jyannni.diskplain.storage-monitor"
    private nonisolated static let cleanupWindow: TimeInterval = 30 * 86_400
    private static let day: TimeInterval = 86_400
    private static let recentReadingWindow: TimeInterval = 90 * day
    private static let dailyReadingWindow: TimeInterval = 365 * day
    private static let rapidDropWindow: TimeInterval = 24 * 3600
    private static let followUpWindow: TimeInterval = 3600
    private var record = Record()
    private var started = false
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var watchedFolderStreams: [UUID: AnyObject] = [:]
    @ObservationIgnored private var pendingFolderChecks: Set<UUID> = []
    @ObservationIgnored private var folderScheduler: Task<Void, Never>?
    @ObservationIgnored var watchFolderChanges = FileChangeWatch.startFolderTree
    @ObservationIgnored var folderCheckDelay: Duration = .seconds(2)
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private let journal: Journal?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let writer: RecordWriter
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private let notifications: (any StorageNotificationDelivery)?
    @ObservationIgnored private let comparisonHistory: ScanComparisonHistory
    @ObservationIgnored var canReadProtectedPaths: () -> Bool = { false }

    public var settings: StorageMonitoringSettings {
        didSet {
            defaults.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if settings.automaticChecks != oldValue.automaticChecks {
                if settings.automaticChecks { lastAttempt = nil }
                schedule()
            }
        }
    }
    public private(set) var isChecking = false
    public private(set) var problem: String?
    public private(set) var notificationStatus: StorageNotificationStatus = .unavailable
    public var readings: [StorageReading] { record.readings }
    public var alerts: [StorageAlert] { record.alerts }
    public var watchedFolders: [WatchedStorageFolder] { record.watchedFolders ?? [] }

    /// Compare observed endpoints for each still-available watched folder.
    public func watchedFolderComparisons(since: Date, through: Date = .now) -> [WatchedFolderComparison] {
        watchedFolders.compactMap { folder in
            guard !folder.unavailable else { return nil }
            let points = folder.readings.filter { $0.date >= since && $0.date <= through }
            guard let earlier = points.first, let later = points.last, earlier.date < later.date else { return nil }
            return WatchedFolderComparison(folder: folder, earlier: earlier, later: later)
        }.sorted {
            abs($0.bytes) == abs($1.bytes) ? $0.folder.reference.url.path < $1.folder.reference.url.path
                : abs($0.bytes) > abs($1.bytes)
        }
    }

    public func watchFolder(_ folder: URL, limitMB: Int) async -> Bool {
        guard (1...1_000_000).contains(limitMB), CleanedFolderCheck.canWatch(folder, env: deps.env) else { return false }
        let env = deps.env
        let reference = await BackgroundWork.runNonThrowing("andromeda.storage.watch-folder") {
            guard FileIdentity(path: folder.path)?.dev == FileIdentity(path: env.home.path)?.dev else {
                return nil as StorageBrowser.FolderReference?
            }
            return StorageBrowser.reference(forFolder: folder)
        }
        guard let reference, !Task.isCancelled else { return false }
        var folders = watchedFolders
        if let index = folders.firstIndex(where: { $0.reference.url.path == reference.url.path }) {
            if folders[index].reference != reference {
                folders[index] = WatchedStorageFolder(id: UUID(), reference: reference, limitMB: limitMB)
            } else if folders[index].limitMB != limitMB {
                folders[index].limitMB = limitMB
                folders[index].wasAboveLimit = false
            }
        } else {
            guard folders.count < 8 else { return false }
            folders.append(WatchedStorageFolder(id: UUID(), reference: reference, limitMB: limitMB))
        }
        record.watchedFolders = folders
        updateFolderWatches()
        _ = await saveRecord()
        return true
    }

    public func stopWatching(_ id: UUID) async {
        record.watchedFolders = watchedFolders.filter { $0.id != id }
        updateFolderWatches()
        _ = await saveRecord()
    }

    public func setWatchedFolderLimit(_ id: UUID, limitMB: Int) async -> Bool {
        var folders = watchedFolders
        guard (1...1_000_000).contains(limitMB), let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        guard folders[index].limitMB != limitMB else { return true }
        folders[index].limitMB = limitMB
        folders[index].wasAboveLimit = false
        record.watchedFolders = folders
        _ = await saveRecord()
        return true
    }

    public func trend(including scans: [StorageReading], since: Date,
                      startup: ConnectedStorage.StartupDisk? = nil) -> [StorageReading] {
        var byDate: [Date: StorageReading] = [:]
        for reading in scans + readings where reading.date >= since {
            if let startup {
                guard let volumeID = startup.volumeID, reading.volume == volumeID,
                      reading.capacity == startup.capacity else { continue }
            }
            byDate[reading.date] = reading
        }
        guard let latest = byDate.values.max(by: { $0.date < $1.date }) else { return [] }
        return byDate.values.filter { $0.volume == latest.volume && $0.capacity == latest.capacity }
            .sorted { $0.date < $1.date }
    }

    public func startupHistoryCSV(including scans: [StorageReading]) -> Data? {
        let points = trend(including: scans, since: .distantPast)
        guard !points.isEmpty else { return nil }
        let utc = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        var csv = "timestamp_utc,free_bytes,capacity_bytes\r\n"
        for point in points {
            csv += "\(point.date.formatted(utc)),\(point.free),\(point.capacity)\r\n"
        }
        return Data(csv.utf8)
    }

    /// Retains actual observations. Buckets use UTC so a time zone change cannot reassign an old reading.
    private static func retainedReadings<Reading>(
        _ readings: [Reading], dated date: KeyPath<Reading, Date>, now: Date
    ) -> [Reading] {
        var recentCount = 0
        var lastDay: Double?
        var lastWeek: Double?
        var retained: [Reading] = []
        for reading in readings.reversed() {
            let timestamp = reading[keyPath: date]
            let age = now.timeIntervalSince(timestamp)
            if age <= recentReadingWindow {
                guard recentCount < 2_400 else { continue }
                recentCount += 1
            } else if age <= dailyReadingWindow {
                let dayBucket = floor(timestamp.timeIntervalSince1970 / day)
                guard dayBucket != lastDay else { continue }
                lastDay = dayBucket
            } else {
                // Unix epoch begins on a Thursday. Offset to Monday-based weeks.
                let weekBucket = floor((timestamp.timeIntervalSince1970 + 3 * day) / (7 * day))
                guard weekBucket != lastWeek else { continue }
                lastWeek = weekBucket
            }
            retained.append(reading)
        }
        return Array(retained.reversed())
    }

    init(
        deps: AppDependencies, journal: Journal?, defaults: UserDefaults,
        comparisonHistory: ScanComparisonHistory,
        notifications: (any StorageNotificationDelivery)?
    ) {
        self.deps = deps
        self.journal = journal
        self.defaults = defaults
        self.comparisonHistory = comparisonHistory
        self.notifications = notifications
        let file = deps.journalDirectory.deletingLastPathComponent().appendingPathComponent("storage-monitor-v1.json")
        writer = RecordWriter(file: file)
        settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(StorageMonitoringSettings.self, from: $0) } ?? .init()
        do {
            record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            lastAttempt = record.readings.last?.date
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First run.
        } catch {
            problem = "Andromeda couldn’t open the saved storage readings."
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        schedule()
    }

    private func schedule() {
        scheduler?.cancel()
        scheduler = nil
        updateFolderWatches()
        guard started, settings.automaticChecks else { return }
        scheduler = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func checkIfDue(now: Date = Date(), canRun: Bool? = nil) async {
        guard settings.automaticChecks, canRun ?? deps.canRunAutomaticStorageWork() else { return }
        updateFolderWatches()
        if let lastAttempt {
            let elapsed = now.timeIntervalSince(lastAttempt)
            guard elapsed < 0 || elapsed >= Double(settings.interval.rawValue) * 3600 else { return }
        }
        await check(now: now, automatic: true)
    }

    public func checkNow() async { await check(now: Date()) }

    private func updateFolderWatches() {
        guard started, settings.automaticChecks else {
            watchedFolderStreams.removeAll()
            pendingFolderChecks.removeAll()
            folderScheduler?.cancel()
            folderScheduler = nil
            return
        }
        let canRead = canReadProtectedPaths()
        let eligible = watchedFolders.filter { canRead || !deps.env.isPromptingPath($0.reference.url) }
        let ids = Set(eligible.map(\.id))
        watchedFolderStreams = watchedFolderStreams.filter { ids.contains($0.key) }
        pendingFolderChecks.formIntersection(ids)
        for folder in eligible where watchedFolderStreams[folder.id] == nil {
            let id = folder.id
            watchedFolderStreams[id] = watchFolderChanges(folder.reference) { [weak self] in
                Task { @MainActor in self?.folderChanged(id) }
            }
        }
    }

    private func folderChanged(_ id: UUID) {
        guard watchedFolderStreams[id] != nil else { return }
        pendingFolderChecks.insert(id)
        guard folderScheduler == nil else { return }
        folderScheduler = Task { [weak self, folderCheckDelay] in
            var delay = folderCheckDelay
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self else { return }
                if self.pendingFolderChecks.isEmpty {
                    self.folderScheduler = nil
                    return
                }
                if !self.deps.canRunAutomaticStorageWork() {
                    delay = self.deps.storageWorkRetryDelay
                    continue
                }
                delay = folderCheckDelay
                guard !self.isChecking else { continue }
                let ids = self.pendingFolderChecks
                self.pendingFolderChecks.removeAll()
                await self.check(now: Date(), onlyFolders: ids, automatic: true)
                guard !Task.isCancelled else { return }
                if self.pendingFolderChecks.isEmpty {
                    self.folderScheduler = nil
                    return
                }
            }
        }
    }

    public func canInvestigate(_ alert: StorageAlert, now: Date = Date()) -> Bool {
        investigationBaseline(for: alert, at: now) != nil
    }

    private func investigationBaseline(for alert: StorageAlert, at date: Date) -> ScanComparisonSnapshot? {
        guard alert.kind == .rapidDrop, alert.folderGrowth == nil, let context = alert.rapidDropContext,
              (0...Self.followUpWindow).contains(date.timeIntervalSince(context.observed.date)) else { return nil }
        return comparisonHistory.baselineForRapidDrop(context.observed, minimumFree: context.baseline.free,
                                                      since: context.observed.date.addingTimeInterval(-Self.rapidDropWindow))
    }

    func includeFollowUpScan(_ scan: ScanComparisonSnapshot) async {
        var updated = false
        for index in record.alerts.indices {
            guard let growth = followUpGrowth(for: record.alerts[index], scan: scan) else { continue }
            record.alerts[index].folderGrowth = growth
            updated = true
        }
        if updated { _ = await saveRecord() }
    }

    private func followUpGrowth(for alert: StorageAlert, scan: ScanComparisonSnapshot) -> StorageAlert.FolderGrowth? {
        guard let context = alert.rapidDropContext, let volume = context.observed.volume,
              scan.date > context.observed.date, scan.startupVolume == volume, scan.homeVolume == volume,
              scan.capacity == context.observed.capacity,
              let free = scan.free, free >= 0, free <= context.observed.free,
              let earlier = investigationBaseline(for: alert, at: scan.date) else { return nil }
        return comparisonHistory.largestMeasuredGrowth(earlier: earlier, later: scan)
    }

    public func refreshNotificationStatus() async {
        notificationStatus = await notifications?.status() ?? .unavailable
    }

    public func enableNotifications() async {
        guard notifications != nil else { return }
        await requestSystemNotificationPermission()
        settings.systemNotifications = notificationStatus == .allowed
    }

    public func requestSystemNotificationPermission() async {
        guard let notifications else { return }
        await notifications.requestPermission()
        await refreshNotificationStatus()
    }

    private func check(now: Date, onlyFolders: Set<UUID>? = nil, automatic: Bool = false) async {
        guard !isChecking, !Task.isCancelled else { return }
        let checkStartup = onlyFolders == nil
        let watches = watchedFolders.filter { onlyFolders?.contains($0.id) ?? true }
            .map { (id: $0.id, reference: $0.reference, limitMB: $0.limitMB) }
        guard checkStartup || !watches.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        if checkStartup { lastAttempt = now }
        let deps = deps, journal = journal
        let minimum = checkStartup && settings.regrowthAlerts ? settings.regrowthBytes : nil
        let reported = Set(record.reportedFolders.keys)
        let cleanupCursor = record.cleanupCursor
        let canRead = canReadProtectedPaths()
        let control = ScanControl { _ in }
        let (reading, cleanup, folderSizes) = await withTaskCancellationHandler {
            await BackgroundWork.runNonThrowing("andromeda.storage.monitor", qos: automatic ? .utility : .userInitiated) {
                let usage = checkStartup ? try? deps.volume.current() : nil
                let reading = usage.flatMap { usage -> StorageReading? in
                    guard usage.containerCapacity > 0, (0...usage.containerCapacity).contains(usage.containerFree) else { return nil }
                    let volume = try? deps.env.dataVolumeRoot.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
                    return StorageReading(date: now, free: usage.containerFree, capacity: usage.containerCapacity, volume: volume)
                }
                let cleanup = minimum.flatMap {
                    Self.findReturnedFolders(deps: deps, journal: journal, now: now, minimum: $0,
                                             reported: reported, cursor: cleanupCursor, canRead: canRead, control: control)
                }
                let folderSizes = watches.map { watch in
                    CleanedFolderCheck.watchedBytes(watch.reference, env: deps.env, canReadProtectedPaths: canRead,
                                                    control: control)
                }
                return (reading, cleanup, folderSizes)
            }
        } onCancel: {
            control.cancel()
        }
        guard !Task.isCancelled else { return }
        var newAlerts: [StorageAlert] = []
        if let reading {
            record.readings.removeAll { $0.date == reading.date }
            record.readings.append(reading)
            record.readings.sort { $0.date < $1.date }
            if let alert = lowSpaceAlert(for: reading) { newAlerts.append(alert) }
            if let alert = rapidDropAlert(for: reading) { newAlerts.append(alert) }
        }
        if settings.regrowthAlerts, let cleanup {
            record.cleanupCursor = cleanup.cursor
            for (entry, bytes) in cleanup.returns where bytes >= settings.regrowthBytes {
                record.reportedFolders[entry.id] = entry.timestamp
                newAlerts.append(StorageAlert(id: entry.id, date: now, kind: .folderReturned,
                                              bytes: bytes, path: entry.originalPath))
            }
        }
        let previousFolders = watchedFolders
        var folders = previousFolders
        for (watch, size) in zip(watches, folderSizes) {
            guard let index = folders.firstIndex(where: {
                $0.id == watch.id && $0.reference == watch.reference && $0.limitMB == watch.limitMB
            }) else { continue }
            folders[index].unavailable = size == nil
            guard let size else { continue }
            if checkStartup || folders[index].readings.last?.bytes != size {
                folders[index].readings.removeAll { $0.date == now }
                folders[index].readings.append(.init(date: now, bytes: size))
                folders[index].readings.sort { $0.date < $1.date }
                folders[index].readings = Self.retainedReadings(folders[index].readings, dated: \.date, now: now)
            }
            let above = size >= folders[index].limitBytes
            if above, !folders[index].wasAboveLimit {
                newAlerts.append(StorageAlert(id: UUID(), date: now, kind: .watchedFolderLimit, bytes: size,
                                              path: watch.reference.url.path))
            }
            folders[index].wasAboveLimit = above
        }
        if !checkStartup, folders == previousFolders, newAlerts.isEmpty { return }
        if folders != previousFolders { record.watchedFolders = folders }
        if reading != nil {
            let bySeries = Dictionary(grouping: record.readings) { StartupSeries(capacity: $0.capacity, volume: $0.volume) }
            record.readings = bySeries.values.flatMap { Self.retainedReadings($0, dated: \.date, now: now) }
                .sorted { $0.date < $1.date }
        }
        record.reportedFolders = record.reportedFolders.filter { now.timeIntervalSince($0.value) <= Self.cleanupWindow }
        record.alerts = Array((newAlerts + record.alerts).prefix(50))
        let saved = await saveRecord(readingUnavailable: checkStartup && reading == nil)
        if saved, settings.systemNotifications, !newAlerts.isEmpty, let notifications,
           await notifications.status() == .allowed {
            for alert in newAlerts where !Task.isCancelled { await notifications.send(alert) }
        }
    }

    private func saveRecord(readingUnavailable: Bool = false) async -> Bool {
        saveRevision += 1
        let revision = saveRevision
        let saved = await writer.save(record, revision: revision)
        if saveRevision == revision {
            problem = !saved ? "Andromeda couldn’t save the storage readings for later."
                : readingUnavailable ? "Andromeda couldn’t measure free space. Check again later." : nil
        }
        return saved
    }

    private actor RecordWriter {
        let file: URL
        private var revision = 0
        private var saved = true

        init(file: URL) { self.file = file }

        func save(_ record: Record, revision: Int) -> Bool {
            guard revision > self.revision else { return saved }
            self.revision = revision
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(record).write(to: file, options: .atomic)
                saved = true
            } catch { saved = false }
            return saved
        }
    }

    private func lowSpaceAlert(for reading: StorageReading) -> StorageAlert? {
        let threshold = settings.lowSpaceBytes
        guard settings.lowSpaceAlerts else { record.lowEpisode = nil; return nil }
        if record.lowEpisode?.matches(reading, threshold: threshold) == true {
            if reading.free >= min(reading.capacity, threshold + 1_000_000_000) {
                record.lowEpisode = nil
            }
            return nil
        }
        record.lowEpisode = nil
        guard reading.free < min(reading.capacity, threshold) else { return nil }
        record.lowEpisode = LowEpisode(threshold: threshold, capacity: reading.capacity, volume: reading.volume)
        return StorageAlert(id: UUID(), date: reading.date, kind: .lowSpace, bytes: reading.free, path: nil)
    }

    private func rapidDropAlert(for reading: StorageReading) -> StorageAlert? {
        guard settings.rapidDropAlerts, let volume = reading.volume else { return nil }
        if let last = record.lastRapidDrop, last.volume == volume, last.capacity == reading.capacity,
           reading.date.timeIntervalSince(last.date) < Self.rapidDropWindow { return nil }
        let cutoff = reading.date.addingTimeInterval(-Self.rapidDropWindow)
        let baseline = (record.readings + comparisonHistory.storageReadings).lazy.filter {
            $0.volume == volume && $0.capacity == reading.capacity && $0.date >= cutoff && $0.date < reading.date
                && (0...reading.capacity).contains($0.free)
        }.max {
            $0.free == $1.free ? $0.date < $1.date : $0.free < $1.free
        }
        let threshold = min(10_000_000_000, 1 + (reading.capacity - 1) / 20)
        guard let baseline, baseline.free - reading.free >= threshold else { return nil }
        record.lastRapidDrop = reading
        let growth = comparisonHistory.largestMeasuredGrowth(from: baseline, to: reading)
        var alert = StorageAlert(id: UUID(), date: reading.date, kind: .rapidDrop, bytes: baseline.free - reading.free,
                                 path: nil, folderGrowth: growth, rapidDropContext: .init(baseline: baseline, observed: reading))
        if growth == nil, comparisonHistory.problem == nil, let latest = comparisonHistory.snapshots.first {
            alert.folderGrowth = followUpGrowth(for: alert, scan: latest)
        }
        return alert
    }

    private nonisolated static func findReturnedFolders(
        deps: AppDependencies, journal: Journal?, now: Date, minimum: Int64, reported: Set<UUID>,
        cursor: CleanupCursor?, canRead: Bool, control: ScanControl
    ) -> (returns: [(JournalEntry, Int64)], cursor: CleanupCursor)? {
        guard !control.isCancelled, let entries = try? journal?.load().entries else { return nil }
        let followUps = JournalHistory.followUps(entries: entries)
        var newestByPath: [String: JournalEntry] = [:]
        for entry in entries where entry.relatesTo == nil && entry.resolvedAction == .trash && entry.outcome == .done {
            guard let path = entry.originalPath, entry.cleanedDirectoryInode != nil,
                  (0...cleanupWindow).contains(now.timeIntervalSince(entry.timestamp)),
                  newestByPath[path].map({ $0.timestamp < entry.timestamp }) ?? true else { continue }
            newestByPath[path] = entry
        }
        let recent = newestByPath.values.filter { entry in
            !reported.contains(entry.id)
                && !(followUps[entry.id] ?? []).contains { $0.outcome == .restored }
        }.sorted { CleanupCursor($0) > CleanupCursor($1) }
        guard !recent.isEmpty else { return nil }
        // A cursor remains a valid position after its entry was reported, undone, or aged out.
        let start = cursor.flatMap { cursor in recent.firstIndex { CleanupCursor($0) < cursor } } ?? 0
        let count = min(16, recent.count)
        var returns: [(JournalEntry, Int64)] = []
        for offset in 0..<count {
            guard !control.isCancelled else { return nil }
            let entry = recent[(start + offset) % recent.count]
            guard let path = entry.originalPath, let inode = entry.cleanedDirectoryInode,
                  let bytes = CleanedFolderCheck.returnedBytes(
                    at: URL(fileURLWithPath: path, isDirectory: true), originalInode: inode, minimum: minimum,
                    env: deps.env, canReadProtectedPaths: canRead, control: control) else { continue }
            returns.append((entry, bytes))
        }
        guard !control.isCancelled else { return nil }
        return (returns, CleanupCursor(recent[(start + count - 1) % recent.count]))
    }
}
