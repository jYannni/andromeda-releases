import Darwin
import Foundation
import Synchronization

/// One exclusive folder automation run per journal, shared by cooperating processes under the same user.
/// Acquire before checking automation history, and hold through the final journal write. This lease does
/// not cover other journal operations. The lock directory must remain in place, including after release.
public final class FolderAutomationLease: Sendable {
    static let lockName = ".folder-automation.lock"
    private let descriptor: Mutex<Int32?>

    private init(descriptor: Int32) {
        self.descriptor = Mutex(descriptor)
    }

    /// Returns nil if another run holds the lease. Throws if the existing journal directory or the lock
    /// cannot be used safely. The caller may release explicitly or allow the lease to leave scope.
    public static func tryAcquire(in journalDirectory: URL) throws -> FolderAutomationLease? {
        guard journalDirectory.isFileURL else { throw POSIXError(.EINVAL) }
        let path = SafetyGuard.withoutSystemPathAlias(journalDirectory.standardizedFileURL.path)
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard directory >= 0 else { throw systemError() }
        defer { close(directory) }
        let parent = try ownedDirectory(directory)
        var filesystem = statfs()
        guard fstatfs(directory, &filesystem) == 0 else { throw systemError() }
        guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw POSIXError(.ENOTSUP) }

        guard mkdirat(directory, lockName, 0o700) == 0 || errno == EEXIST else { throw systemError() }
        let fd = openat(directory, lockName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw systemError() }
        var acquired = false
        defer { if !acquired { close(fd) } }
        let opened = try ownedDirectory(fd)
        guard opened.st_dev == parent.st_dev else { throw POSIXError(.EXDEV) }

        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            if error == EWOULDBLOCK { return nil }
            if error != EINTR { throw systemError(error) }
        }
        var named = stat()
        guard fstatat(directory, lockName, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw systemError() }
        guard named.st_dev == opened.st_dev, named.st_ino == opened.st_ino, isOwnedDirectory(named) else {
            throw POSIXError(.ESTALE)
        }
        acquired = true
        return FolderAutomationLease(descriptor: fd)
    }

    public func release() {
        descriptor.withLock { current in
            guard let fd = current else { return }
            current = nil
            close(fd)
        }
    }

    deinit { release() }

    private static func ownedDirectory(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError() }
        guard isOwnedDirectory(info) else { throw POSIXError(.EACCES) }
        return info
    }

    private static func isOwnedDirectory(_ info: stat) -> Bool {
        info.st_uid == geteuid() && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o022 == 0
            && info.st_flags & UInt32(SF_DATALESS) == 0
    }

    private static func systemError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
