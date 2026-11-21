import AndromedaCore
import Foundation

/// A regular file that passed the guard and the project check, ready to be placed.
struct ScannedFile {
    let url: URL
    let name: String
    /// nil when the classifier can't tell what the file is.
    let kind: Kind?
    /// EXIF date for images and screenshots (never read from a dataless file).
    let date: Date?
    /// The file's creation time (`st_birthtimespec`).
    let birth: Date?
    let snapshot: ItemSnapshot
}

enum ScanResult {
    case refused(FolderPlanResult)
    case scanned(
        files: [ScannedFile], leftAlone: [LeftAlone], unsorted: [LeftAlone],
        /// The top-level folders listed as "Folders stay where they are": the user's own folders (not kind
        /// folders reused as destinations, not excluded or dataless ones). Input to `UserFolderIndex`.
        userFolders: [URL])
}

/// The listing stage of planning (organize §6.1): lstat-based, links never followed, dataless folders never
/// entered, anything unreadable fails closed.
enum FolderScan {
    static func scan(
        folder: URL, env: ScanEnvironment, cloudRoots: [CloudRoot], classifier: KindClassifier,
        isUbiquitous: (URL) -> Bool, reuseKindFolders: Bool, detectProjects: Bool, allowCloud: Bool = false,
        isOnlineOnly: (URL) -> Bool = FolderPlanner.liveIsOnlineOnly
    ) -> ScanResult {
        let folder = folder.standardizedFileURL
        let cache = OrganizeGuard.Cache()
        let rootURLs = cloudRoots.map { $0.url.standardizedFileURL }

        // R-C4: the folder itself must be organizable.
        let top = OrganizeGuard.driveRoot(containing: folder, env: env) ?? env.home.standardizedFileURL
        var folderStat = stat()
        let readable = lstat(folder.path, &folderStat) == 0
        if (readable && folderStat.st_mode & S_IFMT == S_IFLNK)
            || MoveToCloudPlanner.hasSymlinkAncestor(folder, below: top) {
            return .refused(FolderPlanner.refused(folder, OrganizeGuard.reasonText(.symlink)))
        }
        guard readable, folderStat.st_mode & S_IFMT == S_IFDIR, folderStat.st_flags & UInt32(SF_DATALESS) == 0 else {
            return .refused(FolderPlanner.refused(folder, FolderPlanner.unreadableText))
        }
        let cloud = FolderPlanner.isCloudFolder(folder, home: env.home, roots: cloudRoots, isUbiquitous: isUbiquitous)
        if cloud && !allowCloud { return .refused(FolderPlanner.refused(folder, FolderPlanner.cloudFolderText)) }
        // The home folder itself is organizable, groups only (decision 8), unless it is a code project.
        let exclusion = cloud
            ? OrganizeGuard.exclusion(for: folder, env: env, cloudRoots: rootURLs, cache: cache, allowExactCloudRoot: true)
            : OrganizeGuard.folderExclusion(for: folder, env: env, cloudRoots: rootURLs, cache: cache)
        if let e = exclusion {
            return .refused(FolderPlanner.refused(folder, OrganizeGuard.reasonText(e)))
        }
        guard let listing = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return .refused(FolderPlanner.refused(folder, FolderPlanner.unreadableText)) }

        var leftAlone: [LeftAlone] = []
        var unsorted: [LeftAlone] = []
        var userFolders: [URL] = []
        // Regular files that pass the guard, in listing order, before the project check (R-C20).
        var regular: [(url: URL, name: String, kind: Kind?, st: stat)] = []
        let kindNames = Set(Kind.allCases.map { NamingRules.key($0.folderName) })

        for name in FolderPlanner.sortedNames(listing) where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0 else {
                leftAlone.append(LeftAlone(url: url, reason: FolderPlanner.unreadableText)); continue
            }
            // Hidden in Finder (UF_HIDDEN, e.g. `Icon\r`): skipped like a dot-file (R-C17).
            if st.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
            // A download still in progress (a file, or Safari's `.download` bundle) is never moved (R-C17).
            if (st.st_mode & S_IFMT) != S_IFLNK,
               FolderPlanner.downloadingExtensions.contains(url.pathExtension.lowercased()) {
                leftAlone.append(LeftAlone(url: url, reason: FolderPlanner.stillDownloadingText)); continue
            }
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                leftAlone.append(LeftAlone(url: url, reason: OrganizeGuard.reasonText(.symlink)))
            case S_IFDIR:
                // A dataless folder is never entered, so the guard (which lists it) never sees it.
                if st.st_flags & UInt32(SF_DATALESS) != 0 {
                    leftAlone.append(LeftAlone(url: url, reason: FolderPlanner.foldersStayText)); continue
                }
                if let e = OrganizeGuard.exclusion(for: url, env: env, cloudRoots: rootURLs, cache: cache) {
                    leftAlone.append(LeftAlone(url: url, reason: OrganizeGuard.reasonText(e))); continue
                }
                // A plain kind folder is a destination, not something left alone (R-C5), unless kind
                // folders aren't reused.
                if reuseKindFolders && kindNames.contains(NamingRules.key(name)) { continue }
                leftAlone.append(LeftAlone(url: url, reason: FolderPlanner.foldersStayText))
                userFolders.append(url)
            case S_IFREG:
                if cloud && (st.st_flags & UInt32(SF_DATALESS) != 0 || isOnlineOnly(url)) {
                    leftAlone.append(LeftAlone(url: url, reason: FolderPlanner.onlineOnlyText)); continue
                }
                // It blocks its kind's folder; moving it (to Other) would only confuse (T11 F8).
                if kindNames.contains(NamingRules.key(name)) {
                    leftAlone.append(LeftAlone(url: url, reason: FolderPlanner.kindFolderNameText)); continue
                }
                if let e = OrganizeGuard.exclusion(for: url, env: env, cloudRoots: rootURLs, cache: cache) {
                    unsorted.append(LeftAlone(url: url, reason: OrganizeGuard.reasonText(e))); continue
                }
                regular.append((url, name, classifier.kind(of: url), st))
            default:  // FIFO, socket, device
                leftAlone.append(LeftAlone(url: url, reason: FolderPlanner.notRegularFileText))
            }
        }

        // R-C20: files that look like one project stay where they are, together. `GroupPlanner` turns this
        // off: its name groups supersede it, and it applies the rule to its leftovers itself.
        let project = detectProjects ? FolderPlanner.projectTokens(regular.map { ($0.name, $0.kind) }) : [:]
        var files: [ScannedFile] = []
        for (i, r) in regular.enumerated() {
            let (url, name, kind, st) = r
            if let (token, n) = project[i] {
                leftAlone.append(LeftAlone(url: url, reason: FolderPlanner.projectText(token, files: n))); continue
            }
            guard let snapshot = ItemSnapshot.capture(url, bytes: Int64(st.st_blocks) * 512) else {
                // An unreadable file of unknown kind is still just a file the rules can't place.
                if kind == nil {
                    unsorted.append(LeftAlone(url: url, reason: FolderPlanner.unknownKindText))
                } else {
                    leftAlone.append(LeftAlone(url: url, reason: FolderPlanner.unreadableText))
                }
                continue
            }
            // Reading EXIF from a dataless file (e.g. an evicted iCloud Desktop file) would download it.
            let dataless = st.st_flags & UInt32(SF_DATALESS) != 0
            let date =
                (kind == .images || kind == .screenshots) && !dataless ? classifier.dateTaken(of: url) : nil
            let birth = Date(
                timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec)
                    + TimeInterval(st.st_birthtimespec.tv_nsec) / 1_000_000_000)
            files.append(ScannedFile(url: url, name: name, kind: kind, date: date, birth: birth, snapshot: snapshot))
        }
        // Listing order, as if every entry had been handled in the one pass above.
        return .scanned(files: files, leftAlone: FolderPlanner.byName(leftAlone), unsorted: unsorted, userFolders: userFolders)
    }
}
