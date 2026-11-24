import AndromedaAppModel
import AndromedaCore
import AndromedaOrganize
import QuickLook
import SwiftUI

struct DuplicatesView: View {
    let model: AppModel
    let ui: UIState

    @AppStorage("diskplain.hidden-duplicate-groups") private var savedHiddenGroups = Data()
    @AppStorage("diskplain.hidden-similar-image-groups") private var savedHiddenImageGroups = Data()
    @State private var showsHiddenGroups = false
    @State private var folders: [URL] = []
    @State private var revision = 0
    @State private var control: ScanControl?
    @State private var result: DuplicateScanner.Result?
    @State private var similarImages: SimilarImageScanner.Result?
    @State private var mode: ScanMode = .exact
    @State private var cancelled = false
    @State private var search = ""
    @State private var fileKind: Kind?
    @State private var sort: DuplicateSort = .largest
    @State private var selections: [URL: Set<URL>] = [:]
    @State private var similarSearch = ""
    @State private var similarOrder: SimilarImageScanner.ReviewOrder = .scanOrder
    @State private var similarSelections: [URL: Set<URL>] = [:]
    @State private var preview: URL?
    @State private var previewUnavailable = false
    @State private var previewTask: Task<Void, Never>?
    @State private var similarReviewTask: Task<Void, Never>?

    init(model: AppModel, ui: UIState, startsInSimilarMode: Bool = false) {
        self.model = model
        self.ui = ui
        _mode = State(initialValue: startsInSimilarMode ? .similar : .exact)
    }

    var body: some View {
        PageColumn {
            PageHeader(title: "Duplicates", subtitle: mode.subtitle,
                       symbol: "doc.on.doc") {
                if ui.destination == .tool(.similarImages) { ToolBackButton(ui: ui) }
                if mode != .photos {
                    if !hiddenGroups.isEmpty {
                        Button("Hidden Groups…") { showsHiddenGroups = true }
                    }
                    if !folders.isEmpty {
                        Button("Scan Again") { restartScan() }
                            .disabled(control != nil)
                    }
                    Button(folders.isEmpty ? "Choose Folders…" : "Add Folders…", action: chooseFolders)
                }
            }
            Picker("Scan for", selection: $mode) {
                Text("Exact Duplicates").tag(ScanMode.exact)
                Text("Similar Images").tag(ScanMode.similar)
                Text("Apple Photos").tag(ScanMode.photos)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Scan for")
            .fixedSize()
            if mode != .photos, !folders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(folders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(folder.path).lineLimit(1).truncationMode(.middle)
                                .help(folder.path)
                            Spacer()
                            Button {
                                folders.removeAll { $0 == folder }
                                restartScan()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(folder.path) from scan")
                        }
                    }
                }
                .card()
            }
            if mode == .photos {
                PhotoLibrarySimilarImagesView()
            } else if let result {
                results(result)
            } else if let similarImages {
                SimilarImageResults(result: similarImages, hiddenIdentifiers: Set(hiddenGroups.map(\.id)),
                                    search: $similarSearch, order: $similarOrder, selections: $similarSelections,
                                    reviewDisabled: similarReviewTask != nil
                                    || model.removal.removalDisabledReason != nil || model.removal.isExecuting,
                                    review: reviewSimilarImages, hide: hide) { photo, action in
                    open(photo.url, action: action) { photo.isCurrent() }
                }
            } else if let control {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(mode == .exact ? "Checking file contents…" : "Comparing images…")
                    Spacer()
                    Button("Cancel") { control.cancel() }
                }
                .card()
            } else if cancelled {
                EmptyState(title: "Scan cancelled", symbol: "doc.on.doc",
                           message: "Scan again or add another folder.")
            } else if folders.isEmpty {
                EmptyState(title: "Choose a folder", symbol: "doc.on.doc",
                           message: "Start with one folder, then add folders from this Mac or a connected drive.")
            }
        }
        .quickLookPreview($preview)
        .sheet(isPresented: $showsHiddenGroups) { hiddenGroupsSheet }
        .alert("File unavailable", isPresented: $previewUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The file may have moved, changed, or become unavailable. Scan again to refresh the results.")
        }
        .onDisappear {
            previewTask?.cancel()
            similarReviewTask?.cancel()
            similarReviewTask = nil
        }
        .onChange(of: mode) { restartScan() }
        .onChange(of: ui.receiptShowing) {
            if !ui.receiptShowing, !folders.isEmpty { restartScan() }
        }
        .task(id: revision) {
            guard mode != .photos, !folders.isEmpty else { return }
            let selectedFolders = folders
            let selectedMode = mode
            let scan = ScanControl { _ in }
            result = nil
            similarImages = nil
            cancelled = false
            control = scan
            switch selectedMode {
            case .exact:
                let found = await model.findDuplicates(in: selectedFolders, control: scan)
                guard !Task.isCancelled, control === scan else { return }
                result = found
            case .similar:
                let found = await model.findSimilarImages(in: selectedFolders, control: scan)
                guard !Task.isCancelled, control === scan else { return }
                similarImages = found
            case .photos:
                return
            }
            cancelled = result == nil && similarImages == nil
            control = nil
        }
    }

    @ViewBuilder private func results(_ result: DuplicateScanner.Result) -> some View {
        if result.skippedCount > 0 {
            Text("Some items were unavailable or unsupported and couldn’t be checked.")
                .foregroundStyle(.secondary)
        }
        if result.groups.isEmpty {
            EmptyState(title: "No matching copies found", symbol: "doc.on.doc",
                       message: "Add another folder to check it against these files.")
        } else {
            let hidden = Set(hiddenGroups.map(\.id))
            let visible = result.groups.filter { !hidden.contains($0.reviewIdentifier) }
            let groups = visibleGroups(visible)
            TextField("Search duplicates by name or path", text: $search)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("File type", selection: $fileKind) {
                    Text("All types").tag(nil as Kind?)
                    ForEach(Kind.allCases.filter { $0 != .screenshots }, id: \.self) { kind in
                        Text(kind.folderName).tag(Optional(kind))
                    }
                }
                Picker("Sort", selection: $sort) {
                    ForEach(DuplicateSort.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                Spacer()
            }
            Text("Sizes show file contents. Space recovered can differ when copies share disk blocks.")
                .foregroundStyle(.secondary)
            if result.groups.contains(where: { !$0.externalTrashCandidates.isEmpty }) {
                Text("Copies on a drive stay in that drive’s Trash. Reconnect the drive to restore them from History.")
                    .foregroundStyle(.secondary)
            }
            if result.groups.contains(where: { $0.trashCandidates.count < $0.files.count }) {
                Text("Copies without a checkbox can be kept in place and opened in Finder.")
                    .foregroundStyle(.secondary)
            }
            if visible.isEmpty {
                Label("All duplicate groups from this scan are hidden", systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
                    .card()
            } else if groups.isEmpty {
                Label("No duplicate groups match the current filters", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .card()
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(groups) { group in
                        DuplicateGroupView(group: group, model: model, ui: ui, selected: Binding(
                            get: { selections[group.id, default: []] },
                            set: { selections[group.id] = $0 }
                        ), quickLook: { url in quickLook(url, in: group) }, hide: { hide(group) })
                    }
                }
            }
        }
    }

    private struct HiddenGroup: Identifiable, Codable {
        let id: Data
        let filename: String
        let copies: Int
        let bytes: Int64
    }

    private var hiddenGroups: [HiddenGroup] {
        guard mode != .photos else { return [] }
        let data = mode == .exact ? savedHiddenGroups : savedHiddenImageGroups
        return (try? PropertyListDecoder().decode([HiddenGroup].self, from: data)) ?? []
    }

    private var hiddenGroupsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: mode == .exact ? "Hidden Duplicate Groups" : "Hidden Similar Image Groups",
                        symbol: "eye.slash", tint: .secondary)
            if hiddenGroups.isEmpty {
                Text("No hidden groups.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(hiddenGroups) { group in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(group.filename).lineLimit(1).truncationMode(.middle)
                                    Text(mode == .exact ? "\(group.copies) copies · \(ByteFormat.string(group.bytes)) each"
                                         : "\(group.copies) images · \(ByteFormat.string(group.bytes)) total")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Show Again") {
                                    saveHiddenGroups(hiddenGroups.filter { $0.id != group.id })
                                }
                                .accessibilityLabel("Show group for \(group.filename) again")
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            Button("Done") { showsHiddenGroups = false }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 460)
    }

    private func hide(_ group: DuplicateScanner.Group) {
        let hidden = HiddenGroup(id: group.reviewIdentifier, filename: group.id.lastPathComponent,
                                 copies: group.files.count, bytes: group.logicalBytesPerFile)
        addHiddenGroup(hidden)
        selections.removeValue(forKey: group.id)
    }

    private func hide(_ group: SimilarImageScanner.Group) {
        addHiddenGroup(HiddenGroup(id: group.reviewIdentifier, filename: group.id.lastPathComponent,
                                   copies: group.photos.count, bytes: group.totalBytes))
        similarSelections.removeValue(forKey: group.id)
    }

    private func addHiddenGroup(_ group: HiddenGroup) {
        saveHiddenGroups(hiddenGroups.filter { $0.id != group.id } + [group])
    }

    private func saveHiddenGroups(_ groups: [HiddenGroup]) {
        guard let data = try? PropertyListEncoder().encode(groups) else { return }
        switch mode {
        case .exact: savedHiddenGroups = data
        case .similar: savedHiddenImageGroups = data
        case .photos: return
        }
    }

    private func visibleGroups(_ groups: [DuplicateScanner.Group]) -> [DuplicateScanner.Group] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var kindsByExtension: [String: Kind] = [:]
        let matching = term.isEmpty && fileKind == nil ? groups : groups.filter { group in
            group.files.contains { file in
                guard term.isEmpty || file.path.localizedStandardContains(term) else { return false }
                guard let fileKind else { return true }
                let ext = file.pathExtension.lowercased()
                let kind = kindsByExtension[ext] ?? KindClassifier.kind(forExtension: ext) ?? .other
                kindsByExtension[ext] = kind
                return kind == fileKind
            }
        }
        switch sort {
        case .largest:
            return matching
        case .smallest:
            return matching.sorted { $0.logicalBytesPerFile < $1.logicalBytesPerFile }
        case .mostCopies:
            return matching.sorted { $0.files.count > $1.files.count }
        }
    }

    private func chooseFolders() {
        Task {
            let chosen = await model.chooseDuplicateFolders()
            var existing = Set(folders)
            let added = chosen.filter { existing.insert($0).inserted }
            guard !added.isEmpty else { return }
            folders.append(contentsOf: added)
            restartScan()
        }
    }

    private func restartScan() {
        previewTask?.cancel()
        similarReviewTask?.cancel()
        similarReviewTask = nil
        preview = nil
        control?.cancel()
        control = nil
        result = nil
        similarImages = nil
        selections.removeAll()
        similarSelections.removeAll()
        cancelled = false
        revision += 1
    }

    private func reviewSimilarImages(_ group: SimilarImageScanner.Group, _ selected: Set<URL>) {
        guard similarReviewTask == nil else { return }
        similarReviewTask = Task {
            let review = await model.removal.prepareSimilarImageConfirm(group: group, selected: selected)
            guard !Task.isCancelled else { return }
            similarReviewTask = nil
            if let review {
                ui.confirm = review
            } else {
                ui.problem = "Keep one available photo in the group. If a photo has changed, scan again."
            }
        }
    }

    private func quickLook(_ url: URL, in group: DuplicateScanner.Group) {
        open(url, action: .preview) { DuplicateScanner.canPreview(url, in: group) }
    }

    private func open(_ url: URL, action: SimilarImageResults.FileAction, validate: @Sendable @escaping () -> Bool) {
        previewTask?.cancel()
        previewTask = Task {
            let canOpen = try? await BackgroundWork.run("andromeda.duplicates.preview", validate)
            guard !Task.isCancelled else { return }
            guard canOpen == true else {
                previewUnavailable = true
                return
            }
            switch action {
            case .preview: preview = url
            case .reveal: model.reveal(url)
            }
        }
    }

    private enum ScanMode {
        case exact, similar, photos

        var subtitle: String {
            switch self {
            case .exact: "Find identical files across folders and connected drives."
            case .similar: "Compare photos that look alike, including resized or re-encoded copies."
            case .photos: "Find similar images in your Photos library."
            }
        }
    }
}

private enum DuplicateSort: String, CaseIterable {
    case largest = "Largest files first"
    case smallest = "Smallest files first"
    case mostCopies = "Most copies first"
}

private struct DuplicateGroupView: View {
    let group: DuplicateScanner.Group
    let model: AppModel
    let ui: UIState
    @Binding var selected: Set<URL>
    let quickLook: (URL) -> Void
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(group.files.count) copies · \(ByteFormat.string(group.logicalBytesPerFile)) each")
                    .font(.headline)
                Spacer()
                Button("Hide Group", systemImage: "eye.slash", action: hide)
                    .labelStyle(.iconOnly)
                    .help("Hide this duplicate group")
                    .accessibilityLabel("Hide duplicate group for \(group.id.lastPathComponent)")
                if !group.trashCandidates.isEmpty {
                    Button("Review Trash Move…") {
                        if let review = model.removal.prepareDuplicateConfirm(group: group, selected: selected) {
                            ui.confirm = review
                        } else {
                            ui.problem = "Leave a verified copy in place. If a file or drive has changed, scan again."
                        }
                    }
                    .disabled(selected.isEmpty || model.removal.removalDisabledReason != nil || model.removal.isExecuting)
                }
            }
            ForEach(group.files, id: \.self) { url in
                HStack {
                    if group.trashCandidates.contains(url) {
                        Toggle(isOn: Binding(get: { selected.contains(url) }, set: { checked in
                            if checked, selected.count < group.files.count - 1 { selected.insert(url) }
                            if !checked { selected.remove(url) }
                        })) {
                            fileLabel(url)
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Select \(url.path) for Trash")
                        .disabled(!selected.contains(url) && selected.count == group.files.count - 1)
                    } else {
                        fileLabel(url)
                    }
                    Spacer()
                    Button("Quick Look", systemImage: "eye") { quickLook(url) }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Quick Look \(url.lastPathComponent)")
                    Button("Show in Finder") { model.reveal(url) }
                        .accessibilityLabel("Show \(url.lastPathComponent) in Finder")
                }
            }
        }
        .card()
    }

    private func fileLabel(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(url.lastPathComponent)
            Text(url.deletingLastPathComponent().path)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(url.path)
        }
    }
}
