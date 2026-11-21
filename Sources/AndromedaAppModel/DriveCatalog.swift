import Darwin
import AndromedaCore
import AndromedaOrganize
import Foundation
import SQLite3

public struct DriveCatalogSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let savedAt: Date
    public let itemCount: Int
    public let unreadableCount: Int
    public let imagePreviewCount: Int?
    public let includesPDFPreviews: Bool
    public let includesVideoPreviews: Bool
    public let folderPath: String?
    let folderIdentity: CatalogFileIdentity?
}

public struct DriveCatalogMatch: Identifiable, Equatable, Sendable {
    public let driveID: String
    public let driveName: String
    public let relativePath: String
    public let isFolder: Bool
    public let bytes: Int64
    public let modified: Date?
    public let hasImagePreview: Bool
    public internal(set) var fileIdentity: CatalogFileIdentity? = nil
    public internal(set) var hasSavedVideoDetails = false
    public var hasPDFPreview: Bool { hasImagePreview && CatalogImagePreview.isPDF(relativePath) }
    public var hasVideoPreview: Bool { hasImagePreview && CatalogVideoPreview.supports(relativePath) }
    public var id: String { driveID + "/" + relativePath }
}

public struct DriveCatalogSearch: Sendable {
    public let matches: [DriveCatalogMatch]
    public let hasMore: Bool
}

public struct DriveCatalogFilters: Equatable, Sendable {
    public enum ItemType: Hashable, Codable, Sendable {
        case all, files, folders, kind(Kind)

        fileprivate var folderFlag: Int32? {
            switch self {
            case .all: nil
            case .folders: 1
            case .files, .kind: 0
            }
        }

        fileprivate var fileKind: Kind? {
            if case .kind(let kind) = self { return kind == .screenshots ? .images : kind }
            return nil
        }
    }

    public var itemType: ItemType = .all
    public var minimumAllocatedBytes: Int64 = 0
    public var modifiedSince: Date?
    public var requiresUHDVideo = false
    public var camera: String?
    public var videoCodec: String?
    public var minimumFrameRate: CatalogMinimumFrameRate = .any

    public init() {}

    public var isActive: Bool {
        itemType != .all || minimumAllocatedBytes > 0 || modifiedSince != nil || requiresUHDVideo
            || !trimmedCamera.isEmpty || !trimmedVideoCodec.isEmpty || minimumFrameRate != .any
    }
    fileprivate var trimmedCamera: String { (camera ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    fileprivate var trimmedVideoCodec: String { (videoCodec ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum StorageMinimumSize: Int64, CaseIterable, Identifiable, Codable, Sendable {
    case any = 0, oneMB = 1_000_000, tenMB = 10_000_000, hundredMB = 100_000_000, oneGB = 1_000_000_000
    public var id: Self { self }
    public var label: String { self == .any ? "Any size" : "At least \(ByteFormat.string(rawValue))" }
}

public enum CatalogMinimumFrameRate: Int32, CaseIterable, Identifiable, Codable, Sendable {
    case any = 0, fifty = 50, hundred = 100
    public var id: Self { self }
    public var label: String { self == .any ? "Any frame rate" : "At Least \(rawValue) fps" }
}

public struct DriveCatalogQuery: Equatable, Codable, Sendable {
    public enum Sort: String, CaseIterable, Codable, Sendable {
        case path, largest, recentlyModified

        public var label: String {
            switch self {
            case .path: "Drive and Path"
            case .largest: "Largest First"
            case .recentlyModified: "Recently Modified"
            }
        }

        fileprivate var sqlOrder: String {
            switch self {
            case .path: "path"
            case .largest: "bytes DESC, path"
            case .recentlyModified: "modified DESC, path"
            }
        }

        fileprivate func precedes(_ first: DriveCatalogMatch, _ second: DriveCatalogMatch) -> Bool {
            if self == .largest, first.bytes != second.bytes { return first.bytes > second.bytes }
            if self == .recentlyModified, first.modified != second.modified {
                guard let firstDate = first.modified else { return false }
                guard let secondDate = second.modified else { return true }
                return firstDate > secondDate
            }
            if !first.relativePath.utf8.elementsEqual(second.relativePath.utf8) {
                return first.relativePath.utf8.lexicographicallyPrecedes(second.relativePath.utf8)
            }
            return first.driveID < second.driveID
        }
    }

    public enum ModifiedWithin: Int, CaseIterable, Identifiable, Codable, Sendable {
        case any = 0, week = 7, month = 30, quarter = 90, year = 365
        public var id: Self { self }
        public var label: String { self == .any ? "Any date" : "Last \(rawValue) days" }
    }

    public var term = ""
    public var driveID: String?
    public var folderPath: String?
    public var itemType: DriveCatalogFilters.ItemType = .all
    public var minimumSize: StorageMinimumSize = .any
    public var modifiedWithin: ModifiedWithin = .any
    public var requiresUHDVideo: Bool?
    public var camera: String?
    public var videoCodec: String?
    public var minimumFrameRate: CatalogMinimumFrameRate?
    public var offlineOnly: Bool?
    public var sort: Sort?
    public var tag: String?
    public var collectionID: UUID?
    public var sortOrder: Sort { sort ?? .path }
    public var frameRateLimit: CatalogMinimumFrameRate { minimumFrameRate ?? .any }

    public init() {}

    public var hasCriteria: Bool { !trimmedTerm.isEmpty || hasFilters }
    public var hasFilters: Bool {
        driveID != nil || folderPath != nil || itemType != .all || minimumSize != .any || modifiedWithin != .any
            || hasVideoFilters || hasCameraFilter || offlineOnly == true || sortOrder != .path
            || hasTagFilter || collectionID != nil
    }
    public var hasVideoFilters: Bool { requiresUHDVideo == true || hasVideoCodecFilter || frameRateLimit != .any }
    public var hasCameraFilter: Bool { !(camera ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasVideoCodecFilter: Bool { !(videoCodec ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasTagFilter: Bool { !trimmedTag.isEmpty }
    var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedTag: String { (tag ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    // Catalog paths are matched as UTF-8 by SQLite's default binary collation.
    func catalogFolderSuffix(relativeTo folder: String) -> String? {
        guard let folderPath else { return nil }
        if folderPath.utf8.elementsEqual(folder.utf8) { return "" }
        guard folderPath.utf8.starts(with: (folder + "/").utf8) else { return nil }
        return String(decoding: folderPath.utf8.dropFirst(folder.utf8.count), as: UTF8.self)
    }

    func filters(now: Date, calendar: Calendar) -> DriveCatalogFilters {
        var filters = DriveCatalogFilters()
        filters.itemType = itemType
        filters.minimumAllocatedBytes = minimumSize.rawValue
        filters.requiresUHDVideo = requiresUHDVideo == true
        filters.camera = camera
        filters.videoCodec = videoCodec
        filters.minimumFrameRate = frameRateLimit
        if modifiedWithin != .any {
            filters.modifiedSince = calendar.date(byAdding: .day, value: -modifiedWithin.rawValue, to: now)
        }
        return filters
    }
}

public struct SavedDriveCatalogSearch: Identifiable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public let query: DriveCatalogQuery
}

public struct DriveCatalogCollection: Identifiable, Codable, Equatable, Sendable {
    public struct FileReference: Identifiable, Codable, Hashable, Sendable {
        public let driveID: String
        public let relativePath: String
        let bytes: Int64
        let modified: Date?
        let fileIdentity: CatalogFileIdentity?
        public var tracksMoves: Bool { fileIdentity?.singleLink == true }

        public var id: String {
            if let fileIdentity, fileIdentity.singleLink {
                return "\(driveID)/file/\(fileIdentity.inode)/\(fileIdentity.birthTime)"
            }
            return "\(driveID)/path/\(relativePath)"
        }

        init(_ match: DriveCatalogMatch) {
            driveID = match.driveID
            relativePath = match.relativePath
            bytes = match.bytes
            modified = match.modified
            fileIdentity = match.fileIdentity
        }

        func status(for match: DriveCatalogMatch) -> DriveCatalogCollectionItem.Status {
            if match.isFolder { return .changed(nil) }
            return match.bytes == bytes && match.modified == modified ? .current(match) : .changed(match)
        }
    }

    public let id: UUID
    public internal(set) var name: String
    public internal(set) var files: [FileReference]
    public internal(set) var parentID: UUID? = nil
}

public struct DriveCatalogCollectionItem: Identifiable, Sendable {
    public enum Status: Sendable { case current(DriveCatalogMatch), changed(DriveCatalogMatch?), missing, ambiguous }

    public let reference: DriveCatalogCollection.FileReference
    public let driveName: String?
    public let status: Status
    public var id: String { reference.id }
}

public struct DriveCatalogNote: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let reference: DriveCatalogCollection.FileReference
    public let driveName: String
    public internal(set) var text: String
    public internal(set) var tags: [String]

    func applies(to match: DriveCatalogMatch) -> Bool {
        guard !match.isFolder, match.driveID == reference.driveID else { return false }
        if let identity = reference.fileIdentity {
            guard let current = match.fileIdentity, identity.isSameFile(as: current) else { return false }
            return (identity.singleLink && current.singleLink) || reference.relativePath == match.relativePath
        }
        return reference.relativePath == match.relativePath && reference.bytes == match.bytes && reference.modified == match.modified
    }
}

public struct DriveCatalogNoteItem: Identifiable, Sendable {
    public let note: DriveCatalogNote
    public let driveName: String
    public let match: DriveCatalogMatch?
    public var id: UUID { note.id }

    init(note: DriveCatalogNote, item: DriveCatalogCollectionItem) {
        self.note = note
        driveName = item.driveName ?? note.driveName
        let candidate: DriveCatalogMatch?
        switch item.status {
        case .current(let match): candidate = match
        case .changed(let match): candidate = match
        case .missing, .ambiguous: candidate = nil
        }
        match = candidate.flatMap { note.applies(to: $0) ? $0 : nil }
    }
}

struct CatalogFileKey: Hashable, Sendable {
    let inode: Int64
    let birthTime: Int64

    init(_ identity: CatalogFileIdentity) {
        inode = Int64(bitPattern: identity.inode)
        birthTime = identity.birthTime
    }

    fileprivate init(inode: Int64, birthTime: Int64) {
        self.inode = inode
        self.birthTime = birthTime
    }
}

private struct CatalogFilePaths {
    var first: String?
    var second: String?

    mutating func add(_ path: String) {
        if first == nil { first = path }
        else if second == nil { second = path }
    }
}

private enum CatalogIdentityLookup {
    case none, allFiles, collections
}

struct DriveCatalogStore: Sendable {
    let directory: URL
    let trasher: any Trasher

    enum Failure: LocalizedError {
        case invalidDrive, unavailable, incomplete, missingItem, database

        var errorDescription: String? {
            switch self {
            case .invalidDrive: "This drive doesn’t have an identity Andromeda can save."
            case .unavailable: "Reconnect the original drive and try again."
            case .incomplete: "Andromeda kept the previous catalog because some locations couldn’t be read."
            case .missingItem: "This item is no longer available at its saved path. Refresh the catalog to search the current drive."
            case .database: "Andromeda couldn’t read or write the drive catalog."
            }
        }
    }

    static func supports(_ drive: ExternalVolume) -> Bool {
        drive.kind != .timeMachine && UUID(uuidString: drive.id) != nil
    }

    private func catalogURL(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw Failure.invalidDrive }
        return directory.appendingPathComponent(uuid.uuidString).appendingPathExtension("sqlite")
    }

    func summaries() -> [DriveCatalogSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard file.pathExtension == "sqlite", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let db = try? Database(file, write: false), let summary = try? db.summary(),
                  UUID(uuidString: summary.id) == id else { return nil }
            return summary
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func save(
        _ snapshot: StorageBrowser.CatalogSnapshot, for drive: ExternalVolume, includeImagePreviews: Bool = false,
        includePDFPreviews: Bool = false, videoPreviews: [String: SavedCatalogPreview]? = nil,
        videoDetails: [String: CatalogVideoDetails] = [:],
        collectionFiles: Set<CatalogFileKey> = [],
        control: ScanControl, isCurrent: () -> Bool
    ) throws -> DriveCatalogSummary {
        guard Self.supports(drive) else { throw Failure.invalidDrive }
        let root = drive.url.standardizedFileURL
        let folderPath = snapshot.folderPath
        if let folderPath, !Self.isRelativePath(folderPath) { throw Failure.unavailable }
        let scope = folderPath.map { root.appendingPathComponent($0).path } ?? root.path
        guard !snapshot.unreadable.contains(root.path), !snapshot.unreadable.contains(scope), isCurrent()
        else { throw Failure.unavailable }
        let target = try catalogURL(drive.id)
        if !snapshot.unreadable.isEmpty, FileManager.default.fileExists(atPath: target.path) { throw Failure.incomplete }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
        defer {
            if FileManager.default.fileExists(atPath: temporary.path) { _ = try? trasher.trash(temporary) }
        }
        let summary = try write(snapshot, for: drive, to: temporary, includeImagePreviews: includeImagePreviews,
                                includePDFPreviews: includePDFPreviews, videoPreviews: videoPreviews,
                                videoDetails: videoDetails,
                                collectionFiles: collectionFiles, folderPath: folderPath, control: control)
        guard chmod(temporary.path, 0o600) == 0 else { throw Failure.database }
        try Self.check(control)
        guard isCurrent() else { throw Failure.unavailable }
        try Self.check(control)
        guard rename(temporary.path, target.path) == 0 else { throw Failure.database }
        return summary
    }

    private func write(
        _ snapshot: StorageBrowser.CatalogSnapshot, for drive: ExternalVolume, to url: URL,
        includeImagePreviews: Bool, includePDFPreviews: Bool, videoPreviews: [String: SavedCatalogPreview]?,
        videoDetails: [String: CatalogVideoDetails],
        collectionFiles: Set<CatalogFileKey>, folderPath: String?, control: ScanControl
    ) throws -> DriveCatalogSummary {
        let db = try Database(url, write: true)
        if includeImagePreviews { try db.execute("PRAGMA auto_vacuum = FULL;") }
        let identityFields = snapshot.hasFileIdentities ? ", file_inode INTEGER, file_birth INTEGER, file_single INTEGER" : ""
        try db.execute("""
            CREATE TABLE catalog (id TEXT, name TEXT, saved REAL, items INTEGER, unreadable INTEGER);
            CREATE TABLE entries (path TEXT PRIMARY KEY, folded TEXT, folder INTEGER, bytes INTEGER, modified REAL\(identityFields)) WITHOUT ROWID;
            BEGIN;
            """)
        var count = 0
        var collectionPaths = Dictionary(uniqueKeysWithValues: collectionFiles.map { ($0, CatalogFilePaths()) })
        let identityParameters = snapshot.hasFileIdentities ? ", ?, ?, ?" : ""
        try db.withStatement("INSERT INTO entries VALUES (?, ?, ?, ?, ?\(identityParameters))") { row in
            try snapshot.forEachCatalogEntry { path, folder, bytes, modified, identity in
                try Self.check(control)
                try db.bind(path, at: 1, in: row)
                try db.bind(Self.searchKey(path), at: 2, in: row)
                sqlite3_bind_int(row, 3, folder ? 1 : 0)
                sqlite3_bind_int64(row, 4, bytes)
                if let modified { sqlite3_bind_double(row, 5, modified.timeIntervalSince1970) }
                if let identity {
                    sqlite3_bind_int64(row, 6, Int64(bitPattern: identity.inode))
                    sqlite3_bind_int64(row, 7, identity.birthTime)
                    sqlite3_bind_int(row, 8, identity.singleLink ? 1 : 0)
                    if !collectionPaths.isEmpty { collectionPaths[CatalogFileKey(identity)]?.add(path) }
                }
                guard sqlite3_step(row) == SQLITE_DONE else { throw Failure.database }
                sqlite3_reset(row)
                sqlite3_clear_bindings(row)
                count += 1
                control.file(bytes: 0)
            }
        }
        if snapshot.hasFileIdentities {
            try db.writeCollectionPaths(collectionPaths, control: control)
        }
        let includesPDFs = includeImagePreviews && includePDFPreviews
        let includesVideos = includeImagePreviews && videoPreviews != nil
        if includesPDFs { try db.execute("CREATE TABLE pdf_preview_opt_in (enabled INTEGER);") }
        if includesVideos { try db.execute("CREATE TABLE video_preview_opt_in (enabled INTEGER);") }
        if includesVideos && !videoDetails.isEmpty {
            try db.execute("CREATE TABLE catalog_video_details (path TEXT PRIMARY KEY, details BLOB NOT NULL) WITHOUT ROWID;")
            let encoder = JSONEncoder()
            try db.withStatement("INSERT INTO catalog_video_details VALUES (?, ?)") { row in
                for (path, details) in videoDetails {
                    try Self.check(control)
                    let data = try encoder.encode(details)
                    guard data.count <= CatalogImagePreview.maxDetailsBytes else { continue }
                    try db.bind(path, at: 1, in: row)
                    try db.bind(data, at: 2, in: row)
                    guard sqlite3_step(row) == SQLITE_DONE else { throw Failure.database }
                    sqlite3_reset(row)
                    sqlite3_clear_bindings(row)
                }
            }
        }
        let previews = includeImagePreviews
            ? try writePreviews(snapshot, drive: drive, db: db, includePDFs: includesPDFs,
                                videoPreviews: videoPreviews ?? [:], control: control)
            : nil
        let summary = DriveCatalogSummary(id: drive.id, name: drive.name, savedAt: Date(), itemCount: count,
                                          unreadableCount: snapshot.unreadable.count, imagePreviewCount: previews,
                                          includesPDFPreviews: includesPDFs, includesVideoPreviews: includesVideos,
                                          folderPath: folderPath, folderIdentity: snapshot.folderIdentity)
        if let folderPath {
            try db.execute("CREATE TABLE catalog_scope (path TEXT NOT NULL);")
            try db.withStatement("INSERT INTO catalog_scope VALUES (?)") { row in
                try db.bind(folderPath, at: 1, in: row)
                guard sqlite3_step(row) == SQLITE_DONE else { throw Failure.database }
            }
        }
        if let identity = snapshot.folderIdentity {
            try db.execute("CREATE TABLE catalog_scope_identity (file_inode INTEGER NOT NULL, file_birth INTEGER NOT NULL);")
            try db.withStatement("INSERT INTO catalog_scope_identity VALUES (?, ?)") { row in
                sqlite3_bind_int64(row, 1, Int64(bitPattern: identity.inode))
                sqlite3_bind_int64(row, 2, identity.birthTime)
                guard sqlite3_step(row) == SQLITE_DONE else { throw Failure.database }
            }
        }
        try db.withStatement("INSERT INTO catalog VALUES (?, ?, ?, ?, ?)") { row in
            try db.bind(summary.id, at: 1, in: row)
            try db.bind(summary.name, at: 2, in: row)
            sqlite3_bind_double(row, 3, summary.savedAt.timeIntervalSince1970)
            sqlite3_bind_int64(row, 4, Int64(count))
            sqlite3_bind_int64(row, 5, Int64(summary.unreadableCount))
            guard sqlite3_step(row) == SQLITE_DONE else { throw Failure.database }
        }
        if count >= 4 * CatalogPathFilter.blockSize { try db.buildPathFilters(control: control) }
        try db.execute("COMMIT;")
        return summary
    }

    private func writePreviews(
        _ snapshot: StorageBrowser.CatalogSnapshot, drive: ExternalVolume, db: Database,
        includePDFs: Bool, videoPreviews: [String: SavedCatalogPreview], control: ScanControl
    ) throws -> Int {
        let root = SafetyGuard.withoutSystemPathAlias(drive.url.standardizedFileURL.path)
        try db.execute("""
            CREATE TABLE image_previews (path TEXT PRIMARY KEY, jpeg BLOB NOT NULL, photo_details BLOB,
                                         video_details BLOB) WITHOUT ROWID;
            """)
        control.entry("Saved previews")
        control.flush()
        var remaining = CatalogImagePreview.catalogBudget
        var attempts = 0
        var count = 0
        let encoder = JSONEncoder()
        try db.withStatement("INSERT INTO image_previews VALUES (?, ?, ?, ?)") { row in
            try snapshot.forEachEntry { path, folder, _, modified, identity in
                try Self.check(control)
                guard !folder, remaining > 0 else { return }
                let preview: SavedCatalogPreview?
                if let video = videoPreviews[path] {
                    preview = video
                } else {
                    guard let modified, let identity, attempts < CatalogImagePreview.maxAttempts,
                          CatalogImagePreview.supports(path, includePDFs: includePDFs) else { return }
                    attempts += 1
                    preview = autoreleasepool {
                        CatalogImagePreview.make(at: root + "/" + path, identity: identity, modified: modified, control: control)
                    }
                }
                guard let preview else { return }
                func encode(_ value: (some Encodable)?) -> Data? {
                    guard let value, let data = try? encoder.encode(value),
                          data.count <= CatalogImagePreview.maxDetailsBytes else { return nil }
                    return data
                }
                let photo = encode(preview.photoDetails)
                let video = encode(preview.videoDetails)
                let cost = preview.jpeg.count + (photo?.count ?? 0) + (video?.count ?? 0)
                guard cost <= remaining else { return }
                try db.bind(path, at: 1, in: row)
                try db.bind(preview.jpeg, at: 2, in: row)
                if let photo { try db.bind(photo, at: 3, in: row) }
                if let video { try db.bind(video, at: 4, in: row) }
                guard sqlite3_step(row) == SQLITE_DONE else { throw Failure.database }
                sqlite3_reset(row)
                sqlite3_clear_bindings(row)
                remaining -= cost
                count += 1
            }
        }
        return count
    }

    func search(
        _ query: String, in catalogs: [DriveCatalogSummary], filters: DriveCatalogFilters = .init(),
        browse: Bool = false, folderPath: String? = nil, sort: DriveCatalogQuery.Sort = .path,
        matchingTagNotes: [DriveCatalogNote]? = nil,
        collectionMembers: [DriveCatalogCollection.FileReference]? = nil, control: ScanControl
    ) throws -> DriveCatalogSearch {
        let needle = Self.searchKey(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let scoped = matchingTagNotes != nil || collectionMembers != nil
        guard !needle.utf8.contains(0), !needle.isEmpty || browse || filters.isActive || scoped else {
            return .init(matches: [], hasMore: false)
        }
        if let folderPath, !Self.isRelativePath(folderPath) {
            return .init(matches: [], hasMore: false)
        }
        let limit = 100
        var matches: [DriveCatalogMatch] = []
        var omittedMatches = false
        let requiredBits = CatalogPathFilter.requiredBits(needle)
        let camera = filters.trimmedCamera.isEmpty ? nil : Self.searchKey(filters.trimmedCamera)
        let videoCodec = filters.trimmedVideoCodec.isEmpty ? nil : Self.searchKey(filters.trimmedVideoCodec)
        if let camera, camera.isEmpty || camera.utf8.contains(0) { return .init(matches: [], hasMore: false) }
        if let videoCodec, videoCodec.isEmpty || videoCodec.utf8.contains(0) { return .init(matches: [], hasMore: false) }
        let needsVideoDetails = filters.requiresUHDVideo || videoCodec != nil || filters.minimumFrameRate != .any
        let fileKind = filters.itemType.fileKind
        let notesByDrive = matchingTagNotes.map { Dictionary(grouping: $0, by: \.reference.driveID) }
        let membersByDrive = collectionMembers.map { Dictionary(grouping: $0, by: \.driveID) }
        var kindsByExtension: [String: Kind] = [:]
        for catalog in catalogs {
            try Self.check(control)
            let tagNotes = notesByDrive?[catalog.id]
            let members = membersByDrive?[catalog.id]
            if (notesByDrive != nil && tagNotes == nil) || (membersByDrive != nil && members == nil) { continue }
            if needsVideoDetails && !catalog.includesVideoPreviews { continue }
            if camera != nil && (catalog.imagePreviewCount ?? 0) == 0 { continue }
            let db = try Database(catalogURL(catalog.id), write: false)
            if needsVideoDetails || camera != nil || (catalog.imagePreviewCount ?? 0) > 0 || scoped {
                // Resolve saved references and read results from the same catalog snapshot.
                try db.execute("BEGIN;")
            }
            let scopedPaths: String?
            if scoped {
                let paths = try searchPaths(tagNotes: tagNotes, members: members, in: catalog, database: db, control: control)
                if paths.isEmpty { continue }
                scopedPaths = String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)
            } else {
                scopedPaths = nil
            }
            var videoDetailsSource: String?
            if needsVideoDetails || camera != nil {
                let details = try db.previewDetailsColumns()
                if needsVideoDetails {
                    if try db.hasTable("catalog_video_details") {
                        videoDetailsSource = "SELECT path, details FROM catalog_video_details"
                    } else if details.contains("video_details") {
                        videoDetailsSource = "SELECT path, video_details AS details FROM image_previews"
                    } else {
                        continue
                    }
                }
                if camera != nil && !details.contains("photo_details") { continue }
                if camera != nil || videoCodec != nil { try db.registerSearchFolding() }
            }
            let criteria = CatalogSearchCriteria(needle: needle, filters: filters, folderPath: folderPath,
                                                 camera: camera, videoCodec: videoCodec, videoDetailsSource: videoDetailsSource,
                                                 scopedPaths: scopedPaths)
            let columns = try db.catalogColumns(for: catalog, includeIdentity: db.hasFileIdentities())
            sqlite3_progress_handler(db.handle, 1_000, { pointer in
                guard let pointer else { return 0 }
                return Unmanaged<ScanControl>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 1 : 0
            }, Unmanaged.passUnretained(control).toOpaque())
            defer { sqlite3_progress_handler(db.handle, 0, nil, nil) }
            var rankedMatches: [DriveCatalogMatch] = []
            let scanRows = { (row: OpaquePointer) throws -> Bool in
                while true {
                    try Self.check(control)
                    switch sqlite3_step(row) {
                    case SQLITE_ROW:
                        let path = db.text(row, 0)
                        if let fileKind {
                            let ext = (path as NSString).pathExtension.lowercased()
                            let kind = kindsByExtension[ext] ?? KindClassifier.kind(forExtension: ext) ?? .other
                            if kindsByExtension.count < 256 { kindsByExtension[ext] = kind }
                            guard kind == fileKind else { continue }
                        }
                        if sort == .path {
                            if matches.count == limit { return true }
                            matches.append(db.catalogMatch(row, path: path, in: catalog))
                        } else {
                            if rankedMatches.count == limit { return true }
                            rankedMatches.append(db.catalogMatch(row, path: path, in: catalog))
                        }
                    case SQLITE_DONE: return false
                    default:
                        try Self.check(control)
                        throw Failure.database
                    }
                }
            }
            let more: Bool
            // File kinds are derived from saved names. Stop only after the requested number of qualifying rows.
            let remaining = { fileKind == nil ? limit + 1 - (sort == .path ? matches.count : 0) : -1 }
            if !scoped, sort == .path, folderPath == nil, !requiredBits.isEmpty, try db.hasPathFilters() {
                more = try db.searchPathFilters(requiredBits, criteria: criteria, columns: columns,
                                                limit: remaining, scanRows: scanRows)
            } else {
                let ranges: [(String, String)]?
                if !scoped, sort != .path, folderPath == nil, !requiredBits.isEmpty, try db.hasPathFilters() {
                    ranges = try db.selectivePathRanges(requiredBits)
                    if ranges?.isEmpty == true { continue }
                } else {
                    ranges = nil
                }
                let rangePredicate = ranges.map { ranges in
                    ranges.indices.map { "(path >= :lower\($0) AND path <= :upper\($0))" }.joined(separator: " OR ")
                }.map { " AND (\($0))" } ?? ""
                let predicate = criteria.predicate + rangePredicate
                let statement: String
                if sort == .recentlyModified, fileKind == nil, ranges == nil {
                    // Rank compact rows first. Only the winners need their saved identity and preview fields.
                    statement = """
                        SELECT \(columns) FROM (
                            SELECT path AS candidate_path FROM entries WHERE \(predicate)
                            ORDER BY \(sort.sqlOrder) LIMIT :limit
                        ) AS ranked CROSS JOIN entries ON path = candidate_path
                        ORDER BY \(sort.sqlOrder)
                        """
                } else {
                    statement = """
                        SELECT \(columns)
                        FROM entries WHERE \(predicate) ORDER BY \(sort.sqlOrder) LIMIT :limit
                        """
                }
                more = try db.withStatement(statement) { row in
                    try criteria.bind(in: row, database: db, limit: remaining())
                    for (index, range) in (ranges ?? []).enumerated() {
                        try db.bind(range.0, at: sqlite3_bind_parameter_index(row, ":lower\(index)"), in: row)
                        try db.bind(range.1, at: sqlite3_bind_parameter_index(row, ":upper\(index)"), in: row)
                    }
                    return try scanRows(row)
                }
            }
            if sort == .path {
                if more { return .init(matches: matches, hasMore: true) }
            } else {
                // Only a catalog's first 100 qualifying results can reach the global first 100.
                omittedMatches = omittedMatches || more || matches.count + rankedMatches.count > limit
                matches = Array((matches + rankedMatches).sorted(by: sort.precedes).prefix(limit))
            }
        }
        return .init(matches: matches, hasMore: omittedMatches)
    }

    private func searchPaths(
        tagNotes: [DriveCatalogNote]?, members: [DriveCatalogCollection.FileReference]?,
        in catalog: DriveCatalogSummary, database: Database, control: ScanControl
    ) throws -> [String] {
        let references = Set((tagNotes ?? []).map(\.reference) + (members ?? []))
        let items = try collectionItems(Array(references), in: catalog, database: database, control: control)
        let tagged = tagNotes?.compactMap { note in
            items[note.reference].flatMap { DriveCatalogNoteItem(note: note, item: $0).match?.relativePath }
        }
        guard let members else { return tagged ?? [] }
        let paths = members.compactMap { reference -> String? in
            guard case .current(let match) = items[reference]?.status else { return nil }
            return match.relativePath
        }
        guard let tagged else { return paths }
        // SQLite compares these paths byte by byte.
        let taggedKeys = Set(tagged.map { Data($0.utf8) })
        return paths.filter { taggedKeys.contains(Data($0.utf8)) }
    }

    func collectionItems(
        _ files: [DriveCatalogCollection.FileReference], in catalogs: [DriveCatalogSummary], control: ScanControl
    ) throws -> [DriveCatalogCollectionItem] {
        let byDrive = Dictionary(grouping: files, by: \.driveID)
        var results: [DriveCatalogCollection.FileReference: DriveCatalogCollectionItem] = [:]
        for catalog in catalogs {
            guard let references = byDrive[catalog.id] else { continue }
            try Self.check(control)
            let db = try Database(catalogURL(catalog.id), write: false)
            if (catalog.imagePreviewCount ?? 0) > 0 { try db.execute("BEGIN;") }
            results.merge(try collectionItems(references, in: catalog, database: db, control: control)) { _, current in current }
        }
        return files.map { results[$0] ?? .init(reference: $0, driveName: nil, status: .missing) }
    }

    private func collectionItems(
        _ references: [DriveCatalogCollection.FileReference], in catalog: DriveCatalogSummary,
        database db: Database, control: ScanControl
    ) throws -> [DriveCatalogCollection.FileReference: DriveCatalogCollectionItem] {
        let lookup = try db.identityLookup()
        let columns = try db.catalogColumns(for: catalog, includeIdentity: lookup != .none)
        var results: [DriveCatalogCollection.FileReference: DriveCatalogCollectionItem] = [:]
        var moved: [DriveCatalogCollection.FileReference] = []
        try db.withStatement("SELECT \(columns) FROM entries WHERE path = ?") { row in
            for reference in references {
                try Self.check(control)
                let exact = try db.match(at: reference.relativePath, in: catalog, using: row)
                let status: DriveCatalogCollectionItem.Status
                if let identity = reference.fileIdentity, exact?.fileIdentity?.isSameFile(as: identity) != true {
                    status = exact.map { .changed($0.isFolder ? nil : $0) } ?? .missing
                    if lookup != .none, identity.singleLink { moved.append(reference) }
                } else {
                    status = exact.map(reference.status) ?? .missing
                }
                results[reference] = .init(reference: reference, driveName: catalog.name, status: status)
            }
            if !moved.isEmpty {
                let keys = Set(moved.compactMap { $0.fileIdentity.map(CatalogFileKey.init) })
                let resolved = try db.movedPaths(for: keys, lookup: lookup, control: control)
                for reference in moved {
                    guard let identity = reference.fileIdentity,
                          let paths = resolved[CatalogFileKey(identity)], let first = paths.first else { continue }
                    try Self.check(control)
                    let status: DriveCatalogCollectionItem.Status
                    if paths.second != nil {
                        status = .ambiguous
                    } else {
                        guard let match = try db.match(at: first, in: catalog, using: row),
                              let actual = match.fileIdentity, actual.isSameFile(as: identity) else { throw Failure.database }
                        status = actual.singleLink ? reference.status(for: match) : .ambiguous
                    }
                    results[reference] = .init(reference: reference, driveName: catalog.name, status: status)
                }
            }
        }
        return results
    }

    func remove(_ id: String) throws {
        _ = try trasher.trash(catalogURL(id))
    }

    func removeImagePreviews(_ id: String) throws {
        let db = try Database(catalogURL(id), write: true)
        sqlite3_busy_timeout(db.handle, 1_500)
        try db.execute("""
            PRAGMA secure_delete = ON;
            BEGIN;
            DROP TABLE IF EXISTS image_previews;
            DROP TABLE IF EXISTS pdf_preview_opt_in;
            DROP TABLE IF EXISTS video_preview_opt_in;
            DROP TABLE IF EXISTS catalog_video_details;
            COMMIT;
            """)
    }

    func imagePreview(_ match: DriveCatalogMatch) throws -> SavedCatalogPreview? {
        let db = try Database(catalogURL(match.driveID), write: false)
        try db.execute("BEGIN;")
        guard try db.hasImagePreviews() else { return nil }
        if match.fileIdentity != nil, try !db.hasFileIdentities() { return nil }
        let identityCondition = match.fileIdentity == nil ? "" : " AND file_inode = ? AND file_birth = ?"
        let columns = try db.previewDetailsColumns()
        let photoDetails = columns.contains("photo_details") ? "photo_details" : "NULL"
        let videoDetails = columns.contains("video_details") ? "video_details" : "NULL"
        return try db.withStatement("""
            SELECT jpeg, \(photoDetails), \(videoDetails) FROM image_previews JOIN entries USING (path)
            WHERE path = ? AND modified IS ? AND bytes = ?\(identityCondition)
            """) { row in
            try db.bind(match.relativePath, at: 1, in: row)
            if let modified = match.modified { sqlite3_bind_double(row, 2, modified.timeIntervalSince1970) }
            sqlite3_bind_int64(row, 3, match.bytes)
            if let identity = match.fileIdentity {
                sqlite3_bind_int64(row, 4, Int64(bitPattern: identity.inode))
                sqlite3_bind_int64(row, 5, identity.birthTime)
            }
            switch sqlite3_step(row) {
            case SQLITE_DONE: return nil
            case SQLITE_ROW:
                let size = Int(sqlite3_column_bytes(row, 0))
                guard size > 0, size <= CatalogImagePreview.maxBytes,
                      let bytes = sqlite3_column_blob(row, 0) else { throw Failure.database }
                let jpeg = Data(bytes: bytes, count: size)
                func details<T: Decodable>(_ type: T.Type, at column: Int32) -> T? {
                    let count = Int(sqlite3_column_bytes(row, column))
                    guard (1...CatalogImagePreview.maxDetailsBytes).contains(count),
                          let bytes = sqlite3_column_blob(row, column) else { return nil }
                    return try? JSONDecoder().decode(type, from: Data(bytes: bytes, count: count))
                }
                return SavedCatalogPreview(jpeg: jpeg, photoDetails: details(CatalogPhotoDetails.self, at: 1),
                                           videoDetails: details(CatalogVideoDetails.self, at: 2))
            default: throw Failure.database
            }
        }
    }

    func videoDetails(_ match: DriveCatalogMatch) throws -> CatalogVideoDetails? {
        let db = try Database(catalogURL(match.driveID), write: false)
        try db.execute("BEGIN;")
        guard try db.hasTable("catalog_video_details") else { return nil }
        if match.fileIdentity != nil, try !db.hasFileIdentities() { return nil }
        let identity = match.fileIdentity == nil ? "" : " AND file_inode = ? AND file_birth = ?"
        return try db.withStatement("""
            SELECT details FROM catalog_video_details JOIN entries USING (path)
            WHERE path = ? AND modified IS ? AND bytes = ?\(identity)
            """) { row in
            try db.bind(match.relativePath, at: 1, in: row)
            if let modified = match.modified { sqlite3_bind_double(row, 2, modified.timeIntervalSince1970) }
            sqlite3_bind_int64(row, 3, match.bytes)
            if let identity = match.fileIdentity {
                sqlite3_bind_int64(row, 4, Int64(bitPattern: identity.inode))
                sqlite3_bind_int64(row, 5, identity.birthTime)
            }
            switch sqlite3_step(row) {
            case SQLITE_DONE: return nil
            case SQLITE_ROW:
                let count = Int(sqlite3_column_bytes(row, 0))
                guard (1...CatalogImagePreview.maxDetailsBytes).contains(count),
                      let bytes = sqlite3_column_blob(row, 0) else { return nil }
                return try? JSONDecoder().decode(CatalogVideoDetails.self, from: Data(bytes: bytes, count: count))
            default: throw Failure.database
            }
        }
    }

    static func resolve(_ match: DriveCatalogMatch, on drive: ExternalVolume, verifyingPathSnapshot: Bool = false,
                        isCurrent: () -> Bool) throws -> URL {
        guard supports(drive), match.driveID == drive.id, isCurrent() else { throw Failure.unavailable }
        guard isRelativePath(match.relativePath) else { throw Failure.missingItem }
        let root = drive.url.standardizedFileURL.path
        let physicalRoot = SafetyGuard.withoutSystemPathAlias(root)
        let path = physicalRoot + "/" + match.relativePath
        guard let identity = FileIdentity(path: physicalRoot) else { throw Failure.unavailable }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC | (match.isFolder ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw Failure.missingItem }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == identity.dev,
              info.st_mode & S_IFMT == (match.isFolder ? S_IFDIR : S_IFREG), info.st_flags & UInt32(SF_DATALESS) == 0,
              FileIdentity(path: path) == FileIdentity(dev: info.st_dev, ino: info.st_ino) else { throw Failure.missingItem }
        if let fileIdentity = match.fileIdentity {
            guard fileIdentity.matches(info) else { throw Failure.missingItem }
        }
        if verifyingPathSnapshot {
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
            guard match.modified == modified, match.bytes == Int64(info.st_blocks) * 512 else { throw Failure.missingItem }
        }
        guard isCurrent(), FileIdentity(path: physicalRoot) == identity else { throw Failure.unavailable }
        return URL(fileURLWithPath: root + "/" + match.relativePath, isDirectory: match.isFolder)
    }

    static func isRelativePath(_ path: String) -> Bool {
        path.components(separatedBy: "/").allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }
    }

    fileprivate static func searchKey(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func check(_ control: ScanControl) throws {
        if control.isCancelled { throw CancellationError() }
    }
}

/// A compact candidate filter for consecutive path ranges. It only rejects a range when one of
/// the UTF-8 trigrams required by the query is absent. SQLite checks the exact substring afterward.
private struct CatalogPathFilter {
    static let blockSize = 256
    private static let byteCount = 1_024
    private var bits = [UInt8](repeating: 0, count: byteCount)

    private static func trigrams(_ string: String, _ visit: (UInt32) -> Void) {
        var window: UInt32 = 0
        for (index, byte) in string.utf8.enumerated() {
            window = ((window << 8) | UInt32(byte)) & 0xFFFFFF
            if index >= 2 { visit(window) }
        }
    }

    private static func locations(_ trigram: UInt32) -> (Int, Int) {
        let hash = trigram &* 0x9e3779b1
        let mask = UInt32(byteCount * 8 - 1)
        return (Int(hash >> 19), Int((hash ^ (hash >> 13)) & mask))
    }

    static func requiredBits(_ string: String) -> [Int] {
        var bits: Set<Int> = []
        trigrams(string) { trigram in
            let (first, second) = locations(trigram)
            bits.insert(first)
            bits.insert(second)
        }
        return Array(bits)
    }

    mutating func insert(_ string: String) {
        Self.trigrams(string) { trigram in
            let (first, second) = Self.locations(trigram)
            bits[first / 8] |= 1 << (first % 8)
            bits[second / 8] |= 1 << (second % 8)
        }
    }

    func bind(to row: OpaquePointer, at index: Int32) throws {
        let result = bits.withUnsafeBytes {
            sqlite3_bind_blob(row, index, $0.baseAddress, Int32($0.count), Database.transient)
        }
        guard result == SQLITE_OK else { throw DriveCatalogStore.Failure.database }
    }

    static func mayContain(_ required: [Int], in row: OpaquePointer, at column: Int32) -> Bool {
        guard sqlite3_column_bytes(row, column) == byteCount, let blob = sqlite3_column_blob(row, column) else { return true }
        let bits = blob.assumingMemoryBound(to: UInt8.self)
        return required.allSatisfy { bits[$0 / 8] & (1 << ($0 % 8)) != 0 }
    }
}

private struct CatalogSearchCriteria {
    let needle: String
    let filters: DriveCatalogFilters
    let folderPath: String?
    let camera: String?
    let videoCodec: String?
    let videoDetailsSource: String?
    let scopedPaths: String?

    var predicate: String {
        var clauses: [String] = []
        if scopedPaths != nil { clauses.append("path IN (SELECT value FROM json_each(:scopedPaths))") }
        if folderPath != nil { clauses.append("path >= :folderStart AND path < :folderEnd") }
        if !needle.isEmpty { clauses.append("instr(folded, :needle) > 0") }
        if filters.itemType.folderFlag != nil { clauses.append("folder = :folder") }
        if filters.minimumAllocatedBytes > 0 { clauses.append("bytes >= :minimum") }
        if filters.modifiedSince != nil { clauses.append("modified >= :modified") }
        if camera != nil {
            clauses.append("""
                path IN (
                    SELECT path FROM (
                        SELECT path, CAST(photo_details AS TEXT) AS details FROM image_previews
                        WHERE photo_details IS NOT NULL AND length(photo_details) <= \(CatalogImagePreview.maxDetailsBytes)
                    )
                    WHERE CASE WHEN json_valid(details) THEN
                        json_type(details, '$.camera') = 'text'
                        AND instr(diskplain_search_key(json_extract(details, '$.camera')), :camera) > 0
                    ELSE 0 END
                )
                """)
        }
        var videoConditions: [String] = []
        if filters.requiresUHDVideo {
            videoConditions.append("""
                json_type(details, '$.width') = 'integer'
                AND json_type(details, '$.height') = 'integer'
                AND max(json_extract(details, '$.width'), json_extract(details, '$.height')) >= 3840
                AND min(json_extract(details, '$.width'), json_extract(details, '$.height')) >= 2160
                """)
        }
        if videoCodec != nil {
            videoConditions.append("""
                json_type(details, '$.codec') = 'text'
                AND instr(diskplain_search_key(json_extract(details, '$.codec')), :videoCodec) > 0
                """)
        }
        if filters.minimumFrameRate != .any {
            videoConditions.append("""
                json_type(details, '$.frameRate') IN ('integer', 'real')
                AND json_extract(details, '$.frameRate') BETWEEN :minimumFrameRate AND \(Double.greatestFiniteMagnitude)
                """)
        }
        if let videoDetailsSource, !videoConditions.isEmpty {
            // Cast the stored JSON bytes to text and ignore malformed metadata.
            clauses.append("""
                path IN (
                    SELECT path FROM (
                        SELECT path, CAST(details AS TEXT) AS details FROM (\(videoDetailsSource))
                        WHERE details IS NOT NULL AND length(details) <= \(CatalogImagePreview.maxDetailsBytes)
                    )
                    WHERE CASE WHEN json_valid(details) THEN \(videoConditions.joined(separator: " AND ")) ELSE 0 END
                )
                """)
        }
        return clauses.isEmpty ? "1" : clauses.joined(separator: " AND ")
    }

    func bind(in row: OpaquePointer, database: Database, limit: Int) throws {
        if let scopedPaths { try database.bind(scopedPaths, at: sqlite3_bind_parameter_index(row, ":scopedPaths"), in: row) }
        if let folderPath {
            // In the binary path index, `0` sorts immediately after the `/` separator.
            try database.bind(folderPath + "/", at: sqlite3_bind_parameter_index(row, ":folderStart"), in: row)
            try database.bind(folderPath + "0", at: sqlite3_bind_parameter_index(row, ":folderEnd"), in: row)
        }
        if !needle.isEmpty { try database.bind(needle, at: sqlite3_bind_parameter_index(row, ":needle"), in: row) }
        if let camera { try database.bind(camera, at: sqlite3_bind_parameter_index(row, ":camera"), in: row) }
        if let videoCodec { try database.bind(videoCodec, at: sqlite3_bind_parameter_index(row, ":videoCodec"), in: row) }
        if filters.minimumFrameRate != .any {
            sqlite3_bind_int(row, sqlite3_bind_parameter_index(row, ":minimumFrameRate"), filters.minimumFrameRate.rawValue)
        }
        if let flag = filters.itemType.folderFlag {
            sqlite3_bind_int(row, sqlite3_bind_parameter_index(row, ":folder"), flag)
        }
        if filters.minimumAllocatedBytes > 0 {
            sqlite3_bind_int64(row, sqlite3_bind_parameter_index(row, ":minimum"), filters.minimumAllocatedBytes)
        }
        if let modified = filters.modifiedSince {
            sqlite3_bind_double(row, sqlite3_bind_parameter_index(row, ":modified"), modified.timeIntervalSince1970)
        }
        sqlite3_bind_int(row, sqlite3_bind_parameter_index(row, ":limit"), Int32(limit))
    }
}

private final class Database {
    let handle: OpaquePointer
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ url: URL, write: Bool) throws {
        var connection: OpaquePointer?
        let flags = write ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        let path = SafetyGuard.withoutSystemPathAlias(url.path)
        guard sqlite3_open_v2(path, &connection, flags | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let connection else {
            sqlite3_close(connection)
            throw DriveCatalogStore.Failure.database
        }
        handle = connection
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw DriveCatalogStore.Failure.database }
    }

    func registerSearchFolding() throws {
        let result = sqlite3_create_function_v2(handle, "diskplain_search_key", 1,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_DIRECTONLY, nil, { context, _, arguments in
                guard let argument = arguments?[0], sqlite3_value_type(argument) == SQLITE_TEXT,
                      let text = sqlite3_value_text(argument) else {
                    sqlite3_result_null(context)
                    return
                }
                let length = Int(sqlite3_value_bytes(argument))
                let bytes = UnsafeBufferPointer(start: text, count: length)
                guard let label = String(validating: bytes, as: UTF8.self),
                      !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    sqlite3_result_null(context)
                    return
                }
                let key = DriveCatalogStore.searchKey(label)
                sqlite3_result_text(context, key, -1, Database.transient)
            }, nil, nil, nil)
        guard result == SQLITE_OK else { throw DriveCatalogStore.Failure.database }
    }

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw DriveCatalogStore.Failure.database
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    func bind(_ value: String, at index: Int32, in row: OpaquePointer) throws {
        guard sqlite3_bind_text(row, index, value, -1, Self.transient) == SQLITE_OK else { throw DriveCatalogStore.Failure.database }
    }

    func bind(_ value: Data, at index: Int32, in row: OpaquePointer) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(row, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
        guard result == SQLITE_OK else { throw DriveCatalogStore.Failure.database }
    }

    func text(_ row: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(row, index).map { String(cString: $0) } ?? ""
    }

    func summary() throws -> DriveCatalogSummary {
        try withStatement("SELECT id, name, saved, items, unreadable FROM catalog") { row in
            guard sqlite3_step(row) == SQLITE_ROW else { throw DriveCatalogStore.Failure.database }
            let previews = try imagePreviewCount()
            let includesPDFs = try previews != nil && hasTable("pdf_preview_opt_in")
            let includesVideos = try previews != nil && hasTable("video_preview_opt_in")
            let folderPath: String?
            if try hasTable("catalog_scope") {
                folderPath = try withStatement("SELECT path FROM catalog_scope") { scope in
                    guard sqlite3_step(scope) == SQLITE_ROW else { throw DriveCatalogStore.Failure.database }
                    let path = text(scope, 0)
                    guard DriveCatalogStore.isRelativePath(path) else { throw DriveCatalogStore.Failure.database }
                    return path
                }
            } else {
                folderPath = nil
            }
            let folderIdentity: CatalogFileIdentity?
            if folderPath != nil, try hasTable("catalog_scope_identity") {
                folderIdentity = try withStatement("SELECT file_inode, file_birth FROM catalog_scope_identity") { identity in
                    guard sqlite3_step(identity) == SQLITE_ROW else { throw DriveCatalogStore.Failure.database }
                    let inode = UInt64(bitPattern: sqlite3_column_int64(identity, 0))
                    let birth = sqlite3_column_int64(identity, 1)
                    guard inode != 0, birth != 0 else { throw DriveCatalogStore.Failure.database }
                    return .init(inode: inode, birthTime: birth, singleLink: false)
                }
            } else {
                folderIdentity = nil
            }
            return .init(id: text(row, 0), name: text(row, 1), savedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 2)),
                         itemCount: Int(sqlite3_column_int64(row, 3)), unreadableCount: Int(sqlite3_column_int64(row, 4)),
                         imagePreviewCount: previews,
                         includesPDFPreviews: includesPDFs, includesVideoPreviews: includesVideos,
                         folderPath: folderPath, folderIdentity: folderIdentity)
        }
    }

    func hasImagePreviews() throws -> Bool {
        try hasTable("image_previews")
    }

    func previewDetailsColumns() throws -> Set<String> {
        try withStatement("SELECT name FROM pragma_table_info('image_previews')") { row in
            var columns: Set<String> = []
            var step = sqlite3_step(row)
            while step == SQLITE_ROW {
                columns.insert(text(row, 0))
                step = sqlite3_step(row)
            }
            guard step == SQLITE_DONE else { throw DriveCatalogStore.Failure.database }
            return columns
        }
    }

    func hasFileIdentities() throws -> Bool {
        try identityLookup() != .none
    }

    func identityLookup() throws -> CatalogIdentityLookup {
        try withStatement("""
            SELECT name FROM sqlite_master WHERE (type = 'table' AND name = 'collection_identity_paths')
                OR (type = 'index' AND name = 'entries_identity') ORDER BY name LIMIT 1
            """) { row in
            switch sqlite3_step(row) {
            case SQLITE_ROW: return text(row, 0) == "collection_identity_paths" ? .collections : .allFiles
            case SQLITE_DONE: return .none
            default: throw DriveCatalogStore.Failure.database
            }
        }
    }

    func writeCollectionPaths(_ paths: [CatalogFileKey: CatalogFilePaths], control: ScanControl) throws {
        try execute("""
            CREATE TABLE collection_identity_paths (file_inode INTEGER, file_birth INTEGER, first_path TEXT,
                second_path TEXT, PRIMARY KEY (file_inode, file_birth)) WITHOUT ROWID;
            """)
        try withStatement("INSERT INTO collection_identity_paths VALUES (?, ?, ?, ?)") { row in
            for (identity, paths) in paths {
                if control.isCancelled { throw CancellationError() }
                sqlite3_bind_int64(row, 1, identity.inode)
                sqlite3_bind_int64(row, 2, identity.birthTime)
                if let first = paths.first { try bind(first, at: 3, in: row) }
                if let second = paths.second { try bind(second, at: 4, in: row) }
                guard sqlite3_step(row) == SQLITE_DONE else { throw DriveCatalogStore.Failure.database }
                sqlite3_reset(row)
                sqlite3_clear_bindings(row)
            }
        }
    }

    func withInterrupt<T>(_ control: ScanControl, _ operation: () throws -> T) throws -> T {
        sqlite3_progress_handler(handle, 1_000, { pointer in
            guard let pointer else { return 0 }
            return Unmanaged<ScanControl>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 1 : 0
        }, Unmanaged.passUnretained(control).toOpaque())
        defer { sqlite3_progress_handler(handle, 0, nil, nil) }
        return try operation()
    }

    func catalogColumns(for catalog: DriveCatalogSummary, includeIdentity: Bool) throws -> String {
        var preview = "0"
        if let count = catalog.imagePreviewCount, count > 0, try hasImagePreviews() {
            preview = "EXISTS (SELECT 1 FROM image_previews WHERE image_previews.path = entries.path)"
        }
        let identity = includeIdentity ? "file_inode, file_birth, file_single" : "NULL, NULL, NULL"
        let details = try catalog.includesVideoPreviews && hasTable("catalog_video_details")
            ? "EXISTS (SELECT 1 FROM catalog_video_details WHERE catalog_video_details.path = entries.path)" : "0"
        return "path, folder, bytes, modified, \(preview), \(identity), \(details)"
    }

    func catalogMatch(_ row: OpaquePointer, path: String, in catalog: DriveCatalogSummary) -> DriveCatalogMatch {
        let identity: CatalogFileIdentity? = sqlite3_column_type(row, 5) == SQLITE_NULL ? nil
            : .init(inode: UInt64(bitPattern: sqlite3_column_int64(row, 5)), birthTime: sqlite3_column_int64(row, 6),
                    singleLink: sqlite3_column_int(row, 7) == 1)
        return .init(driveID: catalog.id, driveName: catalog.name, relativePath: path,
              isFolder: sqlite3_column_int(row, 1) == 1, bytes: sqlite3_column_int64(row, 2),
              modified: sqlite3_column_type(row, 3) == SQLITE_NULL ? nil
                  : Date(timeIntervalSince1970: sqlite3_column_double(row, 3)),
              hasImagePreview: sqlite3_column_int(row, 4) == 1, fileIdentity: identity,
              hasSavedVideoDetails: sqlite3_column_int(row, 8) == 1)
    }

    func match(at path: String, in catalog: DriveCatalogSummary, using row: OpaquePointer) throws -> DriveCatalogMatch? {
        defer { sqlite3_reset(row); sqlite3_clear_bindings(row) }
        try bind(path, at: 1, in: row)
        switch sqlite3_step(row) {
        case SQLITE_ROW: return catalogMatch(row, path: text(row, 0), in: catalog)
        case SQLITE_DONE: return nil
        default: throw DriveCatalogStore.Failure.database
        }
    }

    func movedPaths(for keys: Set<CatalogFileKey>, lookup: CatalogIdentityLookup,
                    control: ScanControl) throws -> [CatalogFileKey: CatalogFilePaths] {
        let sql: String
        switch lookup {
        case .none: return [:]
        case .allFiles:
            sql = """
                WITH paths AS MATERIALIZED (
                    SELECT path FROM entries WHERE file_inode = ? AND file_birth = ? LIMIT 2
                )
                SELECT (SELECT path FROM paths LIMIT 1), (SELECT path FROM paths LIMIT 1 OFFSET 1)
                """
        case .collections:
            sql = "SELECT first_path, second_path FROM collection_identity_paths WHERE file_inode = ? AND file_birth = ?"
        }
        var paths: [CatalogFileKey: CatalogFilePaths] = [:]
        try withStatement(sql) { row in
            for key in keys {
                if control.isCancelled { throw CancellationError() }
                sqlite3_bind_int64(row, 1, key.inode)
                sqlite3_bind_int64(row, 2, key.birthTime)
                switch sqlite3_step(row) {
                case SQLITE_ROW:
                    let first = sqlite3_column_type(row, 0) == SQLITE_NULL ? nil : text(row, 0)
                    let second = sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : text(row, 1)
                    paths[key] = .init(first: first, second: second)
                case SQLITE_DONE: break
                default: throw DriveCatalogStore.Failure.database
                }
                sqlite3_reset(row)
                sqlite3_clear_bindings(row)
            }
        }
        // A collection can change during a refresh. Resolve all uncovered IDs in one pass.
        let uncovered = keys.subtracting(paths.keys)
        if !uncovered.isEmpty {
            try withInterrupt(control) {
                try withStatement("SELECT file_inode, file_birth, path FROM entries WHERE file_inode IS NOT NULL") { row in
                    var step = sqlite3_step(row)
                    while step == SQLITE_ROW {
                        let key = CatalogFileKey(inode: sqlite3_column_int64(row, 0), birthTime: sqlite3_column_int64(row, 1))
                        if uncovered.contains(key) { paths[key, default: .init()].add(text(row, 2)) }
                        step = sqlite3_step(row)
                    }
                    if control.isCancelled { throw CancellationError() }
                    guard step == SQLITE_DONE else { throw DriveCatalogStore.Failure.database }
                }
            }
        }
        return paths
    }

    func hasTable(_ name: String) throws -> Bool {
        try withStatement("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?") { row in
            try bind(name, at: 1, in: row)
            switch sqlite3_step(row) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw DriveCatalogStore.Failure.database
            }
        }
    }

    private func imagePreviewCount() throws -> Int? {
        guard try hasImagePreviews() else { return nil }
        return try withStatement("SELECT count(*) FROM image_previews") { row in
            guard sqlite3_step(row) == SQLITE_ROW else { throw DriveCatalogStore.Failure.database }
            return Int(sqlite3_column_int64(row, 0))
        }
    }

    func hasPathFilters() throws -> Bool {
        try withStatement("PRAGMA user_version;") { row in
            guard sqlite3_step(row) == SQLITE_ROW else { throw DriveCatalogStore.Failure.database }
            return sqlite3_column_int(row, 0) == 2
        }
    }

    func buildPathFilters(control: ScanControl) throws {
        try execute("CREATE TABLE path_filters (first_path TEXT NOT NULL, last_path TEXT NOT NULL, bits BLOB NOT NULL);")
        try withStatement("SELECT path, folded FROM entries ORDER BY path") { entries in
            try withStatement("INSERT INTO path_filters VALUES (?, ?, ?)") { output in
                var filter = CatalogPathFilter()
                var count = 0
                var first = "", last = ""
                func writeBlock() throws {
                    try bind(first, at: 1, in: output)
                    try bind(last, at: 2, in: output)
                    try filter.bind(to: output, at: 3)
                    guard sqlite3_step(output) == SQLITE_DONE else { throw DriveCatalogStore.Failure.database }
                    sqlite3_reset(output)
                    sqlite3_clear_bindings(output)
                    filter = CatalogPathFilter()
                    count = 0
                }
                while true {
                    if control.isCancelled { throw CancellationError() }
                    switch sqlite3_step(entries) {
                    case SQLITE_ROW:
                        last = text(entries, 0)
                        if count == 0 { first = last }
                        filter.insert(text(entries, 1))
                        count += 1
                        if count == CatalogPathFilter.blockSize { try writeBlock() }
                    case SQLITE_DONE:
                        if count != 0 { try writeBlock() }
                        return
                    default: throw DriveCatalogStore.Failure.database
                    }
                }
            }
        }
        try execute("PRAGMA user_version = 2;")
    }

    /// True matches must occur inside these ranges. Take the full scan path for broad queries.
    func selectivePathRanges(_ required: [Int]) throws -> [(String, String)]? {
        try withStatement("SELECT first_path, last_path, bits FROM path_filters ORDER BY rowid") { row in
            var ranges: [(String, String)] = []
            while true {
                switch sqlite3_step(row) {
                case SQLITE_ROW:
                    guard CatalogPathFilter.mayContain(required, in: row, at: 2) else { continue }
                    guard ranges.count < 16 else { return nil }
                    ranges.append((text(row, 0), text(row, 1)))
                case SQLITE_DONE: return ranges
                case SQLITE_INTERRUPT: throw CancellationError()
                default: throw DriveCatalogStore.Failure.database
                }
            }
        }
    }

    func searchPathFilters(
        _ required: [Int], criteria: CatalogSearchCriteria, columns: String,
        limit: () -> Int, scanRows: (OpaquePointer) throws -> Bool
    ) throws -> Bool {
        // The writer inserts filters in path order. The row ID keeps that order without a second index.
        try withStatement("SELECT first_path, last_path, bits FROM path_filters ORDER BY rowid") { ranges in
            try withStatement("""
                SELECT \(columns) FROM entries
                WHERE path >= ? AND path <= ? AND \(criteria.predicate) ORDER BY path LIMIT :limit
                """) { rows in
                var first = "", last = ""
                var consecutive = 0
                func scanRange() throws -> Bool {
                    guard consecutive > 0 else { return false }
                    defer { consecutive = 0; sqlite3_reset(rows); sqlite3_clear_bindings(rows) }
                    try bind(first, at: 1, in: rows)
                    try bind(last, at: 2, in: rows)
                    try criteria.bind(in: rows, database: self, limit: limit())
                    return try scanRows(rows)
                }
                while true {
                    switch sqlite3_step(ranges) {
                    case SQLITE_ROW:
                        if CatalogPathFilter.mayContain(required, in: ranges, at: 2) {
                            if consecutive == 0 { first = text(ranges, 0) }
                            last = text(ranges, 1)
                            consecutive += 1
                            if consecutive == 8, try scanRange() { return true }
                        } else if try scanRange() { return true }
                    case SQLITE_DONE: return try scanRange()
                    case SQLITE_INTERRUPT: throw CancellationError()
                    default: throw DriveCatalogStore.Failure.database
                    }
                }
            }
        }
    }
}
