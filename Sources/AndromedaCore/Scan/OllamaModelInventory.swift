import CryptoKit
import Darwin
import Foundation

/// A read-only inventory of the default local model store. The sizes describe referenced
/// weight/config files on disk. APFS clones, snapshots, and Ollama's pruning affect freed space.
public enum OllamaModelInventory {
    public struct Model: Identifiable, Equatable, Sendable {
        public let id: String
        public let allocatedBytes: Int64
        public let sharedBytes: Int64
        public let unreadableBlobs: Int
    }

    public struct Result: Sendable {
        public let models: [Model]
        public let incomplete: Bool
    }

    private struct Manifest: Decodable {
        struct Layer: Decodable { let digest: String }

        let config: Layer?
        let layers: [Layer]?
        let manifests: [Manifest]?
        let digest: String?
    }

    private struct Blob {
        let identity: FileIdentity
        let bytes: Int64
    }

    private enum BlobState {
        case local(Blob)
        case unavailable
    }

    private static let manifestLimit = 2 * 1024 * 1024

    public static func scan(home: URL, control: ScanControl = ScanControl(onProgress: { _ in })) -> Result {
        let store = SafetyGuard.withoutSystemPathAlias(home.appendingPathComponent(".ollama/models").path)
        let lister = DirectoryLister(includeCloneRefCount: false, entryLimit: 25_000)
        var incomplete = false
        var manifests: [String: Manifest] = [:]
        let blobsDirectory = open(store + "/blobs", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        defer { if blobsDirectory >= 0 { close(blobsDirectory) } }

        func visit(_ path: String, parts: [String], isV2: Bool) {
            guard !control.isCancelled else { return }
            guard let entries = lister.entries(atPath: path, followAncestorLinks: false,
                                                shouldContinue: { !control.isCancelled }) else {
                incomplete = true
                return
            }
            for entry in entries where !control.isCancelled {
                guard entry.error == 0 else { incomplete = true; continue }
                guard !entry.name.hasPrefix("."), !entry.isMountPoint else { continue }
                let childPath = path + "/" + entry.name
                let components = parts + [entry.name]
                if components.count < 4 {
                    if entry.type == VDIR.rawValue { visit(childPath, parts: components, isV2: isV2) }
                    if entry.type == VLNK.rawValue { incomplete = true }
                } else if entry.type == VREG.rawValue {
                    let id = modelID(components)
                    let fd = open(childPath, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
                    defer { if fd >= 0 { close(fd) } }
                    if let manifest = readManifest(fd) { manifests[id] = manifest }
                    else { incomplete = true }
                } else if entry.type == VLNK.rawValue {
                    let id = modelID(components)
                    if isV2, let name = linkedManifestBlob(entry.name, in: path),
                       let manifest = readManifestBlob(name, in: blobsDirectory) {
                        manifests[id] = manifest
                    } else {
                        incomplete = true
                    }
                }
            }
        }

        for directory in ["manifests", "manifests-v2"] {
            let path = store + "/" + directory
            var info = stat()
            if lstat(path, &info) == 0 {
                visit(path, parts: [], isV2: directory == "manifests-v2")
            } else if errno != ENOENT {
                incomplete = true
            }
        }

        var metadata: [String: BlobState] = [:]
        var uses: [FileIdentity: Int] = [:]
        let inventoried = manifests.compactMap { (id, manifest) -> (String, [FileIdentity: Int64], Int)? in
            guard !control.isCancelled else { return nil }
            var references = Set<String>()
            for child in manifest.manifests ?? [manifest] {
                guard !control.isCancelled else { return nil }
                var content = child
                if child.config == nil, child.layers == nil, let digest = child.digest {
                    guard let name = blobName(digest),
                          let resolved = readManifestBlob(name, in: blobsDirectory) else {
                        incomplete = true
                        continue
                    }
                    content = resolved
                }
                guard content.manifests == nil, let layers = content.layers, let config = content.config else {
                    incomplete = true
                    continue
                }
                for digest in ([config] + layers).map(\.digest) {
                    if let name = blobName(digest) { references.insert(name) }
                    else { incomplete = true }
                }
            }

            var local: [FileIdentity: Int64] = [:]
            var unreadableBlobs = 0
            for name in references {
                guard !control.isCancelled else { return nil }
                let blob = metadata[name] ?? readBlob(name, in: blobsDirectory)
                metadata[name] = blob
                switch blob {
                case .local(let file): local[file.identity] = file.bytes
                case .unavailable: unreadableBlobs += 1
                }
            }
            for identity in local.keys { uses[identity, default: 0] += 1 }
            return (id, local, unreadableBlobs)
        }

        guard !control.isCancelled else { return Result(models: [], incomplete: true) }
        let models = inventoried.map { id, files, unreadable in
            Model(id: id, allocatedBytes: sum(files.values),
                  sharedBytes: sum(files.lazy.filter { uses[$0.key, default: 0] > 1 }.map(\.value)),
                  unreadableBlobs: unreadable)
        }
        return Result(models: models.sorted { a, b in
            a.allocatedBytes == b.allocatedBytes ? a.id < b.id : a.allocatedBytes > b.allocatedBytes
        }, incomplete: incomplete || models.contains { $0.unreadableBlobs > 0 })
    }

    private static func linkedManifestBlob(_ tag: String, in folder: String) -> String? {
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes = [CChar](repeating: 0, count: 256)
        let count = readlinkat(fd, tag, &bytes, bytes.count)
        guard count > 0, count < bytes.count else { return nil }
        // Ollama writes a relative link from the named manifest to the store's blobs directory.
        // Interpret only that spelling and open the digest independently in the pinned directory.
        let target = String(decoding: bytes.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let prefix = "../../../../blobs/"
        guard target.hasPrefix(prefix) else { return nil }
        return blobName(String(target.dropFirst(prefix.count)))
    }

    private static func readManifestBlob(_ name: String, in directory: Int32) -> Manifest? {
        guard directory >= 0 else { return nil }
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return readManifest(fd, matching: name)
    }

    private static func readBlob(_ name: String, in directory: Int32) -> BlobState {
        var info = stat()
        guard directory >= 0, fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_flags & UInt32(SF_DATALESS) == 0,
              info.st_blocks >= 0, info.st_blocks <= Int64.max / 512 else { return .unavailable }
        return .local(Blob(identity: FileIdentity(dev: info.st_dev, ino: info.st_ino),
                           bytes: info.st_blocks * 512))
    }

    private static func readManifest(_ fd: Int32, matching blob: String? = nil) -> Manifest? {
        var before = stat()
        guard fd >= 0, fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_flags & UInt32(SF_DATALESS) == 0, before.st_size > 0,
              before.st_size <= manifestLimit else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var after = stat()
        guard let data = try? file.read(upToCount: Int(before.st_size)), data.count == before.st_size,
              fstat(fd, &after) == 0, DuplicateScanner.unchanged(before, after) else { return nil }
        if let blob, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != blob.dropFirst(7) {
            return nil
        }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func blobName(_ digest: String) -> String? {
        guard digest.hasPrefix("sha256:") || digest.hasPrefix("sha256-") else { return nil }
        let hex = digest.lowercased().utf8.dropFirst(7)
        guard hex.count == 64, hex.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return "sha256-" + String(decoding: hex, as: UTF8.self)
    }

    private static func modelID(_ path: [String]) -> String {
        let host = path[0].replacingOccurrences(of: "%3A", with: ":", options: .caseInsensitive).lowercased()
        if host == "registry.ollama.ai" || host == "ollama.com" {
            return (path[1] == "library" ? "" : path[1] + "/") + path[2] + ":" + path[3]
        }
        return host + "/" + path[1] + "/" + path[2] + ":" + path[3]
    }

    private static func sum(_ values: some Sequence<Int64>) -> Int64 {
        values.reduce(0) { total, bytes in total + min(Int64.max - total, bytes) }
    }
}
