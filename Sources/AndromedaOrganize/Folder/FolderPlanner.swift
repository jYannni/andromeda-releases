import AndromedaCore
import Foundation

/// The board 07 badges.
public struct FolderSummary: Equatable, Sendable {
    public let foldersToCreate: Int
    /// Move steps whose parent folder changes.
    public let filesToMove: Int
    /// Move steps whose file name changes (a step can count in both).
    public let filesToRename: Int
    /// The Unsorted bucket ("left for you", ruling R-C2).
    public let leftForYou: Int

    public init(foldersToCreate: Int, filesToMove: Int, filesToRename: Int, leftForYou: Int) {
        self.foldersToCreate = foldersToCreate
        self.filesToMove = filesToMove
        self.filesToRename = filesToRename
        self.leftForYou = leftForYou
    }
}

/// What `FolderPlanner.plan` returns (ruling R-C1).
public struct FolderPlanResult: Equatable, Sendable {
    /// `var` so the app can stamp the drive the folder is on (`OrganizePlan.volume`).
    public var plan: OrganizePlan
    /// "Unsorted — needs you": files the rules can't place.
    public let unsorted: [LeftAlone]
    public let summary: FolderSummary
    /// IDs of the installer move steps; the UI shows `FolderPlanner.canTrashInStorageText` on them.
    public let canTrashInStorage: Set<UUID>
    /// Name groups this plan makes into new folders (`GroupPlanner`); empty from `FolderPlanner`.
    public var groups: [PlanGroup] = []
    /// Suggested parent folders over several groups (`GroupPlanner`); empty from `FolderPlanner`.
    public var parentSuggestions: [ParentSuggestion] = []
    /// Whether files outside groups were sorted by kind; always true from `FolderPlanner`.
    public var sortedRestByKind: Bool = true
    /// Saved rules not used this time (`GroupPlanner`): rule id → why (the rule's problem, or why its
    /// destination can't receive files). Their files went to Unsorted; the rules themselves are unchanged.
    public var blockedRules: [UUID: String] = [:]
    /// The listing of the picked folder's own folders stopped at `UserFolderIndex.maxEntries` (Review Focus 3):
    /// nothing beyond the cap was matched. Always false from `FolderPlanner`.
    public var userFoldersCapped = false
}

/// Plans organizing one folder's direct files by kind and date (organize §6.1, §6.2). Planning only:
/// nothing here changes the disk. Reads are lstat-based; links are never followed, dataless folders
/// never entered, and anything unreadable fails closed.
public struct FolderPlanner {
    /// A year folder gets `MM/` subfolders when that kind holds more than this many files for the year (O8).
    public static let monthSplitThreshold = 100

    public static let foldersStayText = "Folders stay where they are in this version."
    public static let unknownKindText = "Andromeda can't tell what this is"
    public static let nameTakenText = "A file with this name exists"
    /// An `.inHome` rule whose destination folder no longer exists: its files go to Unsorted, the rule is kept.
    public static let ruleFolderGoneText = "The rule's folder is gone"
    /// A folder this plan would reuse is not reusable here (a group name that is already a folder).
    public static let folderExistsText = "A folder with this name exists"
    /// A loose file whose name is a kind folder's: it stays where it is (T11 F8).
    public static let kindFolderNameText = "Its name is the one Andromeda uses for a folder"
    /// Why a kind's files go to Unsorted when a file sits where that kind's folder (or a year/month folder
    /// under it) would go (T11 F8).
    public static func fileInTheWayText(_ folderName: String) -> String { "A file named “\(folderName)” is in the way" }
    /// Files that look like one project stay together where they are (ruling R-C20).
    public static func projectText(_ token: String, files: Int) -> String {
        "Looks like one project: “\(token)” (\(files) files)"
    }
    /// A file a rule or Move to… sends into the folder it is already in: no step, listed under Left alone.
    public static let alreadyThereText = "Already in that folder"
    /// A loose file outside every group, with Sort the rest by kind off.
    public static let notInAGroupText = "Not in a group — stays where it is"
    /// A loose file that two or more of the user's folders match (relative paths): it stays, and the user decides.
    public static func matchesYourFoldersText(_ paths: [String]) -> String {
        "Matches your folders " + paths.map { "“\($0)”" }.joined(separator: ", ")
    }
    /// The reason `FolderPlanner` leaves the home folder alone: it is planned by groups only.
    public static let homeGroupsOnlyText = "Your home folder is organized by groups only"
    public static let cloudFolderText = "Cloud folders aren't organized in this version"
    public static let cloudScopeText = "Choose a destination inside the selected cloud folder"
    public static let onlineOnlyText = "Online-only file. Download it before organising it."

    public static func isCloudFolder(_ folder: URL, home: URL, roots: [CloudRoot],
                                     isUbiquitous: (URL) -> Bool = liveIsUbiquitous) -> Bool {
        let folder = folder.standardizedFileURL
        if roots.contains(where: { isInside(folder.path, $0.url.standardizedFileURL.path) }) { return true }
        let home = home.standardizedFileURL
        var ancestor = folder
        while ancestor.path != home.path, isInside(ancestor.path, home.path) {
            if isUbiquitous(ancestor) { return true }
            ancestor.deleteLastPathComponent()
        }
        return false
    }
    public static let canTrashInStorageText = "Can trash in Storage"
    public static let unreadableText = "Couldn't be read"
    public static let notRegularFileText = "Not a regular file"
    public static let stillDownloadingText = "Still downloading"
    /// In-progress download extensions (compared case-insensitively); never moved (ruling R-C17).
    static let downloadingExtensions: Set<String> = ["crdownload", "part", "download", "partial"]

    private let env: ScanEnvironment
    private let cloudRoots: [CloudRoot]
    private let classifier: KindClassifier
    private let isUbiquitous: (URL) -> Bool

    /// `isUbiquitous` says whether macOS syncs a folder to iCloud (Desktop & Documents); tests inject it.
    public init(
        env: ScanEnvironment, cloudRoots: [CloudRoot], classifier: KindClassifier = KindClassifier(),
        isUbiquitous: @escaping (URL) -> Bool = FolderPlanner.liveIsUbiquitous
    ) {
        self.env = env
        self.cloudRoots = cloudRoots
        self.classifier = classifier
        self.isUbiquitous = isUbiquitous
    }

    /// The folder's `isUbiquitousItem` resource value; false when it can't be read.
    public static func liveIsUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
    }

    public static func liveIsOnlineOnly(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .notDownloaded
    }

    // MARK: File system probes

    enum Node {
        case missing
        case directory(dataless: Bool)
        case other  // a file, link or anything that isn't a directory
        case unreadable
    }

    static func node(_ path: String) -> Node {
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT ? .missing : .unreadable }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return .other }
        return .directory(dataless: st.st_flags & UInt32(SF_DATALESS) != 0)
    }

    /// Paths compare as APFS does (case- and normalization-insensitively), component-wise.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let p = NamingRules.key(path), f = NamingRules.key(folder)
        return p == f || p.hasPrefix(f + "/")
    }

    static func sortedNames(_ names: [String]) -> [String] {
        names.sorted { a, b in
            let ka = NamingRules.key(a), kb = NamingRules.key(b)
            return ka != kb ? ka < kb : a < b
        }
    }

    /// A plan that leaves `folder` itself alone for `reason`: no steps, shown as the reason instead of a plan.
    public static func refused(_ folder: URL, _ reason: String) -> FolderPlanResult {
        FolderPlanResult(
            plan: OrganizePlan(title: folder.lastPathComponent, steps: [], leftAlone: [LeftAlone(url: folder, reason: reason)]),
            unsorted: [], summary: FolderSummary(foldersToCreate: 0, filesToMove: 0, filesToRename: 0, leftForYou: 0),
            canTrashInStorage: [])
    }

    // MARK: Plan

    public func plan(folder: URL, options: NamingOptions) -> FolderPlanResult {
        let folder = folder.standardizedFileURL
        // Sorting by kind never reaches a top level (home, a drive root; decisions 8 and 6): only GroupPlanner plans it.
        if OrganizeGuard.isTopLevel(folder, env: env) { return Self.refused(folder, Self.homeGroupsOnlyText) }
        let files: [ScannedFile], leftAlone: [LeftAlone]
        var unsorted: [LeftAlone]
        switch FolderScan.scan(
            folder: folder, env: env, cloudRoots: cloudRoots, classifier: classifier,
            isUbiquitous: isUbiquitous, reuseKindFolders: true, detectProjects: true)
        {
        case .refused(let result): return result
        case .scanned(let f, let l, let u, _): (files, leftAlone, unsorted) = (f, l, u)
        }

        let (placements, unknown) = Self.kindPlacements(files)
        unsorted += unknown
        return PlanAssembler.assemble(
            folder: folder, placements: placements, leftAlone: leftAlone, unsorted: unsorted,
            options: options, env: env, cloudRoots: cloudRoots)
    }

    /// Kind placements (`Kind/YYYY[/MM]`, reusing existing kind folders, R-C5) for files with a known kind;
    /// files of unknown kind come back as Unsorted entries.
    static func kindPlacements(_ files: [ScannedFile]) -> (placements: [Placement], unsorted: [LeftAlone]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let known = files.filter { $0.kind != nil }
        let unsorted = files.filter { $0.kind == nil }.map { LeftAlone(url: $0.url, reason: Self.unknownKindText) }
        var perYear: [String: Int] = [:]  // "kind/year" -> count
        for c in known {
            if let d = c.date, let kind = c.kind {
                perYear["\(kind.rawValue)/\(calendar.component(.year, from: d))", default: 0] += 1
            }
        }
        func components(_ c: ScannedFile, _ kind: Kind) -> [String] {
            var parts = [kind.folderName]
            if let d = c.date {
                let year = calendar.component(.year, from: d)
                parts.append(String(format: "%04d", year))
                if perYear["\(kind.rawValue)/\(year)", default: 0] > Self.monthSplitThreshold {
                    parts.append(String(format: "%02d", calendar.component(.month, from: d)))
                }
            }
            return parts
        }
        let placements = known.compactMap { f in
            f.kind.map { Placement(file: f, parts: components(f, $0), reuseExisting: true) }
        }
        return (placements, unsorted)
    }

    /// Entries in listing order (`NamingRules.key`, then the raw name).
    static func byName(_ items: [LeftAlone]) -> [LeftAlone] {
        items.sorted { a, b in
            let ka = NamingRules.key(a.url.lastPathComponent), kb = NamingRules.key(b.url.lastPathComponent)
            return ka != kb ? ka < kb : a.url.lastPathComponent < b.url.lastPathComponent
        }
    }

    // MARK: Project groups (ruling R-C20)

    /// Name words that never tie files together: extensions, and words any file might carry.
    static let projectStopWords: Set<String> = [
        // Extensions
        "pdf", "txt", "md", "doc", "docx", "xls", "xlsx", "csv", "tsv", "json", "py", "js", "ts", "swift", "html",
        "htm", "css", "xml", "rtf", "rdf", "pages", "numbers", "ppt", "pptx", "odt", "epub",
        "png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "webp", "bmp", "svg",
        "mov", "mp4", "m4v", "avi", "mkv", "mp3", "m4a", "wav", "aac", "flac",
        "zip", "gz", "tar", "tgz", "rar", "7z", "bz2", "xz", "dmg", "pkg", "iso",
        "sh", "rb", "go", "java", "kt", "cpp", "rs", "php", "sql", "yaml", "yml", "toml", "ini",
        "xyz", "qzxvbn", "crdownload", "part", "partial", "download", "cache", "git",
        // Generic words
        "file", "files", "copy", "final", "img", "image", "screenshot", "scan", "new", "untitled", "document",
        "notes", "draft", "version", "the", "and", "of",
        // App and capture prefixes: ordinary Downloads clutter, not projects (R-C20 review)
        "whatsapp", "screen", "shot", "recording", "cleanshot", "export", "data", "video", "photo", "audio",
        "unnamed", "downloads", "attachment", "signal", "telegram", "zoom",
    ]
    private static let notWordEdge = CharacterSet.alphanumerics.inverted

    /// A name's words: folded like names are compared (`NamingRules.key`: NFD, lowercase), without the extension, split on `_`, `-`, `.` and whitespace, with any other
    /// punctuation trimmed from each end (so "(1)" is "1"). Digits-only, 1–2 character and stop words dropped.
    static func projectWords(_ name: String) -> Set<String> {
        let base = NamingRules.key((name as NSString).deletingPathExtension)
        var out: Set<String> = []
        for raw in base.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." || $0.isWhitespace }) {
            let word = raw.trimmingCharacters(in: notWordEdge)
            guard word.count > 2, !word.allSatisfy(\.isNumber), !projectStopWords.contains(word) else { continue }
            out.insert(word)
        }
        return out
    }

    /// For each file (by index) in a project group: the qualifying word with the fewest files (ties:
    /// alphabetical) and that word's file count. A word qualifies when 3+ files carry it, they span 2+ kinds
    /// (no kind counts as its own), and at most half of `files` carry it.
    static func projectTokens(_ files: [(name: String, kind: Kind?)]) -> [Int: (String, Int)] {
        var carriers: [String: [Int]] = [:]
        for (i, f) in files.enumerated() { for w in projectWords(f.name) { carriers[w, default: []].append(i) } }
        var qualifying: [(word: String, files: [Int])] = []
        for (word, idx) in carriers where idx.count >= 3 && idx.count * 2 <= files.count {
            let kinds = Set(idx.map { files[$0].kind?.rawValue ?? "" })
            if kinds.count >= 2 { qualifying.append((word, idx)) }
        }
        qualifying.sort { $0.files.count != $1.files.count ? $0.files.count < $1.files.count : $0.word < $1.word }
        var out: [Int: (String, Int)] = [:]
        for q in qualifying { for i in q.files where out[i] == nil { out[i] = (q.word, q.files.count) } }
        return out
    }

    static func changes<T: Equatable>(_ part: (URL) -> T, _ step: PlannedStep) -> Bool {
        guard case .move(let from, let to) = step.action else { return false }
        return part(from) != part(to)
    }
}
