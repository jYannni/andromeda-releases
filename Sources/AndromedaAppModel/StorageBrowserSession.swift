import AndromedaCore
import Foundation
import Observation

/// Owns a browser walk independently of the sidebar page displaying it.
@MainActor @Observable
public final class StorageBrowserSession {
    public private(set) var browser: StorageBrowser?
    public private(set) var isScanning = false
    public private(set) var revision = 0
    public private(set) var completedRevision: Int?
    public private(set) var isStale = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watch: AnyObject?
    @ObservationIgnored private var previousAccess: Bool?

    public init(browser: StorageBrowser? = nil) {
        self.browser = browser
    }

    public func start(
        _ scope: StorageBrowseScope, refresh: Bool = false, prepareTextSearch: Bool = false,
        includeAccessTime: Bool = false, watchFolder: URL? = nil, qos: QualityOfService = .userInitiated
    ) {
        let accessChanged = previousAccess.map { $0 != scope.canReadProtectedPaths } ?? false
        guard refresh || accessChanged || (revision == 0 && browser == nil) else { return }
        previousAccess = scope.canReadProtectedPaths
        cancel()
        revision += 1
        let current = revision
        browser = nil
        isStale = false
        isScanning = true
        let watchedFolder = watch == nil ? watchFolder : nil
        let control = ScanControl { _ in }
        task = Task { [weak self] in
            if let watchedFolder {
                let reference = await BackgroundWork.runNonThrowing("andromeda.browser.watch-folder", qos: qos) {
                    guard (try? watchedFolder.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
                    else { return nil as StorageBrowser.FolderReference? }
                    return StorageBrowser.reference(forFolder: watchedFolder)
                }
                guard !Task.isCancelled, self?.revision == current else { return }
                if let reference {
                    self?.watch = FileChangeWatch.startFolderTree(reference) { [weak self] in
                        Task { @MainActor in self?.isStale = true }
                    }
                }
            }
            let result = await scope.scan(prepareTextSearch: prepareTextSearch, includeAccessTime: includeAccessTime,
                                          qos: qos, control: control)
            guard !Task.isCancelled, let self, revision == current else { return }
            browser = result
            isScanning = false
            completedRevision = current
            task = nil
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        isScanning = false
    }

    deinit { task?.cancel() }
}
