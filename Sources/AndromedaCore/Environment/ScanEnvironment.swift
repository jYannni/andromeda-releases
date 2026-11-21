import Foundation

/// Where a scan looks: injectable so tests never touch the real home, root or Trash.
public struct ScanEnvironment: Equatable, Sendable {
    public var home: URL
    public var root: URL
    public var trash: URL
    public var osMajor: Int
    /// This user's `/private/var/folders/<xx>/<hash>` folder, the parent of `$TMPDIR`. Catalog paths
    /// starting with `$USER_VAR_FOLDER/` resolve against it; nil means they match nothing.
    public var userVarFolder: URL?
    /// Folders that contain installed apps: `<root>/Applications` and `<home>/Applications`.
    public var applicationsRoots: [URL]
    /// The Data volume's root: the outside-home pass walks its top-level folders.
    public var dataVolumeRoot: URL
    /// Lists the firmlinks, one `<visible path>\t<Data-volume relative path>` per line.
    public var firmlinksFile: URL
    /// Mount points of the external drives Organize may work on (plan 7 decision 6): a folder at or below one
    /// is judged as one in home is, with the drive root as its top level. Empty unless the caller sets it.
    public var organizableDriveRoots: [URL] = []
    /// Mount points of mounted drives Organize refuses (read-only, Time Machine): anything at or below one is
    /// `.readOnlyVolume`. Empty unless the caller sets it.
    public var readOnlyDriveRoots: [URL] = []

    /// Catalog path prefix for `userVarFolder`.
    public static let userVarFolderPrefix = "$USER_VAR_FOLDER"

    public init(home: URL, root: URL, trash: URL, osMajor: Int, userVarFolder: URL? = nil, applicationsRoots: [URL]? = nil,
        dataVolumeRoot: URL = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true),
        firmlinksFile: URL = URL(fileURLWithPath: "/usr/share/firmlinks")
    ) {
        self.home = home
        self.root = root
        self.trash = trash
        self.osMajor = osMajor
        self.userVarFolder = userVarFolder
        self.applicationsRoots = applicationsRoots ?? [
            root.appendingPathComponent("Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
        self.dataVolumeRoot = dataVolumeRoot
        self.firmlinksFile = firmlinksFile
    }

    public static func live() -> ScanEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ScanEnvironment(
            home: home,
            root: URL(fileURLWithPath: "/", isDirectory: true),
            trash: home.appendingPathComponent(".Trash", isDirectory: true),
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            userVarFolder: liveUserVarFolder()
        )
    }

    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)` resolved with `realpath` (`/var` → `/private/var`), minus
    /// its last component (`T`). nil if either call fails.
    public static func liveUserVarFolder() -> URL? {
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard n > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: n)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, n) > 0, let real = realpath(buffer, nil) else { return nil }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true).deletingLastPathComponent()
    }

    /// Folders whose contents raise a macOS privacy prompt (Desktop, Documents, ...) unless Full Disk
    /// Access is granted. Relative to `home`; the folder and everything below it counts.
    /// `Library/Caches/com.apple.Music`: listing it asks for media library access (traced on the Air,
    /// macOS 26.6.2, docs/research/app-e2e.md F7).
    private static let promptingRoots: [[String]] = [
        ["desktop"], ["documents"], ["downloads"], ["music"], ["pictures"], ["movies"],
        ["library", "mobile documents"], ["library", "caches", "com.apple.music"],
        // v1 §8 rev 3 (Organize rev 4.9), landed by Task 20's T9: without Full Disk Access, entering a
        // File Provider folder raises a per-provider "access files managed by …" prompt (the Air, macOS 26).
        ["library", "cloudstorage"],
        // v1 §8 rev 4: the Photos libraries folder asks for Photos access (denied silently by hardened runtime
        // on macOS 27, logged by TCC); without Full Disk Access it isn't entered.
        ["library", "photos"],
        // v1 §8 rev 4: unreadable without Full Disk Access on 26 and 27, so the walk doesn't try (fewer refused
        // reads in the system log; their size is unknown either way).
        ["library", "safari"], ["library", "mail"],
    ]

    /// True for `<home>/Desktop`, `Documents`, `Downloads`, `Music`, `Pictures`, `Movies` and
    /// `Library/Mobile Documents`, `Library/CloudStorage`, `Library/Photos`, `Library/Safari` and `Library/Mail` and anything below them, and for
    /// `<home>/Library/Containers/<x>/…` and `<home>/Library/Group Containers/<x>/…` at any depth
    /// below `<x>`. Anchored on `home` and matched case-insensitively on path shape alone, so deciding
    /// never touches the disk. The `Containers` folders themselves are not prompting; their children are.
    /// Without Full Disk Access none of these are stat'ed, listed or walked.
    public func isPromptingPath(_ url: URL) -> Bool {
        let base = home.standardizedFileURL.pathComponents.map { $0.lowercased() }
        let parts = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return false }
        let rel = Array(parts.dropFirst(base.count))
        for root in Self.promptingRoots where rel.count >= root.count && Array(rel.prefix(root.count)) == root {
            return true
        }
        return rel.count >= 3 && rel[0] == "library" && (rel[1] == "containers" || rel[1] == "group containers")
    }

    /// Maps `~/x` to `home/x`, `/x` to `root/x` and `$USER_VAR_FOLDER/x` to `userVarFolder/x`.
    /// Other patterns, and `$USER_VAR_FOLDER` when it is unknown, are returned unchanged.
    public func resolve(_ pattern: String) -> String {
        let prefix = Self.userVarFolderPrefix
        if let folder = userVarFolder, pattern == prefix || pattern.hasPrefix(prefix + "/") {
            let rest = pattern.dropFirst(prefix.count).drop(while: { $0 == "/" })
            return rest.isEmpty ? folder.path : folder.appendingPathComponent(String(rest)).path
        }
        if pattern == "~" { return home.path }
        if pattern.hasPrefix("~/") {
            return home.appendingPathComponent(String(pattern.dropFirst(2))).path
        }
        if pattern.hasPrefix("/") {
            return root.appendingPathComponent(String(pattern.dropFirst())).path
        }
        return pattern
    }
}
