import AndromedaCore
import Darwin
import Foundation

/// Projects a completed scan's category into the file-backed locations that can be browsed
/// without the helper. Other accounts and aggregate-only volume totals have no file rows.
public struct StorageBrowseScope: Sendable {
    public let roots: [StorageBrowser.Root]
    public let excluded: [URL]
    public let env: ScanEnvironment
    public let canReadProtectedPaths: Bool
    private let savedFolder: URL?
    private let folderReference: StorageBrowser.FolderReference?
    private let explicitlyChosen: Bool
    private typealias DriveMount = (root: URL, identity: FileIdentity?, isCurrent: @Sendable () -> Bool)
    private let driveMount: DriveMount?

    public init(category: AppleBucket, result: ScanResult) {
        let env = result.env
        let library = env.home.appendingPathComponent("Library", isDirectory: true)
        let iCloud = library.appendingPathComponent("Mobile Documents", isDirectory: true)
        let claimed = result.findings.flatMap { $0.items.map(\.url) }
        var roots: [StorageBrowser.Root] = []
        var excluded = claimed
        if category != .applications { excluded += env.applicationsRoots }
        switch category {
        case .documents:
            roots.append(.init(env.home, .homeDocuments))
        case .systemData:
            roots.append(.init(env.home, .homeSystemData))
            excluded.append(iCloud)
        case .icloudDrive:
            roots.append(.init(iCloud, .children, mayBeMissing: true))
        case .applications:
            roots += env.applicationsRoots.map { .init($0, .children, mayBeMissing: true) }
        default:
            break
        }
        let outsideRoots = result.reconciliation.outside.filter { $0.row.bucket == category }.flatMap(\.browsableRoots)
        if !outsideRoots.isEmpty {
            roots += outsideRoots.map { StorageBrowser.Root($0) }
            excluded += OutsideHomeScanner.claims(catalogItems: claimed, env: env)
        }
        roots += result.findings.filter { $0.entry.bucket == category }
            .flatMap { $0.items.map { StorageBrowser.Root($0.url) } }
        self.roots = roots
        self.excluded = excluded
        self.env = env
        canReadProtectedPaths = result.fda == .granted
        explicitlyChosen = false
        savedFolder = nil
        folderReference = nil
        driveMount = nil
    }

    public init(
        folder: URL, env: ScanEnvironment, fda: FDAStatus, explicitlyChosen: Bool = true,
        folderReference: StorageBrowser.FolderReference? = nil
    ) {
        roots = [.init(folder, .children)]
        excluded = []
        self.env = env
        self.explicitlyChosen = explicitlyChosen
        // A folder picked explicitly can use the access macOS grants for that folder.
        // Choosing home does not opt the user into probing every protected location in it.
        canReadProtectedPaths = fda == .granted || (explicitlyChosen && env.isPromptingPath(folder))
        savedFolder = explicitlyChosen && folderReference == nil ? nil : folder
        self.folderReference = folderReference
        driveMount = nil
    }

    init(drive: ExternalVolume, env: ScanEnvironment, fda: FDAStatus, isCurrentMount: @escaping @Sendable () -> Bool) {
        let root = drive.url.standardizedFileURL
        self.init(driveMount: (root, FileIdentity(path: root.path), isCurrentMount),
                  excluded: DriveScanner.browserExclusions(on: root), env: env,
                  canReadProtectedPaths: fda == .granted, folderReference: nil)
    }

    private init(
        driveMount: DriveMount, excluded: [URL], env: ScanEnvironment,
        canReadProtectedPaths: Bool, folderReference: StorageBrowser.FolderReference?
    ) {
        roots = [.init(folderReference?.url ?? driveMount.root, .children)]
        self.excluded = excluded
        self.env = env
        self.canReadProtectedPaths = canReadProtectedPaths
        explicitlyChosen = false
        savedFolder = folderReference?.url
        self.folderReference = folderReference
        self.driveMount = driveMount
    }

    public func narrowedToDriveFolder(_ chosen: URL, reference: StorageBrowser.FolderReference? = nil) async -> Self? {
        await BackgroundWork.runNonThrowing("andromeda.scan.drive-folder") {
            narrow(to: chosen, savedReference: reference)
        }
    }

    var catalogFolderURL: URL? { savedFolder }

    func narrowedToSavedCatalogFolder(_ path: String, identity: CatalogFileIdentity?) async -> Self? {
        await BackgroundWork.runNonThrowing("andromeda.scan.saved-drive-folder") {
            guard let driveMount, DriveCatalogStore.isRelativePath(path), Self.isCurrent(driveMount) else { return nil }
            let saved = driveMount.root.appendingPathComponent(path, isDirectory: true)
            guard let identity else { return narrow(to: saved) }

            let physicalRoot = SafetyGuard.withoutSystemPathAlias(driveMount.root.resolvingSymlinksInPath().path)
            var filesystem = statfs()
            guard statfs(physicalRoot, &filesystem) == 0, withUnsafeBytes(of: filesystem.f_fstypename, {
                $0.prefix { $0 != 0 }.elementsEqual("apfs".utf8)
            }) else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let size = fsgetpath(&buffer, buffer.count, &filesystem.f_fsid, identity.inode)
            guard size > 0, size <= buffer.count, buffer.contains(0),
                  let absolute = buffer.withUnsafeBufferPointer({ $0.baseAddress.flatMap(String.init(validatingCString:)) }) else {
                return narrow(to: saved, matching: identity)
            }
            let prefix = (physicalRoot + "/").utf8
            let physicalPath = SafetyGuard.withoutSystemPathAlias(absolute)
            guard physicalPath.utf8.starts(with: prefix) else { return nil }
            let relative = String(decoding: physicalPath.utf8.dropFirst(prefix.count), as: UTF8.self)
            guard DriveCatalogStore.isRelativePath(relative) else { return nil }
            return narrow(to: driveMount.root.appendingPathComponent(relative, isDirectory: true), matching: identity)
        }
    }

    private func narrow(
        to chosen: URL, matching identity: CatalogFileIdentity? = nil,
        savedReference: StorageBrowser.FolderReference? = nil
    ) -> Self? {
        guard let driveMount, Self.isCurrent(driveMount) else { return nil }
        let folder = chosen.standardizedFileURL
        let isRoot = folder.path == driveMount.root.path
        if isRoot, savedReference == nil { return identity == nil ? self : nil }
        let path = folder.path.lowercased()
        guard canReadProtectedPaths || !env.isPromptingPath(folder),
              !path.split(separator: "/").contains(".trashes"),
              !excluded.contains(where: { url in
                  let excludedPath = url.standardizedFileURL.path.lowercased()
                  return path == excludedPath || path.hasPrefix(excludedPath + "/")
              }),
              isRoot || Self.isLocalDriveFolder(folder, mount: driveMount),
              let reference = savedReference ?? StorageBrowser.reference(forFolder: folder),
              reference.url.path == folder.path,
              savedReference == nil || reference.isCurrent() else { return nil }
        if let identity {
            var info = stat()
            guard lstat(folder.path, &info) == 0, identity.matches(info), reference.isCurrent() else { return nil }
        }
        guard Self.isCurrent(driveMount), isRoot || Self.isLocalDriveFolder(folder, mount: driveMount) else { return nil }
        return Self(driveMount: driveMount, excluded: excluded, env: env,
                    canReadProtectedPaths: canReadProtectedPaths, folderReference: reference)
    }

    public func scan(prepareTextSearch: Bool = true, includeAccessTime: Bool = false, qos: QualityOfService = .userInitiated,
                     control: ScanControl) async -> StorageBrowser? {
        await read(control: control, qos: qos, unavailable: StorageBrowser.unavailable) {
            StorageBrowser.scan(roots, excluding: excluded, env: env,
                                canReadProtectedPaths: canReadProtectedPaths,
                                prepareTextSearch: prepareTextSearch, includeAccessTime: includeAccessTime,
                                control: control)
        }
    }

    /// Checked off the main thread for explicitly picked folders only.
    public static func supportsSharedSpaceCheck(
        in folder: StorageBrowser.FolderReference, home: URL
    ) -> Bool {
        let url = folder.url
        let path = SafetyGuard.withoutSystemPathAlias(url.standardizedFileURL.path).lowercased()
        let homePath = SafetyGuard.withoutSystemPathAlias(home.standardizedFileURL.path).lowercased()
        guard url.isFileURL, path != "/", path != homePath, !homePath.hasPrefix(path + "/"),
              folder.isCurrent() else { return false }
        var volume = statfs()
        guard statfs(url.path, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
              withUnsafeBytes(of: volume.f_fstypename, { $0.prefix { $0 != 0 }.elementsEqual("apfs".utf8) }),
              let mountPath = withUnsafeBytes(of: volume.f_mntonname, {
                  String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8)
              }),
              let mount = FileIdentity(path: mountPath), let selected = FileIdentity(path: url.path),
              selected.dev == mount.dev else { return false }
        return selected != mount
    }

    public func analyzeSharedSpace(
        in pickedFolder: StorageBrowser.FolderReference, control: ScanControl
    ) async -> StorageBrowser.WholeCloneAnalysis? {
        guard explicitlyChosen, driveMount == nil, pickedFolder == folderReference,
              canReadProtectedPaths || !env.isPromptingPath(pickedFolder.url) else { return nil }
        return await read(control: control, unavailable: { _ in nil }) {
            guard Self.supportsSharedSpaceCheck(in: pickedFolder, home: env.home) else { return nil }
            return StorageBrowser.analyzeWholeClones(in: pickedFolder, excluding: excluded,
                                                     env: env, canReadProtectedPaths: canReadProtectedPaths,
                                                     control: control)
        }
    }

    public func indexedShortcut(
        _ reference: StorageBrowser.FolderReference, in browser: StorageBrowser
    ) async -> [StorageBrowser.Entry]? {
        await BackgroundWork.runNonThrowing("andromeda.browser.pinned-folder") {
            guard canReadProtectedPaths || !env.isPromptingPath(reference.url),
                  savedFolder.map(canOpenSavedFolder) ?? true,
                  driveMount.map(Self.isCurrent) ?? true else { return nil }
            if let driveMount {
                if reference.url.path == roots.first?.url.path {
                    return reference.isCurrent() ? [] : nil
                }
                guard Self.isLocalDriveFolder(reference.url, mount: driveMount) else { return nil }
            }
            return browser.indexedTrail(to: reference)
        }
    }

    func captureCatalog(control: ScanControl) async -> StorageBrowser.CatalogSnapshot? {
        guard let driveMount else { return nil }
        let root = savedFolder ?? driveMount.root
        return await read(control: control, unavailable: StorageBrowser.CatalogSnapshot.unavailable) {
            StorageBrowser.captureCatalog(root, excluding: excluded, env: env,
                                          canReadProtectedPaths: canReadProtectedPaths, control: control,
                                          relativeTo: savedFolder == nil ? nil : driveMount.root)
        }
    }

    func isCurrentCatalogLocation() -> Bool {
        guard let driveMount, Self.isCurrent(driveMount) else { return false }
        return savedFolder.map(canOpenSavedFolder) ?? true
    }

    private func read<T: Sendable>(
        control: ScanControl, qos: QualityOfService = .userInitiated,
        unavailable: @escaping @Sendable (URL) -> T?, capture: @escaping @Sendable () -> T?
    ) async -> T? {
        await withTaskCancellationHandler {
            await BackgroundWork.runNonThrowing("andromeda.scan.browser", qos: qos) {
                guard !control.isCancelled else { return nil }
                if let driveMount, !Self.isCurrent(driveMount) {
                    return unavailable(driveMount.root)
                }
                let folderToValidate = savedFolder.flatMap { folder in
                    canReadProtectedPaths || !env.isPromptingPath(folder) ? folder : nil
                }
                if let folder = folderToValidate, !canOpenSavedFolder(folder) { return unavailable(folder) }
                let value = capture()
                guard !control.isCancelled else { return nil }
                if let folder = folderToValidate, !canOpenSavedFolder(folder) { return unavailable(folder) }
                if let driveMount, !Self.isCurrent(driveMount) {
                    return unavailable(driveMount.root)
                }
                return value
            }
        } onCancel: {
            control.cancel()
        }
    }

    private func canOpenSavedFolder(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        if let reference = folderReference {
            guard path == reference.url.standardizedFileURL.path, reference.isCurrent() else { return false }
            return driveMount.map { path == $0.root.path || Self.isLocalDriveFolder(folder, mount: $0) } ?? true
        }
        // Older scan comparisons saved a home path. Check its spelling and reject a replaced link.
        let home = env.home.standardizedFileURL
        guard path.hasPrefix(home.path + "/") else { return false }
        let expected = home.resolvingSymlinksInPath().path + String(path.dropFirst(home.path.count))
        return folder.resolvingSymlinksInPath().path == expected
    }

    private static func isCurrent(_ mount: DriveMount) -> Bool {
        guard let identity = mount.identity, mount.isCurrent() else { return false }
        return FileIdentity(path: mount.root.path) == identity
    }

    private static func isLocalDriveFolder(_ folder: URL, mount: DriveMount) -> Bool {
        let root = mount.root.path
        let path = folder.path
        guard path.hasPrefix(root + "/"), let device = mount.identity?.dev,
              FileIdentity(path: path)?.dev == device else { return false }
        let expected = mount.root.resolvingSymlinksInPath().path + String(path.dropFirst(root.count))
        return folder.resolvingSymlinksInPath().path == expected
    }
}
