import CoreServices
import Darwin
import AndromedaCore
import Foundation

/// Advisory changes scoped to a mounted device or the contents of an approved folder.
final class FileChangeWatch {
    struct DriveEvent: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags

        func affectsCatalog(folder: String?) -> Bool {
            guard let folder, flags & FileChangeWatch.incomplete == 0 else { return true }
            let changed = String(path.drop(while: { $0 == "/" })).lowercased()
            let scope = folder.lowercased()
            if changed == scope || changed.hasPrefix(scope + "/") { return true }
            let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemInodeMetaMod)
            return flags & structural != 0 && (changed.isEmpty || scope.hasPrefix(changed + "/"))
        }
    }

    enum FolderChange: Sendable, Equatable {
        case changed
        case discontinuity
    }

    private enum Scope: Sendable {
        case drive(dev_t, mountPath: String, changed: @Sendable ([DriveEvent]) -> Void)
        case folder(String, maximumDepth: Int?, changed: @Sendable (FolderChange) -> Void)
    }

    private final class Callback: Sendable {
        let scope: Scope
        init(scope: Scope) { self.scope = scope }
    }

    private let stream: FSEventStreamRef

    /// Folder events can defer writes until close. Observe a settling file's vnode in the meantime.
    static func startPendingFile(path: String, fileID: UInt64, changed: @escaping @Sendable () -> Void) -> AnyObject? {
        let fd = open(path, O_EVTONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, UInt64(info.st_ino) == fileID, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0 else {
            close(fd)
            return nil
        }
        return PendingFileWatch(fd: fd, changed: changed)
    }

    private final class PendingFileWatch {
        let source: DispatchSourceFileSystemObject

        init(fd: Int32, changed: @escaping @Sendable () -> Void) {
            source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: .main)
            source.setEventHandler(handler: changed)
            source.setCancelHandler { close(fd) }
            source.resume()
        }

        deinit { source.cancel() }
    }

    static func startDrive(_ volume: ExternalVolume, changed: @escaping @Sendable ([DriveEvent]) -> Void) -> AnyObject? {
        let root = URL(fileURLWithPath: volume.url.path, isDirectory: true)
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == volume.id
        else { return nil }
        let mountPath = SafetyGuard.withoutSystemPathAlias(root.standardizedFileURL.path)
        return FileChangeWatch(scope: .drive(info.st_dev, mountPath: mountPath, changed: changed))
    }

    static func startFolder(
        _ folder: AutomationDirectories.Folder, maximumDepth: Int?, changed: @escaping @Sendable () -> Void
    ) -> AnyObject? {
        startFolderEvents(folder, maximumDepth: maximumDepth, queue: .main) { _ in changed() }
    }

    /// Coalesced change notices for an approved folder. A discontinuity requires revalidating the watched root.
    static func startFolderEvents(
        _ folder: AutomationDirectories.Folder, maximumDepth: Int? = 0, queue: DispatchQueue,
        changed: @escaping @Sendable (FolderChange) -> Void
    ) -> AnyObject? {
        guard let fd = folder.openCurrent() else { return nil }
        defer { close(fd) }
        return FileChangeWatch(scope: .folder(folder.path, maximumDepth: maximumDepth, changed: changed), queue: queue)
    }

    static func startFolderTree(_ reference: StorageBrowser.FolderReference, changed: @escaping @Sendable () -> Void) -> AnyObject? {
        guard reference.isCurrent() else { return nil }
        let path = SafetyGuard.withoutSystemPathAlias(reference.url.standardizedFileURL.path)
        return FileChangeWatch(scope: .folder(path, maximumDepth: nil, changed: { _ in changed() }))
    }

    private init?(scope: Scope, queue: DispatchQueue = .main) {
        let callback = Callback(scope: scope)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<Callback>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() } },
            copyDescription: nil)
        let eventCallback: FSEventStreamCallback = { _, pointer, count, paths, flags, _ in
            guard let pointer else { return }
            let callback = Unmanaged<Callback>.fromOpaque(pointer).takeUnretainedValue()
            let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            switch callback.scope {
            case .drive(_, let mountPath, let changed):
                let events = (0..<count).compactMap { index -> DriveEvent? in
                    let path = FileChangeWatch.driveRelativePath(String(cString: names[index]), mountPath: mountPath)
                    let eventFlags = flags[index]
                    guard FileChangeWatch.requiresDriveScan(path: path, flags: eventFlags) else { return nil }
                    return DriveEvent(path: path, flags: eventFlags)
                }
                if !events.isEmpty { changed(events) }
            case .folder(let folder, let maximumDepth, let changed):
                var notice: FolderChange?
                for index in 0..<count {
                    let eventFlags = flags[index]
                    if eventFlags & FileChangeWatch.incomplete != 0 {
                        notice = .discontinuity
                        break
                    }
                    if notice == nil, FileChangeWatch.requiresFolderCheck(path: String(cString: names[index]), folder: folder,
                                                                         flags: eventFlags, maximumDepth: maximumDepth) {
                        notice = .changed
                    }
                }
                if let notice { changed(notice) }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        let sinceNow = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let created: FSEventStreamRef?
        switch scope {
        case .drive(let device, _, _):
            created = FSEventStreamCreateRelativeToDevice(nil, eventCallback, &context, device, ["/"] as CFArray,
                                                         sinceNow, 1, flags)
        case .folder(let path, _, _):
            created = FSEventStreamCreate(nil, eventCallback, &context, [path] as CFArray, sinceNow, 0.25, flags)
        }
        guard let stream = created else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private static let incomplete = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
    private static let changes = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
        | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemXattrMod)

    static func requiresDriveScan(path: String, flags: FSEventStreamEventFlags) -> Bool {
        if flags & incomplete != 0 { return true }
        guard flags & (changes | UInt32(kFSEventStreamEventFlagItemInodeMetaMod)) != 0 else { return false }
        let folder = path.split(separator: "/", maxSplits: 1).first
        // Background indexing and the event journal itself can produce an endless stream of writes.
        return folder != ".fseventsd" && folder != ".Spotlight-V100"
    }

    static func driveRelativePath(_ path: String, mountPath: String) -> String {
        // Device streams can report either a path on the volume or the full mounted path.
        let fullPath = SafetyGuard.withoutSystemPathAlias(path)
        if fullPath == mountPath { return "" }
        let prefix = mountPath.hasSuffix("/") ? mountPath : mountPath + "/"
        return fullPath.hasPrefix(prefix) ? String(fullPath.dropFirst(prefix.count)) : path
    }

    static func requiresFolderCheck(
        path: String, folder: String, flags: FSEventStreamEventFlags, maximumDepth: Int? = 0
    ) -> Bool {
        if flags & incomplete != 0 { return true }
        guard flags & changes != 0 else { return false }
        let path = SafetyGuard.withoutSystemPathAlias(path)
        if path == folder { return true }
        let prefix = folder + "/"
        guard path.hasPrefix(prefix) else { return false }
        guard let maximumDepth else { return true }
        var depth = 0
        for character in path.dropFirst(prefix.count) where character == "/" {
            depth += 1
            if depth > maximumDepth { return false }
        }
        return true
    }
}
