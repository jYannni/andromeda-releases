import AndromedaCore

public struct CleanupSector: Identifiable, Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case projectBuilds, appCaches, packageCaches, xcodeCaches, simulatorCaches, logs, mailDownloads
        case modelCaches, xcodeArchives, temporaryFiles, iosSimulators, androidEmulators, downloads, other

        fileprivate init(entryID: String) {
            switch entryID {
            case "xcode-derived-data": self = .projectBuilds
            case "browser-caches-chrome", "browser-code-sign-clones", "user-caches-other", "spotify-cache": self = .appCaches
            case "homebrew-cache", "package-manager-caches": self = .packageCaches
            case "xcode-caches": self = .xcodeCaches
            case "simulator-caches": self = .simulatorCaches
            case "user-diagnostic-reports", "user-logs": self = .logs
            case "mail-downloads": self = .mailDownloads
            case "ml-model-caches": self = .modelCaches
            case "xcode-archives": self = .xcodeArchives
            case "var-folders": self = .temporaryFiles
            case "simulator-runtimes", "simulator-unavailable-devices", "orphaned-simulator-runtimes": self = .iosSimulators
            case "android-emulator-data": self = .androidEmulators
            default: self = .other
            }
        }

        public var offersTrash: Bool {
            switch self {
            case .temporaryFiles, .iosSimulators, .androidEmulators, .downloads: false
            default: true
            }
        }
    }

    public let id: Kind
    public let rows: [ItemRow]
    /// Allocated disk usage, which can include shared APFS storage.
    public let bytes: Int64
    let isLowerBound: Bool

    public var sizeText: String {
        let size = ByteFormat.string(bytes)
        return Copy.Rows.uses(isLowerBound ? Copy.Rows.atLeast(size) : size)
    }
}

public struct CleanupSuggestions: Equatable, Sendable {
    public let safe: [CleanupSector]
    public let withCare: [CleanupSector]

    public var selectableRows: [ItemRow] {
        (safe + withCare).filter { $0.id.offersTrash }.flatMap(\.rows)
    }

    init(ranked: [(finding: Finding, row: ItemRow)], scan: ScanResult) {
        var safe: [CleanupSector.Kind: [Member]] = [:]
        var withCare: [CleanupSector.Kind: [Member]] = [:]
        for (finding, row) in ranked {
            guard let bytes = finding.bytes, bytes > 0 else { continue }
            let kind = CleanupSector.Kind(entryID: finding.id)
            let member = Member(row: row, bytes: bytes,
                                isLowerBound: !finding.unreadable.isEmpty || scan.rootMeasureTruncated.contains(finding.id))
            if !kind.offersTrash {
                withCare[kind, default: []].append(member)
            } else if case .trash = finding.entry.removal, row.selectable {
                switch row.verdictKind {
                case .safe: safe[kind, default: []].append(member)
                case .withCare: withCare[kind, default: []].append(member)
                default: break
                }
            }
        }

        self.safe = Self.sectors(safe).sorted(by: Self.largestFirst)
        var reviewSectors = Self.sectors(withCare)
        if let bytes = scan.downloadsBytes, bytes > 0 {
            reviewSectors.append(CleanupSector(id: .downloads, rows: [], bytes: bytes, isLowerBound: false))
        }
        self.withCare = reviewSectors.sorted(by: Self.largestFirst)
    }

    private struct Member {
        let row: ItemRow
        let bytes: Int64
        let isLowerBound: Bool
    }

    private static func sectors(_ groups: [CleanupSector.Kind: [Member]]) -> [CleanupSector] {
        groups.map { kind, members in
            CleanupSector(id: kind, rows: members.map(\.row), bytes: members.reduce(0) { $0 + $1.bytes },
                          isLowerBound: members.contains(where: \.isLowerBound))
        }
    }

    private static func largestFirst(_ a: CleanupSector, _ b: CleanupSector) -> Bool {
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        return Copy.Overview.cleanupSectorTitle(a.id) < Copy.Overview.cleanupSectorTitle(b.id)
    }
}
