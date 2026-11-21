import Darwin
import Foundation

/// Directory identities approved for an automatic move, persisted for interrupted runs and undo.
public struct AutomationDirectories: Codable, Equatable, Sendable {
    public struct Folder: Codable, Hashable, Sendable {
        public let path: String
        private let volume: String
        private let inode: UInt64
        private let createdSeconds: Int64
        private let createdNanoseconds: Int64

        public init?(_ url: URL) {
            // Foundation can spell these system paths through aliases. Other links are rejected.
            let input = url.standardizedFileURL.path
            let path = input.hasPrefix("/var/") || input.hasPrefix("/tmp/") ? "/private" + input : input
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0,
                  let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsLocalKey]),
                  values.volumeIsLocal == true, let volume = values.volumeUUIDString else { return nil }
            self.path = path
            self.volume = volume
            inode = UInt64(info.st_ino)
            createdSeconds = Int64(info.st_birthtimespec.tv_sec)
            createdNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        }

        public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

        /// The caller closes the returned descriptor.
        public func openCurrent() -> Int32? {
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            guard matchesOpenedFolder(fd),
                  (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == volume
            else { close(fd); return nil }
            return fd
        }

        /// The descriptor must have been opened on the approved volume.
        public func matchesOpenedFolder(_ fd: Int32) -> Bool {
            var info = stat()
            return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && UInt64(info.st_ino) == inode
                && info.st_birthtimespec.tv_sec == createdSeconds && info.st_birthtimespec.tv_nsec == createdNanoseconds
                && info.st_flags & UInt32(SF_DATALESS) == 0
        }
    }

    public let source: Folder
    public let destination: Folder
    public let sourceBoundary: Folder?
    private let savedSubfolderPermission: Bool?
    public var allowsDestinationSubfolders: Bool { savedSubfolderPermission == true }

    public init(source: Folder, destination: Folder, allowsDestinationSubfolders: Bool = false, sourceBoundary: Folder? = nil) {
        self.source = source
        self.destination = destination
        self.sourceBoundary = sourceBoundary
        savedSubfolderPermission = allowsDestinationSubfolders ? true : nil
    }
}
