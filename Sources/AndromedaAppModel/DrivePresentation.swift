import AndromedaCore
import Foundation

public struct DrivePage: Equatable, Sendable {
    public enum StorageScope: Equatable, Sendable {
        case fileSystem
        case apfsVolume
        case apfsContainer

        public init(volume: ExternalVolume) {
            if volume.apfsStorage != nil {
                self = .apfsContainer
            } else if volume.containerID != nil || volume.format.localizedCaseInsensitiveContains("APFS") {
                self = .apfsVolume
            } else {
                self = .fileSystem
            }
        }

        public var heading: String? {
            switch self {
            case .fileSystem: nil
            case .apfsVolume: "APFS Volume"
            case .apfsContainer: "APFS Container"
            }
        }
    }

    public struct APFSVolumeFigures: Equatable, Sendable {
        public let allocatedText: String
        public let availableText: String?
        public let quotaText: String?
        public let reserveText: String?
    }

    public let id: String
    public let title: String
    /// "Disk image" or "Time Machine backup disk"; nil for an ordinary drive.
    public let kindLabel: String?
    public let storageScope: StorageScope
    public let usedBytes: Int64?
    public var usedText: String? { usedBytes.map(ByteFormat.string) }
    public let capacityText: String
    public var ofCapacityText: String { Copy.Overview.ofCapacity(capacityText) }
    public let availableText: String
    public let usedFraction: Double
    public let apfsVolume: APFSVolumeFigures?
    public let formatText: String
    /// Folders macOS keeps at the top level. Trash is `.withCare` with a hand-off; the rest `.leaveIt`.
    public let hidden: [ItemRow]
    public let largeItems: [LargeItemRow]
    public let otherText: String?
    /// Read-only, Time Machine and mounted-inside-home notes.
    public let notes: [String]
    public let canOrganize: Bool
    /// Other currently mounted volumes identified in the same APFS container.
    public let sharesWith: [String]
}

/// Connection status shown alongside any saved scan comparison.
public struct DriveAbsentPage: Equatable, Sendable {
    /// The drive's name when it was last listed or scanned.
    public let name: String?
    /// "Last seen at …"; nil for one never listed this session.
    public let lastSeenText: String?
    /// "<name> was disconnected" when it went away during its scan.
    public let disconnectedNote: String?

    public init(name: String?, lastSeenText: String?, disconnectedNote: String?) {
        self.name = name
        self.lastSeenText = lastSeenText
        self.disconnectedNote = disconnectedNote
    }
}

enum DrivePresentation {
    static func page(
        _ v: ExternalVolume, result: DriveScanResult?, sharesWith: [String] = [], insideHome: Bool = false
    ) -> DrivePage {
        var notes: [String] = []
        if v.isReadOnly { notes.append(Copy.Drives.readOnlyNote) }
        if v.kind == .timeMachine { notes.append(Copy.Drives.timeMachineNote) }
        if insideHome && v.isOrganizable { notes.append(Copy.Drives.insideHomeNote) }
        let kindLabel: String? = switch v.kind {
        case .drive: nil
        case .diskImage: Copy.Drives.diskImage
        case .timeMachine: Copy.Drives.timeMachineDisk
        }
        let storageScope = DrivePage.StorageScope(volume: v)
        let capacity = v.apfsStorage?.containerCapacity ?? v.capacity
        let available = v.apfsStorage?.containerFree ?? v.available
        let used: Int64? = switch storageScope {
        case .fileSystem: v.used
        case .apfsVolume: nil
        case .apfsContainer: max(0, capacity - available)
        }
        let usedFraction = used.map { capacity > 0 ? min(1, max(0, Double($0) / Double(capacity))) : 0 } ?? 0
        let apfsVolume = v.apfsStorage.map { storage in
            let showAvailable = v.available != storage.containerFree || storage.quota != nil || storage.reserve != nil
            return DrivePage.APFSVolumeFigures(
                allocatedText: ByteFormat.string(storage.volumeUsed),
                availableText: showAvailable ? ByteFormat.string(max(0, v.available)) : nil,
                quotaText: storage.quota.map(ByteFormat.string),
                reserveText: storage.reserve.map(ByteFormat.string))
        }
        return DrivePage(
            id: v.id, title: v.name, kindLabel: kindLabel,
            storageScope: storageScope, usedBytes: used, capacityText: ByteFormat.string(capacity),
            availableText: Copy.Overview.available(ByteFormat.string(max(0, available))),
            usedFraction: usedFraction, apfsVolume: apfsVolume,
            formatText: v.format,
            hidden: (result?.hidden ?? []).map(hiddenRow),
            largeItems: (result?.largeItems ?? []).map { largeRow($0, volume: v) },
            otherText: result.map { Copy.Drives.otherFiles(ByteFormat.string($0.otherBytes)) },
            notes: notes, canOrganize: v.isOrganizable && !insideHome, sharesWith: sharesWith)
    }

    private static func hiddenRow(_ item: HiddenSpaceItem) -> ItemRow {
        let isTrash = item.kind == .trash
        let title: String, detail: String, afterwards: String, howRemoved: String
        switch item.kind {
        case .trash:
            (title, detail, afterwards, howRemoved) = (
                Copy.Drives.trashTitle, Copy.Drives.trashDetail, Copy.Drives.trashAfterwards,
                Copy.Drives.trashHowRemoved)
        case .spotlight:
            (title, detail, afterwards, howRemoved) = (
                Copy.Drives.spotlightTitle, Copy.Drives.spotlightDetail, Copy.Drives.spotlightAfterwards,
                Copy.Drives.spotlightHowRemoved)
        case .fsevents:
            (title, detail, afterwards, howRemoved) = (
                Copy.Drives.fseventsTitle, Copy.Drives.fseventsDetail, Copy.Drives.fseventsAfterwards,
                Copy.Drives.fseventsHowRemoved)
        case .versions:
            (title, detail, afterwards, howRemoved) = (
                Copy.Drives.versionsTitle, Copy.Drives.versionsDetail, Copy.Drives.versionsAfterwards,
                Copy.Drives.versionsHowRemoved)
        case .timeMachineBackups:
            (title, detail, afterwards, howRemoved) = (
                Copy.Drives.backupsTitle, Copy.Drives.backupsDetail, Copy.Drives.backupsAfterwards,
                Copy.Drives.backupsHowRemoved)
        }
        return ItemRow(
            id: item.kind.rawValue, title: title,
            detail: detail, afterwards: afterwards,
            sizeText: item.bytes.map(ByteFormat.string) ?? Copy.Drives.notMeasured,
            freesText: isTrash ? item.freesAtLeast.map { Copy.Rows.frees(ByteFormat.string($0)) } : nil,
            sharedNote: nil, commandSizeNote: nil,
            verdictLabel: isTrash ? Copy.Verdicts.withCare : Copy.Verdicts.leaveIt,
            verdictKind: isTrash ? .withCare : .leaveIt,
            howRemoved: howRemoved,
            selectable: false, startsSelected: false, notVerifiedNote: nil, toolMissingNote: nil,
            couldntCheck: false,
            betterAction: isTrash ? .handoff(instructions: Copy.Drives.trashHandoff, url: item.url) : .none,
            helperCanDoThis: false)
    }

    static func largeRow(_ item: LargeItem, volume: ExternalVolume) -> LargeItemRow {
        let mount = volume.url.standardizedFileURL.pathComponents
        let path = item.url.standardizedFileURL.pathComponents
        let shown = path.count > mount.count && Array(path.prefix(mount.count)) == mount
            ? ([volume.name] + path.dropFirst(mount.count)).joined(separator: "/")
            : item.url.path
        return LargeItemRow(
            id: item.url, name: item.url.lastPathComponent, path: shown,
            sizeText: ByteFormat.string(item.bytes), sharedNote: item.clonesPresent ? Copy.Rows.sharedNote : nil)
    }
}
