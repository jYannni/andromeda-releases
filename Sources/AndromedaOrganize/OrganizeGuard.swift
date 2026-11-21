import AndromedaCore
import Foundation

/// Why Organize leaves an item alone (organize §6.2).
public enum Exclusion: Equatable, Sendable {
    case package
    case insidePackage
    case appLibrary
    case codeProject(marker: String)
    case insideCodeProject
    case library
    case cloudRoot
    case applications
    case symlink
    case notInHome
    /// On a mounted drive Organize never writes to (read-only, or a Time Machine backup disk).
    case readOnlyVolume
}

public enum OrganizeGuard {
    /// A folder holding one of these is a code project and moves as a unit, or not at all.
    /// `*.xcodeproj` and `*.xcworkspace` match by suffix.
    static let codeProjectMarkers = [
        ".git", "*.xcodeproj", "*.xcworkspace", "Package.swift", "package.json",
        "Cargo.toml", "pyproject.toml", "go.mod", "node_modules", ".venv",
    ]

    /// App-managed libraries by extension, beyond what `SafetyGuard.isPackage` knows.
    static let appLibraryExtensions: Set<String> = [
        "photoslibrary", "musiclibrary", "tvlibrary", "lrcat", "lrdata", "fcpbundle", "logicx",
        "cosessiondb",
    ]

    /// Entries of any type that mark an app library everywhere `exclusion` applies (Calibre's notes and trash).
    static let appLibraryEntries: Set<String> = [".calnotes", ".caltrash"]

    /// An app may keep its database in a library folder with no package extension (Calibre's `metadata.db`).
    /// A regular file with one of these extensions directly inside a folder marks it as an app library only
    /// where 3b chooses destinations (`holdsAppDatabase`: `UserFolderIndex`, `DestinationGuard`), never in
    /// `exclusion`, so scans and cloud moves treat database files as Organize 2 did. Windows' `Thumbs.db`
    /// is not one. Matched by name only, the file is never opened.
    static let appDatabaseExtensions: Set<String> = ["db", "sqlite", "sqlite3", "realm"]
    static let notAppDatabases: Set<String> = ["thumbs.db"]

    /// What a directory's own listing says it is.
    enum DirectoryMarker: Equatable {
        case codeProject(String)
        /// A `.calnotes`/`.caltrash` entry.
        case appLibrary
    }

    /// Per-run memo of "which marker does this directory hold", so a planner calling `exclusion` once
    /// per item lists each ancestor directory once instead of once per item.
    public final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var markers: [String: DirectoryMarker?] = [:]

        public init() {}

        func marker(in path: String, compute: () -> DirectoryMarker?) -> DirectoryMarker? {
            lock.lock()
            if let hit = markers[path] { lock.unlock(); return hit }
            lock.unlock()
            let value = compute()
            lock.lock()
            markers[path] = .some(value)
            lock.unlock()
            return value
        }
    }

    public static func exclusion(
        for url: URL, env: ScanEnvironment, cloudRoots: [URL], cache: Cache? = nil,
        allowExactCloudRoot: Bool = false
    ) -> Exclusion? {
        let path = url.standardizedFileURL.path
        // lstat, never stat: a link is judged as a link. An alias file is a regular file.
        if isSymlink(path) { return .symlink }

        let home = env.home.standardizedFileURL.path
        let applications = [
            env.root.appendingPathComponent("Applications").standardizedFileURL.path,
            home + "/Applications",
        ]
        // Folded as APFS compares names: `~/applications` is `~/Applications`, `~/LIBRARY` is `~/Library`.
        if applications.contains(where: { isAtOrInside(path, $0) }) { return .applications }
        if env.readOnlyDriveRoots.contains(where: { isAtOrInside(path, $0.standardizedFileURL.path) }) {
            return .readOnlyVolume
        }
        let isCloudRoot = cloudRoots.contains { NamingRules.key($0.standardizedFileURL.path) == NamingRules.key(path) }
        if isCloudRoot && !allowExactCloudRoot { return .cloudRoot }
        let bound: String
        if let drive = driveRoot(containing: url, env: env) {
            // On a drive, judged as in home with the drive root as the top (decision 6): no Library rule.
            // The bound keeps the item's own spelling, so the walk's prefix check matches it.
            let depth = drive.pathComponents.count, parts = URL(fileURLWithPath: path).pathComponents
            guard parts.count > depth else { return .notInHome }
            bound = NSString.path(withComponents: Array(parts.prefix(depth)))
        } else {
            guard path.hasPrefix(home + "/") else { return .notInHome }
            // Strictly inside a cloud root: real roots mostly live under ~/Library, so skip the Library
            // shortcut and stop the walk at the root (component-wise prefix, so "X-me2" is not in "X-me").
            let cloudRoot = cloudRoots.map { $0.standardizedFileURL.path }.first {
                path.hasPrefix($0 + "/") || (isCloudRoot && allowExactCloudRoot && path == $0)
            }
            let library = home + "/Library"
            if cloudRoot == nil, isAtOrInside(path, library) { return .library }
            bound = isCloudRoot && allowExactCloudRoot ? (path as NSString).deletingLastPathComponent : cloudRoot ?? home
        }

        // Walk from the item up to (not including) home or the drive root, checking each node.
        var node = URL(fileURLWithPath: path)
        var isItem = true
        while node.path.hasPrefix(bound + "/") {
            let ext = node.pathExtension.lowercased()
            if appLibraryExtensions.contains(ext) { return .appLibrary }
            if SafetyGuard.isPackage(node) { return isItem ? .package : .insidePackage }
            if !isSymlink(node.path), let marker = cached(node.path, cache) {
                switch marker {
                case .codeProject(let name): return isItem ? .codeProject(marker: name) : .insideCodeProject
                case .appLibrary: return .appLibrary
                }
            }
            node = node.deletingLastPathComponent()
            isItem = false
        }
        return nil
    }

    public static func reasonText(_ e: Exclusion) -> String {
        switch e {
        case .package: "App-managed package"
        case .insidePackage: "Inside an app-managed package"
        case .appLibrary: "App-managed library"
        case .codeProject(let marker): "Code project (has \(marker))"
        case .insideCodeProject: "Inside a code project"
        case .library: "Inside your Library folder"
        case .cloudRoot: "Cloud folder"
        case .applications: "Applications folder"
        case .symlink: "Link — never followed"
        case .notInHome: "Outside your home folder"
        case .readOnlyVolume: "This drive is read-only"
        }
    }

    /// Whether `url` is the home folder itself or an organizable drive's root (plan 7 decision 6). The one
    /// comparison every top-level rule uses: groups only, never sorted by kind.
    public static func isTopLevel(_ url: URL, env: ScanEnvironment) -> Bool {
        let path = url.standardizedFileURL.path
        if path == env.home.standardizedFileURL.path { return true }
        return driveRoots(env).contains { NamingRules.key($0.path) == NamingRules.key(path) }
    }

    /// The organizable drive root `url` is at or below, if any (component-wise and case-folded, so "vol2" is
    /// not on "vol"). Nil at or under home: home always outranks a drive root, even on a drive that holds it.
    public static func driveRoot(containing url: URL, env: ScanEnvironment) -> URL? {
        let path = url.standardizedFileURL.path
        if isAtOrInside(path, env.home.standardizedFileURL.path) { return nil }
        return driveRoots(env).first { isAtOrInside(path, $0.path) }
    }

    /// The organizable drive roots, less any that is home or holds it (home on an external volume).
    private static func driveRoots(_ env: ScanEnvironment) -> [URL] {
        let home = env.home.standardizedFileURL.path
        return env.organizableDriveRoots.map(\.standardizedFileURL).filter { !isAtOrInside(home, $0.path) }
    }

    /// The exclusion for a folder being organized. As `exclusion(for:)`, except a top-level folder (home, a
    /// drive root) is not "outside home" (decisions 8 and 6): it is refused only when it is a link or a code
    /// project (a dotfiles `.git`, a `package.json`, `node_modules`, …), which the ancestor walk never checks.
    public static func folderExclusion(
        for url: URL, env: ScanEnvironment, cloudRoots: [URL], cache: Cache? = nil
    ) -> Exclusion? {
        guard isTopLevel(url, env: env) else { return exclusion(for: url, env: env, cloudRoots: cloudRoots, cache: cache) }
        let path = url.standardizedFileURL.path
        if isSymlink(path) { return .symlink }
        // A top level is never an app library: a `.calnotes` there doesn't refuse the whole home folder or drive.
        guard case .codeProject(let marker) = cached(path, cache) else { return nil }
        return .codeProject(marker: marker)
    }

    /// `path` is `root` or inside it, compared as APFS compares names (`NamingRules.key`).
    private static func isAtOrInside(_ path: String, _ root: String) -> Bool {
        let p = NamingRules.key(path), r = NamingRules.key(root)
        return p == r || p.hasPrefix(r + "/")
    }

    private static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    private static func cached(_ path: String, _ cache: Cache?) -> DirectoryMarker? {
        guard let cache else { return directoryMarker(in: path) }
        return cache.marker(in: path) { directoryMarker(in: path) }
    }

    /// What the names directly inside the directory at `path` mark it as: the first code-project marker in the
    /// fixed list's order, else an app library by Calibre's entries.
    private static func directoryMarker(in path: String) -> DirectoryMarker? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              let names = try? FileManager.default.contentsOfDirectory(atPath: path)
        else { return nil }
        for marker in codeProjectMarkers {
            if marker.hasPrefix("*") {
                let suffix = String(marker.dropFirst())
                if let hit = names.first(where: { $0.hasSuffix(suffix) }) { return .codeProject(hit) }
            } else if names.contains(marker) {
                return .codeProject(marker)
            }
        }
        if names.contains(where: { appLibraryEntries.contains(NamingRules.key($0)) }) { return .appLibrary }
        return nil
    }

    /// Whether the directory at `path` directly holds a regular app-database file (`appDatabaseExtensions`,
    /// not `Thumbs.db`), so 3b never picks it, or anything below it, as a destination. Not part of `exclusion`.
    public static func holdsAppDatabase(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              let names = try? FileManager.default.contentsOfDirectory(atPath: path)
        else { return false }
        return names.contains { name in
            guard appDatabaseExtensions.contains((name as NSString).pathExtension.lowercased()),
                  !notAppDatabases.contains(name.lowercased()) else { return false }
            var entry = stat()
            return lstat(path + "/" + name, &entry) == 0 && (entry.st_mode & S_IFMT) == S_IFREG
        }
    }
}
