import Darwin
import AndromedaCore
import Foundation

/// Moves inside a manually chosen sync folder. Both sides of a rename are anchored to that folder's
/// recorded identity, and each descendant directory is opened without following links.
struct CloudFolderOperations {
    let folder: AutomationDirectories.Folder

    func create(_ url: URL) -> (Outcome, UInt64?) {
        guard let parent = openParent(url.path) else { return (.skipped(.originalParentMissing), nil) }
        defer { close(parent.fd) }
        guard mkdirat(parent.fd, parent.name, 0o755) == 0 else {
            return (errno == EEXIST ? .skipped(.destinationOccupied) : error(errno), nil)
        }
        var info = stat()
        let inode = fstatat(parent.fd, parent.name, &info, AT_SYMLINK_NOFOLLOW) == 0 ? UInt64(info.st_ino) : nil
        return (.done, inode)
    }

    func contains(_ path: String, fileID: UInt64) -> Bool {
        guard let parent = openParent(path) else { return false }
        defer { close(parent.fd) }
        var info = stat()
        return fstatat(parent.fd, parent.name, &info, AT_SYMLINK_NOFOLLOW) == 0
            && info.st_mode & S_IFMT == S_IFREG && UInt64(info.st_ino) == fileID
    }

    func move(from: String, to: String, fileID: UInt64, snapshot: ItemSnapshot? = nil) -> Outcome {
        let undo = snapshot == nil
        guard let old = openParent(from) else { return .skipped(.notWhereWeLeftIt) }
        defer { close(old.fd) }
        var info = stat()
        guard fstatat(old.fd, old.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, UInt64(info.st_ino) == fileID,
              info.st_flags & UInt32(SF_DATALESS) == 0,
              !FolderPlanner.liveIsOnlineOnly(URL(fileURLWithPath: from)) else {
            return .skipped(undo ? .notWhereWeLeftIt : .changedSinceScan)
        }
        if let snapshot, snapshot.identitySize != info.st_size
            || abs(AutomationDirectories.date(info.st_mtimespec).timeIntervalSince(snapshot.modified)) >= 0.000001 {
            return .skipped(.changedSinceScan)
        }
        guard let new = openParent(to) else { return .skipped(.originalParentMissing) }
        defer { close(new.fd) }
        guard renameatx_np(old.fd, old.name, new.fd, new.name, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { return .skipped(undo ? .originalPathOccupied : .destinationOccupied) }
            if code == EXDEV { return .skipped(.crossVolume) }
            return error(code)
        }
        return undo ? .restored : .done
    }

    private func openParent(_ path: String) -> (fd: Int32, name: String)? {
        let path = SafetyGuard.withoutSystemPathAlias(path)
        guard path.hasPrefix(folder.path + "/") else { return nil }
        let parts = path.dropFirst(folder.path.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        guard let name = parts.last, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              var fd = folder.openCurrent() else { return nil }
        var root = stat()
        guard fstat(fd, &root) == 0 else { close(fd); return nil }
        for part in parts.dropLast() {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return nil }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_dev == root.st_dev, info.st_flags & UInt32(SF_DATALESS) == 0
            else { close(next); return nil }
            fd = next
        }
        return (fd, String(name))
    }

    private func error(_ code: Int32) -> Outcome { .failed(String(cString: strerror(code))) }
}
