import AndromedaCore
import Foundation
import Observation

public struct ScanComparisonSnapshot: Codable, Identifiable, Sendable {
    struct CatalogReading: Codable, Sendable {
        struct Scope: Codable, Equatable, Sendable {
            let paths: [String]
            let exclusions: [String]
            let measuredRoots: [String]
            let volume: String
        }

        let title: String
        let bucket: AppleBucket
        let bytes: Int64
        let scope: Scope

        init?(_ finding: Finding) {
            guard finding.entry.sizing == .allocatedWalk, let bytes = finding.bytes, bytes >= 0,
                  finding.unreadable.isEmpty, !finding.rootMeasureBlocked,
                  let first = finding.items.first, let volume = ScanComparisonSnapshot.volumeID(first.url),
                  finding.items.dropFirst().allSatisfy({ ScanComparisonSnapshot.volumeID($0.url) == volume })
            else { return nil }
            let roots = finding.items.map { SafetyGuard.withoutSystemPathAlias($0.url.standardizedFileURL.path) }
            self.title = finding.entry.title
            self.bucket = finding.entry.bucket
            self.bytes = bytes
            self.scope = Scope(paths: finding.entry.paths, exclusions: finding.entry.exclude,
                               measuredRoots: roots.sorted(), volume: volume)
        }
    }

    public let id: UUID
    public let date: Date
    let home: String
    let homeVolume: String?
    let startupVolume: String?
    let capacity: Int64?
    let free: Int64?
    let excluded: Set<String>
    let folders: [String: Int64]
    /// Missing in older snapshots. Each saved listing is complete, including empty ones.
    let listedDirectories: [String: Set<String>]?
    /// Optional so existing saved scans can still be used for home-folder comparisons.
    let catalogReadings: [String: CatalogReading]?

    init(result: ScanResult, folders: [String: Int64], listedDirectories: [String: Set<String>]? = nil,
         excluded: [URL], catalogFindings: [Finding]? = nil) {
        id = UUID()
        date = result.finishedAt
        home = result.env.home.standardizedFileURL.path
        homeVolume = Self.volumeID(result.env.home)
        startupVolume = Self.volumeID(result.env.dataVolumeRoot)
        capacity = result.usage?.containerCapacity
        free = result.usage?.containerFree
        catalogReadings = catalogFindings.map { findings in
            Dictionary(uniqueKeysWithValues: findings.compactMap { finding in
                CatalogReading(finding).map { (finding.id, $0) }
            })
        }
        let prefix = home.lowercased() + "/"
        self.excluded = Set(excluded.map { $0.standardizedFileURL.path.lowercased() }.filter { $0.hasPrefix(prefix) })
        let bySize = folders.sorted { first, second in
            if first.value == second.value { return first.key < second.key }
            return first.value > second.value
        }
        let retained = Dictionary(uniqueKeysWithValues: bySize.prefix(3_000).map { ($0.key, $0.value) })
        self.folders = retained
        self.listedDirectories = listedDirectories.map { listings in
            let parents = retained.keys.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            let candidates = Set(retained.keys).union(parents).union([result.env.home.standardizedFileURL.path])
            var saved: [String: Set<String>] = [:]
            var remaining = 12_000
            for path in candidates.sorted() {
                guard saved.count < 3_001 else { break }
                guard let names = listings[path], names.count <= remaining else { continue }
                saved[path] = names
                remaining -= names.count
            }
            return saved
        }
    }

    private static func volumeID(_ url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    fileprivate func provesAbsence(of folder: URL) -> Bool {
        guard homeVolume != nil else { return false }
        let parent = folder.deletingLastPathComponent().path
        return listedDirectories?[parent]?.contains(folder.lastPathComponent.lowercased()) == false
    }
}

public struct FolderSizeChange: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case resized, appeared, disappeared }

    public var id: String { url.path }
    public let url: URL
    public let before: Int64
    public let after: Int64
    public let kind: Kind
    public var bytes: Int64 { after - before }
}

public struct CatalogSizeChange: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let bucket: AppleBucket
    public let before: Int64
    public let after: Int64
    public var bytes: Int64 { after - before }
    let scope: ScanComparisonSnapshot.CatalogReading.Scope
}

public struct ScanComparison: Sendable {
    public let comparable: Bool
    public let folderCount: Int
    public let grew: [FolderSizeChange]
    public let shrank: [FolderSizeChange]
    public let freeChange: Int64?
    public let catalogCount: Int
    public let catalogUncomparedCount: Int
    public let catalogChanges: [CatalogSizeChange]

    public init(earlier: ScanComparisonSnapshot, later: ScanComparisonSnapshot) {
        comparable = earlier.date <= later.date && earlier.id != later.id
            && earlier.home == later.home && earlier.homeVolume == later.homeVolume
        guard comparable else {
            folderCount = 0
            grew = []
            shrank = []
            freeChange = nil
            catalogCount = 0
            catalogUncomparedCount = 0
            catalogChanges = []
            return
        }
        if let volume = earlier.startupVolume, volume == later.startupVolume,
           earlier.capacity == later.capacity, let before = earlier.free, let after = later.free {
            freeChange = after - before
        } else {
            freeChange = nil
        }

        // A change in what the catalog claimed can move bytes in or out of this walk without
        // any file changing. Omit the affected folders and their ancestors from this comparison.
        let changedExclusions = earlier.excluded.symmetricDifference(later.excluded)
        let home = earlier.home.lowercased()
        var affected = Set<String>()
        for exclusion in changedExclusions {
            var path = exclusion
            while path.count > home.count {
                affected.insert(path)
                guard let slash = path.lastIndex(of: "/") else { break }
                path = String(path[..<slash])
            }
        }
        var count = 0
        var growth: [FolderSizeChange] = []
        var shrinkage: [FolderSizeChange] = []
        let paths = Set(earlier.folders.keys).union(later.folders.keys)
        for path in paths where !affected.contains(path.lowercased()) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let change: FolderSizeChange
            switch (earlier.folders[path], later.folders[path]) {
            case (let before?, let after?):
                change = .init(url: url, before: before, after: after, kind: .resized)
            case (nil, let after?) where earlier.provesAbsence(of: url):
                change = .init(url: url, before: 0, after: after, kind: .appeared)
            case (let before?, nil) where later.provesAbsence(of: url):
                change = .init(url: url, before: before, after: 0, kind: .disappeared)
            default:
                continue
            }
            count += 1
            if change.bytes > 0 { growth.append(change) }
            else if change.bytes < 0 { shrinkage.append(change) }
        }
        folderCount = count
        grew = growth.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        shrank = shrinkage.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes < $1.bytes }

        var matched = 0
        var namedChanges: [CatalogSizeChange] = []
        let earlierCatalog = earlier.catalogReadings ?? [:]
        let laterCatalog = later.catalogReadings ?? [:]
        for (id, after) in laterCatalog {
            guard let before = earlierCatalog[id], before.scope == after.scope else { continue }
            matched += 1
            guard before.bytes != after.bytes else { continue }
            namedChanges.append(.init(id: id, title: after.title, bucket: after.bucket,
                                      before: before.bytes, after: after.bytes, scope: after.scope))
        }
        catalogCount = matched
        catalogUncomparedCount = Set(earlierCatalog.keys).union(laterCatalog.keys).count - matched
        catalogChanges = namedChanges.sorted { first, second in
            let (a, b) = (abs(first.bytes), abs(second.bytes))
            return a == b ? first.id < second.id : a > b
        }
    }
}

@MainActor @Observable
public final class ScanComparisonHistory {
    public private(set) var snapshots: [ScanComparisonSnapshot] = []
    public private(set) var problem: String?
    public private(set) var isSaving = false
    public var storageReadings: [StorageReading] {
        snapshots.compactMap { snapshot in
            guard let free = snapshot.free, let capacity = snapshot.capacity else { return nil }
            return StorageReading(date: snapshot.date, free: free, capacity: capacity, volume: snapshot.startupVolume)
        }
    }
    @ObservationIgnored private let file: URL
    private static let limit = 10

    func largestMeasuredGrowth(from baseline: StorageReading, to current: StorageReading) -> StorageAlert.FolderGrowth? {
        guard let volume = current.volume, baseline.volume == volume, baseline.capacity == current.capacity,
              baseline.date < current.date else { return nil }
        let window = baseline.date...current.date
        let eligible = snapshots.filter {
            window.contains($0.date) && $0.startupVolume == volume && $0.capacity == current.capacity && $0.free != nil
        }
        guard let later = eligible.first, later.homeVolume == volume,
              let earlier = eligible.last(where: { $0.date < later.date && $0.home == later.home && $0.homeVolume == volume })
        else { return nil }
        return largestMeasuredGrowth(earlier: earlier, later: later)
    }

    func baselineForRapidDrop(_ reading: StorageReading, minimumFree: Int64, since: Date) -> ScanComparisonSnapshot? {
        guard let volume = reading.volume else { return nil }
        return snapshots.first {
            $0.date >= since && $0.date < reading.date && $0.startupVolume == volume && $0.homeVolume == volume
                && $0.capacity == reading.capacity && $0.free.map { $0 >= minimumFree && $0 <= reading.capacity } == true
        }
    }

    func largestMeasuredGrowth(earlier: ScanComparisonSnapshot, later: ScanComparisonSnapshot) -> StorageAlert.FolderGrowth? {
        let comparison = ScanComparison(earlier: earlier, later: later)
        guard let freeChange = comparison.freeChange, freeChange < 0 else { return nil }
        if let catalog = comparison.catalogChanges.first(where: { $0.bytes > 0 && $0.scope.volume == later.startupVolume }),
           catalog.bytes >= (comparison.grew.first?.bytes ?? 0), let path = catalog.scope.measuredRoots.first {
            return .init(path: path, bytes: catalog.bytes, earlierScan: earlier.id, laterScan: later.id,
                         earlierDate: earlier.date, laterDate: later.date, catalogTitle: catalog.title)
        }
        guard let largest = comparison.grew.first else { return nil }
        // If a parent and child gained the same amount, show the more specific path.
        let change = comparison.grew.prefix { $0.bytes == largest.bytes }.max {
            $0.url.pathComponents.count < $1.url.pathComponents.count
        } ?? largest
        return .init(path: change.url.path, bytes: change.bytes, earlierScan: earlier.id, laterScan: later.id,
                     earlierDate: earlier.date, laterDate: later.date, catalogTitle: nil)
    }

    init(directory: URL) {
        file = directory.appendingPathComponent("scan-comparisons-v1.json")
        do {
            let stored = try JSONDecoder().decode([ScanComparisonSnapshot].self, from: Data(contentsOf: file))
            snapshots = Array(stored.sorted { $0.date > $1.date }.prefix(Self.limit))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First run.
        } catch {
            problem = "Andromeda couldn’t read the saved scans. A new scan can start a fresh history."
        }
    }

    func record(_ result: ScanResult, folders: [String: Int64], listedDirectories: [String: Set<String>],
                excluded: [URL], catalogFindings: [Finding]) async {
        isSaving = true
        defer { isSaving = false }
        let previous = Array(snapshots.prefix(Self.limit - 1))
        let file = file
        let (updated, saved) = await BackgroundWork.runNonThrowing("andromeda.scan.comparison") {
            let snapshot = ScanComparisonSnapshot(result: result, folders: folders,
                                                  listedDirectories: listedDirectories, excluded: excluded,
                                                  catalogFindings: catalogFindings)
            let updated = ([snapshot] + previous).sorted { $0.date > $1.date }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(updated).write(to: file, options: .atomic)
                return (updated, true)
            } catch {
                return (updated, false)
            }
        }
        snapshots = updated
        problem = saved ? nil : "Andromeda couldn’t save this scan for later. You can compare it during this session."
    }
}
