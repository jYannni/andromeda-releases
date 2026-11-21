import AndromedaAppModel
import SwiftUI

/// What the window's detail pane shows for the current destination and scan state.
struct DetailView: View {
    let model: AppModel
    let ui: UIState

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
        } else if model.isPreparingScan {
            ScanningView(stage: .checkingAccess, stages: model.scan.stages)
        } else {
            switch model.scan.state {
            case .scanning(let stage):
                ScanningView(
                    stage: stage, stages: model.scan.stages, progress: model.scan.progress,
                    startedAt: model.scan.startedAt, isCancelling: model.scan.isCancelling,
                    onCancel: { model.scan.cancel() })
            case .idle:
                ScanPromptView(
                    title: UICopy.readyTitle, message: UICopy.readyBody, button: UICopy.scan,
                    disabled: !model.canScan) { Task { await model.scan() } }
            case .failed:
                ScanPromptView(
                    title: UICopy.failedTitle, message: model.scanFailedText ?? "", button: UICopy.tryAgain,
                    disabled: !model.canScan) { Task { await model.scan() } }
            case .done: results
            }
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
