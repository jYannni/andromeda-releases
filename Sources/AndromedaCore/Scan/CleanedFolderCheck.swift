import Foundation

/// A bounded, metadata-only check of one previously cleaned local directory.
public enum CleanedFolderCheck {
    public static func returnedBytes(
        at folder: URL, originalInode: UInt64, minimum: Int64,
        env: ScanEnvironment, canReadProtectedPaths: Bool, control: ScanControl
    ) -> Int64? {
        guard minimum > 0 else { return nil }
        return measure(folder, replacedInode: originalInode, minimum: minimum, env: env,
                       canReadProtectedPaths: canReadProtectedPaths, control: control)
    }

    public static func watchedBytes(
        _ reference: StorageBrowser.FolderReference, env: ScanEnvironment,
        canReadProtectedPaths: Bool, control: ScanControl
    ) -> Int64? {
        let folder = reference.url
        guard canWatch(folder, env: env), canReadProtectedPaths || !env.isPromptingPath(folder),
              !control.isCancelled, reference.isCurrent(),
              let bytes = measure(folder, replacedInode: nil, minimum: nil, env: env,
                                  canReadProtectedPaths: canReadProtectedPaths, control: control),
              reference.isCurrent() else { return nil }
        return bytes
    }

    public static func canWatch(_ folder: URL, env: ScanEnvironment) -> Bool {
        guard folder.isFileURL else { return false }
        let home = env.home.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        return path.hasPrefix(home + "/") && !excludes(path, prefixes: excludedPrefixes(home: home, env: env))
    }

    private static func excludedPrefixes(home: String, env: ScanEnvironment) -> [String] {
        let library = home.lowercased() + "/library/"
        return [env.trash.standardizedFileURL.path.lowercased(), library + "cloudstorage", library + "mobile documents"]
    }

    private static func excludes(_ path: String, prefixes: [String]) -> Bool {
        let key = path.lowercased()
        return prefixes.contains { key == $0 || key.hasPrefix($0 + "/") }
    }

    private static func measure(
        _ folder: URL, replacedInode: UInt64?, minimum: Int64?, env: ScanEnvironment,
        canReadProtectedPaths: Bool, control: ScanControl
    ) -> Int64? {
        let path = folder.standardizedFileURL.path
        let home = env.home.standardizedFileURL
        let homePath = home.path
        let excluded = excludedPrefixes(home: homePath, env: env)
        func canRead(_ path: String) -> Bool {
            canReadProtectedPaths || !env.isPromptingPath(URL(fileURLWithPath: path, isDirectory: false))
        }
        guard canWatch(folder, env: env), canRead(path), !control.isCancelled,
              folder.resolvingSymlinksInPath().path == home.resolvingSymlinksInPath().path + String(path.dropFirst(homePath.count))
        else { return nil }
        var info = stat()
        var homeInfo = stat()
        guard stat(homePath, &homeInfo) == 0, lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_dev == homeInfo.st_dev,
              UInt64(info.st_ino) != replacedInode, info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        let device = info.st_dev
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        func hasTime() -> Bool { !control.isCancelled && ContinuousClock.now < deadline }
        var total: Int64 = 0
        var checked = 0
        var folders = [path]
        var counted = Set<UInt64>()
        let lister = DirectoryLister(includeCloneRefCount: false)
        while hasTime(), let parent = folders.popLast() {
            let parentPath = minimum == nil ? SafetyGuard.withoutSystemPathAlias(parent) : parent
            guard let entries = lister.entries(atPath: parentPath, followAncestorLinks: minimum != nil, shouldContinue: hasTime)
            else {
                if minimum == nil { return nil }
                continue
            }
            for entry in entries {
                checked += 1
                guard checked <= 50_000, hasTime() else { return nil }
                if entry.error != 0, minimum == nil { return nil }
                guard entry.error == 0, entry.device == device, !entry.isMountPoint,
                      entry.flags & UInt32(SF_DATALESS) == 0 else { continue }
                if entry.type == VDIR.rawValue {
                    let child = parent + "/" + entry.name
                    if excludes(child, prefixes: excluded) { continue }
                    if canRead(child) { folders.append(child) }
                    else if minimum == nil { return nil }
                } else if entry.type == VREG.rawValue, let bytes = entry.allocated,
                          bytes > 0, entry.inode != 0, counted.insert(entry.inode).inserted {
                    total += bytes
                    if let minimum, total >= minimum { return total }
                } else if minimum == nil, entry.type == VREG.rawValue, entry.allocated == nil || entry.inode == 0 {
                    return nil
                }
            }
        }
        return minimum == nil && hasTime() && folders.isEmpty ? total : nil
    }
}
