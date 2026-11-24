import AndromedaAppModel
import SwiftUI

/// What the window's detail pane shows for the current destination and scan state.
struct DetailView: View {
    let model: AppModel
    let ui: UIState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scanButtonFrame = CGRect.zero
    @State private var expansion: ScanExpansion?

    var body: some View {
        if case .drive(let id) = ui.destination {
            // Drives are scanned on their own, so the page doesn't wait on the main scan.
            DrivePageView(model: model, ui: ui, id: id).id(id)
        } else if ui.destination == .driveCatalogs {
            DriveCatalogView(model: model, ui: ui)
        } else if ui.destination == .history {
            HistoryView(model: model, focusedBatch: ui.focusedRecord) {
                if let title = ui.spacePlanStepTitle { ui.openSpacePlanStep(.archives, title: title) }
                else { ui.destination = .archives }
            }
        } else if ui.destination == .archives {
            ArchivesView(model: model, focusedArchive: ui.focusedRecord)
        } else if ui.destination == .spacePlan {
            SpacePlannerView(model: model, ui: ui)
        } else if ui.destination == .tools {
            ToolsView(model: model, ui: ui)
        } else if case .tool(let page) = ui.destination {
            tool(page).id(page)
        } else if ui.destination == .scanComparison {
            ScanComparisonView(model: model, ui: ui)
        } else if ui.destination == .storageTrends {
            StorageTrendsView(model: model, ui: ui)
        } else if ui.destination == .duplicates {
            DuplicatesView(model: model, ui: ui)
        } else if case .reviewFolder(let folder, let reference) = ui.destination {
            StorageBrowserView(
                model: model, title: folder.lastPathComponent, subtitle: folder.path,
                scope: model.savedFolderScope(folder, reference: reference),
                openPlan: { ui.destination = .spacePlan },
                archive: { url in
                    model.archives.pick(url)
                    ui.openSpacePlanStep(.archives, title: url.lastPathComponent)
                },
                actionTitle: "Back to Space Plan") { ui.returnToSpacePlan(model: model) }
                .id(folder)
        } else if ui.destination == .cloud {
            CloudView(cloud: model.cloud)
        } else if ui.destination == .moveToCloud {
            MoveToCloudView(model: model)
        } else if ui.destination == .organizeFolder {
            OrganizeFolderView(model: model, ui: ui)
        } else if ui.destination == .browseFolder {
            FolderStorageView(model: model, ui: ui)
        } else if case .reviewInstallers(let folder) = ui.destination {
            FolderStorageView(model: model, ui: ui, installerFolder: folder)
                .id(folder)
        } else if ui.destination == .storageMap {
            FolderStorageView(model: model, ui: ui, startAtHome: true)
        } else {
            scanDetail
        }
    }

    @ViewBuilder private func tool(_ page: ToolPage) -> some View {
        switch page {
        case .aiClutter: CleanupToolView(model: model, ui: ui, tool: .aiClutter)
        case .mailAttachments: CleanupToolView(model: model, ui: ui, tool: .mailAttachments)
        case .trashBins: TrashBinsView(model: model, ui: ui)
        case .maintenance: MaintenanceView(model: model, ui: ui)
        case .snapshots: SnapshotToolView(model: model, ui: ui)
        case .downloads, .largeFiles: FolderStorageView(model: model, ui: ui, tool: page)
        case .similarImages: DuplicatesView(model: model, ui: ui, startsInSimilarMode: true)
        }
    }

    private var scanStage: ScanStage? {
        if model.isPreparingScan { return .checkingAccess }
        if case .scanning(let stage) = model.scan.state { return stage }
        return nil
    }

    private var scanDetail: some View {
        let stage = scanStage

        return ZStack {
            if let stage {
                scanning(stage).transition(.identity)
            } else {
                switch model.scan.state {
                case .idle:
                    initialScanPrompt
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                        .zIndex(1)
                case .failed:
                    ScanPromptView(
                        title: UICopy.failedTitle, message: model.scanFailedText ?? "", disabled: !model.canScan
                    ) {
                        Button {
                            Task { await model.scan() }
                        } label: {
                            Text(UICopy.tryAgain).frame(minWidth: 140)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    }
                case .done: results
                case .scanning: EmptyView()
                }
            }
        }
        .background(Palette.canvas)
        .overlay(alignment: .topLeading) {
            if stage != nil, let expansion { expandingButton(expansion) }
        }
        .coordinateSpace(name: ScanExpansionSpace.detail)
        .animation(expansion != nil && stage != nil ? .easeOut(duration: 0.14) : nil, value: stage != nil)
        .onChange(of: reduceMotion) { if reduceMotion { expansion = nil } }
        .onDisappear { expansion = nil }
    }

    private var initialScanPrompt: some View {
        ScanPromptView(title: UICopy.readyTitle, message: UICopy.readyBody, disabled: !model.canScan) {
            StartScanButton(action: startScan)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ScanExpansionSpace.detail)) } action: {
                    scanButtonFrame = $0
                }
                .opacity(expansion == nil ? 1 : 0)
        }
    }

    private func scanning(_ stage: ScanStage) -> ScanningView {
        let preparing = model.isPreparingScan
        return ScanningView(
            stage: stage, stages: model.scan.stages, progress: preparing ? nil : model.scan.progress,
            startedAt: preparing ? nil : model.scan.startedAt, isCancelling: model.scan.isCancelling,
            onCancel: preparing ? nil : { model.scan.cancel() },
            revealsContent: expansion == nil || expansion?.checklistFrame != nil,
            onChecklistFrame: expandScanButton(to:))
    }

    private func expandingButton(_ expansion: ScanExpansion) -> some View {
        ScanButtonExpansion(
            from: expansion.buttonFrame, to: expansion.checklistFrame ?? expansion.buttonFrame,
            progress: expansion.progress)
            .transition(.identity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func startScan() {
        guard model.canScan else { return }
        let launch = reduceMotion || scanButtonFrame.isEmpty ? nil : ScanExpansion(buttonFrame: scanButtonFrame)
        expansion = launch
        Task {
            await model.scan()
            if expansion?.id == launch?.id { expansion = nil }
        }
    }

    private func expandScanButton(to frame: CGRect) {
        guard !frame.isEmpty, let current = expansion else { return }
        expansion?.checklistFrame = frame
        guard current.checklistFrame == nil else { return }
        withAnimation(.timingCurve(0.27, 0.72, 0.21, 1, duration: 0.52), completionCriteria: .logicallyComplete) {
            expansion?.progress = 1
        } completion: {
            guard expansion?.id == current.id else { return }
            expansion = nil
        }
    }

    @ViewBuilder private var results: some View {
        if case .browseCategory(let bucket) = ui.destination, let result = model.scan.lastResult {
            StorageBrowserView(
                model: model, title: Copy.Buckets.title(bucket),
                subtitle: "Browse readable files in this category, sorted by space used.",
                scope: StorageBrowseScope(category: bucket, result: result),
                openPlan: { ui.destination = .spacePlan },
                archive: { url in
                    model.archives.pick(url)
                    ui.destination = .archives
                },
                actionTitle: "Category Details") { ui.destination = .page(bucket) }
                .id(bucket)
        } else if case .page(let bucket) = ui.destination, let page = model.pages.first(where: { $0.id == bucket }) {
            CategoryPageView(model: model, ui: ui, page: page)
        } else {
            OverviewView(model: model, ui: ui)
        }
    }
}

enum ScanExpansionSpace: Hashable { case detail }

private struct ScanExpansion {
    let id = UUID()
    let buttonFrame: CGRect
    var checklistFrame: CGRect?
    var progress: CGFloat = 0
}
