import Foundation
import simd
import Synchronization

/// A read-only index of one category or a folder the user explicitly selected. Kept in memory
/// for the open browser only. Folder sizes are the sum of their indexed descendants.
public struct StorageBrowser: Sendable {
    public struct Root: Sendable {
        public enum Contents: Sendable { case item, children, homeDocuments, homeSystemData }
        public let url: URL
        public let contents: Contents
        fileprivate let mayBeMissing: Bool

        public init(_ url: URL, _ contents: Contents = .item, mayBeMissing: Bool = false) {
            self.url = url
            self.contents = contents
            self.mayBeMissing = mayBeMissing
        }
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: Int
        public let parent: Int?
        public let name: String
        public let path: String
        public let isFolder: Bool
        public let modified: Date?
        public let accessed: Date?
        let fileIdentity: FileIdentity?
        public fileprivate(set) var bytes: Int64
        /// Some entries underneath this folder could not be read.
        public fileprivate(set) var incomplete: Bool
        fileprivate var endOfSubtree: Int

        public var url: URL { URL(fileURLWithPath: path, isDirectory: isFolder) }
    }

    fileprivate struct IndexedEntry: Sendable {
        let name: String
        /// Relative to `sharedRoot` for a single root, absolute otherwise.
        let path: String
        var bytes: Int64
        var endOfSubtree: Int
        // Zero already denotes a missing inode in the directory listing. Keeping these fields
        // directly avoids the optional identity's padding in every retained row.
        let inode: ino_t
        private let modifiedSeconds: Double
        private let parentIndex: Int
        let device: dev_t
        let isFolder: Bool
        var incomplete: Bool

        init(name: String, path: String, bytes: Int64, endOfSubtree: Int, inode: ino_t, modified: Date?,
             isFolder: Bool, incomplete: Bool, device: dev_t, parent: Int?) {
            self.name = name
            self.path = path
            self.bytes = bytes
            self.endOfSubtree = endOfSubtree
            self.inode = inode
            modifiedSeconds = modified?.timeIntervalSinceReferenceDate ?? .nan
            parentIndex = parent ?? -1
            self.device = device
            self.isFolder = isFolder
            self.incomplete = incomplete
        }

        var fileIdentity: FileIdentity? { inode == 0 ? nil : FileIdentity(dev: device, ino: inode) }
        var modified: Date? { modifiedSeconds.isNaN ? nil : Date(timeIntervalSinceReferenceDate: modifiedSeconds) }
        var parent: Int? { parentIndex == -1 ? nil : parentIndex }

        func comesBefore(_ other: Self) -> Bool {
            bytes == other.bytes ? path < other.path : bytes > other.bytes
        }
    }

    public struct Query: Equatable, Sendable {
        public enum Kind: String, CaseIterable, Sendable {
            case all = "Files and folders"
            case files = "Files only"
            case folders = "Folders only"
            case installers = "Installer files"
        }

        public var folder: Int?
        public var text = ""
        public var kind: Kind = .all
        public var minimumBytes: Int64 = 0
        public var modifiedBefore: Date?
        public var accessedBefore: Date?

        public init() {}
    }

    public struct Matches: Sendable {
        public let entries: [Entry]
        public let hasMore: Bool
        public let textMatchBytes: Int64?
        public let textMatchCount: Int?

        fileprivate init(entries: [Entry], hasMore: Bool, textMatchBytes: Int64? = nil, textMatchCount: Int? = nil) {
            self.entries = entries
            self.hasMore = hasMore
            self.textMatchBytes = textMatchBytes
            self.textMatchCount = textMatchCount
        }
    }

    public struct MapContents: Sendable {
        public let entries: [Entry]
        public let smallerBytes: Int64
    }

    /// A saved folder must still refer to the same directory when reopened.
    public struct FolderReference: Codable, Equatable, Hashable, Sendable {
        public let url: URL
        fileprivate let resolvedPath: String
        fileprivate let volume: String?
        fileprivate let device: dev_t
        fileprivate let inode: ino_t

        public func isCurrent() -> Bool {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_flags & UInt32(SF_DATALESS) == 0, info.st_ino == inode,
                  url.resolvingSymlinksInPath().path == resolvedPath else { return false }
            if let volume { return StorageBrowser.volumeID(url) == volume }
            return info.st_dev == device
        }
    }

    private let entries: [IndexedEntry]
    // Aligned to the index, with NaN for rows without an access date. Absent on ordinary scans.
    private let accessTimes: [Double]?
    private let sharedRoot: String?
    private let bySize: [Int]
    private let children: [Int?: [Int]]
    private let rootBytes: Int64
    private let pathCandidates = PathCandidateCache()
    private static let maximumLocalSearchEntries = 512
    public let unreadable: [String]
    public var includesAccessTime: Bool { accessTimes != nil }

    private init(entries: [IndexedEntry], unreadable: Set<String>, sharedRoot: String? = nil,
                 accessTimes: [Double]? = nil) {
        self.entries = entries
        self.accessTimes = accessTimes
        self.sharedRoot = sharedRoot
        bySize = entries.indices.sorted { entries[$0].comesBefore(entries[$1]) }
        children = Dictionary(grouping: bySize) { entries[$0].parent }
        rootBytes = children[nil, default: []].reduce(0) { $0 + entries[$1].bytes }
        self.unreadable = unreadable.sorted()
    }

    public static func unavailable(_ folder: URL) -> Self {
        Self(entries: [], unreadable: [folder.path])
    }

    public struct CatalogSnapshot: Sendable {
        fileprivate let entries: [IndexedEntry]
        fileprivate let identities: [CatalogFileIdentity?]?
        public let unreadable: [String]
        public fileprivate(set) var folderPath: String? = nil
        public fileprivate(set) var folderIdentity: CatalogFileIdentity? = nil

        public static func unavailable(_ root: URL) -> Self { .init(entries: [], identities: nil, unreadable: [root.path]) }
        public var hasFileIdentities: Bool { identities != nil }

        public func forEachEntry(_ visit: (String, Bool, Int64, Date?, FileIdentity?) throws -> Void) rethrows {
            for item in entries where !item.path.isEmpty {
                let path = folderPath.map { $0 + "/" + item.path } ?? item.path
                try visit(path, item.isFolder, item.bytes, item.modified, item.fileIdentity)
            }
        }

        public func forEachCatalogEntry(_ visit: (String, Bool, Int64, Date?, CatalogFileIdentity?) throws -> Void) rethrows {
            for (index, item) in entries.enumerated() where !item.path.isEmpty {
                let path = folderPath.map { $0 + "/" + item.path } ?? item.path
                try visit(path, item.isFolder, item.bytes, item.modified, identities?[index])
            }
        }
    }

    private func absolutePath(_ path: String) -> String {
        guard let sharedRoot else { return path }
        if path.isEmpty { return sharedRoot }
        return sharedRoot == "/" ? "/" + path : sharedRoot + "/" + path
    }

    private func entry(at id: Int, absolutePath: String? = nil) -> Entry {
        let item = entries[id]
        let accessed = accessTimes?[id] ?? .nan
        return Entry(id: id, parent: item.parent, name: item.name, path: absolutePath ?? self.absolutePath(item.path),
                     isFolder: item.isFolder, modified: item.modified,
                     accessed: accessed.isNaN ? nil : Date(timeIntervalSinceReferenceDate: accessed),
                     fileIdentity: item.fileIdentity,
                     bytes: item.bytes, incomplete: item.incomplete, endOfSubtree: item.endOfSubtree)
    }

    public func breadcrumbs(to folder: Int?) -> [Entry] {
        var result: [Entry] = []
        var current = folder
        while let id = current, entries.indices.contains(id) {
            let entry = entry(at: id)
            result.append(entry)
            current = entry.parent
        }
        return result.reversed()
    }

    /// Resolves saved navigation against a fresh scan. Index IDs can change on every walk.
    public func restoreFolder(from trail: [Entry]) -> Int? {
        var parent: Int?
        for saved in trail {
            guard saved.isFolder, let identity = saved.fileIdentity,
                  let match = children[parent, default: []].first(where: { id in
                      let item = entries[id]
                      return item.isFolder && item.fileIdentity == identity && absolutePath(item.path) == saved.path
                  }) else { break }
            parent = match
        }
        return parent
    }

    /// Finds a pinned descendant in this scan without reading the folder's contents again.
    public func indexedTrail(to reference: FolderReference) -> [Entry]? {
        guard let sharedRoot else { return nil }
        let prefix = sharedRoot == "/" ? "/" : sharedRoot + "/"
        let path = reference.url.path
        guard path.utf8.starts(with: prefix.utf8) else { return nil }

        var parent: Int?
        let relative = String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        for component in relative.split(separator: "/") {
            guard let match = children[parent, default: []].first(where: { id in
                entries[id].isFolder && entries[id].name.utf8.elementsEqual(component.utf8)
            }) else { return nil }
            parent = match
        }
        guard let parent, entries[parent].path.utf8.elementsEqual(relative.utf8),
              let identity = entries[parent].fileIdentity,
              identity.ino == reference.inode, reference.isCurrent(),
              FileIdentity(path: path) == identity else { return nil }
        return breadcrumbs(to: parent)
    }

    public func map(in folder: Int?, limit: Int = 18) -> MapContents {
        if let folder, !entries.indices.contains(folder) || !entries[folder].isFolder {
            return MapContents(entries: [], smallerBytes: 0)
        }
        let visible = children[folder, default: []].prefix(max(0, limit)).prefix { entries[$0].bytes > 0 }
            .map { entry(at: $0) }
        let total = folder.map { entries[$0].bytes } ?? rootBytes
        let displayed = visible.reduce(0) { $0 + $1.bytes }
        return MapContents(entries: visible, smallerBytes: max(0, total - displayed))
    }

    public static func reference(for entry: Entry) -> FolderReference? {
        guard entry.isFolder, let identity = entry.fileIdentity else { return nil }
        return reference(forFolder: entry.url, matching: identity)
    }

    public static func reference(forFolder url: URL) -> FolderReference? {
        reference(forFolder: url, matching: nil)
    }

    private static func reference(forFolder url: URL, matching identity: FileIdentity?) -> FolderReference? {
        let url = url.standardizedFileURL
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        if let identity, info.st_dev != identity.dev || info.st_ino != identity.ino { return nil }
        let reference = FolderReference(
            url: url, resolvedPath: url.resolvingSymlinksInPath().path, volume: volumeID(url),
            device: info.st_dev, inode: info.st_ino)
        return reference.isCurrent() ? reference : nil
    }

    private static func volumeID(_ url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    public func matches(_ query: Query, limit: Int, control: ScanControl? = nil) -> Matches {
        if control?.isCancelled == true { return Matches(entries: [], hasMore: false) }
        if let folder = query.folder, !entries.indices.contains(folder) {
            return Matches(entries: [], hasMore: false)
        }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessCutoff = query.accessedBefore?.timeIntervalSinceReferenceDate
        if accessCutoff != nil && accessTimes == nil { return Matches(entries: [], hasMore: false) }
        let filtered = !text.isEmpty || query.kind != .all || query.minimumBytes > 0
            || query.modifiedBefore != nil || accessCutoff != nil
        var matches: [Entry] = []
        var textMatches: [Int] = []
        var hasMore = false
        func consider(_ id: Int) -> Bool {
            if control?.isCancelled == true { return false }
            let entry = entries[id]
            if entry.bytes < query.minimumBytes { return false } // largest first
            if filtered, let folder = query.folder, id <= folder || id >= entries[folder].endOfSubtree { return true }
            switch query.kind {
            case .all: break
            case .files: if entry.isFolder { return true }
            case .folders: if !entry.isFolder { return true }
            case .installers:
                guard !entry.isFolder else { return true }
                guard Self.isInstallerName(entry.name) else { return true }
            }
            if let cutoff = query.modifiedBefore, entry.modified.map({ $0 <= cutoff }) != true { return true }
            if let accessCutoff, !((accessTimes?[id] ?? .nan) <= accessCutoff) { return true }
            let path = absolutePath(entry.path)
            if !text.isEmpty, !path.localizedStandardContains(text) { return true }
            if !text.isEmpty { textMatches.append(id) }
            if matches.count >= max(0, limit) {
                hasMore = true
                return !text.isEmpty
            }
            matches.append(self.entry(at: id, absolutePath: path))
            return true
        }
        if filtered, let folder = query.folder,
           entries[folder].endOfSubtree - (folder + 1) <= Self.maximumLocalSearchEntries {
            // A small subtree is cheaper to order on demand than to walk or prepare the full index.
            let descendants = (folder + 1)..<entries[folder].endOfSubtree
            for id in descendants.sorted(by: { entries[$0].comesBefore(entries[$1]) }) {
                if !consider(id) { break }
            }
        } else if ASCIIPathCandidates.canIndex(text),
           let candidates = pathCandidates.prepare(entries: entries, order: bySize, root: sharedRoot, control: control),
           let needle = candidates.needle(for: text) {
            candidates.visitMatches(needle) { consider(bySize[$0]) }
        } else {
            let candidates = filtered ? bySize : children[query.folder, default: []]
            for id in candidates {
                if !consider(id) { break }
            }
        }
        if text.isEmpty { return Matches(entries: matches, hasMore: hasMore) }
        // The index is stored in depth-first order. A matching folder already includes its
        // descendants, even when those descendants are matches on another page of results.
        var bytes: Int64 = 0
        var coveredThrough = 0
        for id in textMatches.sorted() where id >= coveredThrough {
            if control?.isCancelled == true { return Matches(entries: [], hasMore: false) }
            bytes += entries[id].bytes
            coveredThrough = entries[id].endOfSubtree
        }
        if control?.isCancelled == true { return Matches(entries: [], hasMore: false) }
        return Matches(entries: matches, hasMore: hasMore, textMatchBytes: bytes, textMatchCount: textMatches.count)
    }

    public static func scan(
        _ roots: [Root], excluding: [URL] = [], env: ScanEnvironment, canReadProtectedPaths: Bool,
        prepareTextSearch: Bool = true, includeAccessTime: Bool = false, control: ScanControl
    ) -> StorageBrowser {
        let sharedRoot = roots.count == 1 ? roots.first?.url.standardizedFileURL.path : nil
        let walk = walk(roots, excluding: excluding, env: env, canReadProtectedPaths: canReadProtectedPaths,
                        relativePaths: sharedRoot != nil, includeAccessTime: includeAccessTime,
                        prefetchSmallFolders: sharedRoot != nil, control: control)
        let browser = StorageBrowser(entries: control.isCancelled ? [] : walk.entries, unreadable: walk.unreadable,
                                     sharedRoot: sharedRoot, accessTimes: control.isCancelled ? nil : walk.accessTimes)
        if prepareTextSearch {
            _ = browser.pathCandidates.prepare(entries: browser.entries, order: browser.bySize,
                                               root: sharedRoot, control: control)
        }
        return browser
    }

    /// Counts confirmed whole-clone data forks once within the selected local APFS folder.
    public static func analyzeWholeClones(
        in folder: FolderReference, excluding: [URL] = [], env: ScanEnvironment,
        canReadProtectedPaths: Bool, control: ScanControl
    ) -> WholeCloneAnalysis? {
        let path = folder.url.path
        guard !control.isCancelled, folder.isCurrent(),
              let identity = FileIdentity(path: path), identity.ino == folder.inode,
              DirectoryLister.localAPFSDevice(atPath: path, matching: identity) != nil else { return nil }
        let walk = walk([Root(folder.url, .children)], excluding: excluding, env: env,
                        canReadProtectedPaths: canReadProtectedPaths, relativePaths: true,
                        wholeClonesIn: identity, control: control)
        guard !control.isCancelled, walk.unreadable.isEmpty, let analysis = walk.wholeCloneAnalysis,
              folder.isCurrent(), FileIdentity(path: path) == identity else { return nil }
        return analysis
    }

    /// Walks a drive for the saved catalog without building the live browser's search or map indexes.
    public static func captureCatalog(
        _ root: URL, excluding: [URL], env: ScanEnvironment, canReadProtectedPaths: Bool, control: ScanControl,
        relativeTo driveRoot: URL? = nil
    ) -> CatalogSnapshot {
        let folderPath: String?
        if let driveRoot {
            let prefix = driveRoot.standardizedFileURL.path + "/"
            let path = root.standardizedFileURL.path
            guard path.hasPrefix(prefix), path.count > prefix.count else { return .unavailable(root) }
            folderPath = String(path.dropFirst(prefix.count))
        } else {
            folderPath = nil
        }
        var info = statfs()
        let isAPFS = statfs(root.path, &info) == 0 && withUnsafeBytes(of: info.f_fstypename) {
            $0.prefix { $0 != 0 }.elementsEqual("apfs".utf8)
        }
        var folder = stat()
        let folderIdentity: CatalogFileIdentity?
        if isAPFS, folderPath != nil, lstat(root.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR,
           folder.st_ino != 0, let birth = CatalogFileIdentity.timestamp(folder.st_birthtimespec) {
            folderIdentity = .init(inode: UInt64(folder.st_ino), birthTime: birth, singleLink: false)
        } else {
            folderIdentity = nil
        }
        let walk = walk([Root(root, .children)], excluding: excluding, env: env, canReadProtectedPaths: canReadProtectedPaths,
                        relativePaths: true, captureIdentities: isAPFS, control: control)
        if let folderIdentity, lstat(root.path, &folder) != 0 || folder.st_mode & S_IFMT != S_IFDIR
            || !folderIdentity.matches(folder) { return .unavailable(root) }
        return CatalogSnapshot(entries: control.isCancelled ? [] : walk.entries, identities: walk.catalogIdentities,
                               unreadable: walk.unreadable.sorted(), folderPath: folderPath, folderIdentity: folderIdentity)
    }

    private static func walk(
        _ roots: [Root], excluding: [URL], env: ScanEnvironment, canReadProtectedPaths: Bool,
        relativePaths: Bool, captureIdentities: Bool = false, includeAccessTime: Bool = false,
        prefetchSmallFolders: Bool = false, wholeClonesIn: FileIdentity? = nil, control: ScanControl
    ) -> (entries: [IndexedEntry], unreadable: Set<String>, catalogIdentities: [CatalogFileIdentity?]?,
          accessTimes: [Double]?, wholeCloneAnalysis: WholeCloneAnalysis?) {
        let excluded = Set((excluding + [env.trash]).map { $0.standardizedFileURL.path })
        var excludedChildren: [String: Set<String>] = [:]
        for path in excluded where path != "/" {
            let location = path as NSString
            excludedChildren[location.deletingLastPathComponent, default: []].insert(location.lastPathComponent)
        }
        let excludedIdentities = Set(excluded.compactMap { path -> FileIdentity? in
            guard canReadProtectedPaths || !env.isPromptingPath(URL(fileURLWithPath: path, isDirectory: false))
            else { return nil }
            return FileIdentity(path: path)
        })
        var walk = Walk(
            env: env, canReadProtectedPaths: canReadProtectedPaths, control: control,
            excluded: excluded, excludedChildren: excludedChildren, excludedIdentities: excludedIdentities,
            homePath: env.home.standardizedFileURL.path,
            relativePaths: relativePaths, prefetchSmallFolders: prefetchSmallFolders,
            lister: DirectoryLister(includeModificationTime: wholeClonesIn == nil, includeCreationTime: captureIdentities,
                                    includeAccessTime: includeAccessTime,
                                    includeLinkCount: captureIdentities, includeCloneRefCount: false,
                                    includeWholeCloneMetadata: wholeClonesIn != nil),
            catalogIdentities: captureIdentities ? [] : nil, accessTimes: includeAccessTime ? [] : nil,
            wholeClones: wholeClonesIn.map(WholeCloneAccounting.init(root:)))
        var seen = Set<String>()
        for root in roots {
            let path = root.url.standardizedFileURL.path
            guard seen.insert(path).inserted, !control.isCancelled else { continue }
            if let wholeClonesIn, excluded.contains(path) || excludedIdentities.contains(wholeClonesIn) {
                walk.unreadable.insert(path)
                continue
            }
            walk.visitRoot(path, contents: root.contents, mayBeMissing: root.mayBeMissing)
        }
        return (walk.entries, walk.unreadable, walk.catalogIdentities, walk.accessTimes, walk.wholeClones?.analysis)
    }

    public static func isInstallerName(_ name: String) -> Bool {
        switch (name as NSString).pathExtension.lowercased() {
        case "dmg", "pkg", "mpkg": true
        default: false
        }
    }

    /// An inexpensive row-level check. The removal plan validates the file on disk.
    public static func canSelectInstaller(_ entry: Entry, home: URL) -> Bool {
        !entry.isFolder && isInstallerName(entry.name) && InstallerCleanup.isInDownloads(entry.url, home: home)
    }

    /// Origin is a display hint from local quarantine metadata. It does not establish trust or cleanup eligibility.
    public static let maximumDownloadOriginMatches = 1_000

    public static func isDownloadsFolder(_ folder: FolderReference, home: URL) -> Bool {
        let path = SafetyGuard.withoutSystemPathAlias(folder.url.standardizedFileURL.path)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL.path
        return path.utf8.elementsEqual(SafetyGuard.withoutSystemPathAlias(downloads).utf8)
    }

    public static func recordedDownloadApps(for entries: [Entry], in folder: FolderReference, home: URL,
                                            control: ScanControl) -> [Int: String] {
        guard !control.isCancelled, isDownloadsFolder(folder, home: home), folder.isCurrent() else { return [:] }
        let fd = open(folder.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_ino == folder.inode, info.st_dev == folder.device else { return [:] }
        let prefix = folder.url.path + "/"
        var result: [Int: String] = [:]
        for entry in entries.prefix(maximumDownloadOriginMatches) {
            guard !control.isCancelled else { return [:] }
            guard !entry.isFolder, !entry.incomplete, let identity = entry.fileIdentity,
                  identity.dev == folder.device, entry.path.utf8.starts(with: prefix.utf8) else { continue }
            let relativePath = entry.path.utf8.dropFirst(prefix.utf8.count)
            let components = String(decoding: relativePath, as: UTF8.self).split(separator: "/", omittingEmptySubsequences: false)
            result[entry.id] = recordedDownloadApp(components[...], in: fd, expected: identity)
        }
        return !control.isCancelled && folder.isCurrent() ? result : [:]
    }

    private static func recordedDownloadApp(_ components: ArraySlice<Substring>, in directory: Int32,
                                            expected: FileIdentity) -> String? {
        guard let component = components.first, !component.isEmpty, component != ".", component != ".." else { return nil }
        let name = String(component)
        if components.count > 1 {
            var link = stat()
            guard fstatat(directory, name, &link, AT_SYMLINK_NOFOLLOW) == 0,
                  link.st_mode & S_IFMT == S_IFDIR, link.st_dev == expected.dev,
                  link.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
            let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return nil }
            defer { close(child) }
            var info = stat()
            guard fstat(child, &info) == 0, info.st_dev == link.st_dev, info.st_ino == link.st_ino,
                  info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
            return recordedDownloadApp(components.dropFirst(), in: child, expected: expected)
        }
        // Open for metadata only. Neither following links nor opening the data fork is necessary.
        let file = openat(directory, name, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0,
              FileIdentity(dev: info.st_dev, ino: info.st_ino) == expected else { return nil }
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = buffer.withUnsafeMutableBytes {
            fgetxattr(file, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }
        var after = stat()
        guard count > 0, count <= buffer.count,
              fstatat(directory, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
              after.st_mode & S_IFMT == S_IFREG,
              after.st_dev == info.st_dev, after.st_ino == info.st_ino,
              after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { return nil }
        return quarantineAgent(in: buffer.prefix(count))
    }

    private static func quarantineAgent(in bytes: ArraySlice<UInt8>) -> String? {
        // Local attribute format: flags;timestamp;agent;event ID. Only the agent is used.
        let fields = bytes.split(separator: 0x3b, maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count >= 3, !fields[0].isEmpty, fields[0].count <= 8,
              !fields[1].isEmpty, fields[1].count <= 16,
              UInt32(String(decoding: fields[0], as: UTF8.self), radix: 16) != nil,
              UInt64(String(decoding: fields[1], as: UTF8.self), radix: 16) != nil,
              fields[2].count <= 128, let raw = String(bytes: fields[2], encoding: .utf8),
              raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) &&
                  !CharacterSet.newlines.contains($0) && $0.properties.generalCategory != .format }) else { return nil }
        let app = raw.trimmingCharacters(in: .whitespaces)
        return app.isEmpty ? nil : app
    }

    /// Recheck at click time so a file that changed since the scan doesn't start a cloud download.
    public static func canPreview(_ entry: Entry) -> Bool {
        guard !entry.isFolder, let identity = entry.fileIdentity else { return false }
        return canPreview(entry.url, identity: identity)
    }

    static func canPreview(_ url: URL, identity: FileIdentity, expectedSize: Int64? = nil,
                           allowsAncestorLinks: Bool = true) -> Bool {
        var current = url
        var metadata = stat()
        guard lstat(current.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_flags & UInt32(SF_DATALESS) == 0,
              identity == FileIdentity(dev: metadata.st_dev, ino: metadata.st_ino),
              expectedSize.map({ $0 == metadata.st_size }) ?? true else { return false }
        current.deleteLastPathComponent()
        while current.path != "/" {
            let status = allowsAncestorLinks ? stat(current.path, &metadata) : lstat(current.path, &metadata)
            guard status == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_flags & UInt32(SF_DATALESS) == 0 else { return false }
            current.deleteLastPathComponent()
        }
        return true
    }
}

/// Map and folder browsing use the size index alone. Build the optional text index only when needed.
private final class PathCandidateCache: Sendable {
    private enum State: Sendable {
        case pending
        case prepared(ASCIIPathCandidates?)
    }

    private let state = Mutex<State>(.pending)

    func prepare(entries: [StorageBrowser.IndexedEntry], order: [Int], root: String?,
                 control: ScanControl?) -> ASCIIPathCandidates? {
        state.withLock { state in
            guard control?.isCancelled != true else { return nil }
            if case .prepared(let candidates) = state { return candidates }
            let candidates = ASCIIPathCandidates(entries: entries, order: order, root: root, control: control)
            // A query can be superseded while the user types. Let the next query retry an interrupted build.
            if candidates != nil || control?.isCancelled != true { state = .prepared(candidates) }
            return candidates
        }
    }
}

/// Quickly rejects paths that cannot contain a printable ASCII query. All candidates still use
/// Foundation for the actual comparison. Paths outside this index are always checked there.
private struct ASCIIPathCandidates: Sendable {
    private let bytes: [UInt8]
    private let prefix: [UInt8]
    // The byte budget below bounds both the offsets and the rank count.
    private let offsets: [UInt32]
    private let otherRanks: [UInt32]
    private let sampledByteCounts: [Int]
    private let sampleCount: Int

    private static var supportedLocale: Bool {
        let locale = Locale.current
        return locale.language.languageCode?.identifier == "en" && locale.collation == .standard
    }

    static func canIndex(_ text: String) -> Bool {
        !text.isEmpty && supportedLocale && text.utf8.allSatisfy(isPrintableASCII)
    }

    init?(entries: [StorageBrowser.IndexedEntry], order: [Int], root: String?, control: ScanControl?) {
        guard !order.isEmpty, Self.supportedLocale else { return nil }
        let budget = 16 * 1024 * 1024
        let budgetForOffsets = budget - 128 * MemoryLayout<Int>.stride
        guard order.count < budgetForOffsets / MemoryLayout<UInt32>.stride else { return nil }
        let tableBytes = (order.count + 1) * MemoryLayout<UInt32>.stride + 128 * MemoryLayout<Int>.stride
        var bytes: [UInt8] = []
        var offsets: [UInt32] = [0]
        var otherRanks: [UInt32] = []
        let directory = root.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""
        guard directory.utf8.allSatisfy(Self.isPrintableASCII) else { return nil }
        offsets.reserveCapacity(order.count + 1)
        for (rank, id) in order.enumerated() {
            if rank.isMultiple(of: 256), control?.isCancelled == true { return nil }
            var path = entries[id].path
            let indexed = path.withUTF8 { utf8 in
                guard !utf8.isEmpty, Self.hasOnlyPrintableASCII(utf8) else { return false }
                Self.appendFolded(utf8, to: &bytes)
                return true
            }
            if indexed {
                bytes.append(0)
            } else {
                otherRanks.append(UInt32(rank))
            }
            guard tableBytes + bytes.count + otherRanks.count * MemoryLayout<UInt32>.stride <= budget else {
                return nil
            }
            offsets.append(UInt32(bytes.count))
        }
        guard !bytes.isEmpty else { return nil }
        // This sample only chooses where to start checking for a match. Every match is verified.
        var sampledByteCounts = [Int](repeating: 0, count: 128)
        var sampleCount = 0
        for position in stride(from: 0, to: bytes.count, by: 31) {
            if sampleCount.isMultiple(of: 4096), control?.isCancelled == true { return nil }
            sampledByteCounts[Int(bytes[position])] += 1
            sampleCount += 1
        }
        self.bytes = bytes
        self.prefix = directory.utf8.map(Self.fold)
        self.offsets = offsets
        self.otherRanks = otherRanks
        self.sampledByteCounts = sampledByteCounts
        self.sampleCount = sampleCount
    }

    func needle(for text: String) -> [UInt8]? {
        let needle = text.utf8.map(Self.fold)
        if !prefix.isEmpty {
            // Use the complete paths for a query that could match inside the shared prefix or
            // across its boundary with an indexed suffix.
            if Data(prefix).range(of: Data(needle)) != nil { return nil }
            let overlap = min(needle.count - 1, prefix.count)
            if overlap > 0, (1...overlap).contains(where: { prefix.suffix($0).elementsEqual(needle.prefix($0)) }) {
                return nil
            }
        }
        return needle
    }

    private static func isPrintableASCII(_ byte: UInt8) -> Bool { (32...126).contains(byte) }
    private static func fold(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }

    private static func appendFolded(_ source: UnsafeBufferPointer<UInt8>, to bytes: inout [UInt8]) {
        let start = bytes.count
        bytes.append(contentsOf: source)
        bytes.withUnsafeMutableBufferPointer { buffer in
            let raw = UnsafeMutableRawBufferPointer(buffer)
            let lower = SIMD16<UInt8>(repeating: 65)
            let upper = SIMD16<UInt8>(repeating: 90)
            let toLowercase = SIMD16<UInt8>(repeating: 32)
            let width = MemoryLayout<SIMD16<UInt8>>.size
            var offset = start
            while offset <= buffer.count - width {
                let block = raw.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
                var folded = block
                folded.replace(with: block &+ toLowercase, where: (block .>= lower) .& (block .<= upper))
                withUnsafeBytes(of: &folded) {
                    raw.baseAddress!.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: width)
                }
                offset += width
            }
            for index in offset..<buffer.count { buffer[index] = fold(buffer[index]) }
        }
    }

    private static func hasOnlyPrintableASCII(_ path: UnsafeBufferPointer<UInt8>) -> Bool {
        let raw = UnsafeRawBufferPointer(path)
        let lower = SIMD16<UInt8>(repeating: 32)
        let upper = SIMD16<UInt8>(repeating: 126)
        let width = MemoryLayout<SIMD16<UInt8>>.size
        var offset = 0
        while offset <= path.count - width {
            let block = raw.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
            if any((block .< lower) .| (block .> upper)) { return false }
            offset += width
        }
        return path[offset...].allSatisfy(isPrintableASCII)
    }

    /// Visits candidates in the same descending-size order as the main index. NUL separates paths
    /// so a match cannot straddle two entries.
    func visitMatches(_ needle: [UInt8], _ visit: (Int) -> Bool) {
        bytes.withUnsafeBufferPointer { haystack in
            needle.withUnsafeBufferPointer { needle in
                guard let base = haystack.baseAddress, let query = needle.baseAddress else { return }
                func rareAnchor(using counts: [Int], below limit: Int) -> Int? {
                    needle.indices.min { counts[Int(needle[$0])] < counts[Int(needle[$1])] }
                        .flatMap { counts[Int(needle[$0])] < limit ? $0 : nil }
                }
                var anchor = rareAnchor(using: sampledByteCounts, below: sampleCount / 32)
                var recheckedAnchor = false
                func localAnchor(from start: Int) -> Int? {
                    let sampleLength = min(4096, haystack.count - start)
                    var counts = [Int](repeating: 0, count: 128)
                    for offset in start..<(start + sampleLength) { counts[Int(haystack[offset])] += 1 }
                    return rareAnchor(using: counts, below: max(1, sampleLength / 32))
                }
                func findWithMemmem(from start: Int) -> Int? {
                    memmem(base + start, haystack.count - start, query, needle.count)
                        .map { UnsafeRawPointer($0) - UnsafeRawPointer(base) }
                }
                func findMatch(from start: Int) -> Int? {
                    guard needle.count > 1 else { return findWithMemmem(from: start) }
                    var falseHits = 0
                    var sampleStart = start
                    var position = start
                    let lastStart = haystack.count - needle.count
                    while position <= lastStart {
                        guard let currentAnchor = anchor else { return findWithMemmem(from: position) }
                        guard let hit = memchr(base + position + currentAnchor, Int32(needle[currentAnchor]),
                                               lastStart - position + 1) else { return nil }
                        let candidate = UnsafeRawPointer(hit) - UnsafeRawPointer(base) - currentAnchor
                        if memcmp(base + candidate, query, needle.count) == 0 { return candidate }
                        position = candidate + 1
                        falseHits += 1
                        if falseHits == 256 {
                            // A selective byte can still have many false hits between distant matches.
                            // Resample only when those hits are dense enough to make the anchor costly.
                            if position - sampleStart < falseHits * 16 {
                                let replacement = recheckedAnchor ? nil : localAnchor(from: position)
                                anchor = replacement == currentAnchor ? nil : replacement
                                recheckedAnchor = true
                            }
                            falseHits = 0
                            sampleStart = position
                        }
                    }
                    return nil
                }
                var nextOther = 0
                func visitOtherRanks(before rank: Int) -> Bool {
                    while nextOther < otherRanks.count, Int(otherRanks[nextOther]) < rank {
                        guard visit(Int(otherRanks[nextOther])) else { return false }
                        nextOther += 1
                    }
                    return true
                }
                var cursor = 0
                var firstRank = 0
                while cursor < haystack.count {
                    guard let position = findMatch(from: cursor) else { break }
                    // Find the first path whose end follows the hit, skipping empty ranges.
                    var low = firstRank
                    var high = offsets.count - 1
                    while low < high {
                        let middle = (low + high) / 2
                        if Int(offsets[middle + 1]) <= position { low = middle + 1 }
                        else { high = middle }
                    }
                    guard visitOtherRanks(before: low), visit(low) else { return }
                    firstRank = low + 1
                    cursor = Int(offsets[firstRank])
                }
                _ = visitOtherRanks(before: offsets.count - 1)
            }
        }
    }
}

private extension StorageBrowser {
    struct Walk {
        let env: ScanEnvironment
        let canReadProtectedPaths: Bool
        let control: ScanControl
        let excluded: Set<String>
        let excludedChildren: [String: Set<String>]
        let excludedIdentities: Set<FileIdentity>
        let homePath: String
        let relativePaths: Bool
        let prefetchSmallFolders: Bool
        // The browser shows allocated bytes and modification dates. Cleanup reads clone information separately.
        let lister: DirectoryLister
        var catalogIdentities: [CatalogFileIdentity?]?
        var accessTimes: [Double]?
        var wholeClones: WholeCloneAccounting?
        var entries: [IndexedEntry] = []
        var unreadable: Set<String> = []
        // A single-root walk stays on its starting device. Multi-root scans may cross devices.
        var filesOnRoot: Set<ino_t> = []
        var filesAcrossRoots: Set<FileIdentity> = []
        var apfsPrefetchDevice: dev_t?

        mutating func visitRoot(_ path: String, contents: Root.Contents, mayBeMissing: Bool) {
            guard path != env.trash.standardizedFileURL.path else { return }
            guard canReadProtectedPaths || !env.isPromptingPath(URL(fileURLWithPath: path, isDirectory: false)) else {
                unreadable.insert(path)
                return
            }
            var info = stat()
            // Foundation can turn a selected /private/tmp into /tmp. Read the system's real
            // directory while keeping the indexed spelling and the no-follow policy for other links.
            let readPath = SafetyGuard.withoutSystemPathAlias(path)
            guard lstat(readPath, &info) == 0 else {
                if errno != ENOENT || !mayBeMissing { unreadable.insert(path) }
                return
            }
            guard info.st_flags & UInt32(SF_DATALESS) == 0 else { return }
            if let wholeClones, wholeClones.root != FileIdentity(dev: info.st_dev, ino: info.st_ino) {
                unreadable.insert(path)
                return
            }
            if contents == .item {
                let kind = info.st_mode & S_IFMT
                guard kind == S_IFREG || kind == S_IFDIR else { return }
                let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                                    + Double(info.st_mtimespec.tv_nsec) / 1e9)
                let accessTime = kind == S_IFREG && accessTimes != nil
                    ? DirectoryLister.accessTime(info.st_atimespec) : .nan
                visit(
                    folderPath: kind == S_IFDIR ? path : nil, storedPath: relativePaths ? "" : path,
                    name: (path as NSString).lastPathComponent, isFolder: kind == S_IFDIR,
                    modified: modified, accessTime: accessTime, allocated: Int64(info.st_blocks) * 512, inode: info.st_ino,
                    device: info.st_dev, parent: nil)
            } else if info.st_mode & S_IFMT == S_IFDIR {
                if relativePaths, prefetchSmallFolders, contents == .children, !control.isCancelled {
                    let identity = FileIdentity(dev: info.st_dev, ino: info.st_ino)
                    apfsPrefetchDevice = DirectoryLister.localAPFSDevice(atPath: path, matching: identity)
                }
                visitChildren(path, device: info.st_dev, parent: nil, contents: contents,
                              expectedIdentity: wholeClones?.root)
            }
        }

        mutating func visitChildren(
            _ path: String, device: dev_t, parent: Int?, contents: Root.Contents = .children,
            prefetched: [DirectoryEntry]? = nil, expectedIdentity: FileIdentity? = nil
        ) {
            guard !control.isCancelled else { return }
            let listingPath = SafetyGuard.withoutSystemPathAlias(path)
            guard let children = prefetched ?? lister.entries(atPath: listingPath, followAncestorLinks: expectedIdentity == nil,
                                                              expectedIdentity: expectedIdentity,
                                                              shouldContinue: { !control.isCancelled }) else {
                unreadable.insert(path)
                if let parent { entries[parent].incomplete = true }
                return
            }
            let absolutePrefix = path == "/" ? path : path + "/"
            let ancestor = parent.map { entries[$0].path } ?? ""
            let storedPrefix: String
            if relativePaths {
                storedPrefix = ancestor.isEmpty ? "" : ancestor + "/"
            } else {
                storedPrefix = absolutePrefix
            }
            let excludedNames = excludedChildren[path, default: []]
            let checkProtection = !canReadProtectedPaths && mayContainProtectedChildren(path)
            // Keep at most three levels of prefetched listings alive during depth-first traversal.
            let canPrefetch = prefetchSmallFolders && contents == .children && !checkProtection
                && ancestor.split(separator: "/", maxSplits: 2).count <= 2
                && children.lazy.filter { $0.type == VDIR.rawValue }.prefix(2).count == 2
            let groupSize = canPrefetch ? 16 : max(1, children.count)
            for start in stride(from: 0, to: children.count, by: groupSize) {
                let group = start..<min(start + groupSize, children.count)
                let listings = canPrefetch ? readAhead(children[group], prefix: absolutePrefix,
                                                       device: device, excludedNames: excludedNames) : [:]
                for index in group {
                    if control.isCancelled { return }
                    autoreleasepool {
                        visitChild(children[index], in: path, absolutePrefix: absolutePrefix, storedPrefix: storedPrefix,
                                   excludedNames: excludedNames, checkProtection: checkProtection,
                                   device: device, parent: parent, contents: contents, prefetched: listings[index])
                    }
                }
            }
        }

        private func readAhead(
            _ group: ArraySlice<DirectoryEntry>, prefix: String, device: dev_t, excludedNames: Set<String>
        ) -> [Int: [DirectoryEntry]] {
            let requests = group.indices.compactMap { index -> (Int, String, FileIdentity)? in
                let child = group[index]
                let identity = FileIdentity(dev: child.device, ino: ino_t(child.inode))
                guard child.error == 0, child.type == VDIR.rawValue, !child.name.isEmpty, child.inode != 0,
                      !child.isMountPoint, child.device == device, child.flags & UInt32(SF_DATALESS) == 0,
                      child.name != ".Trashes", !excludedNames.contains(child.name),
                      !excludedIdentities.contains(identity) else { return nil }
                return (index, prefix + child.name, identity)
            }
            guard requests.count >= 2, !control.isCancelled else { return [:] }
            let control = control
            let includeAccessTime = accessTimes != nil
            let apfsPrefetchDevice = apfsPrefetchDevice
            let results = Mutex<[Int: [DirectoryEntry]]>([:])
            DispatchQueue.concurrentPerform(iterations: 2) { worker in
                let reader = DirectoryLister(includeModificationTime: true, includeAccessTime: includeAccessTime,
                                             includeCloneRefCount: false, entryLimit: 512,
                                             apfsPrefetchDevice: apfsPrefetchDevice)
                for offset in stride(from: worker, to: requests.count, by: 2) {
                    if control.isCancelled { return }
                    let (index, path, identity) = requests[offset]
                    if let entries = reader.entries(atPath: path, expectedIdentity: identity,
                                                    shouldContinue: { !control.isCancelled }) {
                        results.withLock { $0[index] = entries }
                    }
                }
            }
            return results.withLock { $0 }
        }

        mutating func visitChild(
            _ child: DirectoryEntry, in path: String, absolutePrefix: String, storedPrefix: String,
            excludedNames: Set<String>, checkProtection: Bool, device: dev_t, parent: Int?, contents: Root.Contents,
            prefetched: [DirectoryEntry]?
        ) {
            if contents == .homeDocuments || contents == .homeSystemData {
                let isSystem = child.name.hasPrefix(".") || child.name.caseInsensitiveCompare("Library") == .orderedSame
                if isSystem != (contents == .homeSystemData) { return }
            }
            if excludedNames.contains(child.name) || (child.name.isEmpty && excluded.contains(path))
                || child.name == ".Trashes"
                || excludedIdentities.contains(FileIdentity(dev: child.device, ino: ino_t(child.inode))) { return }
            func absolutePath() -> String { child.name.isEmpty ? path : absolutePrefix + child.name }
            if (checkProtection && !child.name.isEmpty
                && env.isPromptingPath(URL(fileURLWithPath: absolutePath(), isDirectory: false))) || child.error != 0 {
                unreadable.insert(absolutePath())
                if let parent { entries[parent].incomplete = true }
                return
            }
            let isFolder = child.type == VDIR.rawValue
            guard (isFolder || child.type == VREG.rawValue), !child.isMountPoint, child.device == device,
                  child.flags & UInt32(SF_DATALESS) == 0 else { return }
            var allocated = child.allocated
            var accessTime = isFolder ? .nan : child.accessTime
            if !isFolder, allocated == nil {
                let childPath = absolutePath()
                var info = stat()
                guard lstat(childPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_dev == device,
                      info.st_flags & UInt32(SF_DATALESS) == 0,
                      wholeClones == nil || (child.inode != 0 && info.st_ino == child.inode) else {
                    unreadable.insert(childPath)
                    if let parent { entries[parent].incomplete = true }
                    return
                }
                allocated = Int64(info.st_blocks) * 512
                accessTime = accessTimes != nil && info.st_ino == child.inode
                    ? DirectoryLister.accessTime(info.st_atimespec) : .nan
            }
            let identity: CatalogFileIdentity?
            if !isFolder, child.inode != 0, let birth = child.birthTime, let links = child.linkCount, links > 0 {
                identity = .init(inode: child.inode, birthTime: birth, singleLink: links == 1)
            } else {
                identity = nil
            }
            let folderPath = isFolder ? absolutePath() : nil
            let listing: [DirectoryEntry]?
            if let prefetched, let folderPath,
               FileIdentity(path: folderPath) == FileIdentity(dev: child.device, ino: ino_t(child.inode)) {
                listing = prefetched
            } else {
                listing = nil
            }
            visit(
                folderPath: folderPath,
                storedPath: !relativePaths && child.name.isEmpty ? path : storedPrefix + child.name,
                name: child.name, isFolder: isFolder, modified: child.modified, accessTime: accessTime,
                allocated: allocated ?? 0, inode: ino_t(child.inode), device: device, parent: parent,
                catalogIdentity: identity, prefetched: listing, cloneEntry: !isFolder && wholeClones != nil ? child : nil)
        }

        private func mayContainProtectedChildren(_ path: String) -> Bool {
            guard homePath != "/" else { return false }
            if path == homePath { return true }
            guard path.hasPrefix(homePath + "/") else { return false }
            return path.dropFirst(homePath.count + 1).split(separator: "/", maxSplits: 2).count < 3
        }

        mutating func visit(
            folderPath: String?, storedPath: String, name: String, isFolder: Bool, modified: Date?, accessTime: Double,
            allocated: Int64,
            inode: ino_t, device: dev_t, parent: Int?, catalogIdentity: CatalogFileIdentity? = nil,
            prefetched: [DirectoryEntry]? = nil, cloneEntry: DirectoryEntry? = nil
        ) {
            let id = entries.count
            if let cloneEntry {
                let first = inode == 0 || filesOnRoot.insert(inode).inserted
                if first { wholeClones?.record(cloneEntry, allocated: max(0, allocated)) }
                return
            }
            let bytes: Int64
            if isFolder {
                bytes = 0
            } else if inode == 0 {
                bytes = max(0, allocated)
            } else {
                let first = relativePaths ? filesOnRoot.insert(inode).inserted
                    : filesAcrossRoots.insert(FileIdentity(dev: device, ino: inode)).inserted
                bytes = first ? max(0, allocated) : 0
            }
            entries.append(IndexedEntry(
                name: name, path: storedPath, bytes: bytes, endOfSubtree: id + 1,
                inode: inode, modified: modified, isFolder: isFolder, incomplete: false, device: device, parent: parent))
            catalogIdentities?.append(catalogIdentity)
            accessTimes?.append(accessTime)
            if let folderPath {
                if wholeClones != nil, inode == 0 {
                    unreadable.insert(folderPath)
                    entries[id].incomplete = true
                } else {
                    let identity = wholeClones == nil ? nil : FileIdentity(dev: device, ino: inode)
                    visitChildren(folderPath, device: device, parent: id, prefetched: prefetched, expectedIdentity: identity)
                }
                entries[id].endOfSubtree = entries.count
                if let parent {
                    entries[parent].bytes += entries[id].bytes
                    entries[parent].incomplete = entries[parent].incomplete || entries[id].incomplete
                }
            } else if let parent {
                entries[parent].bytes += bytes
            }
        }
    }
}
