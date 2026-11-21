import Darwin
import AndromedaCore
import Foundation

/// Copies a group of cataloged files and publishes the verified folder or ZIP.
public enum CollectionExport {
    public enum Format: Sendable { case folder, zip }

    public struct Source: Sendable {
        public let driveID: String
        public let root: URL
        let relativePath: String
        let modified: Date?
        let allocatedBytes: Int64
        let fileIdentity: CatalogFileIdentity?

        public init(driveID: String, root: URL, relativePath: String, modified: Date?, allocatedBytes: Int64,
                    fileIdentity: CatalogFileIdentity? = nil) {
            self.driveID = driveID
            self.root = root
            self.relativePath = relativePath
            self.modified = modified
            self.allocatedBytes = allocatedBytes
            self.fileIdentity = fileIdentity
        }
    }

    public struct Group: Sendable {
        let name: String
        let sources: [Source]
        let children: [Group]

        public init(name: String, sources: [Source], children: [Group] = []) {
            self.name = name
            self.sources = sources
            self.children = children
        }

        var allSources: [Source] { sources + children.flatMap(\.allSources) }
    }

    private struct ReviewedFile {
        let source: Source
        let rootPath: String
        let rootIdentity: FileIdentity
        let path: String
        let name: String
        let tree: ArchiveTree
    }

    private struct ReviewedGroup {
        let name: String
        let files: [ReviewedFile]
        let children: [ReviewedGroup]

        init(_ group: Group, control: ScanControl) throws {
            try ArchiveTree.check(control)
            name = group.name
            files = try group.sources.map { try review($0, control: control) }
            children = try group.children.map { try Self($0, control: control) }
        }
    }

    private struct StagedFile {
        let source: ReviewedFile
        let path: String
        let tree: ArchiveTree
    }

    private struct StagedFolder {
        let path: String
        let identity: FileIdentity
        let names: Set<String>

        func verify() throws {
            let fd = ArchiveTree.openDirectory(path)
            guard fd >= 0 else { throw ArchiveFailure.changed(path) }
            defer { close(fd) }
            guard CollectionExport.identity(fd) == identity,
                  try Set(ArchiveTree.children(fd, path: path)) == names else { throw ArchiveFailure.changed(path) }
        }
    }

    public static func copy(
        _ sources: [Source], named name: String, into folder: URL, format: Format = .folder, control: ScanControl,
        areMounted: ([Source]) -> Bool
    ) throws -> URL {
        try copy(Group(name: name, sources: sources), into: folder, format: format, control: control, areMounted: areMounted)
    }

    public static func copy(
        _ group: Group, into folder: URL, format: Format = .folder, control: ScanControl, areMounted: ([Source]) -> Bool
    ) throws -> URL {
        let sources = group.allSources
        guard !sources.isEmpty else { throw ArchiveFailure.unsupportedSource(group.name) }
        return switch format {
        case .folder: try copyFolder(group, sources: sources, named: group.name, into: folder, control: control, areMounted: areMounted)
        case .zip: try copyZIP(group, sources: sources, into: folder, control: control, areMounted: areMounted)
        }
    }

    private static func copyFolder(
        _ group: Group, sources: [Source], named name: String, into folder: URL, forZIP: Bool = false,
        control: ScanControl, areMounted: ([Source]) -> Bool
    ) throws -> URL {
        let parent = ArchiveTree.systemPath(folder.standardizedFileURL.path)
        let directory = ArchiveTree.openDirectory(parent)
        guard directory >= 0 else { throw ArchiveFailure.system(parent, errno) }
        defer { close(directory) }
        guard let parentIdentity = identity(directory) else { throw ArchiveFailure.system(parent, errno) }
        let limit = nameLimit(directory)
        let outputName = exportTitle(name, limit: limit)
        try requireUnoccupied(outputName, under: directory, path: parent)

        guard areMounted(sources) else { throw ArchiveFailure.mediaUnavailable }
        let reviewed = try ReviewedGroup(group, control: control)
        let stage = ".andromeda-export-" + UUID().uuidString
        let stagePath = parent + "/" + stage
        guard mkdirat(directory, stage, 0o700) == 0 else { throw ArchiveFailure.system(parent, errno) }
        let staging = openat(directory, stage, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard staging >= 0 else { throw ArchiveFailure.system(stagePath, errno) }
        defer { close(staging) }
        guard let stageIdentity = identity(staging) else { throw ArchiveFailure.system(stagePath, errno) }
        var published = false
        defer {
            if !published { removeStagingDirectory(stagePath, identity: stageIdentity) }
        }
        var files: [StagedFile] = []
        var folders: [StagedFolder] = []
        try stageContents(reviewed, in: staging, path: stagePath, identity: stageIdentity, limit: limit, forZIP: forZIP,
                          control: control, files: &files, folders: &folders)
        guard areMounted(sources) else { throw ArchiveFailure.mediaUnavailable }
        for file in files {
            try checkMount(file.source)
            guard try ArchiveTree(at: file.source.path, control: control) == file.source.tree,
                  try ArchiveTree(at: file.path, control: control) == file.tree else {
                throw ArchiveFailure.changed(file.source.source.relativePath)
            }
        }
        for folder in folders {
            try ArchiveTree.check(control)
            try folder.verify()
        }
        guard FileIdentity(path: stagePath) == stageIdentity, FileIdentity(path: parent) == parentIdentity else {
            throw ArchiveFailure.changed(parent)
        }
        try ArchiveTree.check(control)
        if renameatx_np(directory, stage, directory, outputName, UInt32(RENAME_EXCL)) != 0 {
            throw errno == EEXIST ? ArchiveFailure.occupied : ArchiveFailure.system(parent, errno)
        }
        published = true
        _ = fsync(directory)
        return URL(fileURLWithPath: parent + "/" + outputName, isDirectory: true)
    }

    private static func removeStagingDirectory(_ path: String, identity: FileIdentity) {
        guard FileIdentity(path: path) == identity else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func stageContents(
        _ group: ReviewedGroup, in directory: Int32, path: String, identity: FileIdentity, limit: Int, forZIP: Bool,
        control: ScanControl, files: inout [StagedFile], folders: inout [StagedFolder]
    ) throws {
        var names: Set<String> = []
        for child in group.children {
            try ArchiveTree.check(control)
            let title = exportTitle(forZIP ? zipComponent(child.name) : child.name, limit: limit)
            let name = try availableName(title, under: directory, limit: limit)
            let childPath = path + "/" + name
            guard mkdirat(directory, name, 0o700) == 0 else { throw ArchiveFailure.system(childPath, errno) }
            let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ArchiveFailure.system(childPath, errno) }
            defer { close(fd) }
            guard let childIdentity = Self.identity(fd), childIdentity.dev == identity.dev else {
                throw ArchiveFailure.changed(childPath)
            }
            names.insert(name)
            try stageContents(child, in: fd, path: childPath, identity: childIdentity, limit: limit, forZIP: forZIP,
                              control: control, files: &files, folders: &folders)
        }
        for file in group.files {
            try ArchiveTree.check(control)
            try checkMount(file)
            control.entry(file.name)
            let name = forZIP ? zipComponent(file.name) : file.name
            let target = try availableName(name, under: directory, limit: limit)
            let destination = path + "/" + target
            names.insert(target)
            let fingerprint = try file.tree.fingerprints(at: file.path, control: control, includeEntries: false,
                                                        verification: .mediaSource)
            try file.tree.copyRegularFile(from: file.path, to: target, under: directory, path: destination, device: identity.dev)
            guard FileIdentity(path: path) == identity else { throw ArchiveFailure.changed(path) }
            let tree = try ArchiveTree(at: destination, control: control)
            let actual = try tree.fingerprints(at: destination, control: control, includeEntries: false,
                                               verification: .mediaSource)
            guard let expected = fingerprint.mediaDigest, actual.mediaDigest == expected else { throw ArchiveFailure.verification }
            files.append(StagedFile(source: file, path: destination, tree: tree))
            control.file(bytes: file.tree.nodes[0].bytes)
        }
        guard fsync(directory) == 0 else { throw ArchiveFailure.system(path, errno) }
        folders.append(StagedFolder(path: path, identity: identity, names: names))
    }

    private static func copyZIP(
        _ group: Group, sources: [Source], into folder: URL, control: ScanControl, areMounted: ([Source]) -> Bool
    ) throws -> URL {
        let name = group.name
        try ArchiveTree.check(control)
        let parent = ArchiveTree.systemPath(folder.standardizedFileURL.path)
        let directory = ArchiveTree.openDirectory(parent)
        guard directory >= 0 else { throw ArchiveFailure.system(parent, errno) }
        defer { close(directory) }
        guard let parentIdentity = identity(directory) else { throw ArchiveFailure.system(parent, errno) }
        let basename = name.lowercased().hasSuffix(".zip") ? String(name.dropLast(4)) : name
        let title = exportTitle(zipComponent(basename), limit: nameLimit(directory) - 4)
        let outputName = title + ".zip"
        try requireUnoccupied(outputName, under: directory, path: parent)

        let stage = ".andromeda-zip-" + UUID().uuidString
        let stagePath = parent + "/" + stage
        guard mkdirat(directory, stage, 0o700) == 0 else { throw ArchiveFailure.system(parent, errno) }
        let staging = openat(directory, stage, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard staging >= 0 else { throw ArchiveFailure.system(stagePath, errno) }
        defer { close(staging) }
        guard let stageIdentity = identity(staging) else { throw ArchiveFailure.system(stagePath, errno) }
        let stageURL = URL(fileURLWithPath: stagePath, isDirectory: true)
        defer { removeStagingDirectory(stagePath, identity: stageIdentity) }

        let payload = try copyFolder(group, sources: sources, named: title, into: stageURL, forZIP: true,
                                     control: control, areMounted: areMounted)
        let payloadTree = try ArchiveTree(at: payload.path, control: control)
        let expected = try payloadTree.fingerprints(at: payload.path, control: control, includeEntries: false,
                                                    verification: .mediaSource).mediaDigest
        let archiveName = ".export.zip"
        let archive = stagePath + "/" + archiveName
        control.entry("Creating ZIP")
        guard FileIdentity(path: stagePath) == stageIdentity,
              try ArchiveTree(at: payload.path, control: control) == payloadTree else { throw ArchiveFailure.changed(payload.path) }
        try runDitto(["-c", "-k", "--rsrc", "--sequesterRsrc", "--keepParent", payload.path, archive], control: control)
        let archiveTree = try ArchiveTree(at: archive, control: control)
        guard archiveTree.nodes.count == 1, let node = archiveTree.nodes.first, !node.folder, node.bytes > 0 else {
            throw ArchiveFailure.verification
        }

        let verifyName = ".verify"
        let verification = stagePath + "/" + verifyName
        guard mkdirat(staging, verifyName, 0o700) == 0 else { throw ArchiveFailure.system(verification, errno) }
        let verificationFD = openat(staging, verifyName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard verificationFD >= 0 else { throw ArchiveFailure.system(verification, errno) }
        defer { close(verificationFD) }
        guard let verificationIdentity = identity(verificationFD) else { throw ArchiveFailure.system(verification, errno) }
        control.entry("Verifying ZIP")
        guard FileIdentity(path: verification) == verificationIdentity,
              try ArchiveTree(at: archive, control: control) == archiveTree else { throw ArchiveFailure.changed(archive) }
        try runDitto(["-x", "-k", "--rsrc", archive, verification], control: control)
        let extracted = verification + "/" + payload.lastPathComponent
        let extractedTree = try ArchiveTree(at: extracted, control: control)
        let actual = try extractedTree.fingerprints(at: extracted, control: control, includeEntries: false,
                                                    verification: .mediaSource).mediaDigest
        guard let expected, expected == actual,
              FileIdentity(path: verification) == verificationIdentity,
              try ArchiveTree.children(verificationFD, path: verification) == [payload.lastPathComponent],
              try ArchiveTree(at: payload.path, control: control) == payloadTree else {
            throw ArchiveFailure.verification
        }

        let zip = openat(staging, archiveName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard zip >= 0 else { throw ArchiveFailure.system(archive, errno) }
        defer { close(zip) }
        guard identity(zip) == node.identity, fsync(zip) == 0,
              try ArchiveTree(at: archive, control: control) == archiveTree,
              FileIdentity(path: stagePath) == stageIdentity, FileIdentity(path: parent) == parentIdentity else {
            throw ArchiveFailure.changed(archive)
        }
        try ArchiveTree.check(control)
        if renameatx_np(staging, archiveName, directory, outputName, UInt32(RENAME_EXCL)) != 0 {
            throw errno == EEXIST ? ArchiveFailure.occupied : ArchiveFailure.system(parent, errno)
        }
        _ = fsync(directory)
        return URL(fileURLWithPath: parent + "/" + outputName)
    }

    private static func runDitto(_ arguments: [String], control: ScanControl) throws {
        try ArchiveTree.check(control)
        let tool = URL(fileURLWithPath: "/usr/bin/ditto")
        let result = try LiveToolRunner().run(tool, arguments, shouldContinue: { !control.isCancelled })
        try ArchiveTree.check(control)
        guard result.exitCode == 0 else { throw ArchiveFailure.collectionZIP }
    }

    private static func requireUnoccupied(_ name: String, under directory: Int32, path: String) throws {
        var existing = stat()
        if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 { throw ArchiveFailure.occupied }
        guard errno == ENOENT else { throw ArchiveFailure.system(path, errno) }
    }

    private static func exportTitle(_ name: String, limit: Int) -> String {
        let sanitized = String(name.map { $0 == "/" || $0 == ":" || $0.isNewline || $0 == "\0" ? "-" : $0 })
        let title = shortened(sanitized.trimmingCharacters(in: .whitespacesAndNewlines), to: limit)
        return title.isEmpty || title.hasPrefix(".") ? "Collection" : title
    }

    /// Some ZIP extractors interpret a backslash as a path separator.
    private static func zipComponent(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "-")
    }

    private static func nameLimit(_ fd: Int32) -> Int {
        let limit = Int(fpathconf(fd, _PC_NAME_MAX))
        return limit > 0 ? limit : 255
    }

    private static func review(_ source: Source, control: ScanControl) throws -> ReviewedFile {
        try ArchiveTree.check(control)
        let parts = source.relativePath.components(separatedBy: "/")
        guard let name = parts.last, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
            throw ArchiveFailure.unsupportedSource(source.relativePath)
        }
        let root = ArchiveTree.systemPath(source.root.standardizedFileURL.path)
        guard let rootIdentity = FileIdentity(path: root) else { throw ArchiveFailure.mediaUnavailable }
        let path = root + "/" + source.relativePath
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveFailure.system(source.relativePath, errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == rootIdentity.dev, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { throw ArchiveFailure.changed(source.relativePath) }
        if let fileIdentity = source.fileIdentity, !fileIdentity.matches(info) { throw ArchiveFailure.changed(source.relativePath) }
        let node = ArchiveTree.Node(info, relative: "")
        let modified = Date(timeIntervalSince1970: Double(node.modifiedSeconds) + Double(node.modifiedNanos) / 1e9)
        // Hard-link deduplication can record zero allocated bytes for a readable file.
        guard source.modified == nil || source.modified == modified,
              source.allocatedBytes == 0 || source.allocatedBytes == Int64(info.st_blocks) * 512 else {
            throw ArchiveFailure.changed(source.relativePath)
        }
        let tree = try ArchiveTree(at: path, control: control)
        guard tree.nodes == [node] else { throw ArchiveFailure.changed(source.relativePath) }
        let file = ReviewedFile(source: source, rootPath: root, rootIdentity: rootIdentity, path: path, name: name, tree: tree)
        try checkMount(file)
        return file
    }

    private static func checkMount(_ file: ReviewedFile) throws {
        guard FileIdentity(path: file.rootPath) == file.rootIdentity else {
            throw ArchiveFailure.mediaUnavailable
        }
    }

    private static func availableName(_ name: String, under directory: Int32, limit: Int) throws -> String {
        let ext = (name as NSString).pathExtension
        let ending = ext.isEmpty ? "" : "." + ext
        let stem = (name as NSString).deletingPathExtension
        var number = 1
        while true {
            let suffix = number == 1 ? "" : " (\(number))"
            let remaining = limit - ending.utf8.count - suffix.utf8.count
            let candidate = name.utf8.count <= limit && number == 1 ? name
                : remaining > 0 ? shortened(stem, to: remaining) + suffix + ending
                : shortened(name, to: limit - suffix.utf8.count) + suffix
            var info = stat()
            if fstatat(directory, candidate, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return candidate }
                throw ArchiveFailure.system(candidate, errno)
            }
            number += 1
        }
    }

    private static func shortened(_ text: String, to limit: Int) -> String {
        var result = text
        while !result.isEmpty, result.utf8.count > limit { result.removeLast() }
        return result
    }

    private static func identity(_ fd: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return FileIdentity(dev: info.st_dev, ino: info.st_ino)
    }
}
