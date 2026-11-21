import AndromedaAppModel
import AndromedaCore
import AndromedaOrganize
import SwiftUI

struct SpacePlannerView: View {
    let model: AppModel
    let ui: UIState
    @Bindable private var plan: SpacePlannerModel
    @State private var confirmStartOver = false

    init(model: AppModel, ui: UIState) {
        self.model = model
        self.ui = ui
        plan = model.spacePlanner
    }

    var body: some View {
        PageColumn {
            PageHeader(
                title: "Space Plan", subtitle: "Make room for new work and decide where older work belongs.",
                symbol: "target")
            if plan.builtFromScan == nil { findOptions }
            if let problem = plan.saveProblem {
                Banner(text: problem, symbol: "exclamationmark.triangle", tint: .orange)
            }
            if plan.isBuilding {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking activity and space estimates…")
                    Spacer()
                    Button("Cancel") { plan.cancel() }
                }
                .card()
            }
            if let built = plan.builtAt {
                if let prior = plan.builtFromScan, let scan = model.scan.lastResult, prior != scan.finishedAt {
                    HStack {
                        Banner(text: "A newer scan is available.", symbol: "arrow.clockwise", tint: .secondary)
                        Button("Refresh Suggestions") { Task { await build() } }
                            .disabled(plan.targetBytes == nil || plan.isBuilding || plan.isMeasuring)
                    }
                }
                results(built)
            }
            if plan.builtFromScan != nil { settings.card() }
        }
        .task(id: plan.selected) { await model.refreshSpacePlanProgress() }
        .onChange(of: model.removal.receipt?.batchID) { _, batch in
            if batch != nil { Task { await model.refreshSpacePlanProgress() } }
        }
        .alert("Start a new space plan?", isPresented: $confirmStartOver) {
            Button("Cancel", role: .cancel) {}
            Button("Start Over", role: .destructive) { plan.startOver() }
        } message: {
            Text("This clears the saved selection and measurement. Your files, archives, and History stay as they are.")
        }
    }

    private var findOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Set a space target", subtitle: "Andromeda suggests ways to make room. You choose which actions to review.")
            HStack(spacing: 8) {
                targetField
                Spacer(minLength: 8)
                if model.scan.lastResult != nil {
                    Button("Find Options") { Task { await build() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(plan.targetBytes == nil || plan.isBuilding || plan.isMeasuring)
                }
            }
            if model.scan.lastResult == nil {
                scanForCleanup("Scan this Mac to find cleanup and storage options for your target.")
            }
            settings
        }
        .disabled(plan.isBuilding)
        .card()
    }

    private var targetField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Space to free").fontWeight(.medium)
            TextField("Space to free in GB", value: $plan.targetGB, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
            Text("GB").foregroundStyle(.secondary)
        }
    }

    private var settings: some View {
        DisclosureGroup("Plan Options") {
            VStack(alignment: .leading, spacing: 12) {
                if plan.builtFromScan != nil { targetField }
                Picker("Prefer for older local files", selection: $plan.destination) {
                    ForEach(SpacePlannerModel.Destination.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                HStack {
                    Button("Check Cloud Copies…") { ui.openSpacePlanStep(.cloud, title: "Check Cloud Copies") }
                        .help("The plan uses results from cloud folders you’ve checked.")
                    if plan.builtAt != nil {
                        Button("Start Over…") { confirmStartOver = true }.disabled(plan.isMeasuring)
                    }
                }
            }
            .padding(.top, 8)
        }
        .disabled(plan.isBuilding)
    }

    private func results(_ built: Date) -> some View {
        let rows = plan.rows
        let reviews = rows.filter { $0.action == .reviewFolder }
        let steps = rows.filter { $0.action != .reviewFolder }
        let selectedCleanupCount = plan.selectedRows.count { if case .cleanup = $0.action { true } else { false } }
        let reviewableCleanupCount = cleanupIDs.count
        return VStack(alignment: .leading, spacing: 16) {
            if !reviews.isEmpty {
                SectionHeading(title: "Folders to review", subtitle: "Saved from Storage Map or What changed?")
                LazyInsetList(items: reviews) { row($0) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeading(title: "Saved plan", subtitle: plan.builtFromScan == nil
                        ? "Folders you added for review." : "Suggestions checked \(built.formatted(date: .abbreviated, time: .shortened)).")
                    Spacer()
                    Menu("Plan Actions") {
                        Button("Suggest Selection") { plan.suggestSelection() }
                            .disabled(plan.targetBytes == nil || plan.isBuilding || plan.isCheckingProgress)
                        if plan.builtFromScan != nil {
                            Button("Refresh Suggestions") { Task { await build() } }
                                .disabled(model.scan.lastResult == nil || plan.targetBytes == nil || plan.isBuilding || plan.isMeasuring)
                        }
                    }
                    .fixedSize()
                }
                if let target = plan.targetBytes {
                    Text("\(ByteFormat.string(plan.estimatedBytes)) estimated from remaining steps · \(ByteFormat.string(target)) target")
                        .font(.headline).monospacedDigit()
                }
                timingTotals
                if plan.unknownCount > 0 {
                    Text("\(plan.unknownCount.formatted()) selected with an unknown space estimate.")
                        .foregroundStyle(.secondary)
                }
                if reviewableCleanupCount > 0 {
                    Button(reviewableCleanupCount == selectedCleanupCount
                           ? "Review Selected Cleanup…" : "Review Available Cleanup…") { reviewCleanup() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canScan || plan.isBuilding || model.removal.removalDisabledReason != nil)
                    if reviewableCleanupCount < selectedCleanupCount {
                        Text("Some saved cleanup steps are missing or have changed. Review only includes the steps that still match.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if selectedCleanupCount > 0, model.scan.lastResult == nil {
                    scanForCleanup("Scan this Mac to check which saved cleanup items are still available.")
                } else if selectedCleanupCount > 0 {
                    Text("The current scan found no matching cleanup options from this plan.").foregroundStyle(.secondary)
                }
            }
            .card()
            measurement
            if let problem = plan.progressProblem {
                Banner(text: problem, symbol: "exclamationmark.triangle", tint: .orange)
            }
            if rows.isEmpty {
                Text("The last scan and checked cloud folders had no matching suggestions.")
                    .foregroundStyle(.secondary).card()
            } else if !steps.isEmpty {
                HStack {
                    SectionHeading(title: "Plan steps")
                    Spacer()
                    if plan.isCheckingProgress { ProgressView().controlSize(.small) }
                    Button("Check Progress") { Task { await model.refreshSpacePlanProgress() } }
                        .disabled(plan.isCheckingProgress || plan.selected.isEmpty)
                }
                LazyInsetList(items: steps.filter { plan.selected.contains($0.id) }
                              + steps.filter { !plan.selected.contains($0.id) }) { row($0) }
            }
        }
    }

    @ViewBuilder private func scanForCleanup(_ instructions: String) -> some View {
        if case .scanning(let stage) = model.scan.state {
            HStack {
                ProgressView().controlSize(.small)
                Text(model.scan.isCancelling ? UICopy.stoppingScan : UICopy.stage(stage))
                Spacer()
                Button("Cancel Scan") { model.scan.cancel() }
                    .disabled(model.scan.isCancelling || model.scan.comparisonHistory.isSaving)
            }
        } else if model.isPreparingScan {
            HStack {
                ProgressView().controlSize(.small)
                Text(UICopy.stage(.checkingAccess))
            }
        } else {
            HStack {
                Text(model.scanFailedText ?? instructions).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(model.scanFailedText == nil ? "Scan This Mac" : "Retry Scan") {
                    Task { await model.scan() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canScan)
            }
        }
    }

    private var timingTotals: some View {
        let selected = plan.pendingRows
        let afterHandoff = selected.reduce(Int64(0)) { total, item in
            switch item.action {
            case .onlineOnly: return total + (item.estimate ?? 0)
            case .moveToCloud where readyForHandoff(item): return total + (item.estimate ?? 0)
            default: return total
            }
        }
        let afterTrash = selected.reduce(Int64(0)) { total, item in
            switch item.action {
            case .cleanup, .archive: return total + (item.estimate ?? 0)
            default: return total
            }
        }
        let afterUpload = selected.filter { $0.action == .moveToCloud && !readyForHandoff($0) }
            .compactMap(\.estimate).reduce(0, +)
        return VStack(alignment: .leading, spacing: 3) {
            if afterHandoff > 0 { Text("\(ByteFormat.string(afterHandoff)) after removing local cloud downloads") }
            if afterTrash > 0 { Text("\(ByteFormat.string(afterTrash)) after cleanup or verified archiving, once the originals leave Trash") }
            if afterUpload > 0 { Text("\(ByteFormat.string(afterUpload)) after upload finishes and you remove the local download") }
        }
        .font(.callout).foregroundStyle(.secondary)
    }

    private var measurement: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading(title: "Measured free space")
                Spacer()
                if plan.isMeasuring { ProgressView().controlSize(.small) }
                Button("Check Free Space") {
                    Task {
                        await plan.checkFreeSpace()
                        await model.refreshSpacePlanProgress()
                    }
                }
                    .disabled(plan.isMeasuring || plan.isBuilding)
            }
            if let first = plan.initialFree, let now = plan.currentFree {
                let delta = now - first
                Text("\(ByteFormat.string(now)) free now · \(delta < 0 ? "−" : "+")\(ByteFormat.string(abs(delta))) net change")
                    .font(.headline).monospacedDigit()
                Text("Compared with \(ByteFormat.string(first)) at the start of this measurement. Other disk activity can affect the result.")
                    .font(.callout).foregroundStyle(.secondary)
                if let target = plan.targetBytes {
                    let remaining = max(0, target - delta)
                    Text(remaining == 0 ? "Measured free space has reached the target."
                         : "\(ByteFormat.string(remaining)) still needed based on measured free space.")
                        .font(.callout.weight(.medium))
                }
                if let at = plan.measuredAt {
                    Text("Checked \(at.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Reset Measurement") {
                    plan.resetMeasurement()
                    Task { await plan.checkFreeSpace() }
                }
                .disabled(plan.isMeasuring || plan.isBuilding)
            }
            if let note = plan.measurementProblem { Text(note).foregroundStyle(.secondary) }
        }
        .card()
    }

    private func row(_ item: SpacePlanItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if item.available || plan.selected.contains(item.id) {
                Toggle(item.title, isOn: Binding(
                    get: { plan.selected.contains(item.id) }, set: { _ in plan.toggle(item) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(plan.isBuilding)
            } else {
                Image(systemName: item.action == .keepLocal ? "pin" : "info.circle")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                if item.paths.count == 1, let path = item.paths.first {
                    Text(Copy.Scan.displayPath(path, home: model.scanHome)).font(.caption)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if plan.selected.contains(item.id), let state = plan.progress[item.id] {
                    Text(state.message).font(.callout)
                    if case .cloudCopy(_, let provider, true, _) = state.nextStep {
                        Text(Copy.Organize.handOff(for: provider)).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text(item.reason).font(.callout).foregroundStyle(.secondary)
                    if let uses = item.uses { Text("\(ByteFormat.string(uses)) at last check").font(.caption) }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(label(item.action)).font(.callout.weight(.medium))
                if let estimate = item.estimate, plan.pendingEstimate(for: item) {
                    Text("\(ByteFormat.string(estimate)) estimated").font(.caption).monospacedDigit()
                }
                action(item).disabled(plan.isBuilding)
            }
        }
        .groupRow()
    }

    private func label(_ action: SpacePlanItem.Action) -> String {
        switch action {
        case .keepLocal: "Keep local"
        case .cleanup: "Review cleanup"
        case .onlineOnly: "Make online-only"
        case .archive: "Archive to drive"
        case .moveToCloud: "Move to cloud"
        case .reviewFolder: "Review folder"
        }
    }

    @ViewBuilder private func action(_ item: SpacePlanItem) -> some View {
        if plan.selected.contains(item.id) {
            if let next = plan.progress[item.id]?.nextStep {
                nextAction(next, title: item.title)
            } else if item.available, let url = item.paths.first, item.paths.count == 1 {
                switch item.action {
                case .onlineOnly:
                    Button("Review Cloud Copy…") {
                        model.cloud.preselectForHandoff(url)
                        ui.openSpacePlanStep(.cloud, title: item.title)
                    }
                case .archive:
                    Button("Review Archive…") {
                        model.archives.pick(url)
                        ui.openSpacePlanStep(.archives, title: item.title)
                    }
                    .disabled(!model.archives.canStart)
                case .moveToCloud:
                    Button("Review Cloud Move…") {
                        model.moveToCloud.preselect(url, measuredBytes: item.uses)
                        ui.openSpacePlanStep(.moveToCloud, title: item.title)
                    }
                case .reviewFolder:
                    Button("Browse Folder…") { ui.destination = .reviewFolder(url, item.folderReference) }
                case .keepLocal, .cleanup: EmptyView()
                }
            }
        }
        if item.paths.count == 1 {
            switch item.action {
            case .cleanup, .reviewFolder: EmptyView()
            default:
                Button(plan.isPinned(item) ? "Unpin" : "Keep Local") { plan.toggleKeepLocal(item) }
                    .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder private func nextAction(_ step: SpacePlanProgress.NextStep, title: String) -> some View {
        switch step {
        case .archive(let id):
            Button("Open Archive…") {
                ui.openSpacePlanStep(.archives, title: title, record: id)
            }
        case .history(let id):
            openHistory(id, title: title)
        case .cloudCopy(let url, _, _, let batch):
            Button("Show Cloud Copy in Finder") { model.reveal(url) }
            if let batch { openHistory(batch, title: title) }
        }
    }

    private func openHistory(_ id: UUID, title: String) -> some View {
        Button("Open History…") {
            ui.openSpacePlanStep(.history, title: title, record: id)
        }
    }

    private func readyForHandoff(_ item: SpacePlanItem) -> Bool {
        if case .cloudCopy(_, _, true, _) = plan.progress[item.id]?.nextStep { return true }
        return false
    }

    private var cleanupIDs: Set<String> {
        model.scan.lastResult.map(plan.cleanupIDs(for:)) ?? []
    }

    private func reviewCleanup() {
        if let confirm = model.removal.prepareConfirm(ids: cleanupIDs) { ui.confirm = confirm }
        else { ui.problem = "Run a fresh scan and build the space plan again to review these cleanup items." }
    }

    private func build() async {
        guard let result = model.scan.lastResult else { return }
        await model.drives.refreshInBackground()
        await plan.build(
            from: result, cloud: model.cloud.providers.flatMap(\.rows), drives: model.drives.volumes,
            settings: model.organizeSettings)
        await model.refreshSpacePlanProgress()
    }
}
