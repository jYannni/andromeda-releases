import AppKit
import AndromedaAppModel
import AndromedaCore
import SwiftUI

struct ApplicationCleanupSheet: View {
    enum Mode: String, Identifiable {
        case installed, leftovers
        var id: Self { self }
        var title: String { self == .installed ? "Manage Installed Apps" : "Leftover App Files" }
    }

    let removal: RemovalFlow
    let mode: Mode
    let cancel: () -> Void
    let confirm: (ConfirmSummary) -> Void

    @State private var search = ""
    @State private var sort: AppSort = .largest
    @State private var olderOnly = false
    @State private var architectureFilter: ArchitectureFilter = .all
    @State private var appGroup: AppGroup = .all
    @State private var installedDetails: [URL: RemovalFlow.InstalledApplicationDetails]?
    @State private var target: Target?
    @State private var review: Review?
    @State private var action: ApplicationCleanup.Action = .uninstall
    @State private var leftovers: [ApplicationCleanup.ObservedApplication]?
    @State private var selected: Set<URL> = []
    @State private var selectingApps = false
    @State private var showingSelectedApps = false
    @State private var selectedApps: Set<String> = []
    @State private var batchTargets: [Target] = []
    @State private var batchReviews: [ApplicationCleanup]?
    @State private var leftoverBatchReviews: [ApplicationCleanup.Leftovers]?
    @State private var problem: String?
    @State private var showingIgnoredItems = false

    private enum AppSort: String, CaseIterable, Identifiable {
        case largest = "Largest First"
        case name = "Name"
        case oldest = "Oldest Opened First"

        var id: Self { self }
    }

    private enum ArchitectureFilter: String, CaseIterable {
        case all = "All Architectures"
        case intel = "Intel Only"
        case legacy = "Legacy"

        func includes(_ architecture: ApplicationCleanup.Architecture?) -> Bool {
            switch self {
            case .all: true
            case .intel: architecture == .intel
            case .legacy: architecture == .legacy
            }
        }
    }

    private enum AppGroup: Hashable {
        case all, appStoreHistory, signingTeam(String)

        func includes(_ details: RemovalFlow.InstalledApplicationDetails?) -> Bool {
            switch self {
            case .all: true
            case .appStoreHistory: details?.hasAppStoreHistory == true
            case .signingTeam(let id): details?.signingTeam?.id == id
            }
        }
    }

    private enum Target: Identifiable {
        case installed(AppItem)
        case removed(ApplicationCleanup.ObservedApplication)

        var id: String {
            switch self {
            case .installed(let app): app.url.path
            case .removed(let app): app.id
            }
        }

        var name: String {
            switch self {
            case .installed(let app): app.url.deletingPathExtension().lastPathComponent
            case .removed(let app): app.name
            }
        }
    }

    private enum Review {
        case installed(ApplicationCleanup)
        case removed(ApplicationCleanup.Leftovers)
    }

    private var candidates: [Target] {
        if selectingApps && showingSelectedApps { return selectedCandidates }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = mode == .installed
            ? installedCandidates.map(Target.installed)
            : (leftovers ?? []).map(Target.removed)
        return all.filter { target in
            if query.isEmpty || target.name.localizedStandardContains(query) || target.id.localizedStandardContains(query) { return true }
            guard case .installed(let app) = target, let team = installedDetails?[app.url]?.signingTeam else { return false }
            return team.displayName.localizedStandardContains(query) || team.id.localizedStandardContains(query)
        }
    }

    private var selectedCandidates: [Target] {
        let available = mode == .installed
            ? sortedInstalledApps(removal.applicationCleanupCandidates).map(Target.installed) : (leftovers ?? []).map(Target.removed)
        return available.filter { selectedApps.contains($0.id) }
    }

    private var signingTeams: [ApplicationCleanup.SigningTeam] {
        let ordered = (installedDetails ?? [:]).values.compactMap(\.signingTeam).sorted {
            if $0.displayName != $1.displayName {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.id < $1.id
        }
        var seen: Set<String> = []
        return ordered.filter { seen.insert($0.id).inserted }
    }

    private var installedCandidates: [AppItem] {
        let details = installedDetails ?? [:]
        var apps = removal.applicationCleanupCandidates.filter {
            let detail = details[$0.url]
            return architectureFilter.includes(detail?.architecture) && appGroup.includes(detail)
        }
        if olderOnly, let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date()) {
            apps = apps.filter { app in details[app.url]?.lastOpened.map { $0 <= cutoff } == true }
        }
        return sortedInstalledApps(apps)
    }

    private func sortedInstalledApps(_ apps: [AppItem]) -> [AppItem] {
        let details = installedDetails ?? [:]
        switch sort {
        case .largest: return apps
        case .name:
            return apps.sorted {
                $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
        case .oldest:
            return apps.sorted {
                (details[$0.url]?.lastOpened ?? .distantFuture) < (details[$1.url]?.lastOpened ?? .distantFuture)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: sheetTitle,
                        symbol: "app.badge", tint: .indigo)
            if showingIgnoredItems {
                ignoredItems
            } else if !batchTargets.isEmpty {
                if mode == .leftovers { leftoverBatchReview }
                else { batchReview }
            } else if let target {
                if let review { choices(review) }
                else if problem == nil { ProgressView("Checking Library files…") }
                if let problem { Text(problem).foregroundStyle(.secondary) }
                Divider()
                HStack {
                    Button("Back") {
                        self.target = nil
                        problem = nil
                    }
                    Spacer()
                    Button("Cancel", role: .cancel, action: cancel)
                    Button("Continue…", action: prepareConfirm)
                        .disabled(review == nil || ((mode == .leftovers || action == .clearData) && selected.isEmpty))
                }
                .task(id: target.id) { await load(target) }
            } else {
                if mode == .leftovers {
                    Text("Andromeda checks earlier scans, Mac App Store history, crash reports, and user LaunchAgents for leftover app files. With Full Disk Access, it also checks for app bundles in Trash.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    TextField(mode == .installed ? "Search installed apps" : "Search removed apps", text: $search)
                        .disabled(selectingApps && showingSelectedApps)
                    if mode == .installed {
                        Picker("Sort apps", selection: $sort) {
                            ForEach(AppSort.allCases) { option in Text(option.rawValue).tag(option) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if selectingApps {
                        Toggle("Show Selected", isOn: $showingSelectedApps)
                    } else {
                        Button("Ignored Items…") { showingIgnoredItems = true }
                    }
                }
                if mode == .installed && !(selectingApps && showingSelectedApps) {
                    HStack {
                        Toggle("Last opened at least 6 months ago", isOn: $olderOnly)
                            .help("Uses Spotlight’s last-opened date. Apps without a recorded date stay in the full list.")
                        Spacer()
                        Picker("App architecture", selection: $architectureFilter) {
                            ForEach(ArchitectureFilter.allCases, id: \.self) { option in Text(option.rawValue) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("Based on the app’s main executable.")
                    }
                    Picker("App group", selection: $appGroup) {
                        Text("All Apps").tag(AppGroup.all)
                        Text("Mac App Store History").tag(AppGroup.appStoreHistory)
                        if !signingTeams.isEmpty { Divider() }
                        ForEach(signingTeams, id: \.id) { team in
                            Text(team.certificateName.map { "\($0) · \(team.id)" } ?? team.id).tag(AppGroup.signingTeam(team.id))
                        }
                    }
                    .help("App Store History shows known bundle IDs in the Mac’s local installation records. Other groups use the signing Team ID recorded in the app’s signature.")
                }
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if mode == .leftovers && leftovers == nil {
                    ProgressView("Checking for leftover app files…")
                } else if mode == .installed && (olderOnly || architectureFilter != .all || appGroup != .all)
                            && installedDetails == nil && !showingSelectedApps {
                    ProgressView("Checking app details…")
                } else if candidates.isEmpty {
                    Text(mode == .leftovers && search.isEmpty ? "No leftover app files found."
                         : olderOnly && search.isEmpty && architectureFilter == .all && appGroup == .all && !showingSelectedApps
                         ? "No apps have a recorded last-opened date this old."
                         : "No matching applications.")
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(candidates) { candidate in candidateRow(candidate) }
                    }
                }
                .frame(height: 340)
                HStack {
                    if selectingApps {
                        Button("Clear Selection") { selectedApps.removeAll() }
                            .disabled(selectedApps.isEmpty)
                        Text("\(selectedCandidates.count) selected").foregroundStyle(.secondary)
                    } else {
                        Button("Select Apps…") { selectingApps = true }
                            .disabled(mode == .leftovers && leftovers?.isEmpty != false)
                    }
                    Spacer()
                    if selectingApps {
                        Button("Cancel Selection", role: .cancel) {
                            selectedApps.removeAll()
                            showingSelectedApps = false
                            selectingApps = false
                        }
                        Button("Review Selected Apps…") {
                            problem = nil
                            selected.removeAll()
                            batchReviews = nil
                            leftoverBatchReviews = nil
                            batchTargets = selectedCandidates
                        }
                        .disabled(selectedCandidates.isEmpty)
                    } else {
                        Button("Cancel", role: .cancel, action: cancel)
                    }
                }
                .task(id: removal.ignoredAppCleanupItems) {
                    guard mode == .leftovers else { return }
                    let result = await removal.leftoverApplicationCandidates()
                    guard !Task.isCancelled else { return }
                    leftovers = result
                    problem = result == nil ? "Andromeda couldn’t check both Applications folders. Try a new scan." : nil
                }
            }
        }
        .padding(24)
        .frame(width: 580)
        .background(Palette.canvas)
        .task(id: removal.applicationCleanupCandidates) {
            guard mode == .installed else { return }
            installedDetails = nil
            let details = await removal.installedApplicationDetails()
            guard !Task.isCancelled else { return }
            installedDetails = details
            if case .signingTeam(let id) = appGroup,
               !details.values.contains(where: { $0.signingTeam?.id == id }) { appGroup = .all }
        }
    }

    private var sheetTitle: String {
        if showingIgnoredItems { return "Ignored App Cleanup Items" }
        if !batchTargets.isEmpty { return "Review Selected Apps" }
        return target.map { "Review \($0.name)" } ?? mode.title
    }

    private var ignoredItems: some View {
        VStack(alignment: .leading, spacing: 12) {
            if removal.ignoredAppCleanupItems.isEmpty {
                Text("No items are ignored. Control-click an app or leftover file to ignore it.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    InsetGroup {
                        ForEach(removal.ignoredAppCleanupItems) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.appName)
                                    Text(ignoredItemDetail(item.id))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(ignoredItemDetail(item.id))
                                }
                                Spacer()
                                Button("Show Again") { removal.showAppCleanupItemAgain(item) }
                                    .accessibilityLabel("Show \(item.appName) again")
                            }
                            .groupRow()
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
            Divider()
            Button("Back") { showingIgnoredItems = false }
        }
    }

    private func ignoredItemDetail(_ key: IgnoredAppCleanupItem.Key) -> String {
        switch key {
        case .installed(let id): "Installed app · \(id)"
        case .leftovers(let id): "All leftovers · \(id)"
        case .leftoverFile(_, let path): path
        }
    }

    @ViewBuilder private func candidateRow(_ candidate: Target) -> some View {
        if selectingApps {
            Toggle(isOn: selection(candidate.id, in: $selectedApps)) {
                candidateLabel(candidate)
            }
            .toggleStyle(.checkbox)
            .groupRow()
        } else {
            Button {
                review = nil
                problem = nil
                action = .uninstall
                target = candidate
            } label: {
                HStack {
                    candidateLabel(candidate)
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .groupRow()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                switch candidate {
                case .installed(let app) where removal.canIgnoreInstalledApp(app):
                    Button("Ignore App") {
                        selectedApps.remove(candidate.id)
                        removal.ignoreInstalledApp(app)
                    }
                case .removed(let app):
                    Button("Ignore All Leftovers for This App") {
                        removal.ignoreLeftoverApp(app)
                        leftovers?.removeAll { $0.id == app.id }
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    private func candidateLabel(_ candidate: Target) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                Text(candidate.id).font(.caption).foregroundStyle(.secondary)
                if case .installed(let app) = candidate, let details = installedDetails?[app.url] {
                    let lastOpened = details.lastOpened.map { "Last opened \($0.formatted(date: .abbreviated, time: .omitted))" }
                        ?? "Last opened unavailable"
                    let summary = [details.architecture?.rawValue, lastOpened,
                                   details.hasAppStoreHistory ? "App Store history" : nil,
                                   details.signingTeam?.displayName].compactMap { $0 }.joined(separator: " · ")
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if case .installed(let app) = candidate { Text(ByteFormat.string(app.bytes)).monospacedDigit() }
        }
    }

    private var batchReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let batchReviews {
                let reviewedPaths = Set(batchReviews.map { $0.app.url.standardizedFileURL.path })
                let unavailable = batchTargets.filter { app in
                    !reviewedPaths.contains(URL(fileURLWithPath: app.id).standardizedFileURL.path)
                }
                if batchReviews.contains(where: { !$0.related.isEmpty }) { librarySelectionNote }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(batchReviews, id: \.app.url) { review in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(review.app.url.deletingPathExtension().lastPathComponent).font(.headline)
                                InsetGroup {
                                    itemRow(review.app)
                                    ForEach(review.related) { libraryChoice($0) }
                                }
                                if review.relatedOwnershipUnclear { uncertainOwnershipNote }
                            }
                        }
                        ForEach(unavailable) { app in
                            Text("\(app.name) couldn’t be reviewed and will stay in place.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 340)
            } else {
                ProgressView("Checking apps and Library files…")
            }
            if let problem { Text(problem).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("Back") {
                    batchTargets.removeAll()
                    problem = nil
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                Button("Continue…") {
                    guard let batchReviews,
                          let summary = removal.prepareApplicationUninstallConfirm(batchReviews, selected: selected) else {
                        problem = "Run a new storage scan and review these files again."
                        return
                    }
                    confirm(summary)
                }
                .disabled(batchReviews?.isEmpty != false)
            }
        }
        .task(id: batchTargets.map(\.id)) {
            let reviews = await removal.inspectApplications(batchTargets.compactMap { target in
                if case .installed(let app) = target { return app.url }
                return nil
            })
            guard !Task.isCancelled else { return }
            batchReviews = reviews
        }
    }

    private var leftoverBatchReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let leftoverBatchReviews {
                let reviewedIDs = Set(leftoverBatchReviews.map(\.application.id))
                if !leftoverBatchReviews.isEmpty { librarySelectionNote }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(leftoverBatchReviews, id: \.application.id) { review in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(review.application.name).font(.headline)
                                InsetGroup {
                                    ForEach(review.items) { libraryChoice($0) }
                                }
                            }
                        }
                        ForEach(batchTargets.filter { !reviewedIDs.contains($0.id) }) { app in
                            Text("\(app.name) couldn’t be reviewed and will stay in place.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 340)
            } else {
                ProgressView("Checking leftover app files…")
            }
            if let problem { Text(problem).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("Back") {
                    batchTargets.removeAll()
                    problem = nil
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                Button("Continue…") {
                    guard let leftoverBatchReviews,
                          let summary = removal.prepareLeftoverConfirm(leftoverBatchReviews, selected: selected) else {
                        problem = "Run a new storage scan and review these files again."
                        return
                    }
                    confirm(summary)
                }
                .disabled(selected.isEmpty)
            }
        }
        .task(id: batchTargets.map(\.id)) {
            let reviews = await removal.inspectLeftovers(batchTargets.compactMap { target in
                if case .removed(let app) = target { return app }
                return nil
            })
            guard !Task.isCancelled else { return }
            leftoverBatchReviews = reviews
        }
    }

    private func load(_ target: Target) async {
        selected = []
        let result: Review?
        switch target {
        case .installed(let app): result = await removal.inspectApplication(app.url).map(Review.installed)
        case .removed(let app): result = await removal.inspectLeftovers(app).map(Review.removed)
        }
        guard !Task.isCancelled else { return }
        review = result
        if result == nil {
            problem = mode == .installed
                ? "Andromeda couldn’t review this app. Apple apps and Andromeda are excluded. The app must be on the startup disk and readable."
                : "Andromeda couldn’t confirm that this app is still absent and its Library files are readable."
        }
    }

    private func prepareConfirm() {
        guard let review else { return }
        let summary: ConfirmSummary?
        switch review {
        case .installed(let app): summary = removal.prepareApplicationConfirm(app, selected: selected, action: action)
        case .removed(let app): summary = removal.prepareLeftoverConfirm(app, selected: selected)
        }
        guard let summary else {
            problem = "Run a new storage scan and review these files again."
            return
        }
        confirm(summary)
    }

    private func choices(_ review: Review) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let items = visibleOptions(review)
            if case .installed(let app) = review {
                Picker("App cleanup action", selection: $action) {
                    Text("Uninstall App").tag(ApplicationCleanup.Action.uninstall)
                    Text("Clear App Data").tag(ApplicationCleanup.Action.clearData)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: action) { _, newAction in
                    selected.formIntersection(app.relatedItems(for: newAction).map(\.url))
                }
                if action == .uninstall {
                    InsetGroup { itemRow(app.app) }
                } else {
                    Text("The app stays installed.").font(.callout).foregroundStyle(.secondary)
                }
            }
            if !items.isEmpty {
                librarySelectionNote
                ScrollView {
                    InsetGroup {
                        ForEach(items) { libraryChoice($0) }
                    }
                }
                .frame(maxHeight: 260)
            } else if case .installed(let app) = review, app.relatedOwnershipUnclear {
                uncertainOwnershipNote
            } else {
                Text("Andromeda found no related Library files available to review.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func visibleOptions(_ review: Review) -> [ApplicationCleanup.Item] {
        switch review {
        case .installed(let app):
            return app.relatedItems(for: action)
        case .removed(let app):
            return app.items.filter { !removal.isLeftoverFileIgnored($0.url, for: app.application) }
        }
    }

    private var librarySelectionNote: some View {
        Text("Select the Library files you want to move to Trash. They may contain your settings or app data.")
            .font(.callout).foregroundStyle(.secondary)
    }

    private var uncertainOwnershipNote: some View {
        Text("Related files were left out because Andromeda couldn’t confirm this is the only installed copy.")
            .font(.callout).foregroundStyle(.secondary)
    }

    private func libraryChoice(_ item: ApplicationCleanup.Item) -> some View {
        Toggle(isOn: selection(item.url, in: $selected)) { itemRow(item) }
            .padding(.leading, 12)
            .contextMenu {
                if item.mayContainUserScripts {
                    Button("Reveal Scripts in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                }
                if case .removed(let app)? = review {
                    Button("Ignore This Leftover File") {
                        removal.ignoreLeftoverFile(item.url, from: app)
                        selected.remove(item.url)
                        if visibleOptions(.removed(app)).isEmpty {
                            target = nil
                            review = nil
                        }
                    }
                }
            }
    }

    private func selection<Value: Hashable>(_ value: Value, in values: Binding<Set<Value>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(value) }, set: { enabled in
            if enabled { values.wrappedValue.insert(value) } else { values.wrappedValue.remove(value) }
        })
    }

    private func itemRow(_ item: ApplicationCleanup.Item) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.body.weight(.medium))
                Text(item.url.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(item.url.path)
                if item.mayContainUserScripts {
                    Text("Review in Finder before moving scripts you may have created.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(ByteFormat.string(item.bytes)).monospacedDigit()
        }
        .groupRow()
    }
}
