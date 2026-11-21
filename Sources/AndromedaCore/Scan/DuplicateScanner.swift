import CryptoKit
import Darwin
import Foundation

public enum DuplicateScanner {
    private static let sampleMinimumBytes: Int64 = 4 * 1_048_576
    private static let sampleWindowBytes = 16 * 1024

    public struct Group: Identifiable, Sendable {
        public var id: URL { files[0] }
        public let logicalBytesPerFile: Int64
        public let files: [URL]
        public let trashCandidates: Set<URL>
        public let externalTrashCandidates: Set<URL>
        public let reviewIdentifier: Data
        fileprivate let candidates: [Candidate]
        fileprivate let digest: SHA256.Digest
    }

    struct TrashCheck: Equatable, Sendable {
        fileprivate let target: Candidate
        fileprivate let keeper: Candidate
        fileprivate let digest: SHA256.Digest

        var targetURL: URL { target.url }
        var keeperURL: URL { keeper.url }
        var volume: ExternalDuplicateVolume? { target.volume }
        var digestData: Data { Data(digest) }

        func verify(env: ScanEnvironment) -> Bool {
            verifiedTarget(env: env) != nil
        }

        func verifiedTarget(env: ScanEnvironment) -> stat? {
            guard let home = FileIdentity(path: env.home.path),
                  DuplicateScanner.canTrash(target, homeDevice: home.dev, env: env),
                  target.volume?.stillMounted() != false,
                  DuplicateScanner.canRetain(keeper, homeDevice: home.dev, env: env)
            else { return nil }
            let control = ScanControl { _ in }
            guard let kept = fingerprint(keeper, control: control), kept.digest == digest,
                  let removed = fingerprint(target, control: control), removed.digest == digest
            else { return nil }
            // Recheck both names after the slower content reads.
            return stillMatches(keeper, kept.info) && stillMatches(target, removed.info) ? removed.info : nil
        }
    }

    public struct Result: Sendable {
        public let groups: [Group]
        public let skippedCount: Int
    }

    public struct Scope: Sendable {
        let folder: URL
        let canReadProtectedPaths: Bool

        public init(folder: URL, canReadProtectedPaths: Bool) {
            self.folder = folder
            self.canReadProtectedPaths = canReadProtectedPaths
        }
    }

    struct Candidate: Equatable, Sendable {
        let url: URL
        let identity: FileIdentity
        let bytes: Int64
        var volume: ExternalDuplicateVolume? = nil
    }

    public static let cleanupCatalogID = "cleanup.duplicate"

    public static func canPreview(_ url: URL, in group: Group) -> Bool {
        guard let candidate = group.candidates.first(where: { $0.url == url }),
              candidate.volume?.stillMounted() != false else { return false }
        return StorageBrowser.canPreview(candidate.url, identity: candidate.identity,
                                         expectedSize: candidate.bytes, allowsAncestorLinks: false)
    }

    static func trashChecks(in group: Group, selected: Set<URL>, env: ScanEnvironment) -> [TrashCheck]? {
        guard !selected.isEmpty, selected.isSubset(of: group.trashCandidates),
              let home = FileIdentity(path: env.home.path),
              let keeper = group.candidates.first(where: {
                  !selected.contains($0.url) && canRetain($0, homeDevice: home.dev, env: env)
              }) else { return nil }
        let targets = group.candidates.filter { selected.contains($0.url) }
        guard targets.allSatisfy({ canTrash($0, homeDevice: home.dev, env: env) }) else { return nil }
        return targets.map { TrashCheck(target: $0, keeper: keeper, digest: group.digest) }
    }

    private static func canRetain(_ candidate: Candidate, homeDevice: dev_t, env: ScanEnvironment) -> Bool {
        candidate.identity.dev != homeDevice || canTrash(candidate.url, env: env)
    }

    private static func canTrash(_ candidate: Candidate, homeDevice: dev_t, env: ScanEnvironment) -> Bool {
        if let volume = candidate.volume { return volume.matches(candidate.url, device: candidate.identity.dev) }
        return candidate.identity.dev == homeDevice && canTrash(candidate.url, env: env)
    }

    static func canTrash(_ url: URL, env: ScanEnvironment) -> Bool {
        guard let path = realpath(env.home.path, nil) else { return false }
        defer { free(path) }
        let prefix = String(cString: path) + "/"
        guard url.path.hasPrefix(prefix),
              let first = url.path.dropFirst(prefix.count).split(separator: "/").first,
              !["library", ".trash"].contains(first.lowercased())
        else { return false }
        return SafetyGuard.checkRemovable(url, env: env) == nil
    }

    /// Returns nil on cancellation. Only files sharing a nonzero logical size need content reads.
    public static func scan(
        _ folder: URL, env: ScanEnvironment, canReadProtectedPaths: Bool, control: ScanControl
    ) -> Result? {
        scan([Scope(folder: folder, canReadProtectedPaths: canReadProtectedPaths)], env: env, control: control)
    }

    public static func scan(
        _ scopes: [Scope], env: ScanEnvironment, volumes: [ExternalVolume] = [], control: ScanControl
    ) -> Result? {
        guard !control.isCancelled else { return nil }
        var bySize: [Int64: [Candidate]] = [:]
        let home = FileIdentity(path: env.home.path)
        guard let walk = walkCandidates(scopes, env: env, volumes: volumes, control: control, visit: { candidate in
            bySize[candidate.bytes, default: []].append(candidate)
            return true
        }) else { return nil }
        var skipped = walk.skipped

        func groupedByFingerprint(_ candidates: [Candidate], sampled: Bool = false) -> [SHA256.Digest: [Candidate]] {
            var byDigest: [SHA256.Digest: [Candidate]] = [:]
            for candidate in candidates {
                guard !control.isCancelled else { return [:] }
                if let match = fingerprint(candidate, control: control, sampled: sampled) {
                    byDigest[match.digest, default: []].append(candidate)
                } else {
                    skipped += 1
                }
            }
            return byDigest
        }

        var groups: [Group] = []
        for (bytes, candidates) in bySize where candidates.count > 1 {
            guard !control.isCancelled else { return nil }
            let batches = bytes >= sampleMinimumBytes
                ? groupedByFingerprint(candidates, sampled: true).values.filter { $0.count > 1 }
                : [candidates]
            for batch in batches {
                for (digest, copies) in groupedByFingerprint(batch) where copies.count > 1 {
                    let sorted = copies.sorted { $0.url.path < $1.url.path }
                    let eligible = home.map { home in
                        sorted.filter { canTrash($0, homeDevice: home.dev, env: env) }
                    } ?? []
                    let files = sorted.map(\.url)
                    groups.append(Group(logicalBytesPerFile: bytes, files: files,
                                        trashCandidates: Set(eligible.map(\.url)),
                                        externalTrashCandidates: Set(eligible.filter { $0.volume != nil }.map(\.url)),
                                        reviewIdentifier: reviewIdentifier(digest: digest, files: files),
                                        candidates: sorted, digest: digest))
                }
            }
        }
        guard !control.isCancelled else { return nil }
        groups.sort {
            if $0.logicalBytesPerFile == $1.logicalBytesPerFile { return $0.id.path < $1.id.path }
            return $0.logicalBytesPerFile > $1.logicalBytesPerFile
        }
        return Result(groups: groups, skippedCount: skipped)
    }

    static func walkCandidates(
        _ scopes: [Scope], env: ScanEnvironment, volumes: [ExternalVolume] = [], control: ScanControl,
        includesFile: (URL) -> Bool = { _ in true },
        visit: (Candidate) -> Bool
    ) -> (skipped: Int, stoppedEarly: Bool)? {
        let lister = DirectoryLister(includeDataLength: true, includeCloneRefCount: false)
        var seen = Set<FileIdentity>()
        var listedDirectories = Set<FileIdentity>()
        let home = FileIdentity(path: env.home.path)
        var eligibleVolumes: [dev_t: ExternalDuplicateVolume] = [:]
        var checkedDevices = Set<dev_t>()
        var skipped = 0
        for scope in scopes {
            guard !control.isCancelled else { return nil }
            guard let (root, identity) = approvedRoot(scope, env: env) else {
                skipped += 1
                continue
            }
            let device = identity.dev
            if device != home?.dev, checkedDevices.insert(device).inserted {
                let rootPath = root.path
                let mounted = volumes.first {
                    let mount = ExternalDuplicateVolume.kernelPath($0.url.path)
                    return rootPath == mount || rootPath.hasPrefix(mount + "/")
                }
                if let mounted, let external = ExternalDuplicateVolume(mounted), external.identity.dev == device {
                    eligibleVolumes[device] = external
                }
            }
            var pending = [(url: root, identity: identity)]
            while let (directory, directoryID) = pending.popLast() {
                guard !control.isCancelled else { return nil }
                guard !listedDirectories.contains(directoryID) else { continue }
                guard let entries = lister.entries(atPath: directory.path, followAncestorLinks: false,
                                                   expectedIdentity: directoryID,
                                                   shouldContinue: { !control.isCancelled }) else {
                    skipped += 1
                    continue
                }
                listedDirectories.insert(directoryID)
                for entry in entries {
                    guard !control.isCancelled else { return nil }
                    if entry.error != 0 {
                        skipped += 1
                        continue
                    }
                    guard !entry.name.isEmpty, !entry.name.hasPrefix("."), entry.flags & UInt32(UF_HIDDEN) == 0 else { continue }
                    guard entry.device == device, !entry.isMountPoint, entry.flags & UInt32(SF_DATALESS) == 0 else {
                        skipped += 1
                        continue
                    }
                    let url = directory.appendingPathComponent(entry.name, isDirectory: entry.type == VDIR.rawValue)
                    guard scope.canReadProtectedPaths || !env.isPromptingPath(url) else {
                        skipped += 1
                        continue
                    }
                    let identity = FileIdentity(dev: device, ino: entry.inode)
                    if entry.type == VDIR.rawValue {
                        guard !SafetyGuard.isPackage(url) else { continue }
                        if entry.inode != 0 {
                            pending.append((url, identity))
                        } else if let current = FileIdentity(path: url.path), current.dev == device {
                            pending.append((url, current))
                        } else {
                            skipped += 1
                        }
                    } else if entry.type == VREG.rawValue, includesFile(url) {
                        guard let bytes = entry.dataLength else {
                            skipped += 1
                            continue
                        }
                        guard bytes > 0, entry.inode != 0, seen.insert(identity).inserted else { continue }
                        let candidate = Candidate(url: url, identity: identity, bytes: bytes,
                                                  volume: eligibleVolumes[device])
                        guard visit(candidate) else { return (skipped, true) }
                    }
                }
            }
        }
        return control.isCancelled ? nil : (skipped, false)
    }

    private static func reviewIdentifier(digest: SHA256.Digest, files: [URL]) -> Data {
        var hash = SHA256()
        hash.update(data: Data(digest))
        let paths = files.map { Data($0.path.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
        for path in paths {
            hash.update(data: path)
            // A filesystem path cannot contain a null byte.
            hash.update(data: Data([0]))
        }
        return Data(hash.finalize())
    }

    private static func approvedRoot(_ scope: Scope, env: ScanEnvironment) -> (URL, FileIdentity)? {
        // Use the kernel spelling so O_NOFOLLOW_ANY can also protect descendants.
        guard scope.canReadProtectedPaths || !env.isPromptingPath(scope.folder),
              let path = realpath(scope.folder.path, nil) else { return nil }
        defer { free(path) }
        let root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        var info = stat()
        let inTrash = root.pathComponents.contains { [".trash", ".trashes"].contains($0.lowercased()) }
        guard !inTrash, scope.canReadProtectedPaths || !env.isPromptingPath(root),
              lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_flags & UInt32(SF_DATALESS) == 0, !SafetyGuard.isPackage(root) else { return nil }
        return (root, FileIdentity(dev: info.st_dev, ino: info.st_ino))
    }

    private static func fingerprint(
        _ candidate: Candidate, control: ScanControl, sampled: Bool = false
    ) -> (digest: SHA256.Digest, info: stat)? {
        let fd = open(candidate.url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, matches(candidate, before) else { return nil }

        // Ignore files with resource forks so equal data forks do not hide different contents.
        let fork = fgetxattr(fd, XATTR_RESOURCEFORK_NAME, nil, 0, 0, 0)
        guard fork == 0 || (fork < 0 && (errno == ENOATTR || errno == ENOTSUP)) else { return nil }

        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var hash = SHA256()
        if sampled {
            // Equal-size copies always use the same beginning, middle, and end windows.
            let lastOffset = candidate.bytes - Int64(sampleWindowBytes)
            for offset in [0, lastOffset / 2, lastOffset] {
                guard !control.isCancelled,
                      (try? file.seek(toOffset: UInt64(offset))) != nil,
                      let block = try? file.read(upToCount: sampleWindowBytes),
                      block.count == sampleWindowBytes else { return nil }
                hash.update(data: block)
            }
        } else {
            var remaining = candidate.bytes
            while remaining > 0 {
                guard !control.isCancelled,
                      let block = try? file.read(upToCount: Int(min(remaining, 1_048_576))),
                      !block.isEmpty else { return nil }
                hash.update(data: block)
                remaining -= Int64(block.count)
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, matches(candidate, after), unchanged(before, after),
              stillMatches(candidate, before)
        else { return nil }
        return (hash.finalize(), after)
    }

    static func stillMatches(_ candidate: Candidate, _ checked: stat) -> Bool {
        var current = stat()
        return lstat(candidate.url.path, &current) == 0
            && matches(candidate, current) && unchanged(checked, current)
    }

    static func matches(_ candidate: Candidate, _ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_flags & UInt32(SF_DATALESS) == 0
            && info.st_dev == candidate.identity.dev && info.st_ino == candidate.identity.ino
            && info.st_size == candidate.bytes
    }

    static func unchanged(_ before: stat, _ after: stat) -> Bool {
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    static func matchesTrashFingerprint(at url: URL, info: stat, digest: Data) -> Bool {
        let candidate = Candidate(url: url, identity: FileIdentity(dev: info.st_dev, ino: info.st_ino),
                                  bytes: info.st_size)
        guard let fingerprint = fingerprint(candidate, control: ScanControl { _ in }) else { return false }
        return Data(fingerprint.digest) == digest
    }
}
