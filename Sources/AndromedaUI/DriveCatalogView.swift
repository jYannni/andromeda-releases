import AndromedaAppModel
import AndromedaCore
import AndromedaOrganize
import QuickLook
import SwiftUI

struct DriveCatalogView: View {
    let model: AppModel
    @Bindable var ui: UIState
    @FocusState private var searchFieldFocused: Bool
    @State private var query = DriveCatalogQuery()
    @State private var reopenCount = 0
    @State private var searchToSave: SearchDraft?
    @State private var result: DriveCatalogSearch?
    @State private var searchError: String?
    @State private var itemError: String?
    @State private var forget: DriveCatalogSummary?
    @State private var catalogToExpand: DriveCatalogSummary?
    @State private var catalogFolderChange: CatalogFolderChange?
    @State private var preview: DriveCatalogMatch?
    @State private var quickLookURL: URL?
    @State private var noteDraft: CatalogNoteDraft?
    @State private var showsCatalogNotes = false
    @State private var selectedCollectionID: UUID?
    @State private var collectionDraft: CollectionDraft?
    @State private var collectionToRemove: DriveCatalogCollection?
    @State private var collectionResponse: CollectionResponse?
    @State private var collectionError: String?
    @State private var collectionExport: (name: String, task: Task<Void, Never>)?
    @State private var exportedFolder: (collection: UUID, url: URL)?

    private struct Search: Equatable {
        let query: DriveCatalogQuery
        let catalogs: [DriveCatalogSummary]
        let reopenCount: Int
        let mountedIDs: Set<String>
        let notes: [DriveCatalogNote]
        let collectionBranch: [DriveCatalogCollection]
    }

    private enum ScrollTarget { case search }

    private struct SearchDraft: Identifiable {
        let id = UUID()
        let query: DriveCatalogQuery
        var existing: SavedDriveCatalogSearch?
    }

    private struct CatalogFolderChange {
        let driveID: String
        let folder: URL
        let relativePath: String
        let savedSearchCount: Int
    }

    private struct CollectionRequest: Equatable {
        let branch: [DriveCatalogCollection]
        let catalogs: [DriveCatalogSummary]
    }

    private struct CollectionResponse {
        let request: CollectionRequest
        let items: [DriveCatalogCollectionItem]
    }

    private var drives: DrivesModel { model.drives }
    private var connected: [ExternalVolume] { drives.volumes.filter(drives.canCatalog) }
    private var activeQuery: DriveCatalogQuery {
        var current = query
        if current.driveID != ui.catalogDriveID { current.folderPath = nil }
        current.driveID = ui.catalogDriveID
        return current
    }
    private var missingDrive: String? { ui.catalogDriveID.flatMap { drives.catalog($0) == nil ? $0 : nil } }
    private var missingCollection: UUID? {
        query.collectionID.flatMap { id in drives.catalogCollections.contains { $0.id == id } ? nil : id }
    }
    private var collectionRequest: CollectionRequest? {
        guard let selectedCollectionID else { return nil }
        let branch = drives.catalogCollectionBranch(selectedCollectionID)
        return branch.isEmpty ? nil : CollectionRequest(branch: branch, catalogs: drives.catalogs)
    }

    var body: some View {
        ScrollViewReader { scroll in
            catalogPage
                .onChange(of: ui.catalogSearchRequest, initial: true) { _, request in
                    guard let request else { return }
                    // The catalog page may have just replaced a different destination.
                    DispatchQueue.main.async {
                        guard ui.catalogSearchRequest == request else { return }
                        ui.catalogSearchRequest = nil
                        guard !drives.catalogs.isEmpty else { return }
                        scroll.scrollTo(ScrollTarget.search, anchor: .top)
                        searchFieldFocused = true
                    }
                }
        }
    }

    private var catalogPage: some View {
        let currentQuery = activeQuery
        let request = Search(query: currentQuery, catalogs: drives.catalogs, reopenCount: reopenCount,
                             mountedIDs: currentQuery.offlineOnly == true ? Set(drives.volumes.map(\.id)) : [],
                             notes: currentQuery.hasTagFilter ? drives.catalogNotes : [],
                             collectionBranch: currentQuery.collectionID.map { drives.catalogCollectionBranch($0) } ?? [])
        let collectionRequest = self.collectionRequest
        return PageColumn {
            PageHeader(title: "Drive Catalogs", subtitle: "Find files and folders on drives you’ve cataloged, even when they’re unplugged.",
                       symbol: "externaldrive.badge.magnifyingglass") {
                Button("Notes & Tags", systemImage: "tag") { showsCatalogNotes = true }
                Button("New Collection…", systemImage: "folder.badge.plus") { collectionDraft = .init() }
            }
            if let problem = drives.catalogProblem ?? itemError ?? collectionError ?? searchError {
                Banner(text: problem, symbol: "exclamationmark.triangle", tint: .orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Automatically catalog new drives", isOn: Binding(
                    get: { drives.automaticallyCatalogsNewDrives },
                    set: { drives.setAutomaticallyCatalogsNewDrives($0) }))
                    .toggleStyle(.switch)
                    .help("Automatic cataloging waits in Low Power Mode or under high thermal pressure.")
                Text("Save file names, paths, sizes, and dates for connected drives, without previews. You can forget a drive’s catalog to skip it in the future.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            if drives.catalogingDriveID != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    if drives.catalogProgress?.currentEntry != nil {
                        Text("Saving previews…")
                    } else if let count = drives.catalogProgress?.itemsChecked, count > 0 {
                        Text("Saving catalog · \(count.formatted()) items")
                    } else {
                        Text("Reading drive…")
                    }
                    Spacer()
                    Button("Cancel") { drives.cancelCatalog() }
                }
                .card()
            }
            if let collectionExport {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Copying and verifying \(collectionExport.name)…")
                    Spacer()
                    Button("Cancel") { collectionExport.task.cancel() }
                }
                .card()
            }
            if !drives.catalogCollections.isEmpty { collectionsSection(collectionRequest) }
            if !drives.catalogs.isEmpty || !drives.savedCatalogSearches.isEmpty || missingDrive != nil { searchResults }
            SectionHeading(title: "Saved drives", subtitle: "Catalogs store names, paths, sizes, dates, and any previews you choose to save on this Mac.")
            if drives.catalogs.isEmpty, connected.isEmpty {
                Text("Connect a drive to save a searchable catalog.").foregroundStyle(.secondary).card()
            }
            if !drives.catalogs.isEmpty {
                LazyInsetList(items: drives.catalogs) { catalog in catalogRow(catalog) }
            }
            let uncataloged = connected.filter { drives.catalog($0.id) == nil }
            if !uncataloged.isEmpty {
                SectionHeading(title: "Connected drives")
                LazyInsetList(items: uncataloged) { drive in
                    HStack {
                        Label(drive.name, systemImage: "externaldrive")
                        Spacer()
                        Button("Save Catalog") { save(drive.id) }.disabled(!drives.canSaveCatalog(drive.id))
                        Menu {
                            Button("Save Folder Catalog…") {
                                Task {
                                    guard let folder = await model.chooseStorageFolder(startingAt: drive.url) else { return }
                                    await drives.saveFolderCatalog(folder, on: drive.id, fda: model.access.fda)
                                }
                            }
                            Button("Save With Image Previews") { save(drive.id, includeImagePreviews: true) }
                            Button("Save With Image and PDF Previews") { save(drive.id, includePDFPreviews: true) }
                            Button("Save With Media Previews") { save(drive.id, includeVideoPreviews: true) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(!drives.canSaveCatalog(drive.id))
                        .accessibilityLabel("Catalog options for \(drive.name)")
                    }
                    .groupRow()
                }
            }
        }
        .task { await drives.refreshInBackground() }
        .onChange(of: ui.catalogDriveID) { _, driveID in
            if query.driveID != driveID { query.folderPath = nil }
        }
        .sheet(item: $preview) { match in CatalogImagePreviewSheet(drives: drives, match: match) }
        .quickLookPreview($quickLookURL)
        .sheet(item: $searchToSave) { draft in
            SaveCatalogSearchSheet(drives: drives, query: draft.query, existing: draft.existing)
        }
        .sheet(item: $collectionDraft) { draft in
            CatalogCollectionNameSheet(drives: drives, draft: draft) { selectedCollectionID = $0 }
        }
        .sheet(isPresented: $showsCatalogNotes) { DriveCatalogNotesSheet(drives: drives) }
        .sheet(item: $noteDraft) { CatalogNoteEditor(drives: drives, draft: $0) }
        .task(id: collectionRequest) {
            collectionResponse = nil
            collectionError = nil
            guard let collectionRequest else { return }
            do {
                let items = try await drives.catalogCollectionItems(collectionRequest.branch)
                if !Task.isCancelled { collectionResponse = .init(request: collectionRequest, items: items) }
            } catch {
                if !Task.isCancelled { collectionError = error.localizedDescription }
            }
        }
        .task(id: request) {
            result = nil
            searchError = nil
            guard !request.catalogs.isEmpty, request.query.hasCriteria else { return }
            if let id = request.query.driveID, !request.catalogs.contains(where: { $0.id == id }) { return }
            do {
                try await Task.sleep(for: .milliseconds(180))
                let found = try await drives.searchCatalogs(request.query)
                if !Task.isCancelled { result = found }
            } catch {
                if !Task.isCancelled { searchError = error.localizedDescription }
            }
        }
        .alert("Forget this drive catalog?", isPresented: Binding(
            get: { forget != nil }, set: { if !$0 { forget = nil } }), presenting: forget) { catalog in
            Button("Cancel", role: .cancel) {}
            Button("Forget Catalog", role: .destructive) {
                Task { await drives.forgetCatalog(catalog.id) }
            }
        } message: { catalog in
            Text("Andromeda will move the saved catalog for \(catalog.name) to this Mac’s Trash and remove its collection references, notes, and tags.")
        }
        .alert("Catalog the entire drive?", isPresented: Binding(
            get: { catalogToExpand != nil }, set: { if !$0 { catalogToExpand = nil } }), presenting: catalogToExpand) { catalog in
            Button("Cancel", role: .cancel) {}
            Button("Catalog Entire Drive") {
                itemError = nil
                Task { await drives.expandFolderCatalog(catalog.id, fda: model.access.fda) }
            }
        } message: { catalog in
            let scope = "Andromeda will save readable file details from all of \(catalog.name) on this Mac. Collections, notes, tags, and saved searches stay in place."
            Text(catalog.imagePreviewCount == nil ? scope : scope + " Your saved preview settings apply to the entire drive.")
        }
        .alert("Change the catalog folder?", isPresented: Binding(
            get: { catalogFolderChange != nil }, set: { if !$0 { catalogFolderChange = nil } }),
               presenting: catalogFolderChange) { change in
            Button("Cancel", role: .cancel) {}
            Button(change.savedSearchCount > 0 ? "Keep Existing Search Paths" : "Save Folder Catalog") {
                itemError = nil
                Task { await drives.changeCatalogFolder(change.folder, on: change.driveID, fda: model.access.fda) }
            }
            if change.savedSearchCount > 0 {
                Button("Save and Move Searches") {
                    itemError = nil
                    Task {
                        await drives.changeCatalogFolder(change.folder, on: change.driveID, fda: model.access.fda,
                                                         moveSavedSearches: true)
                    }
                }
            }
        } message: { change in
            let scope = "The catalog will cover \(change.relativePath). Collection references outside the new folder may become unavailable."
            if change.savedSearchCount > 0 {
                Text("\(scope) You can move the \(change.savedSearchCount.formatted()) saved \(change.savedSearchCount == 1 ? "search" : "searches") that use the old folder or its subfolders to the matching paths in the new folder.")
            } else {
                Text(scope)
            }
        }
        .alert("Remove this collection?", isPresented: Binding(
            get: { collectionToRemove != nil }, set: { if !$0 { collectionToRemove = nil } }), presenting: collectionToRemove) { collection in
            Button("Cancel", role: .cancel) {}
            Button("Remove Collection", role: .destructive) {
                updateCollection {
                    try drives.removeCatalogCollection(collection.id)
                    selectedCollectionID = nil
                }
            }
        } message: { collection in
            if drives.catalogCollections.contains(where: { $0.parentID == collection.id }) {
                Text("Remove \(collection.name) and its saved references. Its subcollections move up one level.")
            } else {
                Text("Remove \(collection.name) and its saved references from Drive Catalogs.")
            }
        }
    }

    private func collectionsSection(_ request: CollectionRequest?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading(title: "Collections")
                Spacer()
                Picker("Collection", selection: $selectedCollectionID) {
                    Text("Choose a collection").tag(UUID?.none)
                    ForEach(drives.catalogCollections) { collection in
                        Text(drives.catalogCollectionTitle(collection)).tag(Optional(collection.id))
                    }
                }
                .labelsHidden()
                if let collection = request?.branch.first {
                    Menu {
                        Button("Search This Collection") {
                            query.collectionID = collection.id
                            ui.focusCatalogSearch()
                        }
                        .disabled(drives.catalogs.isEmpty)
                        Button("New Subcollection…") { collectionDraft = .init(parentID: collection.id) }
                        Button("Rename Collection…") { collectionDraft = .init(existing: collection) }
                        Menu("Move Collection") {
                            if collection.parentID != nil {
                                Button("Top Level") { updateCollection { try drives.moveCatalogCollection(collection.id, to: nil) } }
                            }
                            let descendants = Set(request?.branch.map(\.id) ?? [])
                            ForEach(drives.catalogCollections.filter {
                                !descendants.contains($0.id) && $0.id != collection.parentID
                            }) { parent in
                                Button(drives.catalogCollectionTitle(parent)) {
                                    updateCollection { try drives.moveCatalogCollection(collection.id, to: parent.id) }
                                }
                            }
                        }
                        Button("Remove Collection…", role: .destructive) { collectionToRemove = collection }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Options for \(collection.name)")
                }
            }
            if let request, let collection = request.branch.first {
                ForEach(request.branch.filter { $0.parentID == collection.id }) { child in
                    Button(child.name, systemImage: "folder") { selectedCollectionID = child.id }
                        .buttonStyle(.plain)
                }
                if request.branch.allSatisfy({ $0.files.isEmpty }) {
                    Text(drives.catalogs.isEmpty ? "Save a drive catalog to add files."
                         : "Find a file below and choose Add to Collection.").foregroundStyle(.secondary)
                } else if let response = collectionResponse, response.request == request {
                    collectionExportControls(response.items, collection: collection)
                    LazyInsetList(items: Array(response.items.prefix(collection.files.count))) { item in
                        collectionRow(item, in: collection.id)
                    }
                } else if collectionError == nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Reading collection")
                }
            }
        }
    }

    @ViewBuilder private func collectionExportControls(_ items: [DriveCatalogCollectionItem], collection: DriveCatalogCollection) -> some View {
        if let exportedFolder, exportedFolder.collection == collection.id {
            HStack {
                Text("Verified \(exportedFolder.url.lastPathComponent)").font(.callout).foregroundStyle(.secondary)
                Button("Show Export in Finder") { model.reveal(exportedFolder.url) }
            }
        }
        if let problem = drives.collectionExportProblem(items) {
            Text(problem).font(.callout).foregroundStyle(.secondary)
        } else {
            Menu("Export Collection", systemImage: "square.and.arrow.up") {
                Button("Export as Folder…") { exportCollection(collection, format: .folder) }
                Button("Export as ZIP…") { exportCollection(collection, format: .zip) }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(collectionExport != nil)
        }
    }

    private func exportCollection(_ collection: DriveCatalogCollection, format: CollectionExport.Format) {
        guard collectionExport == nil else { return }
        collectionError = nil
        exportedFolder = nil
        let task = Task {
            defer { collectionExport = nil }
            guard let folder = await model.chooseStorageFolder(), !Task.isCancelled else { return }
            do {
                let url = try await drives.exportCatalogCollection(collection.id, into: folder, format: format)
                exportedFolder = (collection.id, url)
            } catch {
                if !Task.isCancelled { collectionError = error.localizedDescription }
            }
        }
        collectionExport = (collection.name, task)
    }

    @ViewBuilder private func collectionRow(_ item: DriveCatalogCollectionItem, in id: UUID) -> some View {
        switch item.status {
        case .current(let match):
            resultRow(match, membership: (item.reference, id))
        case .changed, .missing, .ambiguous:
            HStack {
                Image(systemName: "doc.badge.ellipsis").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.reference.relativePath).textSelection(.enabled)
                    if let name = item.driveName { Text(name).font(.caption).foregroundStyle(.secondary) }
                    Text(collectionStatus(item.status)).font(.caption).foregroundStyle(.secondary)
                    if case .changed(let match?) = item.status, match.relativePath != item.reference.relativePath {
                        Text(match.relativePath).font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = drives.storageLocation(for: item.reference.driveID) {
                        DriveStorageLocationLabel(note: note)
                    }
                }
                Spacer()
                if case .changed(let match?) = item.status {
                    Button("Use Current Entry") {
                        updateCollection { try drives.replaceCatalogFile(item.reference, with: match, in: id) }
                    }
                }
                removeReference(item.reference, from: id)
            }
            .groupRow()
        }
    }

    private func collectionStatus(_ status: DriveCatalogCollectionItem.Status) -> String {
        switch status {
        case .changed: "Changed since it was added"
        case .ambiguous: "Several links match. Remove this reference and add the path you want from search."
        case .missing, .current: "Missing from the saved catalog"
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search cataloged files and folders", text: $query.term).textFieldStyle(.roundedBorder)
                    .focused($searchFieldFocused)
                Picker("Drive", selection: $ui.catalogDriveID) {
                    Text("All cataloged drives").tag(String?.none)
                    ForEach(drives.catalogs) { catalog in Text(catalog.name).tag(Optional(catalog.id)) }
                    if let missingDrive { Text("Catalog unavailable").tag(Optional(missingDrive)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .id(ScrollTarget.search)
            if let folder = activeQuery.folderPath {
                HStack {
                    Label(folder, systemImage: "folder")
                        .lineLimit(2)
                        .help(folder)
                        .accessibilityLabel("Searching in \(folder)")
                    Spacer()
                    Button("Clear Folder") { query.folderPath = nil }
                }
            }
            HStack(spacing: 8) {
                Picker("Item type", selection: $query.itemType) {
                    Text("All types").tag(DriveCatalogFilters.ItemType.all)
                    Text("Files only").tag(DriveCatalogFilters.ItemType.files)
                    Text("Folders only").tag(DriveCatalogFilters.ItemType.folders)
                    Divider()
                    ForEach(Kind.allCases.filter { $0 != .screenshots }, id: \.self) { kind in
                        Text(kind.folderName).tag(DriveCatalogFilters.ItemType.kind(kind))
                    }
                }
                .labelsHidden().fixedSize()
                Picker("Minimum size on disk", selection: $query.minimumSize) {
                    ForEach(StorageMinimumSize.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                Picker("Last modified", selection: $query.modifiedWithin) {
                    ForEach(DriveCatalogQuery.ModifiedWithin.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                if activeQuery.hasFilters {
                    Button("Reset Filters") {
                        ui.catalogDriveID = nil
                        let term = query.term
                        query = .init()
                        query.term = term
                    }
                }
                Spacer(minLength: 0)
                savedSearchMenu
            }
            catalogScopeControls
            if activeQuery.hasVideoFilters || drives.catalogs.contains(where: {
                $0.includesVideoPreviews && (activeQuery.driveID == nil || activeQuery.driveID == $0.id)
            }) {
                HStack(spacing: 12) {
                    Toggle("4K or higher", isOn: Binding(
                        get: { query.requiresUHDVideo == true },
                        set: { query.requiresUHDVideo = $0 ? true : nil }
                    ))
                    .help("Matches cataloged videos at 3840 × 2160 or higher, including portrait video.")
                    TextField("Video codec", text: Binding(
                        get: { query.videoCodec ?? "" },
                        set: { query.videoCodec = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("H.264, HEVC, ProRes…"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .help("Matches saved codec names, even when the drive is unplugged.")
                    Picker("Minimum frame rate", selection: Binding(
                        get: { query.frameRateLimit },
                        set: { query.minimumFrameRate = $0 == .any ? nil : $0 }
                    )) {
                        ForEach(CatalogMinimumFrameRate.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .help("Matches the nominal frame rate saved in the catalog, even when the drive is unplugged.")
                }
                if activeQuery.hasVideoFilters {
                    Text("Only videos with saved media details can match.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if activeQuery.hasCameraFilter || drives.catalogs.contains(where: {
                ($0.imagePreviewCount ?? 0) > 0 && (activeQuery.driveID == nil || activeQuery.driveID == $0.id)
            }) {
                HStack(spacing: 8) {
                    Text("Camera")
                    TextField("Camera make or model", text: Binding(
                        get: { query.camera ?? "" },
                        set: { query.camera = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .help("Matches camera information saved with photo previews, even when the drive is unplugged.")
                }
                if activeQuery.hasCameraFilter {
                    Text("Only photos with saved camera information can match.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if missingDrive != nil {
                Text("Save a catalog for the original drive or choose another drive.").foregroundStyle(.secondary)
            } else if missingCollection != nil {
                Text("This collection was removed. Choose another collection or clear the collection filter.")
                    .foregroundStyle(.secondary)
            } else if let result {
                if result.matches.isEmpty {
                    Text(noCatalogMatches).foregroundStyle(.secondary)
                } else {
                    LazyInsetList(items: result.matches) { match in resultRow(match) }
                    if result.hasMore {
                        Text("Showing the first 100 results. Narrow the search to see more matches.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var offlineFilter: some View {
        Toggle("Offline drives only", isOn: Binding(
            get: { query.offlineOnly == true },
            set: { query.offlineOnly = $0 ? true : nil }))
            .toggleStyle(.checkbox)
    }

    private var catalogCollectionPicker: some View {
        Picker("Search collection", selection: $query.collectionID) {
            Text("No collection filter").tag(UUID?.none)
            ForEach(drives.catalogCollections) { collection in
                Text(drives.catalogCollectionTitle(collection)).tag(Optional(collection.id))
            }
            if let missingCollection { Text("Collection unavailable").tag(Optional(missingCollection)) }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
        .help("Search files in this collection and its subcollections.")
    }

    @ViewBuilder private var collectionAndTagPickers: some View {
        if !drives.catalogCollections.isEmpty || missingCollection != nil {
            catalogCollectionPicker
        }
        let tags = drives.catalogSearchTags
        if !tags.isEmpty || activeQuery.hasTagFilter {
            Picker("Catalog tag", selection: $query.tag) {
                Text("All catalog tags").tag(String?.none)
                ForEach(tags, id: \.self) { Text($0).tag(Optional($0)) }
                if let tag = query.tag, activeQuery.hasTagFilter, !tags.contains(tag) {
                    Text(tag).tag(Optional(tag))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            .help("Filter by tags saved in Andromeda, even when the drive is unplugged.")
        }
    }

    private var catalogScopeControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                offlineFilter
                Spacer()
                collectionAndTagPickers
                catalogSortPicker
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    offlineFilter
                    Spacer()
                    catalogSortPicker
                }
                HStack { collectionAndTagPickers }
            }
        }
    }

    private var catalogSortPicker: some View {
        Picker("Sort by", selection: Binding(
            get: { query.sortOrder },
            set: { query.sort = $0 == .path ? nil : $0 })) {
            ForEach(DriveCatalogQuery.Sort.allCases, id: \.self) { order in
                Text(order.label).tag(order)
            }
        }
        .fixedSize()
    }

    private var noCatalogMatches: String {
        let filter = activeQuery
        let inScope = drives.catalogs.filter { filter.driveID == nil || $0.id == filter.driveID }
        let mountedIDs = Set(drives.volumes.map(\.id))
        if filter.offlineOnly == true, !inScope.isEmpty, inScope.allSatisfy({ mountedIDs.contains($0.id) }) {
            return "The cataloged drives in this search are connected."
        }
        return "No matching files or folders."
    }

    private var savedSearchMenu: some View {
        Menu("Saved Searches", systemImage: "bookmark") {
            Button("Save Current Search…") { searchToSave = SearchDraft(query: activeQuery) }
                .disabled(!activeQuery.hasCriteria || missingDrive != nil || missingCollection != nil || drives.catalogs.isEmpty)
            if !drives.savedCatalogSearches.isEmpty {
                Divider()
                ForEach(drives.savedCatalogSearches) { search in
                    Button(search.name) {
                        query = search.query
                        ui.catalogDriveID = search.query.driveID
                        reopenCount += 1
                    }
                }
                Divider()
                Menu("Update Saved Search…") {
                    ForEach(drives.savedCatalogSearches) { search in
                        Button(search.name) { searchToSave = SearchDraft(query: activeQuery, existing: search) }
                    }
                }
                .disabled(!activeQuery.hasCriteria || missingDrive != nil || missingCollection != nil || drives.catalogs.isEmpty)
                Menu("Remove Saved Search") {
                    ForEach(drives.savedCatalogSearches) { search in
                        Button(search.name) { searchError = drives.removeCatalogSearch(search.id) }
                    }
                }
            }
        }
        .fixedSize()
    }

    private func catalogRow(_ catalog: DriveCatalogSummary) -> some View {
        let drive = connected.first { $0.id == catalog.id }
        let online = drive != nil
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Label(catalog.name, systemImage: online ? "externaldrive" : "externaldrive.badge.xmark")
                    .font(.headline)
                if let folder = catalog.folderPath {
                    Label(folder, systemImage: "folder")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityLabel("Catalog folder: \(folder)")
                }
                Text("\(catalog.itemCount.formatted()) items · \(catalog.savedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
                if !online { Text("Offline").font(.callout).foregroundStyle(.secondary) }
                if let note = drives.storageLocation(for: catalog.id) {
                    DriveStorageLocationLabel(note: note)
                }
                DriveStorageLocationButton(drives: drives, id: catalog.id, name: catalog.name)
                    .controlSize(.small)
                if let count = catalog.imagePreviewCount {
                    Text("\(count.formatted()) saved \(count == 1 ? "preview" : "previews")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if catalog.unreadableCount > 0 {
                    Text("\(catalog.unreadableCount.formatted()) unreadable locations omitted")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Refresh automatically", isOn: Binding(
                    get: { drives.isCatalogAutomaticallyRefreshed(catalog.id) },
                    set: { drives.setAutomaticCatalogRefresh($0, for: catalog.id) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Refreshes on reconnect and after file changes. Automatic refreshes wait in Low Power Mode or under high thermal pressure.")
            }
            Spacer()
            if online { Button("Refresh Catalog") { save(catalog.id) }.disabled(!drives.canSaveCatalog(catalog.id)) }
            Menu {
                Button("Search This Drive") {
                    query.folderPath = nil
                    ui.catalogDriveID = catalog.id
                }
                if let folder = catalog.folderPath {
                    Button("Search in Catalog Folder") {
                        query.driveID = catalog.id
                        query.folderPath = folder
                        ui.catalogDriveID = catalog.id
                    }
                }
                if let drive, let oldFolder = catalog.folderPath {
                    Button("Choose Catalog Folder…") {
                        Task {
                            guard let folder = await model.chooseStorageFolder(startingAt: drive.url) else { return }
                            let prefix = drive.url.standardizedFileURL.path + "/"
                            let path = folder.standardizedFileURL.path
                            guard path.hasPrefix(prefix) else {
                                itemError = "Choose a folder inside \(drive.name)."
                                return
                            }
                            let relativePath = String(path.dropFirst(prefix.count))
                            let count = oldFolder.utf8.elementsEqual(relativePath.utf8) ? 0
                                : drives.savedSearchCount(inCatalogFolder: oldFolder, on: catalog.id)
                            catalogFolderChange = .init(driveID: catalog.id, folder: folder,
                                                        relativePath: relativePath, savedSearchCount: count)
                        }
                    }
                    .disabled(!drives.canSaveCatalog(catalog.id))
                    Button("Catalog Entire Drive…") { catalogToExpand = catalog }
                        .disabled(!drives.canSaveCatalog(catalog.id))
                }
                if drives.canSetStorageLocation(for: catalog.id) {
                    Toggle("Remind Me on Disconnect", isOn: Binding(
                        get: { drives.locationRemindersEnabled(for: catalog.id) },
                        set: { drives.setLocationRemindersEnabled($0, for: catalog.id) }))
                }
                if catalog.imagePreviewCount != nil {
                    Button("Remove Saved Previews") { Task { await drives.removeCatalogImagePreviews(catalog.id) } }
                        .help("Also removes video and photo details saved with this catalog.")
                        .disabled(drives.catalogingDriveID != nil)
                } else if online {
                    Button("Save With Image Previews") { save(catalog.id, includeImagePreviews: true) }
                        .disabled(!drives.canSaveCatalog(catalog.id))
                }
                if online, !catalog.includesPDFPreviews {
                    Button("Save With Image and PDF Previews") { save(catalog.id, includePDFPreviews: true) }
                        .disabled(!drives.canSaveCatalog(catalog.id))
                }
                if online, !catalog.includesVideoPreviews {
                    Button("Save With Media Previews") { save(catalog.id, includeVideoPreviews: true) }
                        .disabled(!drives.canSaveCatalog(catalog.id))
                }
                Button("Forget Catalog…", role: .destructive) { forget = catalog }.disabled(drives.catalogingDriveID != nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Options for \(catalog.name)")
        }
        .groupRow()
    }

    private func resultRow(
        _ match: DriveCatalogMatch, membership: (DriveCatalogCollection.FileReference, UUID)? = nil
    ) -> some View {
        let online = connected.contains { $0.id == match.driveID }
        let note = match.isFolder ? nil : drives.catalogNote(for: match)
        return HStack {
            Image(systemName: match.isFolder ? "folder" : "doc").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(match.relativePath).textSelection(.enabled)
                if let (reference, _) = membership, reference.relativePath != match.relativePath {
                    Text("Moved from \(reference.relativePath)").font(.caption).foregroundStyle(.secondary)
                } else if let (reference, _) = membership, !reference.tracksMoves {
                    Text("Saved path").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(match.driveName) · \(ByteFormat.string(match.bytes))").font(.caption).foregroundStyle(.secondary)
                if let modified = match.modified {
                    Text("Modified \(modified.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !online, let note = drives.storageLocation(for: match.driveID) {
                    DriveStorageLocationLabel(note: note)
                }
                if let note, !note.tags.isEmpty {
                    Label(note.tags.joined(separator: ", "), systemImage: "tag")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if match.isFolder {
                Button("Search in Folder") {
                    query.driveID = match.driveID
                    query.folderPath = match.relativePath
                    ui.catalogDriveID = match.driveID
                }
                .accessibilityLabel("Search in \(match.relativePath)")
            }
            if match.hasImagePreview {
                Button(online ? "Saved Preview" : "Preview") { preview = match }
                    .accessibilityLabel("Saved preview \(match.relativePath)")
            } else if match.hasSavedVideoDetails {
                Button("Video Details") { preview = match }
                    .accessibilityLabel("Video details for \(match.relativePath)")
            }
            if online {
                if !match.isFolder {
                    Button("Quick Look", systemImage: "eye") {
                        Task {
                            itemError = nil
                            do { quickLookURL = try await drives.catalogQuickLookURL(match) }
                            catch { itemError = error.localizedDescription }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Quick Look \(match.relativePath)")
                    .help("Quick Look")
                }
                Button("Show in Finder") { Task { itemError = await drives.revealCatalogItem(match) } }
            } else {
                Text("Reconnect drive").font(.caption).foregroundStyle(.secondary)
            }
            if !match.isFolder {
                Button(note == nil ? "Add Note or Tags" : "Edit Note and Tags", systemImage: "tag") {
                    noteDraft = .init(match: match, note: note)
                }
                .labelStyle(.iconOnly)
                .help(note == nil ? "Add Note or Tags" : "Edit Note and Tags")
            }
            if let (reference, id) = membership {
                removeReference(reference, from: id)
            } else if !match.isFolder {
                Menu("Add to Collection", systemImage: "folder.badge.plus") {
                    ForEach(drives.catalogCollections) { collection in
                        Button(drives.catalogCollectionTitle(collection)) {
                            updateCollection {
                                try drives.saveCatalogFile(match, in: collection.id)
                                selectedCollectionID = collection.id
                            }
                        }
                    }
                    Button("New Collection…") { collectionDraft = .init(match: match) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Add \(match.relativePath) to a collection")
            }
        }
        .groupRow()
    }

    private func removeReference(_ reference: DriveCatalogCollection.FileReference, from id: UUID) -> some View {
        Button {
            updateCollection { try drives.removeCatalogFile(reference, from: id) }
        } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Remove \(reference.relativePath) from collection")
        .help("Remove from collection")
    }

    private func updateCollection(_ update: () throws -> Void) {
        do {
            try update()
            collectionError = nil
        } catch { collectionError = error.localizedDescription }
    }

    private func save(_ id: String, includeImagePreviews: Bool? = nil, includePDFPreviews: Bool? = nil,
                      includeVideoPreviews: Bool? = nil) {
        itemError = nil
        Task {
            await drives.saveCatalog(id, fda: model.access.fda, includeImagePreviews: includeImagePreviews,
                                     includePDFPreviews: includePDFPreviews, includeVideoPreviews: includeVideoPreviews)
        }
    }
}

private struct CollectionDraft: Identifiable {
    let id = UUID()
    var existing: DriveCatalogCollection?
    var match: DriveCatalogMatch?
    var parentID: UUID?
}

private struct CatalogCollectionNameSheet: View {
    let drives: DrivesModel
    let draft: CollectionDraft
    let open: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var problem: String?

    init(drives: DrivesModel, draft: CollectionDraft, open: @escaping (UUID) -> Void) {
        self.drives = drives
        self.draft = draft
        self.open = open
        _name = State(initialValue: draft.existing?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: draft.existing != nil ? "Rename Collection"
                        : draft.parentID == nil ? "New Catalog Collection" : "New Subcollection",
                        symbol: "folder.badge.plus", tint: .indigo)
            TextField("Collection name", text: $name).textFieldStyle(.roundedBorder)
                .onChange(of: name) { problem = nil }
            if let problem { Text(problem).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        let id: UUID
                        if let existing = draft.existing {
                            try drives.renameCatalogCollection(existing.id, to: name)
                            id = existing.id
                        } else {
                            id = try drives.createCatalogCollection(named: name, containing: draft.match, parentID: draft.parentID)
                        }
                        open(id)
                        dismiss()
                    } catch { problem = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

private struct SaveCatalogSearchSheet: View {
    let drives: DrivesModel
    let query: DriveCatalogQuery
    let existing: SavedDriveCatalogSearch?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var problem: String?

    init(drives: DrivesModel, query: DriveCatalogQuery, existing: SavedDriveCatalogSearch?) {
        self.drives = drives
        self.query = query
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: existing == nil ? "Save Catalog Search" : "Update Catalog Search", symbol: "bookmark", tint: .indigo)
            if let existing {
                Text("Replace the filters for \(existing.name) with the current search.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField("Search name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { problem = nil }
            if let problem { Text(problem).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let existing {
                        problem = drives.updateCatalogSearch(existing.id, named: name, query: query)
                    } else {
                        problem = drives.saveCatalogSearch(named: name, query: query)
                    }
                    if problem == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

private struct CatalogImagePreviewSheet: View {
    let drives: DrivesModel
    let match: DriveCatalogMatch
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var photoDetails: CatalogPhotoDetails?
    @State private var videoDetails: CatalogVideoDetails?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: title, symbol: symbol, tint: .indigo)
            Text(match.relativePath).font(.headline).textSelection(.enabled)
            Text(match.driveName).foregroundStyle(.secondary)
            if match.hasPDFPreview { Text("First page").font(.callout).foregroundStyle(.secondary) }
            if match.hasVideoPreview { Text("Saved video frame").font(.callout).foregroundStyle(.secondary) }
            if let note = drives.storageLocation(for: match.driveID) {
                DriveStorageLocationLabel(note: note)
            }
            if match.hasImagePreview {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                            .accessibilityLabel(match.hasVideoPreview ? "Saved video frame"
                                : match.hasPDFPreview ? "Saved first page of PDF" : "Saved image thumbnail")
                    } else if isLoading {
                        ProgressView()
                    } else {
                        Text("This saved preview is no longer available.").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 400, height: 260)
            } else if isLoading {
                ProgressView()
            } else if videoDetails == nil {
                Text("These saved video details are no longer available.").foregroundStyle(.secondary)
            }
            if let photoDetails {
                VStack(alignment: .leading, spacing: 4) {
                    if let camera = photoDetails.camera { Text(camera).font(.callout.weight(.semibold)) }
                    if let lens = photoDetails.lens { Text(lens).font(.callout) }
                    Text(photoSummary(photoDetails)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 400, alignment: .leading)
                .textSelection(.enabled)
            }
            if let videoDetails {
                Text(videoSummary(videoDetails)).font(.callout).foregroundStyle(.secondary)
                    .frame(width: 400, alignment: .leading)
                    .textSelection(.enabled)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .task {
            if let preview = try? await drives.catalogSavedPreview(match) {
                image = NSImage(data: preview.jpeg)
                photoDetails = preview.photoDetails
                videoDetails = preview.videoDetails
            }
            if videoDetails == nil {
                videoDetails = try? await drives.catalogSavedVideoDetails(match)
            }
            isLoading = false
        }
    }

    private var title: String {
        if match.hasVideoPreview { return "Saved Video Preview" }
        if match.hasSavedVideoDetails { return "Saved Video Details" }
        return match.hasPDFPreview ? "Saved PDF Preview" : "Saved Image Preview"
    }

    private var symbol: String {
        if match.hasVideoPreview || match.hasSavedVideoDetails { return "film" }
        return match.hasPDFPreview ? "doc" : "photo"
    }

    private func videoSummary(_ details: CatalogVideoDetails) -> String {
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...3))
        return ["\(details.width) × \(details.height) px", details.codec,
                details.frameRate.map { "\($0.formatted(number)) fps" },
                details.durationSeconds.map { "\($0.formatted(number)) s" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func photoSummary(_ details: CatalogPhotoDetails) -> String {
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        let dimensions = "\(details.width) × \(details.height) px"
        let exposure = details.exposureSeconds.map { value in
            let reciprocal = 1 / value
            let nearest = reciprocal.rounded()
            if (2...10_000).contains(nearest), abs(reciprocal - nearest) < 0.01 * nearest {
                return "1/\(Int(nearest)) s"
            }
            return "\(value.formatted(.number.precision(.fractionLength(0...6)))) s"
        }
        return [dimensions, details.aperture.map { "f/\($0.formatted(number))" }, exposure,
                details.iso.map { "ISO \($0)" }, details.focalLength.map { "\($0.formatted(number)) mm" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
