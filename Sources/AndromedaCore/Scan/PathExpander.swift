import Foundation

/// Expands catalog path patterns (`~/x`, `/x`, `$USER_VAR_FOLDER/x`, with `*` / `?` in any component) into the
/// URLs that currently exist. Symlinks are never returned and never traversed.
public enum PathExpander {
    public static func expand(_ pattern: String, env: ScanEnvironment) -> [URL] {
        expandReportingSkipped(pattern, env: env, promptingPathsReadable: true).urls
    }

    /// With `promptingPathsReadable` false, expansion stops at the first protected folder it reaches
    /// (see `ScanEnvironment.isPromptingPath`): nothing inside it is stat'ed or listed, and its own URL
    /// comes back in `skipped` instead of `urls`.
    public static func expandReportingSkipped(
        _ pattern: String, env: ScanEnvironment, promptingPathsReadable: Bool
    ) -> (urls: [URL], skipped: [URL]) {
        let base: String
        let rest: Substring
        if pattern == "~" {
            base = env.home.path
            rest = ""
        } else if pattern.hasPrefix("~/") {
            base = env.home.path
            rest = pattern.dropFirst(2)
        } else if pattern.hasPrefix("/") {
            base = env.root.path
            rest = pattern.dropFirst()
        } else if pattern == ScanEnvironment.userVarFolderPrefix
                    || pattern.hasPrefix(ScanEnvironment.userVarFolderPrefix + "/") {
            guard let folder = env.userVarFolder else { return ([], []) }
            base = folder.path
            rest = pattern.dropFirst(ScanEnvironment.userVarFolderPrefix.count)
        } else {
            return ([], [])
        }

        let components = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var current: [String] = [base]
        var skipped = Set<String>()
        for component in components {
            var next: [String] = []
            for parent in current {
                if isWildcard(component) {
                    for name in childNames(of: parent) where matches(component, name) {
                        let path = join(parent, name)
                        if hold(path, env: env, readable: promptingPathsReadable) { skipped.insert(path); continue }
                        if isRealEntry(path) { next.append(path) }
                    }
                } else {
                    let path = join(parent, component)
                    if hold(path, env: env, readable: promptingPathsReadable) {
                        // A literal name may not exist (folder absent, app not installed). Check by listing the
                        // parent, never by stat'ing the folder.
                        if listsChild(path) { skipped.insert(path) }
                        continue
                    }
                    if isRealEntry(path) { next.append(path) }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        let skippedURLs = skipped.sorted().map { URL(fileURLWithPath: $0) }
        if current.isEmpty { return ([], skippedURLs) }

        // With no components the pattern names the base itself; apply the same symlink rule.
        let results = components.isEmpty ? current.filter(isRealEntry) : current
        return (Set(results).sorted().map { URL(fileURLWithPath: $0) }, skippedURLs)
    }

    /// Whether `path`'s name is among its parent's children (case-insensitive, like APFS).
    private static func listsChild(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        return childNames(of: url.deletingLastPathComponent().path).contains { $0.lowercased() == name }
    }

    /// True when `path` is a protected folder that must not be touched. Decided on the path alone,
    /// before any stat, so nothing inside it is probed.
    private static func hold(_ path: String, env: ScanEnvironment, readable: Bool) -> Bool {
        !readable && env.isPromptingPath(URL(fileURLWithPath: path))
    }

    /// Joins without doubling the separator, so a base of `/` gives `/private`, not `//private`.
    static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    private static func isWildcard(_ component: String) -> Bool {
        component.contains("*") || component.contains("?")
    }

    private static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, FNM_PERIOD) == 0
    }

    private static func childNames(of directory: String) -> [String] {
        #if ANDROMEDA_TRACE
        ScanTrace.note("list", path: directory)
        #endif
        return (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    }

    /// Exists and is not a symlink.
    private static func isRealEntry(_ path: String) -> Bool {
        var st = stat()
        #if ANDROMEDA_TRACE
        ScanTrace.note("lstat", path: path)
        #endif
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) != S_IFLNK
    }
}
