import AndromedaCore
import AndromedaOrganize
import Foundation
import Observation

public struct SpacePlanItem: Codable, Identifiable, Equatable, Sendable {
    public enum Action: Codable, Equatable, Sendable {
        case keepLocal, cleanup(String), onlineOnly(CloudProvider), archive, moveToCloud, reviewFolder
    }

    public let id: String
    public let title: String
    public let paths: [URL]
    public let action: Action
    public let uses: Int64?
    public let estimate: Int64?
    public let reason: String
    public let available: Bool
    public internal(set) var folderReference: StorageBrowser.FolderReference?

    fileprivate func pinned() -> Self {
        .init(id: id, title: title, paths: paths, action: .keepLocal, uses: uses, estimate: nil,
              reason: "You marked this item or a related folder to stay on this Mac.", available: false)
    }
}

enum SpacePlanSelection {
    static func ordered(_ rows: [SpacePlanItem]) -> [SpacePlanItem] {
        func rank(_ action: SpacePlanItem.Action) -> Int {
            switch action {
            case .onlineOnly: 0
            case .cleanup: 1
            case .archive: 2
            case .moveToCloud: 3
            case .reviewFolder: 4
            case .keepLocal: 5
            }
        }
        return rows.sorted {
            let left = rank($0.action), right = rank($1.action)
            if left != right { return left < right }
            let a = $0.estimate ?? $0.uses ?? 0, b = $1.estimate ?? $1.uses ?? 0
            return a == b ? $0.id < $1.id : a > b
        }
    }

    static func pick(_ rows: [SpacePlanItem], target: Int64) -> Set<String> {
        var picks: [SpacePlanItem] = []
        var planned: Int64 = 0
        for row in rows where planned < target && row.available {
            guard let amount = row.estimate, amount > 0,
                  !picks.contains(where: { overlap($0.paths, row.paths) }) else { continue }
            picks.append(row)
            planned += amount
        }
        return Set(picks.map(\.id))
    }

    static func overlap(_ first: [URL], _ second: [URL]) -> Bool {
        first.contains { one in
            second.contains { two in
                let a = one.standardizedFileURL.path
                let b = two.standardizedFileURL.path
                return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
            }
        }
    }
}

@MainActor @Observable
public final class SpacePlannerModel {
    public enum Destination: String, Codable, CaseIterable, Identifiable, Sendable {
        case byItem = "By item", external = "External drive", cloud = "Cloud"
        public var id: Self { self }
    }

    public var targetGB = 20.0 { didSet { savePlan() } }
    public var destination: Destination = .byItem { didSet { savePlan() } }
    public private(set) var selected: Set<String> = []
    public private(set) var isBuilding = false
    public private(set) var isMeasuring = false
    public private(set) var builtAt: Date?
    public private(set) var builtFromScan: Date?
    public private(set) var startedAt: Date?
    public private(set) var initialFree: Int64?
    public private(set) var currentFree: Int64?
    public private(set) var measuredAt: Date?
    public private(set) var measurementProblem: String?
    public private(set) var saveProblem: String?
    public private(set) var progressProblem: String?
    public private(set) var isCheckingProgress = false
    public private(set) var progress: [String: SpacePlanProgress] = [:]

    private var candidates: [SpacePlanItem] = []
    private var pins: Set<String>
    private var capacity: Int64?
    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let planFile: URL
    @ObservationIgnored private let journal: Journal?
    @ObservationIgnored private var control: ScanControl?
    @ObservationIgnored private var progressGeneration = 0
    private static let pinKey = "io.github.jyannni.diskplain.keep-local-paths"

    private struct SavedPlan: Codable {
        let targetGB: Double
        let destination: Destination
        let selected: Set<String>
        let candidates: [SpacePlanItem]
        let startedAt: Date
        let builtAt: Date
        let builtFromScan: Date?
        let initialFree: Int64?
        let currentFree: Int64?
        let capacity: Int64?
        let measuredAt: Date?
    }

    init(deps: AppDependencies, defaults: UserDefaults, journal: Journal? = nil) {
        self.deps = deps
        self.defaults = defaults
        self.journal = journal
        planFile = deps.journalDirectory.deletingLastPathComponent().appendingPathComponent("space-plan.json")
        pins = Set(defaults.stringArray(forKey: Self.pinKey) ?? [])
        do {
            guard let saved = try JSONDecoder().decode(SavedPlan?.self, from: Data(contentsOf: planFile)) else { return }
            targetGB = saved.targetGB
            destination = saved.destination
            candidates = saved.candidates
            selected = saved.selected
            startedAt = saved.startedAt
            builtAt = saved.builtAt
            builtFromScan = saved.builtFromScan
            initialFree = saved.initialFree
            currentFree = saved.currentFree
            capacity = saved.capacity
            measuredAt = saved.measuredAt
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First run.
        } catch {
            saveProblem = "The saved plan couldn’t be opened. Build a new plan to replace it."
        }
    }

    private func savePlan() {
        guard let startedAt, let builtAt else { return }
        let saved = SavedPlan(
            targetGB: targetGB.isFinite ? targetGB : 0, destination: destination,
            selected: selected, candidates: candidates, startedAt: startedAt, builtAt: builtAt,
            builtFromScan: builtFromScan, initialFree: initialFree, currentFree: currentFree,
            capacity: capacity, measuredAt: measuredAt)
        do {
            try writePlan(saved)
            saveProblem = nil
        } catch {
            saveProblem = "Andromeda couldn’t save this plan. The latest changes may be lost when you quit."
        }
    }

    private func writePlan(_ plan: SavedPlan?) throws {
        try FileManager.default.createDirectory(at: planFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: planFile, options: .atomic)
    }

    public func startOver() {
        guard !isBuilding, !isMeasuring else { return }
        do {
            try writePlan(nil)
        } catch {
            saveProblem = "Andromeda couldn’t clear the saved plan. Try again."
            return
        }
        startedAt = nil
        builtAt = nil
        builtFromScan = nil
        selected = []
        candidates = []
        progress = [:]
        progressProblem = nil
        saveProblem = nil
        resetMeasurement()
    }

    public var targetBytes: Int64? {
        guard targetGB.isFinite, (0.1...100_000).contains(targetGB) else { return nil }
        return Int64((targetGB * 1_000_000_000).rounded())
    }

    public var rows: [SpacePlanItem] {
        let pinnedPaths = pins.map { URL(fileURLWithPath: $0, isDirectory: false) }
        return SpacePlanSelection.ordered(candidates.map {
            $0.action != .reviewFolder && SpacePlanSelection.overlap($0.paths, pinnedPaths) ? $0.pinned() : $0
        })
    }

    public var selectedRows: [SpacePlanItem] { rows.filter { selected.contains($0.id) } }
    public var pendingRows: [SpacePlanItem] { selectedRows.filter { pendingEstimate(for: $0) } }
    public var estimatedBytes: Int64 { pendingRows.compactMap(\.estimate).reduce(0, +) }
    public var unknownCount: Int { pendingRows.count { $0.estimate == nil } }

    public func pendingEstimate(for item: SpacePlanItem) -> Bool {
        item.action != .reviewFolder && selected.contains(item.id)
            && item.available && progress[item.id]?.usesSavedEstimate != false
    }

    public func containsFolderForReview(_ folder: URL) -> Bool {
        selected.contains(Self.reviewID(folder))
    }

    private static func reviewID(_ folder: URL) -> String { "review:" + folder.standardizedFileURL.path }

    public func addFolderForReview(_ change: FolderSizeChange) {
        guard !isBuilding, !isMeasuring, change.bytes > 0 else { return }
        let folder = change.url.standardizedFileURL
        guard folder.path.hasPrefix(deps.env.home.standardizedFileURL.path + "/") else { return }
        let bytes = ByteFormat.string(change.bytes)
        let reason = change.kind == .appeared
            ? "Appeared at this path between the scans you compared and uses \(bytes)."
            : "Grew by \(bytes) between the scans you compared."
        saveReview(folder, reason: reason)
    }

    public func addFolderForReview(_ entry: StorageBrowser.Entry) async -> Bool {
        guard !isBuilding, !isMeasuring, entry.isFolder else { return false }
        let reference = await BackgroundWork.runNonThrowing("andromeda.map.save-folder") {
            StorageBrowser.reference(for: entry)
        }
        guard let reference, !Task.isCancelled, !isBuilding, !isMeasuring else { return false }
        let size = ByteFormat.string(entry.bytes)
        let reason = entry.incomplete ? "At least \(size) on the storage map." : "\(size) on the storage map."
        saveReview(reference.url, reason: reason, reference: reference)
        return true
    }

    public func addFolderForReview(_ folder: WatchedStorageFolder) {
        saveReview(folder.reference.url, reason: "Watched in Storage Trends.", reference: folder.reference)
    }

    public func addFolderForReview(_ change: WatchedFolderComparison) {
        guard !isBuilding, !isMeasuring, change.bytes > 0 else { return }
        let reference = change.folder.reference
        let reason = "Grew by \(ByteFormat.string(change.bytes)) between watched-folder checks."
        saveReview(reference.url, reason: reason, reference: reference)
    }

    private func saveReview(_ folder: URL, reason: String, reference: StorageBrowser.FolderReference? = nil) {
        let id = Self.reviewID(folder)
        let now = Date()
        if startedAt == nil { startedAt = now }
        if builtAt == nil { builtAt = now }
        let row = SpacePlanItem(id: id, title: folder.lastPathComponent, paths: [folder],
                                action: .reviewFolder, uses: nil, estimate: nil,
                                reason: reason, available: true, folderReference: reference)
        if let index = candidates.firstIndex(where: { $0.id == id }) { candidates[index] = row }
        else { candidates.append(row) }
        selected.insert(id)
        savePlan()
    }

    public func toggle(_ item: SpacePlanItem) {
        if selected.remove(item.id) == nil {
            guard item.available else { return }
            if item.action != .reviewFolder {
                for row in selectedRows where row.action != .reviewFolder && SpacePlanSelection.overlap(row.paths, item.paths) {
                    selected.remove(row.id)
                }
            }
            selected.insert(item.id)
        }
        savePlan()
    }

    public func suggestSelection() {
        guard let targetBytes else { return }
        let tracked = selectedRows.filter { progress[$0.id]?.hasRecordedAction == true }
        let reviews = selectedRows.filter { $0.action == .reviewFolder }
        let trackedPaths = tracked.flatMap(\.paths)
        let options = rows.filter {
            progress[$0.id]?.usesSavedEstimate != false && !SpacePlanSelection.overlap($0.paths, trackedPaths)
        }
        let measuredChange = (currentFree ?? 0) - (initialFree ?? 0)
        let underway = tracked.filter { progress[$0.id]?.usesSavedEstimate == true }.compactMap(\.estimate).reduce(0, +)
        selected = Set((tracked + reviews).map(\.id))
            .union(SpacePlanSelection.pick(options, target: targetBytes - measuredChange - underway))
        savePlan()
    }

    public func isPinned(_ item: SpacePlanItem) -> Bool {
        item.paths.count == 1 && item.paths.first.map { pins.contains($0.standardizedFileURL.path) } == true
    }

    public func toggleKeepLocal(_ item: SpacePlanItem) {
        guard item.paths.count == 1, let url = item.paths.first else { return }
        let path = url.standardizedFileURL.path
        if pins.remove(path) == nil { pins.insert(path) }
        defaults.set(pins.sorted(), forKey: Self.pinKey)
        selected.subtract(rows.filter { $0.action == .keepLocal }.map(\.id))
        savePlan()
    }

    public func cancel() { control?.cancel() }

    public func build(from scan: ScanResult, cloud: [OffloadRow], drives: [ExternalVolume], settings: OrganizeSettings) async {
        guard !isBuilding, !isMeasuring, targetBytes != nil else { return }
        isBuilding = true
        let preference = destination
        let provider = deps.volume
        let control = ScanControl { _ in }
        self.control = control
        defer { self.control = nil; isBuilding = false }
        let result = await BackgroundWork.runNonThrowing("andromeda.space.plan") {
            let now = Date()
            let candidates = Self.buildItems(scan: scan, cloud: cloud, drives: drives, settings: settings,
                                             preference: preference, now: now, control: control)
            return (candidates, control.isCancelled ? nil : try? provider.current(), now)
        }
        guard !control.isCancelled else { return }
        let firstSuggestions = builtFromScan == nil
        if startedAt == nil { startedAt = result.2 }
        let savedSelection = Dictionary(uniqueKeysWithValues: candidates.filter { selected.contains($0.id) }.map { ($0.id, $0) })
        let freshIDs = Set(result.0.map(\.id))
        candidates = result.0.map { fresh in
            guard let saved = savedSelection[fresh.id] else { return fresh }
            // Keep the chosen action and paths even when a later scan suggests something different.
            return fresh.action == saved.action && Set(fresh.paths) == Set(saved.paths) ? fresh : saved
        } + savedSelection.values.filter { !freshIDs.contains($0.id) }
        builtFromScan = scan.finishedAt
        builtAt = result.2
        if initialFree == nil, let volume = result.1 { initialFree = volume.containerFree; capacity = volume.containerCapacity }
        if let volume = result.1 { applyMeasurement(volume) }
        else { measurementProblem = "Andromeda couldn’t measure current free space. Check again when you’re ready." }
        if firstSuggestions { suggestSelection() }
        else { savePlan() }
    }

    public func checkFreeSpace() async {
        guard !isMeasuring, !isBuilding, builtAt != nil else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        let provider = deps.volume
        guard let volume = await BackgroundWork.runNonThrowing("andromeda.space.measure", { try? provider.current() }) else {
            measurementProblem = "Andromeda couldn’t measure free space on the Mac. Try again."
            return
        }
        if initialFree == nil { initialFree = volume.containerFree; capacity = volume.containerCapacity }
        applyMeasurement(volume)
        savePlan()
    }

    private func applyMeasurement(_ volume: VolumeUsage) {
        guard capacity == volume.containerCapacity else {
            measurementProblem = "The disk capacity changed. Start a new measurement to compare free space."
            return
        }
        currentFree = volume.containerFree
        measuredAt = Date()
        measurementProblem = nil
    }

    public func resetMeasurement() {
        initialFree = nil
        currentFree = nil
        capacity = nil
        measuredAt = nil
        measurementProblem = nil
        savePlan()
    }

    func refreshProgress(loadArchives: (Bool) async -> [ArchiveRecord]?) async {
        guard let startedAt else { return }
        progressGeneration += 1
        let generation = progressGeneration
        isCheckingProgress = true
        defer { if generation == progressGeneration { isCheckingProgress = false } }
        let items = selectedRows
        let archives = await loadArchives(items.contains { $0.action == .archive })
        guard !Task.isCancelled, generation == progressGeneration, self.startedAt == startedAt else { return }
        let deps = self.deps, journal = self.journal
        let snapshot = await BackgroundWork.runNonThrowing("andromeda.space.progress") {
            SpacePlanProgress.check(items, since: startedAt, archives: archives, journal: journal, deps: deps)
        }
        guard !Task.isCancelled, generation == progressGeneration, self.startedAt == startedAt else { return }
        progress = snapshot.rows
        progressProblem = snapshot.problem
    }

    public func cleanupIDs(for scan: ScanResult) -> Set<String> {
        let selectedCleanup = Dictionary(uniqueKeysWithValues: selectedRows.compactMap { item -> (String, Set<URL>)? in
            guard case .cleanup(let id) = item.action else { return nil }
            return (id, Set(item.paths.map(\.standardizedFileURL)))
        })
        return Set(scan.findings.compactMap { finding in
            guard let paths = selectedCleanup[finding.id],
                  finding.entry.tier == .safe, finding.entry.removal == .trash, finding.verdict.actionable,
                  !finding.items.isEmpty, finding.items.allSatisfy({ paths.contains($0.url.standardizedFileURL) })
            else { return nil }
            return finding.id
        })
    }

    nonisolated static func buildItems(
        scan: ScanResult, cloud: [OffloadRow], drives: [ExternalVolume], settings: OrganizeSettings,
        preference: Destination, now: Date, control: ScanControl,
        lastUse: (URL) -> LastUse? = { LastUsedReader().lastUse(of: $0) },
        size: (URL) -> SizeResult = { AllocatedSizer().size(of: $0) },
        cloudRoots: [CloudRoot]? = nil
    ) -> [SpacePlanItem] {
        let roots = cloudRoots ?? CloudRootLocator.roots(env: scan.env)
        var exclusions = MoveToCloudPlanner.walkExclusions(env: scan.env, cloudRoots: roots)
        if scan.fda == .granted {
            exclusions += ["Desktop", "Documents"].map { scan.env.home.appendingPathComponent($0, isDirectory: true) }
                .filter(FolderPlanner.liveIsUbiquitous)
        }
        let archiveDrives = drives.filter(ExternalArchive.supports)
        var rows: [SpacePlanItem] = scan.findings.compactMap { f in
            guard f.entry.tier == .safe, f.entry.removal == .trash, f.verdict.actionable, !f.items.isEmpty else { return nil }
            return SpacePlanItem(id: "cleanup:" + f.id, title: f.entry.title, paths: f.items.map(\.url),
                                 action: .cleanup(f.id), uses: f.bytes, estimate: f.freeableBytes,
                                 reason: f.entry.consequence, available: true)
        }
        rows += cloud.compactMap { row in
            guard row.isSelectable, row.state.sync == .synced, !row.state.isUploading else { return nil }
            return SpacePlanItem(id: "offload:" + row.id.path, title: row.id.lastPathComponent, paths: [row.id],
                                 action: .onlineOnly(row.state.provider), uses: row.state.usesBytes,
                                 estimate: row.state.freesAtLeast,
                                 reason: "The last cloud check confirmed an uploaded copy. Use Finder to remove the local download.",
                                 available: true)
        }
        let guardCache = OrganizeGuard.Cache()
        for item in scan.largeItems {
            if control.isCancelled { break }
            let url = item.url
            var metadata = stat()
            guard ExternalArchive.couldArchive(url, in: scan.env),
                  !SpacePlanSelection.overlap([url], exclusions),
                  scan.fda == .granted || !scan.env.isPromptingPath(url),
                  lstat(url.path, &metadata) == 0, [S_IFREG, S_IFDIR].contains(metadata.st_mode & S_IFMT),
                  metadata.st_flags & UInt32(SF_DATALESS) == 0,
                  (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem != true
            else { continue }
            let use = lastUse(url)
            let age = use.map { now.timeIntervalSince($0.date) }
            let activity = use.map { Copy.Organize.lastUse($0) } ?? "No reliable activity date."
            let action: SpacePlanItem.Action
            let explanation: String
            let available: Bool
            var estimate: Int64?
            let exclusion = OrganizeGuard.exclusion(for: url, env: scan.env, cloudRoots: roots.map(\.url), cache: guardCache)
            let cloudEligible = !roots.isEmpty && exclusion == nil
            let fitsDrive = archiveDrives.contains { $0.available >= item.bytes }
            let standaloneFile = metadata.st_mode & S_IFMT == S_IFREG
            if exclusion == .appLibrary || exclusion == .package || exclusion == .insidePackage
                || exclusion == .insideCodeProject {
                action = .keepLocal
                explanation = "Keep this with its project or app. Use the app’s archive workflow or review the whole project folder."
                available = false
            } else if let age, age >= max(30 * OrganizeSettings.day, settings.moveMinAge) {
                if cloudEligible && (preference == .cloud || (preference == .byItem && standaloneFile)) {
                    action = .moveToCloud
                    available = true
                    explanation = "Review a cloud move. Space may return after upload completes and you remove the download."
                } else {
                    action = .archive
                    available = fitsDrive
                    explanation = available
                        ? "Keep this project available on a drive. Local space may return after the copy is verified and the original leaves Trash."
                        : "Connect a writable APFS drive with enough space to review this archive."
                }
                let measured = size(url)
                if measured.unreadable.isEmpty { estimate = measured.privateBytes }
            } else {
                action = .keepLocal
                explanation = "Keep this on the Mac for now."
                available = false
            }
            rows.append(SpacePlanItem(id: "local:" + url.path, title: url.lastPathComponent, paths: [url],
                                      action: action, uses: item.bytes, estimate: estimate,
                                      reason: activity + " " + explanation, available: available))
        }
        return rows
    }
}
