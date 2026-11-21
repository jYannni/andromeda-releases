import AndromedaAppModel
import AndromedaCore
import Observation
import QuickLook
import SwiftUI

@MainActor @Observable
final class FolderStorageState {
    var folder: URL?
    var reference: StorageBrowser.FolderReference?
    var pickedFileReviewFolder: StorageBrowser.FolderReference?
    var pickedFolderSupportsSharedSpace = false
    var presentation: StorageBrowserPresentation
    var session = StorageBrowserSession()
    var selection = 0
    @ObservationIgnored var dropTask: Task<Void, Never>?

    init(folder: URL? = nil, startInMap: Bool = false) {
        self.folder = folder
        presentation = StorageBrowserPresentation(startInMap: startInMap)
    }
}

struct FolderStorageView: View {
    let model: AppModel
    let ui: UIState
    private let startAtHome: Bool
    private let findsInstallers: Bool
    @State private var state: FolderStorageState
    @State private var pinUnavailable = false
    @State private var isDropTargeted = false
    @State private var dropUnavailable = false

    init(model: AppModel, ui: UIState, startAtHome: Bool = false, installerFolder: URL? = nil) {
        self.model = model
        self.ui = ui
        self.startAtHome = startAtHome
        findsInstallers = installerFolder != nil
        _state = State(initialValue: installerFolder.map { FolderStorageState(folder: $0) }
            ?? (startAtHome ? ui.storageMapBrowser : ui.folderBrowser))
    }

    private var folder: URL? { state.folder ?? (startAtHome ? model.scanHome : nil) }

    var body: some View {
        Group {
            if let folder {
                let homeMap = startAtHome && folder == model.scanHome
                let folderName = folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
                StorageBrowserView(
                    model: model, title: findsInstallers ? "Installer Files" : homeMap ? "Storage Map" : folderName,
                    subtitle: homeMap ? "Explore space used by local files in your home folder." : folder.path,
                    scope: model.storageFolderScope(folder, reference: state.reference),
                    openPlan: { ui.destination = .spacePlan },
                    archive: { url in
                        model.archives.pick(url)
                        ui.destination = .archives
                    },
                    startInMap: startAtHome, shortcuts: shortcutMenu,
                    initialKind: findsInstallers ? .installers : .all,
                    offersAccessTime: !startAtHome && !findsInstallers,
                    trashReview: trashReview,
                    sharedSpaceFolder: state.pickedFolderSupportsSharedSpace ? state.reference : nil,
                    retainedSession: findsInstallers ? nil : (homeMap ? model.homeStorageMap : state.session),
                    retainedPresentation: findsInstallers ? nil : state.presentation,
                    actionTitle: "Choose Another Folder…", action: chooseFolder)
                    .id(state.selection)
            } else {
                PageColumn {
                    PageHeader(
                        title: "Scan a Folder", subtitle: "See what uses space inside one folder.",
                        symbol: "folder.fill") {
                        shortcutMenu
                        Button("Choose Folder…", action: chooseFolder)
                    }
                    EmptyState(
                        title: "Choose a folder to scan", symbol: "folder",
                        message: "Choose a folder or drop one from Finder.")
                }
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let url = urls.first else {
                dropUnavailable = true
                return false
            }
            scanDroppedFolder(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .alert("Couldn’t Pin Folder", isPresented: $pinUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Check that the folder is still available, then choose it again.")
        }
        .alert("Couldn’t Scan Dropped Folder", isPresented: $dropUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Drop one local folder from Finder.")
        }
    }

    private var shortcutMenu: FolderShortcutMenu {
        FolderShortcutMenu(model: model, folder: folder, open: { pinned in
            state.dropTask?.cancel()
            openFolder(pinned.url, reference: pinned)
        }, pin: { url in
            Task { if !(await model.pinStorageFolder(url)) { pinUnavailable = true } }
        })
    }

    private var trashReview: BrowserTrashReview? {
        if findsInstallers { return BrowserTrashReview(scope: .installers) { ui.confirm = $0 } }
        return state.pickedFileReviewFolder.map { folder in
            BrowserTrashReview(scope: .files(folder)) { ui.confirm = $0 }
        }
    }

    private func chooseFolder() {
        state.dropTask?.cancel()
        Task {
            if let chosen = await model.chooseStorageFolder() {
                state.dropTask?.cancel()
                let scopedPicker = !startAtHome && !findsInstallers
                let home = model.scanHome
                let allowCleanup = scopedPicker && PlanBuilder.allowsBrowserCleanup(in: chosen, home: home)
                var picked: (reference: StorageBrowser.FolderReference, allowsSharedSpace: Bool)?
                if scopedPicker {
                    picked = try? await BackgroundWork.run("andromeda.browser.picked-folder") {
                        guard let reference = Self.localFolderReference(chosen) else { return nil }
                        return (reference, StorageBrowseScope.supportsSharedSpaceCheck(in: reference, home: home))
                    }
                }
                openFolder(chosen, reference: picked?.reference, allowFileReview: allowCleanup,
                           allowsSharedSpace: picked?.allowsSharedSpace == true)
            }
        }
    }

    private func openFolder(
        _ url: URL, reference: StorageBrowser.FolderReference? = nil,
        allowFileReview: Bool = false, allowsSharedSpace: Bool = false
    ) {
        let folder = url.standardizedFileURL
        state.folder = folder
        state.reference = reference
        state.pickedFileReviewFolder = allowFileReview ? reference : nil
        state.pickedFolderSupportsSharedSpace = allowsSharedSpace
        state.session.cancel()
        state.session = StorageBrowserSession()
        state.presentation = StorageBrowserPresentation(startInMap: startAtHome)
        state.selection += 1
        guard !findsInstallers else { return }
        let session = startAtHome && folder == model.scanHome ? model.homeStorageMap : state.session
        session.start(model.storageFolderScope(folder, reference: reference), watchFolder: folder)
    }

    private func scanDroppedFolder(_ url: URL) {
        state.dropTask?.cancel()
        state.dropTask = Task {
            let dropped = try? await BackgroundWork.run("andromeda.scan.dropped-folder") {
                Self.localFolderReference(url)
            }
            guard !Task.isCancelled else { return }
            state.dropTask = nil
            guard let dropped else {
                dropUnavailable = true
                return
            }
            openFolder(dropped.url, reference: dropped)
        }
    }

    nonisolated private static func localFolderReference(_ url: URL) -> StorageBrowser.FolderReference? {
        let host = url.host()?.lowercased() ?? ""
        guard url.isFileURL, host.isEmpty || host == "localhost",
              url.path.hasPrefix("/"), url.query() == nil, url.fragment() == nil else { return nil }
        let folder = url.standardizedFileURL
        guard let reference = StorageBrowser.reference(forFolder: folder) else { return nil }
        let originalPath = SafetyGuard.withoutSystemPathAlias(folder.path)
        let resolvedPath = SafetyGuard.withoutSystemPathAlias(folder.resolvingSymlinksInPath().path)
        guard originalPath == resolvedPath, !SafetyGuard.isPackage(folder),
              (try? folder.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true,
              reference.isCurrent() else { return nil }
        return reference
    }
}

struct FolderShortcutMenu: View {
    let model: AppModel
    let folder: URL?
    var driveRoot: URL?
    let open: (StorageBrowser.FolderReference) -> Void
    let pin: (URL) -> Void
    var cancelPendingOpen: (() -> Void)?

    var body: some View {
        let root = driveRoot?.standardizedFileURL.path
        let pinnedFolders = model.pinnedStorageFolders.filter { reference in
            guard let root else { return true }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            let path = reference.url.path
            return path.utf8.elementsEqual(root.utf8) || path.utf8.starts(with: prefix.utf8)
        }
        if folder != nil || !pinnedFolders.isEmpty {
            Menu("Pinned Folders", systemImage: "pin") {
                if let folder {
                    if let pinned = pinnedFolders.first(where: { $0.url.path == folder.path }) {
                        Button("Unpin This Folder", systemImage: "pin.slash") { model.unpinStorageFolder(pinned) }
                    } else {
                        Button("Pin This Folder", systemImage: "pin") { pin(folder) }
                    }
                }
                if folder != nil && !pinnedFolders.isEmpty { Divider() }
                ForEach(pinnedFolders, id: \.self) { pinned in
                    Button(pinned.url.path) { open(pinned) }
                }
            }
        }
    }
}

struct BrowserTrashReview {
    enum Scope {
        case installers
        case files(StorageBrowser.FolderReference)
    }

    let scope: Scope
    let present: (ConfirmSummary) -> Void

    var isInstaller: Bool {
        if case .installers = scope { return true }
        return false
    }

    func pickedDownloads(home: URL) -> StorageBrowser.FolderReference? {
        guard case .files(let folder) = scope, StorageBrowser.isDownloadsFolder(folder, home: home) else { return nil }
        return folder
    }

    func canSelect(_ entry: StorageBrowser.Entry, home: URL) -> Bool {
        switch scope {
        case .installers: StorageBrowser.canSelectInstaller(entry, home: home)
        case .files(let folder): PlanBuilder.canSelectBrowserFile(entry, in: folder, home: home)
        }
    }
}

struct StorageBrowserView: View {
    struct Seed {
        let browser: StorageBrowser
        let trail: [StorageBrowser.Entry]
    }

    private enum SharedSpaceCheck {
        case idle
        case checking(UUID, Task<Void, Never>)
        case completed(StorageBrowser.WholeCloneAnalysis)
        case unavailable
    }

    let model: AppModel
    let title: String
    let subtitle: String
    let scope: StorageBrowseScope
    let openPlan: () -> Void
    let archive: (URL) -> Void
    let shortcuts: FolderShortcutMenu?
    let indexChanged: ((StorageBrowser?) -> Void)?
    let trashReview: BrowserTrashReview?
    let sharedSpaceFolder: StorageBrowser.FolderReference?
    let offersAccessTime: Bool
    let actionTitle: String
    let action: () -> Void

    @State private var session: StorageBrowserSession
    @State private var presentation: StorageBrowserPresentation
    private let keepsScanning: Bool
    @State private var shortcutTask: Task<Void, Never>?
    @State private var sharedSpaceCheck: SharedSpaceCheck = .idle

    init(
        model: AppModel, title: String, subtitle: String, scope: StorageBrowseScope, openPlan: @escaping () -> Void,
        archive: @escaping (URL) -> Void, startInMap: Bool = false, shortcuts: FolderShortcutMenu? = nil,
        initialKind: StorageBrowser.Query.Kind = .all, offersAccessTime: Bool = false,
        trashReview: BrowserTrashReview? = nil,
        sharedSpaceFolder: StorageBrowser.FolderReference? = nil,
        seed: Seed? = nil, indexChanged: ((StorageBrowser?) -> Void)? = nil,
        retainedSession: StorageBrowserSession? = nil, retainedPresentation: StorageBrowserPresentation? = nil,
        actionTitle: String, action: @escaping () -> Void
    ) {
        self.model = model
        self.title = title
        self.subtitle = subtitle
        self.scope = scope
        self.openPlan = openPlan
        self.archive = archive
        self.shortcuts = shortcuts
        self.indexChanged = indexChanged
        self.trashReview = trashReview
        self.sharedSpaceFolder = sharedSpaceFolder
        self.offersAccessTime = offersAccessTime
        self.actionTitle = actionTitle
        self.action = action
        keepsScanning = retainedSession != nil
        _session = State(initialValue: retainedSession ?? StorageBrowserSession(browser: seed?.browser))
        _presentation = State(initialValue: retainedPresentation ?? StorageBrowserPresentation(
            startInMap: startInMap, trail: seed?.trail ?? [], kind: initialKind))
    }

    var body: some View {
        @Bindable var presentation = presentation
        PageColumn {
            PageHeader(title: title, subtitle: subtitle, symbol: "folder.fill") {
                if let shortcuts {
                    FolderShortcutMenu(model: model, folder: presentation.navigation.trail.last?.url ?? shortcuts.folder,
                                       driveRoot: shortcuts.driveRoot,
                                       open: { openShortcut($0, fallback: shortcuts.open) }, pin: shortcuts.pin)
                }
                Button(actionTitle, action: action)
            }
            if let browser = session.browser {
                if presentation.navigation.returnedToParent {
                    Banner(text: "The previous folder is unavailable. Showing the closest available location.",
                           symbol: "folder.badge.questionmark", tint: .orange)
                }
                if session.isStale {
                    Text("Folder contents changed. Rescan to update these sizes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let sharedSpaceFolder, presentation.navigation.trail.isEmpty, !session.isScanning {
                    sharedSpaceCard(sharedSpaceFolder)
                }
                BrowserResults(model: model, browser: browser, rootTitle: title, openPlan: openPlan,
                               archive: archive, trashReview: trashReview, offersAccessTime: offersAccessTime,
                               mode: $presentation.mode, navigation: $presentation.navigation) { startScan(refresh: true) }
                    .id(session.revision)
            } else if session.isScanning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading files and folders…")
                    Spacer()
                    Button("Cancel", action: session.cancel)
                }
                .card()
            } else {
                Button("Scan Again") { startScan(refresh: true) }
            }
        }
        .onDisappear {
            if !keepsScanning { session.cancel() }
            shortcutTask?.cancel()
            resetSharedSpaceCheck()
        }
        .onChange(of: presentation.navigation.trail) {
            shortcutTask?.cancel()
            resetSharedSpaceCheck()
        }
        .onChange(of: sharedSpaceFolder) { resetSharedSpaceCheck() }
        .onChange(of: scope.canReadProtectedPaths) { startScan() }
        .onChange(of: model.removal.receipt?.batchID) {
            if trashReview != nil, model.removal.receipt?.rows.contains(where: \.ok) == true { startScan(refresh: true) }
        }
        .onChange(of: presentation.navigation.age) {
            guard presentation.navigation.age.requiresAccessTime, session.browser?.includesAccessTime != true else { return }
            startScan(refresh: true)
        }
        .onAppear {
            startScan()
            restoreTrail()
        }
        .onChange(of: session.revision) {
            if session.browser == nil { indexChanged?(nil) }
        }
        .onChange(of: session.completedRevision) {
            restoreTrail()
            indexChanged?(session.browser)
        }
    }

    private func startScan(refresh: Bool = false) {
        if refresh {
            shortcutTask?.cancel()
            resetSharedSpaceCheck()
        }
        let hasTextSearch = !presentation.navigation.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        session.start(scope, refresh: refresh, prepareTextSearch: presentation.mode == .list && hasTextSearch,
                      includeAccessTime: presentation.navigation.age.requiresAccessTime,
                      watchFolder: keepsScanning ? scope.roots.first?.url : nil)
    }

    private func restoreTrail() {
        guard let browser = session.browser, presentation.restoredRevision != session.revision else { return }
        let trail = presentation.navigation.trail
        let restored = browser.breadcrumbs(to: browser.restoreFolder(from: trail))
        presentation.navigation.returnedToParent = restored.count < trail.count
        presentation.navigation.trail = restored
        presentation.restoredRevision = session.revision
    }

    private func sharedSpaceCard(_ folder: StorageBrowser.FolderReference) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading(title: "Shared space")
                Spacer()
                if case .checking = sharedSpaceCheck {
                    Button("Cancel", action: resetSharedSpaceCheck)
                } else {
                    Button("Check Shared Space") { checkSharedSpace(folder) }
                }
            }
            switch sharedSpaceCheck {
            case .idle:
                Text("Check for whole-file APFS clones that share data within this folder.")
                    .font(.callout).foregroundStyle(.secondary)
            case .checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking shared space…")
                }
            case .completed(let result):
                LabeledContent("Allocated size", value: ByteFormat.string(result.allocatedBytes))
                LabeledContent("Adjusted size", value: ByteFormat.string(result.adjustedBytes))
                LabeledContent("Full-clone adjustment", value: ByteFormat.string(result.countedSharedBytes))
                Text("The adjusted size counts shared file data once for confirmed full APFS clones. Resource forks and partial clones contribute separately.")
                    .font(.callout).foregroundStyle(.secondary)
            case .unavailable:
                Text("Couldn’t complete this check. Try again or choose a smaller folder.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func checkSharedSpace(_ folder: StorageBrowser.FolderReference) {
        resetSharedSpaceCheck()
        let id = UUID()
        let revision = session.revision
        let fda = model.access.fda
        let task = Task {
            let result = await scope.analyzeSharedSpace(in: folder, control: ScanControl { _ in })
            guard !Task.isCancelled, session.revision == revision, model.access.fda == fda,
                  presentation.navigation.trail.isEmpty, case .checking(let current, _) = sharedSpaceCheck,
                  current == id else { return }
            sharedSpaceCheck = result.map(SharedSpaceCheck.completed) ?? .unavailable
        }
        sharedSpaceCheck = .checking(id, task)
    }

    private func resetSharedSpaceCheck() {
        if case .checking(_, let task) = sharedSpaceCheck { task.cancel() }
        sharedSpaceCheck = .idle
    }

    private func openShortcut(
        _ pinned: StorageBrowser.FolderReference, fallback: @escaping (StorageBrowser.FolderReference) -> Void
    ) {
        shortcuts?.cancelPendingOpen?()
        shortcutTask?.cancel()
        guard let browser = session.browser else {
            fallback(pinned)
            return
        }
        shortcutTask = Task {
            let trail = await scope.indexedShortcut(pinned, in: browser)
            guard !Task.isCancelled else { return }
            if let trail {
                if presentation.navigation.trail != trail {
                    presentation.navigation = BrowserNavigation(trail: trail)
                }
            } else {
                fallback(pinned)
            }
        }
    }
}

@MainActor @Observable
final class StorageBrowserPresentation {
    var mode: BrowserMode
    var navigation: BrowserNavigation
    var restoredRevision: Int?

    init(startInMap: Bool = false, trail: [StorageBrowser.Entry] = [], kind: StorageBrowser.Query.Kind = .all) {
        mode = startInMap ? .map : .list
        navigation = BrowserNavigation(trail: trail, kind: kind)
    }
}

enum BrowserMode: String, CaseIterable, Identifiable {
    case list = "List", map = "Map"
    var id: Self { self }
}

struct BrowserNavigation {
    enum MinimumAge: Hashable {
        enum Days: Int, CaseIterable {
            case month = 30, quarter = 90, year = 365

            var cutoff: Date? { Calendar.current.date(byAdding: .day, value: -rawValue, to: Date()) }
        }

        case any, modified(Days), accessed(Days)

        var requiresAccessTime: Bool {
            if case .accessed = self { return true }
            return false
        }
    }

    var trail: [StorageBrowser.Entry] = []
    var search = ""
    var kind: StorageBrowser.Query.Kind = .all
    var size: StorageMinimumSize = .any
    var age: MinimumAge = .any
    var limit = 200
    var returnedToParent = false
}

private struct BrowserResults: View {
    let model: AppModel
    let browser: StorageBrowser
    let rootTitle: String
    let openPlan: () -> Void
    let archive: (URL) -> Void
    let trashReview: BrowserTrashReview?
    let offersAccessTime: Bool
    @Binding var mode: BrowserMode
    @Binding var navigation: BrowserNavigation
    let rescan: () -> Void

    private var folder: Int? { navigation.trail.last?.id }
    @State private var response: (request: Request, results: SearchResults)?
    @State private var preview: URL?
    @State private var previewUnavailable = false
    @State private var isAdding = false
    @State private var addProblem = false
    @State private var selectionUnavailable = false
    @State private var selectingFiles = false
    @State private var selectedFiles: [Int: StorageBrowser.Entry] = [:]
    @State private var trashReviewTask: Task<Void, Never>?
    @State private var groupByDownloadingApp = false

    private var pickedDownloads: StorageBrowser.FolderReference? { trashReview?.pickedDownloads(home: model.scanHome) }

    private struct SearchResults: Sendable {
        let matches: StorageBrowser.Matches
        let downloadApps: [Int: String]
    }

    private struct Request: Equatable {
        let folder: Int?
        let search: String
        let kind: StorageBrowser.Query.Kind
        let size: StorageMinimumSize
        let age: BrowserNavigation.MinimumAge
        let limit: Int
        let groupByDownloadingApp: Bool
    }

    var body: some View {
        let groupDownloads = groupByDownloadingApp && pickedDownloads != nil
        let request = Request(folder: folder, search: navigation.search, kind: navigation.kind,
                              size: navigation.size, age: navigation.age,
                              limit: groupDownloads ? min(navigation.limit, StorageBrowser.maximumDownloadOriginMatches)
                                  : navigation.limit,
                              groupByDownloadingApp: groupDownloads)
        VStack(alignment: .leading, spacing: 12) {
            breadcrumbs
            HStack {
                Picker("Storage view", selection: $mode) {
                    ForEach(BrowserMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 135)
                Spacer()
                if let entry = browser.breadcrumbs(to: folder).last { planButton(entry) }
                Button("Rescan", systemImage: "arrow.clockwise", action: rescan)
                    .labelStyle(.iconOnly)
                    .help("Refresh the storage view")
            }
            if !browser.unreadable.isEmpty {
                DisclosureGroup("Some locations couldn’t be read") {
                    ScrollablePathList(paths: browser.unreadable).padding(.top, 6)
                }
            }
            if mode == .map {
                StorageMapView(contents: browser.map(in: folder)) { entry in
                    if entry.isFolder { open(entry.id) }
                    else { quickLook(entry) }
                } showList: {
                    open(folder)
                    mode = .list
                } folderActions: { entry in
                    folderPlanAction(entry)
                }
            } else {
                list(request)
            }
        }
        .task(id: mode == .list ? request : nil) {
            if mode == .list { await find(request) }
        }
        .onChange(of: navigation.search) { navigation.limit = 200 }
        .onChange(of: navigation.kind) { navigation.limit = 200 }
        .onChange(of: navigation.size) { navigation.limit = 200 }
        .onChange(of: navigation.age) { navigation.limit = 200 }
        .onChange(of: request.folder) { resetFileSelection() }
        .onChange(of: mode) { resetFileSelection() }
        .onDisappear { trashReviewTask?.cancel() }
        .quickLookPreview($preview)
        .alert("Preview unavailable", isPresented: $previewUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The file may have moved or may no longer be downloaded. Rescan to refresh this list.")
        }
        .alert("Couldn’t add folder", isPresented: $addProblem) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The folder may have moved or become unavailable. Refresh the storage view and try again.")
        }
        .alert("Couldn’t review the selected files", isPresented: $selectionUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(trashReview?.isInstaller == true
                 ? "Choose local installer files in Downloads that don’t have other hard links. If a selected file changed, rescan and try again."
                 : "Choose regular local files without other hard links. If a file or the selected folder changed, rescan and try again.")
        }
    }

    @ViewBuilder private func list(_ request: Request) -> some View {
        TextField("Search by name or path", text: $navigation.search)
            .accessibilityIdentifier("storage-browser-search")
            .textFieldStyle(.roundedBorder)
        HStack {
            Picker("Show", selection: $navigation.kind) {
                ForEach(StorageBrowser.Query.Kind.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            Picker("Size on disk", selection: $navigation.size) {
                ForEach(StorageMinimumSize.allCases) { Text($0.label).tag($0) }
            }
            Picker(offersAccessTime ? "File age" : "Last modified", selection: $navigation.age) {
                Text("Any age").tag(BrowserNavigation.MinimumAge.any)
                ForEach(BrowserNavigation.MinimumAge.Days.allCases, id: \.self) { days in
                    if offersAccessTime {
                        Text("Modified at least \(days.rawValue) days ago").tag(BrowserNavigation.MinimumAge.modified(days))
                    } else {
                        Text("At least \(days.rawValue) days old").tag(BrowserNavigation.MinimumAge.modified(days))
                    }
                }
                if offersAccessTime {
                    Divider()
                    ForEach(BrowserNavigation.MinimumAge.Days.allCases, id: \.self) { days in
                        Text("Accessed at least \(days.rawValue) days ago").tag(BrowserNavigation.MinimumAge.accessed(days))
                    }
                }
            }
            Spacer()
        }
        if request.age.requiresAccessTime {
            Text("Uses the filesystem’s last access date for files. Background reads can affect this date.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let trashReview, !trashReview.isInstaller {
            HStack {
                Button(selectingFiles ? "Done Selecting" : "Select Files…") {
                    if selectingFiles { resetFileSelection() }
                    else { selectingFiles = true }
                }
                .disabled(isTrashReviewDisabled)
                Spacer()
                if pickedDownloads != nil {
                    Toggle("Group by Downloading App", isOn: $groupByDownloadingApp)
                }
            }
        }
        if let trashReview, !selectedFiles.isEmpty {
            HStack {
                Text("\(selectedFiles.count.formatted()) selected across filters")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Selection") { selectedFiles.removeAll() }
                    .disabled(trashReviewTask != nil)
                Button("Review Selected…", systemImage: "trash") {
                    reviewTrash(selectedFiles.values.sorted { $0.path < $1.path }, using: trashReview)
                }
                .disabled(isTrashReviewDisabled)
            }
        }
        if let response, response.request.folder == request.folder, response.request.search == request.search,
           response.request.kind == request.kind, response.request.size == request.size, response.request.age == request.age,
           response.request.groupByDownloadingApp == request.groupByDownloadingApp {
            let matches = response.results.matches
            if let bytes = matches.textMatchBytes, let count = matches.textMatchCount {
                HStack(alignment: .firstTextBaseline) {
                    Text(count == 1 ? "1 match" : "\(count.formatted()) matches")
                    Spacer()
                    Text((browser.unreadable.isEmpty ? "" : "At least ") + ByteFormat.string(bytes))
                        .monospacedDigit()
                }
                .font(.callout.weight(.semibold))
                .help("Total size on disk for all matches. Items inside a matching folder count once.")
                .accessibilityIdentifier("storage-browser-search-total")
            }
            if matches.entries.isEmpty {
                Text(request.age.requiresAccessTime ? "No files matched with an available access date."
                                                   : "No matching files or folders.")
                    .foregroundStyle(.secondary).card()
            } else {
                if request.groupByDownloadingApp {
                    groupedDownloads(matches.entries, apps: response.results.downloadApps)
                } else {
                    LazyInsetList(items: matches.entries) { row($0) }
                }
                if matches.hasMore {
                    if request.groupByDownloadingApp && response.request.limit == StorageBrowser.maximumDownloadOriginMatches {
                        Text("Showing the first \(StorageBrowser.maximumDownloadOriginMatches.formatted()) matches. Narrow the search to group more files.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button("Show More") { navigation.limit += 200 }
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).accessibilityLabel("Looking for matching files")
        }
    }

    private enum DownloadGroup: Hashable {
        case app(String), missing, folders

        var title: String {
            switch self {
            case .app(let name): name
            case .missing: "No Recorded Downloading App"
            case .folders: "Folders"
            }
        }
    }

    @ViewBuilder private func groupedDownloads(_ entries: [StorageBrowser.Entry], apps: [Int: String]) -> some View {
        let groups = Dictionary(grouping: entries) { entry in
            if entry.isFolder { return DownloadGroup.folders }
            return apps[entry.id].map(DownloadGroup.app) ?? .missing
        }
        let appGroups = groups.keys.compactMap { group -> String? in
            if case .app(let name) = group { return name }
            return nil
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map(DownloadGroup.app)
        ForEach(appGroups + [.missing, .folders], id: \.self) { group in
            if let rows = groups[group] {
                HStack {
                    Text(group.title).font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if selectingFiles, let trashReview, group != .folders {
                        downloadGroupSelection(rows, group: group, review: trashReview)
                    }
                }
                LazyInsetList(items: rows) { row($0) }
            }
        }
    }

    @ViewBuilder private func downloadGroupSelection(_ rows: [StorageBrowser.Entry], group: DownloadGroup,
                                                     review: BrowserTrashReview) -> some View {
        let eligible = rows.filter { review.canSelect($0, home: model.scanHome) }
        if !eligible.isEmpty {
            let selected = eligible.count(where: { selectedFiles[$0.id] != nil })
            let allSelected = selected == eligible.count
            Text("\(selected.formatted()) of \(eligible.count.formatted()) shown selected")
                .font(.callout).foregroundStyle(.secondary)
            Button(allSelected ? "Deselect Shown" : "Select Shown") {
                for entry in eligible {
                    selectedFiles[entry.id] = allSelected ? nil : entry
                }
            }
            .accessibilityLabel(
                allSelected ? "Deselect shown files in \(group.title)" : "Select shown files in \(group.title)")
            .disabled(isTrashReviewDisabled)
        }
    }

    @ViewBuilder private func planButton(_ entry: StorageBrowser.Entry) -> some View {
        let plan = model.spacePlanner
        if plan.containsFolderForReview(entry.url) {
            Label("Added to Space Plan", systemImage: "checkmark")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Space Plan", action: openPlan)
        } else {
            addFolderButton(entry)
        }
    }

    @ViewBuilder private func folderPlanAction(_ entry: StorageBrowser.Entry) -> some View {
        if model.spacePlanner.containsFolderForReview(entry.url) {
            Button("Open Space Plan", systemImage: "checkmark", action: openPlan)
                .accessibilityLabel("Open Space Plan for \(entry.name)")
                .help("Open Space Plan")
        } else {
            addFolderButton(entry)
        }
    }

    private func addFolderButton(_ entry: StorageBrowser.Entry) -> some View {
        Button("Add to Space Plan", systemImage: "plus") {
            isAdding = true
            Task {
                addProblem = !(await model.spacePlanner.addFolderForReview(entry))
                isAdding = false
            }
        }
        .accessibilityLabel("Add \(entry.name) to Space Plan")
        .help("Add to Space Plan")
        .disabled(isAdding || model.spacePlanner.isBuilding || model.spacePlanner.isMeasuring)
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button(rootTitle) { open(nil) }.buttonStyle(.link)
                ForEach(browser.breadcrumbs(to: folder)) { entry in
                    Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true)
                    Button(entry.name) { open(entry.id) }.buttonStyle(.link)
                }
            }
        }
        .scrollIndicators(.never)
        .accessibilityLabel("Folder path")
    }

    private func row(_ entry: StorageBrowser.Entry) -> some View {
        HStack(spacing: 12) {
            if let trashReview, trashReview.isInstaller || selectingFiles,
               trashReview.canSelect(entry, home: model.scanHome) {
                Toggle("Select \(entry.name) for Trash review", isOn: Binding(
                    get: { selectedFiles[entry.id] != nil },
                    set: { selectedFiles[entry.id] = $0 ? entry : nil }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(isTrashReviewDisabled)
            }
            Image(systemName: entry.isFolder ? "folder.fill" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if entry.isFolder {
                    Button(entry.name) { open(entry.id) }.buttonStyle(.link)
                } else {
                    Text(entry.name).fontWeight(.medium)
                }
                Text(entry.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .help(entry.path)
            Spacer(minLength: 8)
            if let date = navigation.age.requiresAccessTime ? entry.accessed : entry.modified {
                Text(date, format: .dateTime.year().month().day())
                    .font(.caption).foregroundStyle(.secondary)
                    .help(navigation.age.requiresAccessTime ? "Last accessed" : "Last modified")
            }
            Text((entry.incomplete ? "≥ " : "") + ByteFormat.string(entry.bytes))
                .monospacedDigit()
                .frame(minWidth: 78, alignment: .trailing)
            if entry.isFolder {
                folderPlanAction(entry).labelStyle(.iconOnly)
            }
            if !entry.isFolder {
                Button { quickLook(entry) } label: {
                    Image(systemName: "eye")
                }
                .accessibilityLabel("Quick Look \(entry.name)")
                .help("Quick Look")
                if let trashReview, trashReview.isInstaller, trashReview.canSelect(entry, home: model.scanHome) {
                    Button { reviewTrash([entry], using: trashReview) } label: { Image(systemName: "trash") }
                    .help("Review move to Trash")
                    .accessibilityLabel("Review moving \(entry.name) to Trash")
                    .disabled(isTrashReviewDisabled)
                }
            }
            Button {
                model.reveal(entry.url)
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .accessibilityLabel("Show \(entry.name) in Finder")
            .help(UICopy.showInFinder)
        }
        .buttonStyle(.borderless)
        .groupRow()
        .contextMenu {
            if entry.isFolder { folderPlanAction(entry) }
            if model.archives.offersArchive(entry.url) {
                Button("Archive to External Drive…") { archive(entry.url) }
                    .disabled(!model.archives.canStart)
            }
        }
    }

    private func quickLook(_ entry: StorageBrowser.Entry) {
        if StorageBrowser.canPreview(entry) { preview = entry.url }
        else { previewUnavailable = true }
    }

    private var isTrashReviewDisabled: Bool {
        trashReviewTask != nil || model.removal.isExecuting || model.removal.removalDisabledReason != nil
    }

    private func resetFileSelection() {
        selectingFiles = false
        selectedFiles.removeAll()
        trashReviewTask?.cancel()
    }

    private func reviewTrash(_ entries: [StorageBrowser.Entry], using review: BrowserTrashReview) {
        guard !isTrashReviewDisabled else { return }
        trashReviewTask = Task {
            defer { trashReviewTask = nil }
            let summary: ConfirmSummary?
            switch review.scope {
            case .installers: summary = await model.removal.prepareInstallerConfirm(entries)
            case .files(let folder): summary = await model.removal.prepareBrowserFileConfirm(entries, in: folder)
            }
            guard !Task.isCancelled else { return }
            if let summary { review.present(summary) }
            else { selectionUnavailable = true }
        }
    }

    private func open(_ id: Int?) {
        navigation = BrowserNavigation(trail: browser.breadcrumbs(to: id))
    }

    private func find(_ request: Request) async {
        let control = ScanControl { _ in }
        let index = browser
        var query = StorageBrowser.Query()
        query.folder = request.folder
        query.text = request.search
        query.kind = request.kind
        query.minimumBytes = request.size.rawValue
        switch request.age {
        case .any: break
        case .modified(let days): query.modifiedBefore = days.cutoff
        case .accessed(let days): query.accessedBefore = days.cutoff
        }
        let filter = query
        let downloadScope = request.groupByDownloadingApp ? pickedDownloads : nil
        let home = model.scanHome
        let result = await withTaskCancellationHandler {
            try? await BackgroundWork.run("andromeda.browser.search") {
                let matches = index.matches(filter, limit: request.limit, control: control)
                let apps = downloadScope.map {
                    StorageBrowser.recordedDownloadApps(for: matches.entries, in: $0, home: home, control: control)
                } ?? [:]
                return SearchResults(matches: matches, downloadApps: apps)
            }
        } onCancel: {
            control.cancel()
        }
        guard !Task.isCancelled else { return }
        response = result.map { (request, $0) }
    }
}
