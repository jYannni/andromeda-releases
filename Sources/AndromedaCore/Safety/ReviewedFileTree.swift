import Darwin
import Foundation

/// Metadata approved by a person before a file operation. Directory traversal stays on the
/// original device and never follows a symbolic link.
struct ReviewedFileTree: Equatable, Sendable {
    struct Stamp: Equatable, Sendable {
        let identity: FileIdentity
        let kind: mode_t
        let owner: uid_t
        let size: Int64
        let blocks: Int64
        let modified: timespec
        let changed: timespec

        init(_ info: stat) {
            identity = FileIdentity(dev: info.st_dev, ino: info.st_ino)
            kind = info.st_mode & S_IFMT
            owner = info.st_uid
            size = info.st_size
            blocks = info.st_blocks
            modified = info.st_mtimespec
            changed = info.st_ctimespec
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.identity == rhs.identity && lhs.kind == rhs.kind && lhs.owner == rhs.owner
                && lhs.size == rhs.size && lhs.blocks == rhs.blocks
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    let nodes: [String: Stamp]
    let bytes: Int64
    var root: Stamp { nodes[""]! }

    private init(nodes: [String: Stamp]) {
        self.nodes = nodes
        var counted: Set<FileIdentity> = []
        bytes = nodes.values.reduce(0) { total, node in
            total + (counted.insert(node.identity).inserted ? max(0, node.blocks) * 512 : 0)
        }
    }

    static func openDirectory(_ url: URL) -> Int32 {
        open(SafetyGuard.withoutSystemPathAlias(url.path), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    }

    static func capture(_ url: URL, control: ScanControl? = nil) -> Self? {
        let parent = openDirectory(url.deletingLastPathComponent())
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        return capture(parent: parent, name: url.lastPathComponent, control: control)
    }

    static func stamp(parent: Int32, name: String) -> Stamp? {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        return Stamp(info)
    }

    static func names(in fd: Int32) -> [String]? {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 ? result.sorted() : nil }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(bytes: raw.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
            }
            guard let name else { return nil }
            if name != "." && name != ".." { result.append(name) }
        }
    }

    static func capture(parent: Int32, name: String, control: ScanControl? = nil) -> Self? {
        guard let root = stamp(parent: parent, name: name) else { return nil }
        var nodes: [String: Stamp] = [:]
        func visit(parent: Int32, name: String, path: String, depth: Int) -> Bool {
            guard depth <= 96, nodes.count < 100_000, control?.isCancelled != true,
                  let info = stamp(parent: parent, name: name), info.owner == getuid(),
                  info.identity.dev == root.identity.dev else { return false }
            nodes[path] = info
            switch info.kind {
            case S_IFREG, S_IFLNK: return true
            case S_IFDIR:
                let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { return false }
                defer { close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0, Stamp(opened) == info, let contents = names(in: fd) else { return false }
                for child in contents {
                    guard visit(parent: fd, name: child, path: path.isEmpty ? child : path + "/" + child,
                                depth: depth + 1) else { return false }
                }
                return stamp(parent: parent, name: name) == info
            default: return false
            }
        }
        guard visit(parent: parent, name: name, path: "", depth: 0), nodes[""] == root else { return nil }
        return Self(nodes: nodes)
    }
}
