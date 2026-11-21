import AndromedaCore
import AndromedaOrganize
import Foundation
import Observation

/// Mounted drives, saved comparisons, and opt-in scans on connection and filesystem changes.
@MainActor @Observable
public final class DrivesModel {
    public enum State: Equatable {
        case idle
        case scanning(ScanProgress?)
        case done(DriveScanResult)
    }

    public struct BrowsableFolder: Equatable, Identifiable, Sendable {
        public var id: URL { url }
        public let url: URL
        public let bytes: Int64?
    }

    public private(set) var volumes: [ExternalVolume] = []
    public private(set) var comparisonProblem: String?
    public private(set) var catalogs: [DriveCatalogSummary]
    public private(set) var savedCatalogSearches: [SavedDriveCatalogSearch]
    public private(set) var catalogCollections: [DriveCatalogCollection]
    public private(set) var catalogNotes: [DriveCatalogNote]
    public private(set) var catalogingDriveID: String?
    public private(set) var catalogProgress: ScanProgress?
    public private(set) var catalogProblem: String?
    public private(set) var automaticallyCatalogsNewDrives: Bool
    private static let automaticScansKey = "diskplain.automaticDriveScans.v1"
    private static let automaticCatalogsKey = "diskplain.automaticDriveCatalogs.v1"
    private static let automaticFirstCatalogKey = "diskplain.automaticallyCatalogNewDrives.v1"
    private static let forgottenCatalogsKey = "diskplain.forgottenDriveCatalogs.v1"
    private static let storageLocationsKey = "diskplain.driveStorageLocations.v1"
    private static let mutedLocationRemindersKey = "diskplain.mutedDriveLocationReminders.v1"
    private static let savedCatalogSearchesKey = "diskplain.savedDriveCatalogSearches.v1"
    private static let catalogCollectionsKey = "diskplain.driveCatalogCollections.v1"
    private static let catalogNotesKey = "diskplain.driveCatalogNotes.v1"

    private struct StorageLocation: Codable, Equatable {
        let driveName: String
        let note: String
    }

    private var storageLocations: [String: StorageLocation]
    private var mutedLocationReminders: Set<String>
    private var locationReminders: [OfflineDrive] = []

    public var nextLocationReminder: OfflineDrive? { locationReminders.first }

    public struct OfflineDrive: Identifiable, Sendable {
        public let id: String
        public let name: String
    }

    public var offlineDrives: [OfflineDrive] {
        let mounted = Set(volumes.map(\.id))
        let mountedKeys = Set(mounted.compactMap(Self.storageLocationKey))
        let catalogNames = Dictionary(catalogs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let known = Set(scanHistory.keys).union(automaticDriveNames.keys).union(catalogNames.keys)
        let represented = Set(known.union(mounted).compactMap(Self.storageLocationKey))
        let locationOnly = storageLocations.keys.filter { !represented.contains($0) }
        return known.union(locationOnly).compactMap { id -> OfflineDrive? in
            let location = Self.storageLocationKey(id).flatMap { storageLocations[$0] }
            guard !mounted.contains(id), Self.storageLocationKey(id).map({ !mountedKeys.contains($0) }) ?? true,
                  let name = scanHistory[id]?.first?.name ?? automaticDriveNames[id] ?? catalogNames[id]
                      ?? seen[id]?.name ?? location?.driveName else { return nil }
            return OfflineDrive(id: id, name: name)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    public func comparison(_ id: String) -> DriveComparison? {
        guard let scans = scanHistory[id], let latest = scans.first else { return nil }
        return DriveComparison(latest: latest, baseline: scans.dropFirst().first)
    }

    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let comparisonWriter: DriveComparisonWriter
    @ObservationIgnored private let catalogStore: DriveCatalogStore
    @ObservationIgnored private var catalogControl: ScanControl?
    @ObservationIgnored private var catalogToken: UUID?
    @ObservationIgnored private var catalogMutationInProgress = false
    @ObservationIgnored private var catalogScopeChangeInProgress = false
    @ObservationIgnored private var comparisonRevision = 0
    private var scanHistory: [String: [DriveScanSnapshot]] = [:]
    private var states: [String: State] = [:]
    /// Folder rows from the latest completed scan on each current mount.
    private var completedBrowseFolders: [String: [BrowsableFolder]] = [:]
    /// Every drive listed during this app session: its name, and when it was last seen mounted.
    private var seen: [String: (name: String, lastSeen: Date)] = [:]
    /// Drives that went away while their scan ran: "<name> was disconnected", until the drive is back.
    private var disconnectedNotes: [String: String] = [:]
    @ObservationIgnored private var controls: [String: ScanControl] = [:]
    /// Per drive, so a progress report from an earlier scan that arrives late is dropped.
    @ObservationIgnored private var tokens: [String: UUID] = [:]
    /// Bumped by every refresh, so a background read that finishes after a newer one is dropped.
    @ObservationIgnored private var refreshGeneration = 0
    private var automaticDriveNames: [String: String]
    private var automaticCatalogs: Set<String>
    @ObservationIgnored private var forgottenCatalogs: Set<String>
    @ObservationIgnored private var attemptedMounts: Set<String> = []
    @ObservationIgnored private var attemptedCatalogMounts: Set<String> = []
    @ObservationIgnored private var automaticScansStarted = false
    @ObservationIgnored private var automaticWorker: Task<Void, Never>?
    @ObservationIgnored private var automaticRetry: Task<Void, Never>?
    @ObservationIgnored private var automaticControl: ScanControl?
    @ObservationIgnored private var automaticCatalogControl: ScanControl?
    @ObservationIgnored var watchDriveChanges = FileChangeWatch.startDrive
    @ObservationIgnored var changeQuietPeriod: Duration = .seconds(2)
    private struct Watch {
        let token: UUID
        let stream: AnyObject?
    }
    @ObservationIgnored private var watches: [String: Watch] = [:]
    @ObservationIgnored private var changeTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var changedMounts: Set<String> = []
    @ObservationIgnored private var catalogChangeTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var changedCatalogMounts: Set<String> = []

    public init(deps: AppDependencies, defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { Date() }) {
        self.deps = deps
        self.defaults = defaults
        self.now = now
        automaticDriveNames = defaults.dictionary(forKey: Self.automaticScansKey) as? [String: String] ?? [:]
        automaticCatalogs = Set(defaults.stringArray(forKey: Self.automaticCatalogsKey) ?? [])
        automaticallyCatalogsNewDrives = defaults.bool(forKey: Self.automaticFirstCatalogKey)
        forgottenCatalogs = Set(defaults.stringArray(forKey: Self.forgottenCatalogsKey) ?? [])
        storageLocations = defaults.data(forKey: Self.storageLocationsKey)
            .flatMap { try? JSONDecoder().decode([String: StorageLocation].self, from: $0) } ?? [:]
        mutedLocationReminders = Set(defaults.stringArray(forKey: Self.mutedLocationRemindersKey) ?? [])
        savedCatalogSearches = defaults.data(forKey: Self.savedCatalogSearchesKey)
            .flatMap { try? JSONDecoder().decode([SavedDriveCatalogSearch].self, from: $0) } ?? []
        catalogCollections = defaults.data(forKey: Self.catalogCollectionsKey)
            .flatMap { try? JSONDecoder().decode([DriveCatalogCollection].self, from: $0) } ?? []
        catalogNotes = defaults.data(forKey: Self.catalogNotesKey)
            .flatMap { try? JSONDecoder().decode([DriveCatalogNote].self, from: $0) } ?? []
        let file = deps.journalDirectory.deletingLastPathComponent().appendingPathComponent("drive-comparisons-v1.json")
        comparisonWriter = DriveComparisonWriter(file: file)
        let store = DriveCatalogStore(directory: file.deletingLastPathComponent().appendingPathComponent("drive-catalogs-v1"),
                                      trasher: deps.trasher)
        catalogStore = store
        catalogs = store.summaries()
        do {
            scanHistory = try JSONDecoder().decode([String: [DriveScanSnapshot]].self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First run.
        } catch {
            comparisonProblem = "Andromeda couldn’t read the saved drive scans. A new scan can start a fresh comparison."
        }
    }

    public func state(_ id: String) -> State { states[id] ?? .idle }

    public func canSetStorageLocation(for id: String) -> Bool { Self.storageLocationKey(id) != nil }

    public func storageLocation(for id: String) -> String? {
        Self.storageLocationKey(id).flatMap { storageLocations[$0]?.note }
    }

    public func locationRemindersEnabled(for id: String) -> Bool {
        guard let key = Self.storageLocationKey(id) else { return false }
        return !mutedLocationReminders.contains(key)
    }

    public func setLocationRemindersEnabled(_ enabled: Bool, for id: String) {
        guard let key = Self.storageLocationKey(id) else { return }
        if enabled {
            mutedLocationReminders.remove(key)
        } else {
            mutedLocationReminders.insert(key)
            dismissLocationReminder(for: key)
        }
        defaults.set(mutedLocationReminders.sorted(), forKey: Self.mutedLocationRemindersKey)
    }

    public func dismissLocationReminder(for id: String) {
        guard let key = Self.storageLocationKey(id) else { return }
        locationReminders.removeAll { $0.id == key }
    }

    public static func isValidStorageLocation(_ text: String) -> Bool {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.count <= 160 && !note.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    @discardableResult
    public func setStorageLocation(_ text: String, for id: String, driveName: String) -> Bool {
        guard let key = Self.storageLocationKey(id), Self.isValidStorageLocation(text) else { return false }
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = volumes.first { Self.storageLocationKey($0.id) == key }?.name
            ?? storageLocations[key]?.driveName ?? driveName
        var updated = storageLocations
        updated[key] = note.isEmpty ? nil : StorageLocation(driveName: name, note: note)
        guard saveStorageLocations(updated) else { return false }
        dismissLocationReminder(for: key)
        return true
    }

    @discardableResult
    private func saveStorageLocations(_ updated: [String: StorageLocation]) -> Bool {
        guard updated != storageLocations else { return true }
        guard let data = try? JSONEncoder().encode(updated) else { return false }
        defaults.set(data, forKey: Self.storageLocationsKey)
        storageLocations = updated
        return true
    }

    private nonisolated static func storageLocationKey(_ id: String) -> String? { UUID(uuidString: id)?.uuidString }

    public func browseScope(_ id: String, fda: FDAStatus) -> StorageBrowseScope? {
        guard let drive = volumes.first(where: { $0.id == id }), drive.kind != .timeMachine else { return nil }
        let mounted = deps.volumes
        return StorageBrowseScope(drive: drive, env: deps.env, fda: fda) {
            mounted().contains { $0.id == id && $0.url.path == drive.url.path && $0.kind != .timeMachine }
        }
    }

    public func browseFolder(
        _ folder: URL, on id: String, fda: FDAStatus, reference: StorageBrowser.FolderReference? = nil
    ) async -> StorageBrowseScope? {
        guard let drive = browseScope(id, fda: fda), let mount = drive.roots.first?.url else { return nil }
        let runningScan = controls[id]
        guard let scope = await drive.narrowedToDriveFolder(folder, reference: reference), !Task.isCancelled,
              let currentVolume = volumes.first(where: {
                  $0.id == id && $0.url.standardizedFileURL == mount && $0.kind != .timeMachine
              })
        else { return nil }
        if let runningScan, controls[id] === runningScan, let root = scope.roots.first?.url, root != mount {
            runningScan.prioritizeDriveFolder(root, on: currentVolume.url)
        }
        return scope
    }

    public func canCatalog(_ drive: ExternalVolume) -> Bool { DriveCatalogStore.supports(drive) }

    public func catalog(_ id: String) -> DriveCatalogSummary? { catalogs.first { $0.id == id } }

    public func canSaveCatalog(_ id: String) -> Bool {
        guard !catalogMutationInProgress, volumes.contains(where: { $0.id == id && canCatalog($0) }) else { return false }
        if case .scanning = state(id) { return false }
        return true
    }

    public func setAutomaticallyCatalogsNewDrives(_ enabled: Bool) {
        guard automaticallyCatalogsNewDrives != enabled else { return }
        automaticallyCatalogsNewDrives = enabled
        defaults.set(enabled, forKey: Self.automaticFirstCatalogKey)
        if enabled {
            for drive in volumes where catalog(drive.id) == nil { attemptedCatalogMounts.remove(drive.id) }
        } else if let id = catalogingDriveID, catalog(id) == nil {
            automaticCatalogControl?.cancel()
        }
        scheduleAutomaticScans()
    }

    public func saveCatalog(
        _ id: String, fda: FDAStatus, includeImagePreviews: Bool? = nil, includePDFPreviews: Bool? = nil,
        includeVideoPreviews: Bool? = nil
    ) async {
        await saveCatalog(id, fda: fda, automatic: false, includeImagePreviews: includeImagePreviews,
                          includePDFPreviews: includePDFPreviews, includeVideoPreviews: includeVideoPreviews)
    }

    public func saveFolderCatalog(_ folder: URL, on id: String, fda: FDAStatus) async {
        guard catalog(id) == nil else { return }
        await saveCatalog(id, fda: fda, automatic: false, chosenFolder: folder)
    }

    public func expandFolderCatalog(_ id: String, fda: FDAStatus) async {
        guard catalog(id)?.folderPath != nil else { return }
        await saveCatalog(id, fda: fda, automatic: false, expandToWholeDrive: true)
    }

    public func changeCatalogFolder(_ folder: URL, on id: String, fda: FDAStatus, moveSavedSearches: Bool = false) async {
        guard catalog(id)?.folderPath != nil else { return }
        await saveCatalog(id, fda: fda, automatic: false, chosenFolder: folder, moveSavedSearches: moveSavedSearches)
    }

    public func savedSearchCount(inCatalogFolder folder: String, on id: String) -> Int {
        savedCatalogSearches.count { search in
            search.query.driveID == id && search.query.catalogFolderSuffix(relativeTo: folder) != nil
        }
    }

    private func saveCatalog(
        _ id: String, fda: FDAStatus, automatic: Bool, includeImagePreviews: Bool? = nil,
        includePDFPreviews: Bool? = nil, includeVideoPreviews: Bool? = nil, chosenFolder: URL? = nil,
        expandToWholeDrive: Bool = false, moveSavedSearches: Bool = false
    ) async {
        guard canSaveCatalog(id),
              let drive = volumes.first(where: { $0.id == id }), canCatalog(drive),
              let driveScope = browseScope(id, fda: fda) else { return }
        let mounted = deps.volumes
        let previousCatalog = catalog(id)
        let includesVideos = includeImagePreviews != false && (includeVideoPreviews
            ?? (includeImagePreviews == nil && includePDFPreviews == nil && previousCatalog?.includesVideoPreviews == true))
        let includesPDFs = includesVideos
            || (includePDFPreviews ?? (includeImagePreviews == nil && previousCatalog?.includesPDFPreviews == true))
        let includeImagePreviews = includeImagePreviews ?? (includesPDFs || previousCatalog?.imagePreviewCount != nil)
        attemptedCatalogMounts.insert(id)
        clearCatalogChange(id)
        catalogMutationInProgress = true
        catalogScopeChangeInProgress = expandToWholeDrive || (chosenFolder != nil && previousCatalog != nil)
        catalogingDriveID = id
        catalogProblem = nil
        catalogProgress = nil
        let token = UUID()
        catalogToken = token
        let control = ScanControl { [weak self] progress in
            Task { @MainActor in
                guard self?.catalogToken == token else { return }
                self?.catalogProgress = progress
            }
        }
        catalogControl = control
        if automatic { automaticCatalogControl = control }
        defer {
            catalogingDriveID = nil
            catalogProgress = nil
            catalogControl = nil
            catalogToken = nil
            catalogMutationInProgress = false
            catalogScopeChangeInProgress = false
            if automatic { automaticCatalogControl = nil }
            scheduleAutomaticScans()
        }
        let savedFolder = !expandToWholeDrive && chosenFolder == nil ? previousCatalog?.folderPath : nil
        let expectedFolderIdentity = savedFolder == nil ? nil : previousCatalog?.folderIdentity
        let scope: StorageBrowseScope
        var followedSavedFolder = false
        if let folder = chosenFolder {
            guard drive.url.standardizedFileURL.path != folder.standardizedFileURL.path,
                  let narrowed = await driveScope.narrowedToDriveFolder(folder) else {
                catalogProblem = "Choose a readable folder inside this drive."
                return
            }
            scope = narrowed
        } else if let savedFolder {
            guard let narrowed = await driveScope.narrowedToSavedCatalogFolder(savedFolder, identity: expectedFolderIdentity),
                  let currentFolder = narrowed.catalogFolderURL else {
                catalogProblem = "The original catalog folder isn’t available. Use Choose Catalog Folder… to select a folder again."
                return
            }
            let previousPath = drive.url.standardizedFileURL.appendingPathComponent(savedFolder).path
            followedSavedFolder = !previousPath.utf8.elementsEqual(currentFolder.path.utf8)
            if followedSavedFolder { catalogScopeChangeInProgress = true }
            scope = narrowed
        } else {
            scope = driveScope
        }
        guard let snapshot = await scope.captureCatalog(control: control), !control.isCancelled else { return }
        if let expectedFolderIdentity, snapshot.folderIdentity != expectedFolderIdentity {
            catalogProblem = "Andromeda kept the previous catalog because it couldn’t verify the original folder."
            return
        }
        let store = catalogStore
        let trackedReferences = catalogCollections.flatMap(\.files) + catalogNotes.map(\.reference)
        let collectionFiles = Set(trackedReferences.compactMap { file -> CatalogFileKey? in
            guard file.driveID == id, let identity = file.fileIdentity, identity.singleLink else { return nil }
            return CatalogFileKey(identity)
        })
        do {
            catalogs = try await withTaskCancellationHandler {
                let videos = includesVideos ? try await CatalogVideoPreview.capture(snapshot, drive: drive, control: control) : nil
                return try await BackgroundWork.run("andromeda.drive-catalog.save", qos: .utility) {
                    _ = try store.save(snapshot, for: drive, includeImagePreviews: includeImagePreviews,
                                       includePDFPreviews: includesPDFs, videoPreviews: videos?.frames,
                                       videoDetails: videos?.details ?? [:],
                                       collectionFiles: collectionFiles, control: control) {
                        scope.isCurrentCatalogLocation() && mounted().contains {
                            $0.id == drive.id && $0.url.path == drive.url.path && DriveCatalogStore.supports($0)
                        }
                    }
                    return store.summaries()
                }
            } onCancel: { control.cancel() }
            if moveSavedSearches || followedSavedFolder,
               let original = previousCatalog?.folderPath, let destination = catalog(id)?.folderPath,
               !original.utf8.elementsEqual(destination.utf8) {
                let updated = savedCatalogSearches.map { search in
                    guard search.query.driveID == id,
                          let suffix = search.query.catalogFolderSuffix(relativeTo: original) else { return search }
                    var query = search.query
                    query.folderPath = destination + suffix
                    return SavedDriveCatalogSearch(id: search.id, name: search.name, query: query)
                }
                catalogProblem = persistCatalogSearches(updated)
            }
            if !automatic, let key = Self.storageLocationKey(id), forgottenCatalogs.remove(key) != nil {
                defaults.set(forgottenCatalogs.sorted(), forKey: Self.forgottenCatalogsKey)
            }
            updateAutomaticScans()
        } catch {
            if !control.isCancelled { catalogProblem = error.localizedDescription }
        }
    }

    public func cancelCatalog() { catalogControl?.cancel() }

    public func forgetCatalog(_ id: String) async {
        guard !catalogMutationInProgress, catalog(id) != nil else { return }
        catalogMutationInProgress = true
        catalogProblem = nil
        defer {
            catalogMutationInProgress = false
            scheduleAutomaticScans()
        }
        let store = catalogStore
        do {
            try await BackgroundWork.run("andromeda.drive-catalog.forget") { try store.remove(id) }
            if let key = Self.storageLocationKey(id) {
                forgottenCatalogs.insert(key)
                defaults.set(forgottenCatalogs.sorted(), forKey: Self.forgottenCatalogsKey)
            }
            catalogs.removeAll { $0.id == id }
            dismissLocationReminder(for: id)
            setAutomaticCatalogRefresh(false, for: id)
            if catalogCollections.contains(where: { $0.files.contains { $0.driveID == id } }) {
                var updated = catalogCollections
                for index in updated.indices { updated[index].files.removeAll { $0.driveID == id } }
                try persistCatalogCollections(updated)
            }
            try persistCatalogNotes(catalogNotes.filter { $0.reference.driveID != id })
        } catch { catalogProblem = error.localizedDescription }
    }

    public func removeCatalogImagePreviews(_ id: String) async {
        guard !catalogMutationInProgress, catalog(id)?.imagePreviewCount != nil else { return }
        catalogMutationInProgress = true
        catalogProblem = nil
        defer {
            catalogMutationInProgress = false
            scheduleAutomaticScans()
        }
        let store = catalogStore
        do {
            catalogs = try await BackgroundWork.run("andromeda.drive-catalog.remove-previews") {
                try store.removeImagePreviews(id)
                return store.summaries()
            }
        } catch { catalogProblem = error.localizedDescription }
    }

    public func isCatalogAutomaticallyRefreshed(_ id: String) -> Bool { automaticCatalogs.contains(id) }

    public func setAutomaticCatalogRefresh(_ enabled: Bool, for id: String) {
        if enabled {
            guard catalog(id) != nil else { return }
            automaticCatalogs.insert(id)
        } else {
            automaticCatalogs.remove(id)
            clearCatalogChange(id)
            attemptedCatalogMounts.remove(id)
            if catalogingDriveID == id, let automaticCatalogControl {
                automaticCatalogControl.cancel()
            }
        }
        defaults.set(automaticCatalogs.sorted(), forKey: Self.automaticCatalogsKey)
        updateAutomaticScans()
    }

    public func searchCatalogs(
        _ query: String, driveID: String?, filters: DriveCatalogFilters = .init()
    ) async throws -> DriveCatalogSearch {
        try await searchCatalogs(query, driveID: driveID, filters: filters, folderPath: nil)
    }

    private func searchCatalogs(
        _ query: String, driveID: String?, filters: DriveCatalogFilters, folderPath: String?, offlineOnly: Bool = false,
        sort: DriveCatalogQuery.Sort = .path, matchingTagNotes: [DriveCatalogNote]? = nil,
        collectionMembers: [DriveCatalogCollection.FileReference]? = nil
    ) async throws -> DriveCatalogSearch {
        guard folderPath == nil || driveID != nil else { return .init(matches: [], hasMore: false) }
        let mountedIDs = offlineOnly ? Set(volumes.map(\.id)) : []
        let selected = catalogs.filter { (driveID == nil || $0.id == driveID) && !mountedIDs.contains($0.id) }
        let control = ScanControl { _ in }, store = catalogStore
        return try await withTaskCancellationHandler {
            try await BackgroundWork.run("andromeda.drive-catalog.search") {
                try store.search(query, in: selected, filters: filters, browse: driveID != nil || offlineOnly || sort != .path,
                                 folderPath: folderPath, sort: sort, matchingTagNotes: matchingTagNotes,
                                 collectionMembers: collectionMembers, control: control)
            }
        } onCancel: { control.cancel() }
    }

    public func searchCatalogs(_ query: DriveCatalogQuery, now: Date = .now, calendar: Calendar = .current) async throws -> DriveCatalogSearch {
        let tag = query.trimmedTag.lowercased()
        let notes = tag.isEmpty ? nil : catalogNotes.filter { $0.tags.contains { $0.lowercased() == tag } }
        let members = query.collectionID.map { catalogCollectionBranch($0).flatMap(\.files) }
        return try await searchCatalogs(query.trimmedTerm, driveID: query.driveID, filters: query.filters(now: now, calendar: calendar),
                                       folderPath: query.folderPath, offlineOnly: query.offlineOnly == true, sort: query.sortOrder,
                                       matchingTagNotes: notes, collectionMembers: members)
    }

    public func saveCatalogSearch(named name: String, query: DriveCatalogQuery) -> String? {
        saveCatalogSearch(named: name, query: query, replacing: nil)
    }

    public func updateCatalogSearch(_ id: UUID, named name: String, query: DriveCatalogQuery) -> String? {
        guard savedCatalogSearches.contains(where: { $0.id == id }) else { return "This saved search is no longer available." }
        return saveCatalogSearch(named: name, query: query, replacing: id)
    }

    private func saveCatalogSearch(named name: String, query: DriveCatalogQuery, replacing id: UUID?) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return "Enter a name for this search."
        }
        guard query.hasCriteria else { return "Enter a search term or choose a filter first." }
        if let folder = query.folderPath, query.driveID == nil || !DriveCatalogStore.isRelativePath(folder) {
            return "Choose a cataloged folder first."
        }
        if let driveID = query.driveID, catalog(driveID) == nil { return "Save a catalog for this drive first." }
        if let collectionID = query.collectionID, !catalogCollections.contains(where: { $0.id == collectionID }) {
            return "Choose an available collection first."
        }
        guard !savedCatalogSearches.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return "There’s already a saved search with that name."
        }
        var query = query
        query.term = query.trimmedTerm
        query.tag = query.hasTagFilter ? query.trimmedTag : nil
        let search = SavedDriveCatalogSearch(id: id ?? UUID(), name: name, query: query)
        let updated = (savedCatalogSearches.filter { $0.id != id } + [search])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return persistCatalogSearches(updated)
    }

    public func removeCatalogSearch(_ id: UUID) -> String? {
        persistCatalogSearches(savedCatalogSearches.filter { $0.id != id })
    }

    private func persistCatalogSearches(_ searches: [SavedDriveCatalogSearch]) -> String? {
        guard let data = try? JSONEncoder().encode(searches) else { return "Andromeda couldn’t save your catalog searches." }
        defaults.set(data, forKey: Self.savedCatalogSearchesKey)
        savedCatalogSearches = searches
        return nil
    }

    private enum CollectionFailure: LocalizedError {
        case invalidName, duplicateName, missingCollection, invalidParent, missingCatalogFile, exportUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .invalidName: "Enter a name for this collection."
            case .duplicateName: "There’s already a collection with that name."
            case .missingCollection: "This collection is no longer available."
            case .invalidParent: "Choose a collection outside this branch."
            case .missingCatalogFile: "Choose a file from a saved drive catalog."
            case .exportUnavailable(let message): message
            }
        }
    }

    public func createCatalogCollection(named name: String, containing match: DriveCatalogMatch? = nil,
                                        parentID: UUID? = nil) throws -> UUID {
        if let parentID, !catalogCollections.contains(where: { $0.id == parentID }) {
            throw CollectionFailure.missingCollection
        }
        let name = try collectionName(name, parentID: parentID, excluding: nil)
        let files = try match.map { [try collectionReference($0)] } ?? []
        let collection = DriveCatalogCollection(id: UUID(), name: name, files: files, parentID: parentID)
        try persistCatalogCollections(catalogCollections + [collection])
        return collection.id
    }

    public func renameCatalogCollection(_ id: UUID, to name: String) throws {
        guard let index = catalogCollections.firstIndex(where: { $0.id == id }) else { throw CollectionFailure.missingCollection }
        var updated = catalogCollections
        updated[index].name = try collectionName(name, parentID: updated[index].parentID, excluding: id)
        try persistCatalogCollections(updated)
    }

    public func catalogCollectionBranch(_ id: UUID) -> [DriveCatalogCollection] {
        guard let root = catalogCollections.first(where: { $0.id == id }) else { return [] }
        let children = Dictionary(grouping: catalogCollections, by: \.parentID)
        var branch = [root]
        var visited = Set([id])
        var index = 0
        while index < branch.count {
            for child in children[branch[index].id, default: []] where visited.insert(child.id).inserted {
                branch.append(child)
            }
            index += 1
        }
        return branch
    }

    public func catalogCollectionTitle(_ collection: DriveCatalogCollection) -> String {
        var names = [collection.name]
        var visited = Set([collection.id])
        var parent = collection.parentID
        while let id = parent, visited.insert(id).inserted,
              let entry = catalogCollections.first(where: { $0.id == id }) {
            names.append(entry.name)
            parent = entry.parentID
        }
        return names.reversed().joined(separator: " › ")
    }

    public func moveCatalogCollection(_ id: UUID, to parentID: UUID?) throws {
        guard let index = catalogCollections.firstIndex(where: { $0.id == id }) else { throw CollectionFailure.missingCollection }
        if let parentID {
            guard catalogCollections.contains(where: { $0.id == parentID }) else { throw CollectionFailure.missingCollection }
            guard !catalogCollectionBranch(id).contains(where: { $0.id == parentID }) else { throw CollectionFailure.invalidParent }
        }
        var updated = catalogCollections
        _ = try collectionName(updated[index].name, parentID: parentID, excluding: id)
        updated[index].parentID = parentID
        try persistCatalogCollections(updated)
    }

    public func saveCatalogFile(_ match: DriveCatalogMatch, in id: UUID) throws {
        guard let index = catalogCollections.firstIndex(where: { $0.id == id }) else { throw CollectionFailure.missingCollection }
        let reference = try collectionReference(match)
        var updated = catalogCollections
        if let existing = updated[index].files.firstIndex(where: { saved in
            if saved.id == reference.id { return true }
            guard saved.driveID == reference.driveID, saved.relativePath == reference.relativePath else { return false }
            if let savedIdentity = saved.fileIdentity, let newIdentity = reference.fileIdentity {
                return savedIdentity.isSameFile(as: newIdentity)
            }
            return saved.fileIdentity == nil
        }) {
            guard updated[index].files[existing] != reference else { return }
            updated[index].files[existing] = reference
        } else {
            updated[index].files.append(reference)
        }
        try persistCatalogCollections(updated)
    }

    public func replaceCatalogFile(_ reference: DriveCatalogCollection.FileReference, with match: DriveCatalogMatch,
                                   in id: UUID) throws {
        guard let collection = catalogCollections.firstIndex(where: { $0.id == id }),
              let index = catalogCollections[collection].files.firstIndex(of: reference) else {
            throw CollectionFailure.missingCollection
        }
        let replacement = try collectionReference(match)
        var updated = catalogCollections
        if reference.id != replacement.id, updated[collection].files.contains(where: { $0.id == replacement.id }) {
            updated[collection].files.remove(at: index)
        } else {
            updated[collection].files[index] = replacement
        }
        try persistCatalogCollections(updated)
    }

    public func removeCatalogFile(_ reference: DriveCatalogCollection.FileReference, from id: UUID) throws {
        guard let index = catalogCollections.firstIndex(where: { $0.id == id }) else { return }
        var updated = catalogCollections
        updated[index].files.removeAll { $0.id == reference.id }
        try persistCatalogCollections(updated)
    }

    public func removeCatalogCollection(_ id: UUID) throws {
        guard let removed = catalogCollections.first(where: { $0.id == id }) else { return }
        var updated = catalogCollections.filter { $0.id != id }
        for index in updated.indices where updated[index].parentID == id {
            let base = updated[index].name
            var name = base
            var suffix = 2
            while updated.contains(where: {
                $0.parentID == removed.parentID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                name = "\(base) (\(suffix))"
                suffix += 1
            }
            updated[index].name = name
            updated[index].parentID = removed.parentID
        }
        try persistCatalogCollections(updated)
    }

    public func catalogCollectionItems(_ collection: DriveCatalogCollection) async throws -> [DriveCatalogCollectionItem] {
        try await catalogCollectionItems([collection])
    }

    public func catalogCollectionItems(_ branch: [DriveCatalogCollection]) async throws -> [DriveCatalogCollectionItem] {
        let control = ScanControl { _ in }, store = catalogStore, catalogs = catalogs
        let files = branch.flatMap(\.files)
        return try await withTaskCancellationHandler {
            try await BackgroundWork.run("andromeda.drive-catalog.collection") {
                try store.collectionItems(files, in: catalogs, control: control)
            }
        } onCancel: { control.cancel() }
    }

    public func collectionExportProblem(_ items: [DriveCatalogCollectionItem]) -> String? {
        let connected = Set(volumes.filter(DriveCatalogStore.supports).map(\.id))
        var seen: Set<String> = []
        let offline = items.compactMap { item -> String? in
            let id = item.reference.driveID
            guard !connected.contains(id), let name = item.driveName, seen.insert(id).inserted else { return nil }
            return storageLocation(for: id).map { "\(name) (\($0))" } ?? name
        }
        if !offline.isEmpty { return "Reconnect \(offline.formatted(.list(type: .and))) to export this collection." }
        if items.contains(where: { item in
            if case .current = item.status { return false }
            return true
        }) {
            return "Review the changed or missing references before exporting."
        }
        return items.isEmpty ? "Add files to this collection before exporting." : nil
    }

    public func exportCatalogCollection(_ id: UUID, into folder: URL, format: CollectionExport.Format = .folder) async throws -> URL {
        let branch = catalogCollectionBranch(id)
        guard let collection = branch.first else { throw CollectionFailure.missingCollection }
        let items = try await catalogCollectionItems(branch)
        if let problem = collectionExportProblem(items) { throw CollectionFailure.exportUnavailable(problem) }
        guard catalogCollectionBranch(id) == branch else { throw CollectionFailure.missingCollection }
        let connected = Dictionary(volumes.filter(DriveCatalogStore.supports).map { ($0.id, $0.url) },
                                   uniquingKeysWith: { first, _ in first })
        var sources: [DriveCatalogCollection.FileReference: CollectionExport.Source] = [:]
        for item in items {
            guard case .current(let match) = item.status, let root = connected[match.driveID] else {
                throw CollectionFailure.missingCatalogFile
            }
            sources[item.reference] = .init(driveID: match.driveID, root: root, relativePath: match.relativePath,
                                           modified: match.modified, allocatedBytes: match.bytes, fileIdentity: match.fileIdentity)
        }
        let children = Dictionary(grouping: branch.dropFirst(), by: \.parentID)
        func exportGroup(_ entry: DriveCatalogCollection) throws -> CollectionExport.Group {
            let files = try entry.files.map {
                guard let source = sources[$0] else { throw CollectionFailure.missingCatalogFile }
                return source
            }
            return .init(name: entry.name, sources: files, children: try children[entry.id, default: []].map(exportGroup))
        }
        let group = try exportGroup(collection)
        let mounted = deps.volumes
        let control = ScanControl { _ in }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await BackgroundWork.run("andromeda.drive-catalog.export") {
                try CollectionExport.copy(group, into: folder, format: format, control: control) { sources in
                    let available = mounted()
                    return sources.allSatisfy { source in
                        available.contains { DriveCatalogStore.supports($0) && $0.id == source.driveID && $0.url.path == source.root.path }
                    }
                }
            }
        } onCancel: { control.cancel() }
    }

    private func collectionName(_ name: String, parentID: UUID?, excluding id: UUID?) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CollectionFailure.invalidName
        }
        guard !catalogCollections.contains(where: {
            $0.id != id && $0.parentID == parentID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw CollectionFailure.duplicateName
        }
        return name
    }

    private func collectionReference(_ match: DriveCatalogMatch) throws -> DriveCatalogCollection.FileReference {
        guard !match.isFolder, catalog(match.driveID) != nil, DriveCatalogStore.isRelativePath(match.relativePath) else {
            throw CollectionFailure.missingCatalogFile
        }
        return .init(match)
    }

    private func persistCatalogCollections(_ collections: [DriveCatalogCollection]) throws {
        let sorted = collections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        defaults.set(try JSONEncoder().encode(sorted), forKey: Self.catalogCollectionsKey)
        catalogCollections = sorted
    }

    public func catalogSavedPreview(_ match: DriveCatalogMatch) async throws -> SavedCatalogPreview? {
        guard match.hasImagePreview, catalog(match.driveID)?.imagePreviewCount != nil else { return nil }
        let store = catalogStore
        return try await BackgroundWork.run("andromeda.drive-catalog.preview") { try store.imagePreview(match) }
    }

    public func catalogSavedVideoDetails(_ match: DriveCatalogMatch) async throws -> CatalogVideoDetails? {
        guard match.hasSavedVideoDetails, catalog(match.driveID)?.includesVideoPreviews == true else { return nil }
        let store = catalogStore
        return try await BackgroundWork.run("andromeda.drive-catalog.video-details") { try store.videoDetails(match) }
    }

    public func catalogNote(for match: DriveCatalogMatch) -> DriveCatalogNote? {
        catalogNotes.first { $0.applies(to: match) }
    }

    public var catalogSearchTags: [String] {
        var seen: Set<String> = []
        return catalogNotes.flatMap(\.tags).filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func addCatalogNote(_ text: String, tags: [String], to match: DriveCatalogMatch) throws {
        let reference = try collectionReference(match)
        if let existing = catalogNote(for: match) {
            try updateCatalogNote(existing.id, text: text, tags: tags)
            return
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = Self.catalogNoteTags(tags)
        guard !text.isEmpty || !tags.isEmpty else { return }
        try persistCatalogNotes(catalogNotes + [
            DriveCatalogNote(id: UUID(), reference: reference, driveName: match.driveName, text: text, tags: tags)
        ])
    }

    public func updateCatalogNote(_ id: UUID, text: String, tags: [String]) throws {
        guard let index = catalogNotes.firstIndex(where: { $0.id == id }) else {
            throw CollectionFailure.missingCatalogFile
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = Self.catalogNoteTags(tags)
        if text.isEmpty, tags.isEmpty {
            try removeCatalogNote(id)
            return
        }
        var updated = catalogNotes
        updated[index].text = text
        updated[index].tags = tags
        try persistCatalogNotes(updated)
    }

    public func removeCatalogNote(_ id: UUID) throws {
        try persistCatalogNotes(catalogNotes.filter { $0.id != id })
    }

    public func catalogNoteItems(matching query: String) async throws -> [DriveCatalogNoteItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = catalogNotes
        guard !saved.isEmpty else { return [] }
        let control = ScanControl { _ in }, store = catalogStore, catalogs = catalogs
        return try await withTaskCancellationHandler {
            try await BackgroundWork.run("andromeda.drive-catalog.notes") {
                let notes = saved.filter {
                    term.isEmpty || $0.text.localizedStandardContains(term)
                        || $0.tags.contains { $0.localizedStandardContains(term) }
                        || $0.reference.relativePath.localizedStandardContains(term)
                }
                if notes.isEmpty { return [] }
                let items = try store.collectionItems(notes.map(\.reference), in: catalogs, control: control)
                return zip(notes, items).map { DriveCatalogNoteItem(note: $0.0, item: $0.1) }
            }
        } onCancel: { control.cancel() }
    }

    private func persistCatalogNotes(_ notes: [DriveCatalogNote]) throws {
        guard notes != catalogNotes else { return }
        defaults.set(try JSONEncoder().encode(notes), forKey: Self.catalogNotesKey)
        catalogNotes = notes
    }

    private static func catalogNoteTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty && seen.insert($0.lowercased()).inserted
        }
    }

    public func revealCatalogItem(_ match: DriveCatalogMatch) async -> String? {
        await revealCatalogItem(match, verifyingPathSnapshot: false)
    }

    public func revealCatalogNote(_ item: DriveCatalogNoteItem) async -> String? {
        guard let match = item.match, let note = catalogNotes.first(where: { $0.id == item.id }),
              note.applies(to: match) else { return CollectionFailure.missingCatalogFile.localizedDescription }
        return await revealCatalogItem(match, verifyingPathSnapshot: note.reference.fileIdentity == nil)
    }

    private func revealCatalogItem(_ match: DriveCatalogMatch, verifyingPathSnapshot: Bool) async -> String? {
        do {
            let url = try await resolveCatalogItem(match, verifyingPathSnapshot: verifyingPathSnapshot)
            deps.workspace.reveal(url)
            return nil
        } catch { return error.localizedDescription }
    }

    public func catalogQuickLookURL(_ match: DriveCatalogMatch) async throws -> URL {
        guard !match.isFolder else { throw DriveCatalogStore.Failure.missingItem }
        return try await resolveCatalogItem(match, verifyingPathSnapshot: true)
    }

    private func resolveCatalogItem(_ match: DriveCatalogMatch, verifyingPathSnapshot: Bool) async throws -> URL {
        guard let drive = volumes.first(where: { $0.id == match.driveID }) else { throw DriveCatalogStore.Failure.unavailable }
        let mounted = deps.volumes
        return try await BackgroundWork.run("andromeda.drive-catalog.resolve") {
            try DriveCatalogStore.resolve(match, on: drive, verifyingPathSnapshot: verifyingPathSnapshot) {
                mounted().contains { $0.id == drive.id && $0.url.path == drive.url.path && DriveCatalogStore.supports($0) }
            }
        }
    }

    public func isAutomaticallyScanned(_ id: String) -> Bool { automaticDriveNames[id] != nil }

    public func setAutomaticScan(_ enabled: Bool, for id: String) {
        if enabled {
            guard let volume = volumes.first(where: { $0.id == id && $0.hasStableIdentity }) else { return }
            automaticDriveNames[id] = volume.name
        } else {
            automaticDriveNames[id] = nil
            clearScanChange(id)
            if let control = controls[id], control === automaticControl, !control.isCancelled {
                control.cancel()
                attemptedMounts.remove(id)
            }
        }
        defaults.set(automaticDriveNames, forKey: Self.automaticScansKey)
        updateAutomaticScans()
    }

    func startAutomaticScans() {
        automaticScansStarted = true
        updateAutomaticScans()
    }

    private var nextAutomaticDrive: String? {
        guard automaticScansStarted else { return nil }
        return volumes.first {
            guard $0.hasStableIdentity, isAutomaticallyScanned($0.id), catalogingDriveID != $0.id else { return false }
            if case .scanning = state($0.id) { return false }
            return !attemptedMounts.contains($0.id) || changedMounts.contains($0.id)
        }?.id
    }

    private var nextAutomaticCatalog: String? {
        guard automaticScansStarted, !catalogMutationInProgress else { return nil }
        return volumes.first { drive in
            let id = drive.id
            guard canSaveCatalog(id) else { return false }
            if catalog(id) != nil {
                return isCatalogAutomaticallyRefreshed(id)
                    && (!attemptedCatalogMounts.contains(id) || changedCatalogMounts.contains(id))
            }
            guard automaticallyCatalogsNewDrives, drive.kind == .drive,
                  let key = Self.storageLocationKey(id), !forgottenCatalogs.contains(key) else { return false }
            return !attemptedCatalogMounts.contains(id)
        }?.id
    }

    private func updateAutomaticScans() {
        guard automaticScansStarted else { return }
        let watched = volumes.filter { volume in
            volume.hasStableIdentity && isAutomaticallyScanned(volume.id)
                || canCatalog(volume) && catalog(volume.id) != nil && isCatalogAutomaticallyRefreshed(volume.id)
        }
        let activeIDs = Set(watched.map(\.id))
        for id in Array(watches.keys) where !activeIDs.contains(id) { stopWatching(id) }
        // One event stream per device, established before either initial pass.
        for volume in watched where watches[volume.id] == nil {
            let id = volume.id, token = UUID()
            let stream = watchDriveChanges(volume) { [weak self] events in
                Task { @MainActor in self?.driveChanged(id, token: token, events: events) }
            }
            watches[id] = Watch(token: token, stream: stream)
        }
        scheduleAutomaticScans()
    }

    private func driveChanged(_ id: String, token: UUID, events: [FileChangeWatch.DriveEvent]) {
        guard watches[id]?.token == token else { return }
        if isAutomaticallyScanned(id) { queueScanChange(id, token: token) }
        if isCatalogAutomaticallyRefreshed(id), let catalog = catalog(id) {
            let folder = catalogScopeChangeInProgress && catalogingDriveID == id ? nil : catalog.folderPath
            guard events.contains(where: { $0.affectsCatalog(folder: folder) }) else { return }
            queueCatalogChange(id, token: token)
        }
    }

    private func queueScanChange(_ id: String, token: UUID) {
        clearScanChange(id)
        let delay = changeQuietPeriod
        changeTimers[id] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.watches[id]?.token == token, !Task.isCancelled else { return }
            self.changeTimers[id] = nil
            self.changedMounts.insert(id)
            self.scheduleAutomaticScans()
        }
    }

    private func queueCatalogChange(_ id: String, token: UUID) {
        clearCatalogChange(id)
        let delay = changeQuietPeriod
        catalogChangeTimers[id] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.watches[id]?.token == token, !Task.isCancelled else { return }
            self.catalogChangeTimers[id] = nil
            self.changedCatalogMounts.insert(id)
            self.scheduleAutomaticScans()
        }
    }

    private func stopWatching(_ id: String) {
        watches[id] = nil
        clearScanChange(id)
        clearCatalogChange(id)
    }

    private func clearScanChange(_ id: String) {
        changeTimers.removeValue(forKey: id)?.cancel()
        changedMounts.remove(id)
    }

    private func clearCatalogChange(_ id: String) {
        catalogChangeTimers.removeValue(forKey: id)?.cancel()
        changedCatalogMounts.remove(id)
    }

    private func scheduleAutomaticScans() {
        guard automaticWorker == nil else { return }
        guard nextAutomaticDrive != nil || nextAutomaticCatalog != nil else {
            automaticRetry?.cancel()
            automaticRetry = nil
            return
        }
        guard deps.canRunAutomaticStorageWork() else {
            guard automaticRetry == nil else { return }
            automaticRetry = Task { [weak self, delay = deps.storageWorkRetryDelay] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.automaticRetry = nil
                self.scheduleAutomaticScans()
            }
            return
        }
        automaticRetry?.cancel()
        automaticRetry = nil
        automaticWorker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.deps.canRunAutomaticStorageWork() {
                if let id = self.nextAutomaticDrive {
                    await self.scan(id, automatic: true)
                } else if let id = self.nextAutomaticCatalog {
                    let readFDA = self.deps.fda
                    let access = await BackgroundWork.runNonThrowing("andromeda.drive-catalog.access", qos: .utility) { readFDA() }
                    guard self.nextAutomaticCatalog == id else { continue }
                    guard self.deps.canRunAutomaticStorageWork(), !Task.isCancelled else { break }
                    await self.saveCatalog(id, fda: access, automatic: true)
                } else { break }
            }
            self.automaticWorker = nil
            self.scheduleAutomaticScans()
        }
    }

    /// Re-reads the mounted volumes now, on the main actor, and forgets everything about drives that are gone.
    /// For a caller that needs the answer before it goes on (picking a folder); discovery's cheap filter keeps
    /// it short. Launch and mount notifications use `refreshInBackground()`.
    public func refresh() {
        refreshGeneration += 1
        publish(deps.volumes())
    }

    /// As `refresh()`, with the disk reads off the main actor; a newer refresh meanwhile wins.
    public func refreshInBackground() async {
        refreshGeneration += 1
        let mine = refreshGeneration
        let read = deps.volumes
        let found = await BackgroundWork.runNonThrowing("andromeda.drives.refresh") { read() }
        guard mine == refreshGeneration else { return }
        publish(found)
    }

    /// Invalidate the old connection before discovery. A fast remount can reuse the same path.
    func didUnmount(at url: URL) {
        refreshGeneration += 1
        let path = url.standardizedFileURL.path
        let disconnected = volumes.first { $0.url.standardizedFileURL.path == path }
        publish(volumes.filter { $0.url.standardizedFileURL.path != path })
        guard let disconnected, let key = Self.storageLocationKey(disconnected.id),
              locationRemindersEnabled(for: key),
              catalogs.contains(where: { Self.storageLocationKey($0.id) == key }),
              !locationReminders.contains(where: { $0.id == key }) else { return }
        locationReminders.append(OfflineDrive(id: key, name: disconnected.name))
    }

    private func publish(_ found: [ExternalVolume]) {
        let at = now()
        // Seen now: the ones listed, and the ones that were listed until this moment.
        for v in volumes + found { seen[v.id] = (name: v.name, lastSeen: at) }
        let paths = Dictionary(found.map { ($0.id, $0.url.path) }, uniquingKeysWith: { first, _ in first })
        for v in volumes where paths[v.id] != v.url.path { forget(v.id) }
        volumes = found
        if !locationReminders.isEmpty {
            let mounted = Set(found.compactMap { Self.storageLocationKey($0.id) })
            locationReminders.removeAll { mounted.contains($0.id) }
        }
        var updatedLocations = storageLocations
        for volume in found {
            guard let key = Self.storageLocationKey(volume.id), let old = updatedLocations[key],
                  old.driveName != volume.name else { continue }
            updatedLocations[key] = StorageLocation(driveName: volume.name, note: old.note)
        }
        saveStorageLocations(updatedLocations)
        for id in Array(disconnectedNotes.keys) where paths[id] != nil { disconnectedNotes[id] = nil }
        updateAutomaticScans()
    }

    public func scan(_ id: String) async {
        await scan(id, automatic: false)
    }

    private func scan(_ id: String, automatic: Bool) async {
        guard catalogingDriveID != id else { return }
        if case .scanning = state(id) { return }
        if !volumes.contains(where: { $0.id == id }) { refresh() }
        guard let volume = volumes.first(where: { $0.id == id }) else { return }
        let followsChange = automatic && attemptedMounts.contains(id)
        clearScanChange(id)
        attemptedMounts.insert(id)
        disconnectedNotes[id] = nil
        let token = UUID()
        tokens[id] = token
        let control = ScanControl { [weak self] _ in
            Task { @MainActor in
                guard let self, self.tokens[id] == token, case .scanning = self.state(id),
                      let control = self.controls[id], !control.isCancelled else { return }
                self.states[id] = .scanning(control.snapshot)
            }
        }
        controls[id] = control
        if automatic { automaticControl = control }
        defer {
            if automatic { automaticControl = nil }
            scheduleAutomaticScans()
        }
        completedBrowseFolders[id] = nil
        states[id] = .scanning(nil)
        let scanner = deps.driveScan
        let outcome = await BackgroundWork.runNonThrowing("andromeda.scan.drive", qos: automatic ? .utility : .userInitiated) {
            scanner(volume, control)
        }
        guard tokens[id] == token else { return }
        switch outcome {
        case .done(let result):
            controls[id] = nil
            let sameMount = volumes.contains { $0.id == id && $0.url.path == volume.url.path }
            guard !control.isCancelled, sameMount else {
                states[id] = .idle
                await refreshInBackground()
                return
            }
            if volume.kind != .timeMachine, !result.rootWasUnreadable {
                completedBrowseFolders[id] = Self.browseRows(from: control.snapshot)
            }
            // The scanner checked the mount before returning. File results are ready while
            // discovery refreshes the independent capacity figures and mount inventory.
            states[id] = .done(result)
            async let refresh: Void = refreshInBackground()
            if volume.hasStableIdentity, !result.rootWasUnreadable {
                await remember(result, id: id, onlyIfChanged: followsChange)
            }
            await refresh
        case .cancelled:
            controls[id] = nil
            states[id] = .idle
        case .disconnected:
            controls[id] = nil
            states[id] = .idle
            await refreshInBackground()
            // Still listed (the scanner saw it go before discovery did): the note waits for it to be gone.
            if !volumes.contains(where: { $0.id == id }) { disconnectedNotes[id] = Copy.Drives.disconnected(volume.name) }
        }
    }

    public func cancel(_ id: String) {
        guard let control = controls[id] else { return }
        control.cancel()
        if case .scanning(var progress?) = state(id) {
            progress.driveLargeItems = []
            progress.driveFolders = []
            progress.driveFolderSizes = [:]
            states[id] = .scanning(progress)
        }
    }

    public func largeItemsFoundDuringScan(_ id: String) -> [LargeItemRow] {
        guard case .scanning(let progress) = state(id), controls[id]?.isCancelled == false,
              let volume = volumes.first(where: { $0.id == id }) else { return [] }
        return (progress?.driveLargeItems ?? []).map { DrivePresentation.largeRow($0, volume: volume) }
    }

    public func foldersFoundDuringScan(_ id: String) -> [URL] {
        guard case .scanning = state(id) else { return [] }
        return browsableFolders(id).map(\.url)
    }

    public func browsableFolders(_ id: String) -> [BrowsableFolder] {
        guard volumes.contains(where: { $0.id == id && $0.kind != .timeMachine }) else { return [] }
        switch state(id) {
        case .idle:
            return []
        case .scanning(let progress):
            guard let progress, controls[id]?.isCancelled == false else { return [] }
            return Self.browseRows(from: progress)
        case .done:
            return completedBrowseFolders[id] ?? []
        }
    }

    private static func browseRows(from progress: ScanProgress) -> [BrowsableFolder] {
        progress.driveFolders.map { BrowsableFolder(url: $0, bytes: progress.driveFolderSizes[$0.path]) }
    }

    private func remember(_ result: DriveScanResult, id: String, onlyIfChanged: Bool) async {
        let snapshot = DriveScanSnapshot(result)
        if onlyIfChanged, let last = scanHistory[id]?.first, last.folders == snapshot.folders,
           last.hadUnreadableLocations == snapshot.hadUnreadableLocations { return }
        scanHistory[id] = Array(([snapshot] + (scanHistory[id] ?? [])).sorted { $0.date > $1.date }.prefix(2))
        comparisonRevision += 1
        let revision = comparisonRevision
        let saved = await comparisonWriter.save(scanHistory, revision: revision)
        guard revision == comparisonRevision else { return }
        comparisonProblem = saved ? nil : "Andromeda couldn’t save the drive scan. Its comparison is available for this session."
    }

    /// Nil when the volume isn't mounted: a page never shows numbers for a drive that is gone.
    public func page(_ id: String) -> DrivePage? {
        guard let volume = volumes.first(where: { $0.id == id }) else { return nil }
        var result: DriveScanResult?
        if case .done(let r) = state(id) { result = r }
        let sharesWith = volume.containerID.map { container in
            volumes.filter { $0.id != id && $0.containerID == container }.map(\.name)
        } ?? []
        return DrivePresentation.page(
            volume, result: result, sharesWith: sharesWith,
            insideHome: Self.isMountedInsideHome(volume, home: deps.env.home))
    }

    /// Name from discovery or a saved scan, plus this session's last-seen and interrupted-scan notes.
    public func absentPage(_ id: String) -> DriveAbsentPage {
        let known = seen[id]
        let location = Self.storageLocationKey(id).flatMap { storageLocations[$0] }
        return DriveAbsentPage(
            name: known?.name ?? scanHistory[id]?.first?.name ?? automaticDriveNames[id] ?? catalog(id)?.name
                ?? location?.driveName,
            lastSeenText: known.map { Copy.Drives.lastSeen($0.lastSeen) },
            disconnectedNote: disconnectedNotes[id])
    }

    /// A volume mounted at or under the home folder: listed, but never organized (its folders are judged as
    /// home, so its journal lines could carry no drive UUID).
    nonisolated static func isMountedInsideHome(_ v: ExternalVolume, home: URL) -> Bool {
        let home = NamingRules.key(home.standardizedFileURL.path)
        let root = NamingRules.key(v.url.standardizedFileURL.path)
        return root == home || root.hasPrefix(home + "/")
    }

    private func forget(_ id: String) {
        if catalogingDriveID == id { cancelCatalog() }
        stopWatching(id)
        attemptedMounts.remove(id)
        attemptedCatalogMounts.remove(id)
        if case .scanning = states[id] {
            disconnectedNotes[id] = Copy.Drives.disconnected(seen[id]?.name ?? id)
        }
        controls[id]?.cancel()
        controls[id] = nil
        tokens[id] = nil
        completedBrowseFolders[id] = nil
        states[id] = nil
    }
}
