import Foundation

enum InstallerCleanup {
    static let catalogID = "cleanup.installer"

    static func isInDownloads(_ url: URL, home: URL) -> Bool {
        let path = SafetyGuard.withoutSystemPathAlias(url.standardizedFileURL.path)
        let downloads = SafetyGuard.withoutSystemPathAlias(home.appendingPathComponent("Downloads").standardizedFileURL.path)
        return path.hasPrefix(downloads + "/")
    }
}

enum BrowserFileCleanup {
    static let catalogID = "cleanup.browser-file"

    enum Scope: Equatable, Sendable {
        case installers
        case folder(StorageBrowser.FolderReference)

        var catalogID: String {
            switch self {
            case .installers: InstallerCleanup.catalogID
            case .folder: BrowserFileCleanup.catalogID
            }
        }

        func canSelect(_ entry: StorageBrowser.Entry, home: URL) -> Bool {
            switch self {
            case .installers: StorageBrowser.canSelectInstaller(entry, home: home)
            case .folder(let reference):
                !entry.isFolder && !entry.incomplete && entry.fileIdentity != nil && entry.modified != nil
                    && Self.allowsFolder(reference.url, home: home)
                    && Self.path(entry.url).hasPrefix(Self.path(reference.url) + "/")
            }
        }

        func allows(_ url: URL, home: URL) -> Bool {
            switch self {
            case .installers: InstallerCleanup.isInDownloads(url, home: home) && StorageBrowser.isInstallerName(url.lastPathComponent)
            case .folder(let reference):
                Self.allowsFolder(reference.url, home: home) && Self.path(url).hasPrefix(Self.path(reference.url) + "/")
                    && reference.isCurrent()
            }
        }

        static func allowsFolder(_ folder: URL, home: URL) -> Bool {
            guard folder.isFileURL else { return false }
            let folderPath = path(folder)
            return ["Downloads", "Documents"].contains { name in
                let root = path(home.appendingPathComponent(name, isDirectory: true))
                return folderPath == root || folderPath.hasPrefix(root + "/")
            }
        }

        private static func path(_ url: URL) -> String {
            SafetyGuard.withoutSystemPathAlias(url.standardizedFileURL.path)
        }
    }

    struct TrashCheck: Equatable, Sendable {
        let scope: Scope
        let url: URL
        let identity: FileIdentity
        let bytes: Int64
        let modified: Date
        let changed: Date

        init?(_ entry: StorageBrowser.Entry, scope: Scope, env: ScanEnvironment) {
            guard scope.canSelect(entry, home: env.home), let identity = entry.fileIdentity,
                  let modified = entry.modified, let info = Self.eligibleFile(entry.url, scope: scope, env: env),
                  Self.date(info.st_mtimespec) == modified, Int64(info.st_blocks) * 512 == entry.bytes,
                  identity == FileIdentity(dev: info.st_dev, ino: info.st_ino) else { return nil }
            self.scope = scope
            url = entry.url
            self.identity = identity
            bytes = entry.bytes
            self.modified = modified
            changed = Self.date(info.st_ctimespec)
        }

        func matches(_ info: stat, env: ScanEnvironment) -> Bool {
            guard let current = Self.eligibleFile(url, scope: scope, env: env) else { return false }
            return [info, current].allSatisfy {
                identity == FileIdentity(dev: $0.st_dev, ino: $0.st_ino)
                    && bytes == Int64($0.st_blocks) * 512
                    && modified == Self.date($0.st_mtimespec) && changed == Self.date($0.st_ctimespec)
            }
        }

        private static func eligibleFile(_ url: URL, scope: Scope, env: ScanEnvironment) -> stat? {
            let path = SafetyGuard.withoutSystemPathAlias(url.standardizedFileURL.path)
            guard scope.allows(url, home: env.home),
                  path == SafetyGuard.withoutSystemPathAlias(url.resolvingSymlinksInPath().path),
                  SafetyGuard.checkRemovable(url, env: env) == nil else { return nil }
            var info = stat(), trash = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_flags & UInt32(SF_DATALESS | UF_HIDDEN) == 0 else { return nil }
            let listed = FileIdentity(dev: info.st_dev, ino: info.st_ino)
            // Open only for metadata, and refuse symbolic links at every path component.
            let fd = open(path, O_EVTONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  FileIdentity(dev: info.st_dev, ino: info.st_ino) == listed,
                  info.st_uid == getuid(), info.st_nlink == 1, info.st_flags & UInt32(SF_DATALESS | UF_HIDDEN) == 0,
                  lstat(env.trash.path, &trash) == 0, trash.st_mode & S_IFMT == S_IFDIR,
                  trash.st_uid == getuid(), trash.st_dev == info.st_dev,
                  FileIdentity(path: env.home.path)?.dev == info.st_dev else { return nil }
            var uncached = url
            uncached.removeAllCachedResourceValues()
            guard let attributes = try? uncached.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey]),
                  attributes.volumeIsLocal == true, attributes.isUbiquitousItem != true,
                  scope.allows(url, home: env.home),
                  path == SafetyGuard.withoutSystemPathAlias(uncached.resolvingSymlinksInPath().path),
                  FileIdentity(path: path) == listed else { return nil }
            return info
        }

        private static func date(_ time: timespec) -> Date {
            Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
        }
    }
}
