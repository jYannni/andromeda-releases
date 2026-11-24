import Darwin
import Foundation

public enum TrashBins {
    public struct Bin: Identifiable, Sendable {
        public var id: URL { root }
        public let title: String
        public let root: URL
        public let items: [Item]
        public let preserved: Int
        public let unavailable: Bool
    }

    public struct Item: Identifiable, Sendable {
        public var id: URL { url }
        public let url: URL
        public let binTitle: String
        public var bytes: Int64 { tree.bytes }
        let root: URL
        let binIdentity: FileIdentity
        let volume: ExternalVolume?
        let tree: ReviewedFileTree
    }

    public struct Receipt: Sendable {
        public var deleted = 0
        public var skipped = 0
        public var failed = 0
        public var journalFailed = false
    }

    public static func scan(env: ScanEnvironment, volumes: [ExternalVolume], control: ScanControl) -> [Bin] {
        let startup = scan(root: env.trash, title: "Startup Disk", volume: nil, control: control)
        let external = volumes.compactMap { volume -> Bin? in
            guard volume.kind == .drive, !volume.isReadOnly, volume.hasStableIdentity, !control.isCancelled else { return nil }
            let root = volume.url.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true)
            return scan(root: root, title: volume.name, volume: volume, control: control)
        }
        return [startup] + external
    }

    private static func scan(root: URL, title: String, volume: ExternalVolume?, control: ScanControl) -> Bin {
        let fd = ReviewedFileTree.openDirectory(root)
        guard fd >= 0 else {
            return Bin(title: title, root: root, items: [], preserved: 0, unavailable: errno != ENOENT)
        }
        defer { close(fd) }
        guard let identity = binIdentity(fd),
              volume.map({ FileIdentity(path: $0.url.path)?.dev == identity.dev }) ?? true,
              let names = ReviewedFileTree.names(in: fd) else {
            return Bin(title: title, root: root, items: [], preserved: 0, unavailable: true)
        }
        var preserved = 0
        let items = names.compactMap { name -> Item? in
            guard !control.isCancelled, name != ".DS_Store" else { return nil }
            guard let tree = ReviewedFileTree.capture(parent: fd, name: name, control: control),
                  tree.root.identity.dev == identity.dev else { preserved += 1; return nil }
            return Item(url: root.appendingPathComponent(name), binTitle: title, root: root,
                        binIdentity: identity, volume: volume, tree: tree)
        }
        return Bin(title: title, root: root, items: items, preserved: preserved, unavailable: false)
    }

    static func binIdentity(_ fd: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() else { return nil }
        return FileIdentity(dev: info.st_dev, ino: info.st_ino)
    }
}
