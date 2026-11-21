import AndromedaAppModel
import AndromedaCore
import SwiftUI

struct ScanComparisonView: View {
    let model: AppModel
    let ui: UIState
    @State private var watchedDays = 7

    private var history: ScanComparisonHistory { model.scan.comparisonHistory }
    private var plan: SpacePlannerModel { model.spacePlanner }

    var body: some View {
        PageColumn {
            PageHeader(title: "What changed?", subtitle: "Compare how much space your folders and known storage locations used at different times.",
                       symbol: "arrow.up.arrow.down") {
                Button("Open Space Plan", systemImage: "target") { ui.destination = .spacePlan }
                Button("Scan the Mac") { Task { await model.scan() } }
                    .disabled(!model.canScan)
            }
            if let problem = history.problem {
                Banner(text: problem, symbol: "exclamationmark.triangle", tint: .orange)
            }
            if let problem = model.scanFailedText {
                Banner(text: problem, symbol: "exclamationmark.triangle", tint: .orange)
            }
            if let problem = plan.saveProblem {
                Banner(text: problem, symbol: "exclamationmark.triangle", tint: .orange)
            }
            if case .scanning = model.scan.state {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Scanning the Mac…")
                    Spacer()
                    Button("Cancel") { model.scan.cancel() }.disabled(model.scan.isCancelling || history.isSaving)
                }
                .card()
            }
            if history.snapshots.count < 2 {
                let baseline = history.snapshots.first
                EmptyState(title: baseline == nil ? "Scan to save a baseline" : "Baseline saved",
                           symbol: "clock.arrow.circlepath",
                           message: baseline.map { "The scan from \(stamp($0)) is saved on this Mac. Scan again to see what changed." }
                               ?? "Run two scans to see which folders grew or shrank. Andromeda keeps your ten most recent scans on this Mac.")
            } else {
                comparison(history.snapshots)
            }
            if !model.storageMonitor.watchedFolders.isEmpty { watchedFolderChanges }
        }
    }

    private var watchedFolderChanges: some View {
        let now = Date()
        let since = now.addingTimeInterval(-Double(watchedDays) * 86_400)
        let monitor = model.storageMonitor
        let comparisons = monitor.watchedFolderComparisons(since: since, through: now)
        let changes = comparisons.filter { $0.bytes != 0 }
        let unavailable = monitor.watchedFolders.count { $0.unavailable }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeading(title: "Watched folder changes", subtitle: "From folder checks in the selected time range.")
                Spacer()
                Picker("Watched folder time range", selection: $watchedDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .labelsHidden().fixedSize()
                Button("Storage Trends") { ui.destination = .storageTrends }
            }
            if changes.isEmpty {
                Text(comparisons.isEmpty ? "Two complete checks in this range are needed for each folder."
                     : "No measured size changes in this range.")
                    .foregroundStyle(.secondary).card()
            } else {
                LazyInsetList(items: changes) { change in watchedFolderRow(change) }
            }
            if unavailable > 0 {
                Text(unavailable == 1 ? "The latest check was unavailable for 1 watched folder."
                     : "The latest check was unavailable for \(unavailable) watched folders.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func watchedFolderRow(_ change: WatchedFolderComparison) -> some View {
        let folder = change.folder.reference.url
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute().second()
        let earlier = change.earlier.date.formatted(format)
        let later = change.later.date.formatted(format)
        return HStack(spacing: 12) {
            SymbolTile(symbol: "folder", tint: .blue, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.Scan.displayPath(folder, home: model.scanHome))
                    .font(.headline).lineLimit(1).truncationMode(.middle).help(folder.path)
                Text("\(earlier) → \(later)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(signed(change.bytes)).font(.headline).monospacedDigit()
                Text("\(ByteFormat.string(change.earlier.bytes)) → \(ByteFormat.string(change.later.bytes))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if change.bytes > 0 {
                let saved = plan.selectedRows.contains { $0.folderReference == change.folder.reference }
                folderPlanAction(folder, saved: saved) { plan.addFolderForReview(change) }
            }
        }
        .groupRow()
    }

    @ViewBuilder private func comparison(_ snapshots: [ScanComparisonSnapshot]) -> some View {
        let laterOptions = Array(snapshots.dropLast())
        if let later = laterOptions.first(where: { $0.id == ui.comparisonLaterID }) ?? laterOptions.first,
           let laterIndex = snapshots.firstIndex(where: { $0.id == later.id }) {
            let earlierOptions = Array(snapshots.dropFirst(laterIndex + 1))
            if let earlier = earlierOptions.first(where: { $0.id == ui.comparisonEarlierID }) ?? earlierOptions.first {
                HStack {
                    Picker("Earlier", selection: Binding(get: { earlier.id }, set: { ui.comparisonEarlierID = $0 })) {
                        ForEach(earlierOptions) { Text(stamp($0)).tag($0.id) }
                    }
                    Picker("Later", selection: Binding(get: { later.id }, set: { ui.comparisonLaterID = $0 })) {
                        ForEach(laterOptions) { Text(stamp($0)).tag($0.id) }
                    }
                    Spacer()
                }
                .card()
                results(ScanComparison(earlier: earlier, later: later))
            }
        }
    }

    @ViewBuilder private func results(_ comparison: ScanComparison) -> some View {
        if !comparison.comparable {
            EmptyState(title: "These scans cover different home locations", symbol: "folder.badge.questionmark",
                       message: "Choose two scans of the same home folder and volume to compare them.")
        } else {
            freeSpaceSummary(comparison)
            let changes = comparison.catalogChanges.map(MeasuredChange.location)
                + comparison.grew.map(MeasuredChange.folder)
                + comparison.shrank.map(MeasuredChange.folder)
            if changes.isEmpty {
                if comparison.folderCount == 0 && comparison.catalogCount == 0 {
                    EmptyState(title: "No locations could be compared", symbol: "folder",
                               message: "Try two scans that could read the same locations.")
                } else {
                    EmptyState(title: "No measured changes", symbol: "checkmark.circle",
                               message: "The locations that could be compared used the same amount of space.")
                }
            } else {
                changeList("Where space grew", changes: changes.filter { $0.bytes > 0 })
                changeList("Where space shrank", changes: changes.filter { $0.bytes < 0 })
            }
            comparisonCoverage(comparison)
        }
    }

    private func freeSpaceSummary(_ comparison: ScanComparison) -> some View {
        let change = comparison.freeChange
        let title: String
        if let change {
            title = change == 0 ? "Free space stayed the same"
                : "\(ByteFormat.string(abs(change))) \(change < 0 ? "less" : "more") free"
        } else {
            title = "Free-space comparison unavailable"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold)).monospacedDigit()
            Text(change == nil ? "Both scans need comparable free-space readings from the same startup disk."
                 : "Measured free space on the startup disk between these two scans.")
                .font(.callout).foregroundStyle(.secondary)
            if !comparison.grew.isEmpty || !comparison.shrank.isEmpty {
                Text("A change can appear in both a folder and its parent.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func comparisonCoverage(_ comparison: ScanComparison) -> some View {
        DisclosureGroup("What these scans could compare") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compared \(comparison.folderCount.formatted()) home folders and \(comparison.catalogCount.formatted()) known storage locations.")
                if comparison.catalogUncomparedCount > 0 {
                    Text("\(comparison.catalogUncomparedCount.formatted()) known locations had missing or different scan coverage.")
                }
                Text("Folder measurements cover local data up to three levels deep in your home folder. Locations measured separately are listed by name.")
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .card()
    }

    private enum MeasuredChange: Identifiable {
        case location(CatalogSizeChange), folder(FolderSizeChange)

        var id: String {
            switch self {
            case .location(let change): "location:" + change.id
            case .folder(let change): "folder:" + change.id
            }
        }

        var bytes: Int64 {
            switch self {
            case .location(let change): change.bytes
            case .folder(let change): change.bytes
            }
        }
    }

    @ViewBuilder private func changeList(_ title: String, changes: [MeasuredChange]) -> some View {
        if !changes.isEmpty {
            let sorted = changes.sorted {
                abs($0.bytes) == abs($1.bytes) ? $0.id < $1.id : abs($0.bytes) > abs($1.bytes)
            }
            SectionHeading(title: title)
            LazyInsetList(items: Array(sorted.prefix(5))) { change in measuredRow(change) }
            if sorted.count > 5 {
                DisclosureGroup("Show \((sorted.count - 5).formatted()) more") {
                    LazyInsetList(items: Array(sorted.dropFirst(5))) { change in measuredRow(change) }
                        .padding(.top, 8)
                }
                .accessibilityLabel("Show \((sorted.count - 5).formatted()) more changes for \(title)")
                .card()
            }
        }
    }

    @ViewBuilder private func measuredRow(_ change: MeasuredChange) -> some View {
        switch change {
        case .location(let location): catalogRow(location)
        case .folder(let folder): row(folder)
        }
    }

    private func catalogRow(_ change: CatalogSizeChange) -> some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: Style.symbol(change.bucket), tint: Style.bucketColor(change.bucket), size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(change.title).font(.headline)
                Text(Copy.Buckets.title(change.bucket)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(signed(change.bytes)).font(.headline)
                Text("\(ByteFormat.string(change.before)) → \(ByteFormat.string(change.after))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            if model.scan.lastResult?.findings.contains(where: { $0.id == change.id && $0.entry.bucket == change.bucket }) == true {
                Button("Review Category") { ui.destination = .page(change.bucket) }
                    .accessibilityLabel("Review \(Copy.Buckets.title(change.bucket)) for \(change.title)")
            }
        }
        .groupRow()
    }

    private func row(_ change: FolderSizeChange) -> some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: "folder", tint: .blue, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(change.url.lastPathComponent).font(.headline)
                Text(Copy.Scan.displayPath(change.url, home: model.scanHome))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(change.url.path)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(signed(change.bytes)).font(.headline).monospacedDigit()
                Group {
                    switch change.kind {
                    case .resized: Text("\(ByteFormat.string(change.before)) → \(ByteFormat.string(change.after))")
                    case .appeared: Text("New at this path")
                    case .disappeared: Text("No longer at this path")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if change.bytes > 0 {
                folderPlanAction(change.url, saved: plan.containsFolderForReview(change.url)) {
                    plan.addFolderForReview(change)
                }
            }
        }
        .groupRow()
    }

    @ViewBuilder private func folderPlanAction(_ folder: URL, saved: Bool, add: @escaping () -> Void) -> some View {
        if saved {
            Button("Open Space Plan", systemImage: "checkmark") { ui.destination = .spacePlan }
                .accessibilityLabel("Open Space Plan with \(folder.lastPathComponent)")
        } else {
            Button("Add to Space Plan", action: add)
                .accessibilityLabel("Add \(folder.lastPathComponent) to Space Plan")
                .disabled(plan.isBuilding || plan.isMeasuring)
        }
    }

    private func stamp(_ snapshot: ScanComparisonSnapshot) -> String {
        snapshot.date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().second())
    }

    private func signed(_ bytes: Int64) -> String {
        (bytes < 0 ? "−" : "+") + ByteFormat.string(abs(bytes))
    }
}
