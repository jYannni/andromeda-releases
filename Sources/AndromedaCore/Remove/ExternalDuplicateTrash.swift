import Foundation

/// An explicitly scanned file on a writable local volume. Never infer an external
/// volume from a path prefix alone: a different disk can reuse the same mount path.
struct ExternalDuplicateVolume: Equatable, Sendable {
    let uuid: String
    let name: String
    let root: URL
    let identity: FileIdentity

    init?(_ volume: ExternalVolume) {
        guard volume.hasStableIdentity, volume.isOrganizable,
              let root = Self.canonicalDirectory(volume.url),
              let values = try? root.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsLocalKey,
                                                            .volumeIsReadOnlyKey]),
              values.volumeUUIDString == volume.id, values.volumeIsLocal == true,
              values.volumeIsReadOnly == false, !VolumeDiscovery.isTimeMachineDestination(volume),
              VolumeDiscovery.supportsExclusiveRename(at: root) == true,
              let identity = FileIdentity(path: root.path) else { return nil }
        self.uuid = volume.id
        self.name = volume.name
        self.root = root
        self.identity = identity
    }

    var trash: URL { root.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true) }

    func matches(_ file: URL, device: dev_t) -> Bool {
        guard device == identity.dev, let relative = Self.relative(file.path, inside: root.path),
              relative.allSatisfy({ !$0.hasPrefix(".") }) else { return false }
        var parent = root
        for component in relative.dropLast() {
            parent.appendPathComponent(component, isDirectory: true)
            if SafetyGuard.isPackage(parent) { return false }
        }
        return true
    }

    func remap(_ path: String, from recordedMount: String) -> URL? {
        guard let relative = Self.relative(path, inside: recordedMount) else { return nil }
        return relative.reduce(root) { $0.appendingPathComponent($1) }
    }

    func openDirectory(_ url: URL) -> Int32? {
        let fd = open(Self.kernelPath(url.path), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == identity.dev else {
            close(fd)
            return nil
        }
        return fd
    }

    func stillMounted() -> Bool {
        let fresh = URL(fileURLWithPath: root.path, isDirectory: true)
        return FileIdentity(path: root.path) == identity
            && (try? fresh.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == uuid
    }

    func makeTrashDestination(for source: URL, id: UUID) throws -> URL {
        for directory in [trash.deletingLastPathComponent(), trash] {
            var info = stat()
            if lstat(directory.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_dev == identity.dev else {
                    throw RestoreError.notOurs
                }
            } else if errno != ENOENT {
                throw RestoreError.notOurs
            }
        }
        // Resolve Trash against the verified mount root, even if the source folder has changed.
        let folder = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                 appropriateFor: root, create: true)
        guard Self.kernelPath(folder.path) == trash.path, let fd = openDirectory(trash) else {
            throw POSIXError(.EXDEV)
        }
        close(fd)
        return trashDestination(for: source, id: id)
    }

    func trashDestination(for source: URL, id: UUID) -> URL {
        let suffix = " " + id.uuidString
        let ext = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
        let ending = ext.utf8.count <= 48 ? suffix + ext : suffix
        let base = source.deletingPathExtension().lastPathComponent
        var name = ""
        for character in base {
            let next = String(character)
            guard name.utf8.count + next.utf8.count + ending.utf8.count <= 255 else { break }
            name += next
        }
        return trash.appendingPathComponent(name + ending)
    }

    @discardableResult
    func rename(_ source: URL, to destination: URL, verify: (stat) -> Bool) throws -> stat? {
        guard let from = openDirectory(source.deletingLastPathComponent()) else {
            throw RestoreError.originalParentMissing
        }
        defer { close(from) }
        guard let to = openDirectory(destination.deletingLastPathComponent()) else {
            throw RestoreError.originalParentMissing
        }
        defer { close(to) }
        var info = stat()
        guard stillMounted(), fstatat(from, source.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == identity.dev, info.st_mode & S_IFMT == S_IFREG, verify(info) else {
            throw RestoreError.notOurs
        }
        if renameatx_np(from, source.lastPathComponent, to, destination.lastPathComponent, UInt32(RENAME_EXCL)) != 0 {
            if errno == EEXIST { throw RestoreError.originalPathOccupied }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var landed = stat()
        if fstatat(to, destination.lastPathComponent, &landed, AT_SYMLINK_NOFOLLOW) == 0 { return landed }
        return nil
    }

    static func kernelPath(_ path: String) -> String { SafetyGuard.withoutSystemPathAlias(path) }

    private static func canonicalDirectory(_ url: URL) -> URL? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        let result = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        // Only a direct mount of this volume may serve as the reference.
        guard let here = FileIdentity(path: result.path),
              let parent = FileIdentity(path: result.deletingLastPathComponent().path),
              here.dev != parent.dev else { return nil }
        return result
    }

    private static func relative(_ path: String, inside root: String) -> [String]? {
        let root = kernelPath(root).split(separator: "/")
        let parts = kernelPath(path).split(separator: "/")
        guard path.hasPrefix("/"), parts.count > root.count,
              parts.prefix(root.count).elementsEqual(root),
              !parts.contains("."), !parts.contains("..") else { return nil }
        return parts.dropFirst(root.count).map(String.init)
    }
}
