import Foundation

/// Why a path may never be moved to the Trash.
public enum SafetyViolation: Error, Equatable, Sendable {
    case systemPath
    /// Carries the last path component of the package ancestor.
    case insidePackage(String)
    /// Carries the last path component of the protected store ("Messages", "Mail", "CloudDocs").
    case protectedStore(String)
    case outsideAllowedRoots
    case symlinkEscape
}

/// The gate every removal passes through right before it happens.
public enum SafetyGuard {
    /// Foundation may spell these two macOS system directories through their aliases.
    public static func withoutSystemPathAlias(_ path: String) -> String {
        path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/")
            ? "/private" + path : path
    }

    /// Stores that are never removable, relative to home. Internal so catalog validation can reuse them.
    static let protectedStoreRelativePaths: [String] = [
        "Library/Application Support/CloudDocs",
        "Library/Messages",
        "Library/Mail",
    ]

    /// Fallback for when `isPackageKey` is false (e.g. in a temp dir where the type isn't registered).
    private static let packageExtensions: Set<String> = [
        "photoslibrary", "app", "musiclibrary", "tvlibrary", "bundle",
        "xcarchive", "pvm", "utm", "sparsebundle",
    ]

    public static func checkRemovable(_ url: URL, env: ScanEnvironment) -> SafetyViolation? {
        let standardized = url.standardizedFileURL
        if let violation = check(standardized, roots: Roots(env: env, resolving: false)) {
            return violation
        }
        // Symlinks can hide the real target: the resolved path must pass too. `realpath` is included
        // because the kernel resolves `link/../x` through the link, unlike lexical standardizing.
        var resolvedPaths = [url.resolvingSymlinksInPath().standardizedFileURL]
        if let real = realPath(url.path) { resolvedPaths.append(URL(fileURLWithPath: real)) }
        let rootsResolved = Roots(env: env, resolving: true)
        for resolved in resolvedPaths where components(resolved) != components(standardized) {
            switch check(resolved, roots: rootsResolved) {
            case nil: continue
            case .insidePackage(let name): return .insidePackage(name)
            default: return .symlinkEscape
            }
        }
        return nil
    }

    private static func realPath(_ path: String) -> String? {
        guard let buf = realpath(path, nil) else { return nil }
        defer { free(buf) }
        return String(cString: buf)
    }

    private struct Roots {
        let home: [String]
        let applications: [String]
        let system: [String]
        /// `<user var folder>/X`, only when the folder sits exactly at
        /// `<root>/private/var/folders/<xx>/<hash>`; otherwise nil and nothing there is removable.
        let userX: [String]?
        let protectedStores: [[String]]

        init(env: ScanEnvironment, resolving: Bool) {
            func norm(_ u: URL) -> [String] {
                components(resolving ? u.resolvingSymlinksInPath() : u)
            }
            home = norm(env.home)
            applications = norm(env.root.appendingPathComponent("Applications", isDirectory: true))
            system = norm(env.root.appendingPathComponent("System", isDirectory: true))
            let folders = norm(env.root.appendingPathComponent("private/var/folders", isDirectory: true))
            if let folder = env.userVarFolder.map(norm),
               folder.count == folders.count + 2, isInside(folder, folders) {
                userX = folder + ["X"]
            } else {
                userX = nil
            }
            protectedStores = SafetyGuard.protectedStoreRelativePaths.map {
                norm(env.home) + $0.split(separator: "/").map(String.init)
            }
        }
    }

    /// Path components without the root "/" or a trailing-slash component, so directory and file URLs compare equal.
    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.path.split(separator: "/").map(String.init)
    }

    /// Component-wise and case-insensitive (APFS is case-insensitive by default).
    private static func isInside(_ path: [String], _ ancestor: [String]) -> Bool {
        path.count >= ancestor.count
            && zip(path, ancestor).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
    }

    private static func check(_ url: URL, roots: Roots) -> SafetyViolation? {
        let path = components(url)
        if isInside(path, roots.system) { return .systemPath }
        let root: [String]
        if isInside(path, roots.home) {
            root = roots.home
        } else if isInside(path, roots.applications) {
            root = roots.applications
        } else if let userX = roots.userX, isInside(path, userX) {
            root = userX
        } else {
            return .outsideAllowedRoots
        }
        // The allowed roots themselves are never removable.
        if path.count == root.count { return .outsideAllowedRoots }
        // A protected store, anything inside it, or anything that contains it.
        for store in roots.protectedStores where isInside(path, store) || isInside(store, path) {
            return .protectedStore(store.last ?? "")
        }
        // Ancestors strictly between the allowed root and the item; the item itself may be a package.
        if path.count > root.count + 1 {
            for depth in (root.count + 1)..<path.count {
                let ancestor = URL(fileURLWithPath: "/" + path.prefix(depth).joined(separator: "/"))
                if isPackage(ancestor) { return .insidePackage(ancestor.lastPathComponent) }
            }
        }
        return nil
    }

    public static func isPackage(_ url: URL) -> Bool {
        packageExtensions.contains(url.pathExtension.lowercased())
            || (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}
