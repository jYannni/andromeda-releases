import AndromedaCore
import Foundation

struct DriveScanSnapshot: Codable, Sendable {
    let name: String
    let date: Date
    let folders: [String: Int64]
    let hadUnreadableLocations: Bool?

    init(_ result: DriveScanResult) {
        name = result.volume.name
        date = result.finishedAt
        hadUnreadableLocations = !result.unreadable.isEmpty
        let largest = result.folderSizes.sorted { first, second in
            first.value == second.value ? first.key < second.key : first.value > second.value
        }.prefix(3_000)
        folders = Dictionary(uniqueKeysWithValues: largest.map { ($0.key, $0.value) })
    }
}

public struct DriveComparison: Sendable {
    public struct Change: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        public let before: Int64
        public let after: Int64
        public var bytes: Int64 { after - before }
    }

    public let baseline: Date?
    public let latest: Date
    public let comparedCount: Int
    public let changes: [Change]
    public let hasPartialScan: Bool

    init(latest: DriveScanSnapshot, baseline: DriveScanSnapshot?) {
        self.baseline = baseline?.date
        self.latest = latest.date
        hasPartialScan = latest.hadUnreadableLocations == true || baseline?.hadUnreadableLocations == true
        let pairs = latest.folders.compactMap { name, after -> Change? in
            guard let before = baseline?.folders[name], before >= 0, after >= 0 else { return nil }
            return Change(name: name, before: before, after: after)
        }
        comparedCount = pairs.count
        changes = pairs.filter { $0.bytes != 0 }.sorted {
            abs($0.bytes) == abs($1.bytes) ? $0.name < $1.name : abs($0.bytes) > abs($1.bytes)
        }
    }
}

/// Serializes complete snapshots from scans that can finish concurrently on different drives.
actor DriveComparisonWriter {
    private let file: URL
    private var writtenRevision = 0

    init(file: URL) { self.file = file }

    func save(_ snapshots: [String: [DriveScanSnapshot]], revision: Int) -> Bool {
        guard revision >= writtenRevision else { return true }
        writtenRevision = revision
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshots).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
