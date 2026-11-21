import AndromedaCore
import Foundation

/// Uses the same startup APFS container free-space reading as the storage overview.
struct CleanupSpaceMeter {
    struct Reading {
        let disk: FileIdentity
        let capacity: Int64
        let free: Int64
    }

    let deps: AppDependencies

    private var startupDisk: FileIdentity? { FileIdentity(path: deps.env.dataVolumeRoot.path) }

    func startupActions(_ plan: RemovalPlan) -> Set<UUID> {
        guard let disk = startupDisk else { return [] }
        return Set(plan.removals.compactMap { item in
            if case .moveToTrash(let url) = item.action, FileIdentity(path: url.path)?.dev != disk.dev { return nil }
            return item.id
        })
    }

    func read() -> Reading? {
        guard let disk = startupDisk, let usage = try? deps.volume.current(), startupDisk == disk,
              usage.containerCapacity > 0, (0...usage.containerCapacity).contains(usage.containerFree) else { return nil }
        return Reading(disk: disk, capacity: usage.containerCapacity, free: usage.containerFree)
    }

    func record(
        _ before: Reading?, batchID: UUID, operation: CleanupSpaceMeasurement.Operation, journal: Journal
    ) -> CleanupSpaceMeasurement? {
        guard let before, let after = read(), before.disk == after.disk, before.capacity == after.capacity,
              let result = CleanupSpaceMeasurement(batchID: batchID, operation: operation, before: before.free, after: after.free)
        else { return nil }
        try? journal.appendCleanupMeasurement(result)
        return result
    }

    func deleteFromTrash(batchID: UUID, journal: Journal) throws -> (
        deleted: [UUID], skipped: [(UUID, SkipReason)], measurement: CleanupSpaceMeasurement?
    ) {
        let trashPath = deps.env.trash.resolvingSymlinksInPath().path
        let before = startupDisk.map { FileIdentity(path: trashPath)?.dev == $0.dev } == true ? read() : nil
        let result = try TrashLedger(env: deps.env, journal: journal).permanentlyDelete(batchID: batchID)
        let measurement = result.deleted.isEmpty ? nil
            : record(before, batchID: batchID, operation: .permanentDeletion, journal: journal)
        return (result.deleted, result.skipped, measurement)
    }
}
