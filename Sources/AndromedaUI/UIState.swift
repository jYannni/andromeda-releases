import AndromedaAppModel
import AndromedaCore
import Foundation
import Observation

/// View-level state shared by the shell and its pages. It decides nothing about files; it only
/// carries what the user pressed and what sheet is showing.
@MainActor @Observable
public final class UIState {
    public enum Destination: Hashable {
        case tools, tool(ToolPage)
        case overview, page(AppleBucket), browseCategory(AppleBucket), browseFolder, storageMap, duplicates
        case drive(String), driveCatalogs, history, cloud, moveToCloud, organizeFolder, archives, spacePlan, scanComparison, storageTrends
        case reviewFolder(URL, StorageBrowser.FolderReference?)
        case reviewInstallers(URL)
    }

    public var destination: Destination = .overview {
        didSet {
            if oldValue != destination {
                focusedRecord = nil
                spacePlanStepTitle = nil
            }
            if destination != .driveCatalogs {
                catalogDriveID = nil
                catalogSearchRequest = nil
            }
            if oldValue == .scanComparison && destination != .scanComparison {
                comparisonEarlierID = nil
                comparisonLaterID = nil
            }
        }
    }
    var focusedRecord: UUID?
    private(set) var spacePlanStepTitle: String?
    var comparisonEarlierID: UUID?
    var comparisonLaterID: UUID?
    var catalogDriveID: String?
    var catalogSearchRequest: UUID?
    public var sidebarIsCompact = false
    let folderBrowser = FolderStorageState()
    let storageMapBrowser = FolderStorageState(startInMap: true)
    /// Set when the user presses the review button; `resolveRequests` turns it into `confirm`.
    public var reviewRequested = false
    /// Set to the row's ID when the user presses "Rebuild…"; `resolveRequests` turns it into `confirm`.
    public var rebuildRequested: String?
    /// The confirm sheet's content while it is showing.
    public var confirm: ConfirmSummary?
    /// True from the moment the user confirms until they close the receipt.
    public var receiptShowing = false
    /// The receipt must belong to the confirmed batch, including before its task starts.
    var receiptRequest: (batchID: UUID, itemCount: Int, fromSpacePlan: Bool)?
    /// Set when a row's "Let Andromeda do it…" is pressed.
    public var helperSheetRequested = false
    /// Why a review couldn't start, when the model says so.
    public var problem: String?

    public init() {}

    func openSpacePlanStep(_ page: Destination, title: String, record: UUID? = nil) {
        destination = page
        focusedRecord = record
        spacePlanStepTitle = title
    }

    func returnToSpacePlan(model: AppModel) {
        destination = .spacePlan
        if model.spacePlanner.initialFree != nil {
            Task { await model.spacePlanner.checkFreeSpace() }
        }
    }

    func focusCatalogSearch() {
        destination = .driveCatalogs
        catalogSearchRequest = UUID()
    }

    func requestReview() { reviewRequested = true }
    func requestRebuild(_ rowID: String) { rebuildRequested = rowID }
    func requestHelperSheet() { helperSheetRequested = true }

    /// **Organize these** on a large-item row: open Move to cloud with that item ticked.
    public func organizeThese(_ url: URL, model: AppModel) {
        let measuredBytes = model.scan.lastResult?.largeItems.first { $0.url == url }?.bytes
        model.moveToCloud.preselect(url, measuredBytes: measuredBytes)
        destination = .moveToCloud
    }

    /// **Organize these** on a drive page's large item: open Organize a folder and plan that folder (a file's or
    /// a package's own folder), since Move to cloud only lists the home folder.
    public func organizeOnDrive(_ url: URL, model: AppModel) {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let folder = isFolder && !SafetyGuard.isPackage(url) ? url : url.deletingLastPathComponent()
        destination = .organizeFolder
        Task { await model.folderOrganize.pick(folderAt: folder) }
    }

    /// Turns the pending review or rebuild request into a confirm summary (or `problem`), then clears it.
    public func resolveRequests(removal: RemovalFlow) {
        var asked = false
        var summary: ConfirmSummary?
        if reviewRequested {
            reviewRequested = false
            asked = true
            summary = removal.prepareConfirm()
        }
        if let id = rebuildRequested {
            rebuildRequested = nil
            asked = true
            summary = removal.prepareConfirm(betterActionFor: id)
        }
        guard asked else { return }
        confirm = summary
        problem = summary == nil ? removal.actionProblem : nil
    }

    /// The user confirmed: close the sheet and start the receipt view. Returns the summary to run.
    func takeConfirmed() -> ConfirmSummary? {
        guard let summary = confirm else { return nil }
        confirm = nil
        receiptRequest = (summary.plan.batchID, summary.plan.removals.count, destination == .spacePlan)
        receiptShowing = true
        return summary
    }
}
