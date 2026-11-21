import AppKit
import AndromedaAppModel
import AndromedaCore
import AndromedaOrganize
import SwiftUI

/// Organize › Organize a folder (§6.1, boards 07–09). Pick Downloads, Desktop, a drive or any folder; the plan is
/// a before/after pair: left, the folder as it is now with a tick per move; right, the proposed tree
/// with counts and the Unsorted bucket. **Apply plan** opens a summary sheet whose default is Cancel.
/// After the run: "<folder> is organized" and **Undo this run**.
struct OrganizeFolderView: View {
    let model: AppModel
    let ui: UIState
    @State private var summaryShowing = false
    @State private var handOffShowing = false
    @State private var undoAsked = false
    @State private var undoGroupAsked: UndoableGroup?
    /// Why a loose row's Move to… didn't happen, by row id.
    @State private var moveProblems: [UUID: String] = [:]

    private var folder: FolderOrganizeModel { model.folderOrganize }
    private var flow: OrganizeFlow { model.organize }
    private static let cloudSyncNote = "Moves in this cloud folder can sync to your other devices. Check your provider for sync status."

    var body: some View {
        // The receipt replaces a plan that may be scrolled far down: it starts at the top (T11 F3).
        PageColumn(scrollsToTopOn: flow.receipt?.batchID) {
            PageHeader(
                title: model.englishSpelling.wording(Copy.Organize.organizeFolderTitle),
                subtitle: model.englishSpelling.wording(Copy.Organize.organizeFolderSubtitle),
                symbol: "folder.badge.gearshape", tint: .indigo
            ) {
                if let review = folder.review, review.canConfirm, flow.receipt?.folderName == nil {
                    Button { summaryShowing = true } label: { Text(Copy.Organize.applyPlan).frame(minWidth: 90) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(flow.isApplying || folder.isPlanning)
                }
            }
            picker
            if folder.isOrganisingCloudFolder {
                Banner(text: Self.cloudSyncNote, symbol: "icloud", tint: .secondary)
            }
            if let problem = flow.applyProblem {
                Banner(text: problem, symbol: "externaldrive.badge.xmark", tint: .orange)
            }
            if folder.isPlanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.Organize.planning).foregroundStyle(.secondary)
                }
            } else if let receipt = flow.receipt, receipt.folderName != nil {
                FolderReceiptView(
                    receipt: receipt, spelling: model.englishSpelling,
                    isUndoing: flow.isUndoing, isApplying: flow.isApplying, progress: flow.progress,
                    undoProblem: flow.undoProblem,
                    disconnectedNote: folder.receiptDisconnectedNote,
                    canHandOff: folder.receiptDisconnectedNote == nil && model.moveToCloud.handOffAvailable,
                    onHandOff: { handOffShowing = true },
                    onUndo: { undoAsked = true }, onUndoGroup: { undoGroupAsked = $0 }, onDone: { flow.closeReceipt() })
            } else if let review = folder.review {
                if let reason = folder.refusedReason {
                    Banner(text: reason, symbol: "hand.raised.fill", tint: .secondary)
                } else if review.rows.isEmpty && review.unsorted.isEmpty {
                    Banner(text: model.englishSpelling.wording(Copy.Organize.nothingToOrganize),
                           symbol: "checkmark.circle.fill", tint: .green)
                } else {
                    planView(review)
                }
                // A refused folder has no plan to tune.
                if folder.refusedReason == nil {
                    if folder.canSortRestByKind { sorting }
                    naming
                }
            } else {
                EmptyState(title: model.englishSpelling.wording(UICopy.organizeEmptyTitle),
                           symbol: "folder.badge.questionmark", message: model.englishSpelling.wording(UICopy.organizeEmptyBody))
            }
        }
        .sheet(isPresented: $summaryShowing) {
            if let review = folder.review {
                FolderApplySheet(
                    review: review, summary: flow.folderSummary, isApplying: flow.isApplying, progress: flow.progress,
                    onCancel: { summaryShowing = false },
                    onExport: { json in Task { _ = await flow.exportPlan(json: json) } },
                    onApply: { [planID = review.plan.planID] in
                        Task { _ = await flow.apply(planID: planID); summaryShowing = false }
                    })
            }
        }
        // Names only: whether a cloud folder exists decides if the receipt offers the hand-off.
        .task(id: flow.receipt?.batchID) { model.refreshOrganizeRoots() }
        .sheet(isPresented: $handOffShowing) {
            CloudHandOffView(model: model) { handOffShowing = false }
        }
        // The hand-off's review is Move to cloud's own: the same confirm sheet (default Cancel) and receipt.
        .sheet(isPresented: Binding(get: { flow.review != nil && flow.review?.folderName == nil }, set: { if !$0 { flow.cancel() } })) {
            if let review = flow.review, review.folderName == nil {
                OrganizeConfirmSheet(
                    review: review, isApplying: flow.isApplying, progress: flow.progress, onCancel: { flow.cancel() },
                    onExport: { json in Task { _ = await flow.exportPlan(json: json) } },
                    onConfirm: { [planID = review.plan.planID] in Task { _ = await flow.apply(planID: planID) } })
            }
        }
        .sheet(isPresented: Binding(get: { flow.receipt != nil && flow.receipt?.folderName == nil }, set: { if !$0 { flow.closeReceipt() } })) {
            if let receipt = flow.receipt, receipt.folderName == nil { OrganizeReceiptView(receipt: receipt) { flow.closeReceipt() } }
        }
        .alert(Copy.Organize.undoConfirmTitle, isPresented: $undoAsked) {
            Button(UICopy.cancel, role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button(Copy.Organize.undoConfirm) { Task { await folder.undoRun() } }
        } message: {
            Text(Copy.Organize.undoConfirmBody)
        }
        .alert(
            Copy.Organize.undoGroupConfirmTitle(undoGroupAsked?.folderName ?? ""),
            isPresented: Binding(get: { undoGroupAsked != nil }, set: { if !$0 { undoGroupAsked = nil } })
        ) {
            Button(UICopy.cancel, role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button(Copy.Organize.undoConfirm) {
                if let group = undoGroupAsked { Task { await folder.undoGroup(id: group.id) } }
            }
        } message: {
            Text(Copy.Organize.undoGroupConfirmBody)
        }
    }

    private var picker: some View {
        HStack(spacing: 10) {
            sourceButton(Copy.Organize.downloads, symbol: "arrow.down.circle.fill", place: .downloads)
            sourceButton(Copy.Organize.desktop, symbol: "menubar.dock.rectangle", place: .desktop)
            // One per drive Organize may work on (`url(for:)` nil for read-only, Time Machine, or home's own volume).
            ForEach(model.drives.volumes.filter { folder.url(for: .drive($0.id)) != nil }) { drive in
                sourceButton(drive.name, symbol: "externaldrive.fill", place: .drive(drive.id),
                             icon: NSWorkspace.shared.icon(forFile: drive.url.path))
            }
            sourceButton(Copy.Organize.chooseFolder, symbol: "folder.fill", place: .chosen)
            if folder.place == .chosen, let name = folder.folder?.lastPathComponent {
                Label(name, systemImage: "folder").font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .disabled(folder.isPlanning || flow.isApplying)
    }

    /// The source on screen is drawn selected; the others stay plain buttons.
    @ViewBuilder
    private func sourceButton(
        _ title: String, symbol: String, place: FolderOrganizeModel.Place, icon: NSImage? = nil
    ) -> some View {
        let selected = folder.place == place
        let button = Button { Task { await folder.pick(place) } } label: {
            Label {
                Text(title)
            } icon: {
                // A drive shows its Finder icon, as its sidebar row does.
                if let icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) } else { Image(systemName: symbol) }
            }
            .padding(.horizontal, 4)
        }
        .controlSize(.large)
        .accessibilityAddTraits(selected ? .isSelected : [])
        if selected { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }

    private func planView(_ review: OrganizeReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SummaryBadges(summary: flow.folderSummary)
            if folder.isTopLevel {
                Text(folder.isOnDrive ? Copy.Drives.topLevelGroupsOnly : Copy.Organize.homeGroupsOnly)
                    .font(.callout).foregroundStyle(.secondary)
            }
            OrganizeGroupsSection(review: review, folder: folder, flow: flow)
            HStack(alignment: .top, spacing: 16) {
                // Lazy: a big Downloads has thousands of rows (built as they scroll into view).
                LazyVStack(alignment: .leading, spacing: 10) {
                    Label(Copy.Organize.nowHeading + " · " + review.title, systemImage: "tray.full").font(.headline)
                        .padding(.bottom, 2)
                    ForEach(review.rows.filter { $0.groupID == nil }) { row in
                        FolderMoveRow(row: row, problem: moveProblems[row.id], onToggle: { flow.toggle(stepID: row.id) },
                                      onStorage: { ui.destination = .overview },
                                      onMoveTo: {
                                          Task { moveProblems[row.id] = await MoveToPanel.move(rowID: row.id, folder: folder) }
                                      })
                            .disabled(folder.isPlanning || flow.isApplying)
                    }
                    ForEach(Array(review.unsorted.enumerated()), id: \.offset) { _, left in
                        LeftRow(row: left)
                    }
                    ForEach(Array(review.leftAlone.enumerated()), id: \.offset) { _, left in
                        LeftRow(row: left)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .card()
                VStack(alignment: .leading, spacing: 10) {
                    Label(Copy.Organize.proposedHeading, systemImage: "sparkles.rectangle.stack").font(.headline)
                        .padding(.bottom, 2)
                    ForEach(review.tree, id: \.path) { node in
                        Label {
                            Text(Copy.Organize.treeFolder(node.path, count: node.count))
                        } icon: {
                            Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                    if !review.unsorted.isEmpty {
                        Label(Copy.Organize.treeFolder(Copy.Organize.unsorted, count: review.unsorted.count),
                              systemImage: "questionmark.folder")
                            .foregroundStyle(.orange)
                    }
                    if !review.leftAlone.isEmpty {
                        Text(Copy.Organize.leftAloneHeading).font(.subheadline.weight(.semibold)).padding(.top, 4)
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(review.leftAlone.enumerated()), id: \.offset) { _, left in
                                Text(left.name).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .card()
            }
        }
    }

    /// Sort the rest by kind, under its own heading (T12 F2: not a renaming option). Hidden at a top level (home, a drive root).
    private var sorting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Copy.Organize.sortingHeading).font(.headline)
            Toggle(Copy.Organize.sortRestByKind, isOn: Binding(
                get: { folder.sortRestByKind },
                set: { value in Task { await folder.setSortRestByKind(value) } }))
                .accessibilityLabel(Copy.Organize.sortRestByKind)
        }
        .toggleStyle(.checkbox)
        .disabled(folder.isPlanning || flow.isApplying)
        .card()
    }

    private var naming: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Copy.Organize.namingHeading).font(.headline)
            toggle(Copy.Organize.datePhotos, \.datePhotos)
            toggle(Copy.Organize.leaveSensible, \.leaveSensible)
            toggle(Copy.Organize.tidySuffixes, \.tidySuffixes)
            HStack(spacing: 8) {
                Toggle(Copy.Organize.readInside, isOn: .constant(false)).disabled(true)
                Chip(text: Copy.Organize.comingLater)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(folder.isPlanning || flow.isApplying)
        .card()
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<NamingOptions, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { folder.options[keyPath: key] },
            set: { value in
                var options = folder.options
                options[keyPath: key] = value
                Task { await folder.setOptions(options) }
            }))
    }
}

private struct SummaryBadges: View {
    let summary: FolderSummary

    var body: some View {
        HStack(spacing: 10) {
            StatTile(value: "\(summary.foldersToCreate)", label: Copy.Organize.foldersToCreateLabel(summary.foldersToCreate))
            StatTile(value: "\(summary.filesToMove)", label: Copy.Organize.filesToMoveLabel(summary.filesToMove))
            StatTile(value: "\(summary.filesToRename)", label: Copy.Organize.filesToRenameLabel(summary.filesToRename))
            StatTile(value: "\(summary.leftForYou)", label: Copy.Organize.leftForYouLabel,
                     tint: summary.leftForYou > 0 ? .orange : nil)
        }
    }
}

private struct FolderMoveRow: View {
    let row: OrganizeReviewRow
    var problem: String? = nil
    let onToggle: () -> Void
    let onStorage: () -> Void
    let onMoveTo: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(row.name, isOn: Binding(get: { row.ticked }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.body.weight(.medium))
                Text(row.destination + "/" + row.newName).font(.caption).foregroundStyle(.secondary)
                if row.canTrashInStorage {
                    Button(Copy.Organize.canTrashInStorage, action: onStorage)
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            }
            Spacer(minLength: 8)
            Button(Copy.Organize.moveTo, action: onMoveTo)
                .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                .accessibilityLabel(Copy.Organize.moveToLabel(row.name))
            Text(row.sizeText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .opacity(row.ticked ? 1 : 0.6)
    }
}

private struct LeftRow: View {
    let row: OrganizeLeftAloneRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name).font(.body.weight(.medium))
            Text(row.reason).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 24)
    }
}

/// Board 09: the counts, then **Apply plan**. Cancel is the default; Apply has no shortcut.
struct FolderApplySheet: View {
    let review: OrganizeReview
    let summary: FolderSummary
    var isApplying = false
    var progress: OrganizeProgress? = nil
    let onCancel: () -> Void
    let onExport: (_ json: Bool) -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: review.title, subtitle: Copy.Organize.applySubtitle, symbol: "folder.badge.gearshape", tint: .indigo)
            if review.plan.cloudOrganizeFolder != nil {
                Banner(text: "Changes can sync to your other devices. Undo puts files back and leaves new folders in place.",
                       symbol: "icloud", tint: .orange)
            }
            SummaryBadges(summary: summary)
            InsetGroup {
                ForEach(review.tree, id: \.path) { node in
                    Label {
                        Text(Copy.Organize.treeFolder(node.path, count: node.count))
                    } icon: {
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if isApplying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress.map { Copy.Organize.moving($0.done, of: $0.total) } ?? Copy.Organize.applying)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                Divider()
                HStack {
                    Menu(Copy.Organize.exportPlan) {
                        Button(Copy.Organize.exportText) { onExport(false) }
                        Button(Copy.Organize.exportJSON) { onExport(true) }
                    }
                    .fixedSize()
                    Spacer()
                    Button(UICopy.cancel, action: onCancel).keyboardShortcut(.defaultAction)
                    Button(review.confirmTitle, action: onApply).disabled(!review.canConfirm)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 560)
        .background(Palette.canvas)
        .interactiveDismissDisabled(isApplying)
    }
}

/// After a folder run: "<folder> is organized", what happened to each file, and **Undo this run**.
struct FolderReceiptView: View {
    let receipt: OrganizeReceipt
    var spelling: EnglishSpelling = .us
    var isUndoing = false
    /// Another plan (a cloud hand-off) is being applied: nothing here can undo meanwhile.
    var isApplying = false
    var progress: OrganizeProgress? = nil
    var undoProblem: String?
    var disconnectedNote: String?
    /// Show **Move some of these to the cloud…** (the run made group folders and a cloud folder exists).
    var canHandOff = false
    var onHandOff: () -> Void = {}
    let onUndo: () -> Void
    var onUndoGroup: (UndoableGroup) -> Void = { _ in }
    let onDone: () -> Void

    private var headline: String {
        guard let folder = receipt.folderName, receipt.headline == Copy.Organize.organized(folder) else {
            return receipt.headline
        }
        return "\(folder) \(spelling.wording("is organized"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The run's actions sit with its headline: a big folder's receipt is hundreds of rows long.
            HStack(alignment: .center, spacing: 12) {
                SymbolTile(symbol: "checkmark", tint: .green, size: 36)
                Text(headline).font(.title3.weight(.bold))
                Spacer(minLength: 12)
                if let undo = receipt.undoTitle, disconnectedNote == nil {
                    Button(undo, action: onUndo).disabled(isUndoing || isApplying)
                }
                if canHandOff {
                    Button(Copy.Organize.moveSomeToCloud, action: onHandOff)
                        .disabled(isUndoing || isApplying)
                        .accessibilityLabel(Copy.Organize.moveSomeToCloud)
                }
                Button(UICopy.done, action: onDone).buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            if isUndoing, let progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.Organize.puttingBack(progress.done, of: progress.total)).foregroundStyle(.secondary)
                }
            }
            if let note = receipt.stoppedNote { Banner(text: note, symbol: "exclamationmark.triangle.fill", tint: .orange) }
            if let disconnectedNote { Banner(text: disconnectedNote, symbol: "externaldrive.badge.xmark", tint: .secondary) }
            if let undoProblem { Banner(text: undoProblem, symbol: "exclamationmark.triangle.fill", tint: .orange) }
            if !receipt.groups.isEmpty {
                InsetGroup {
                    ForEach(receipt.groups, id: \.id) { group in
                        GroupUndoRow(group: group, disabled: disconnectedNote != nil || isUndoing || isApplying) {
                            onUndoGroup(group)
                        }.groupRow()
                    }
                }
            }
            LazyInsetList(items: receipt.rows) { row in OutcomeRowView(row: row, canAct: false) { _ in } }
        }
    }
}

/// One group of a run ("Nietzsche, 4 files") with **Undo this group**; the button is gone once nothing of the
/// group is still moved. Shared by the folder receipt and History.
struct GroupUndoRow: View {
    let group: UndoableGroup
    let disabled: Bool
    let onUndo: () -> Void

    var body: some View {
        HStack {
            Text(Copy.Organize.groupRow(group.folderName, files: group.moves)).font(.callout)
                .foregroundStyle(group.undone ? .secondary : .primary)
            if group.undone { Chip(text: Copy.Organize.groupUndone, tint: .green) }
            Spacer()
            if group.canUndo {
                Button(Copy.Organize.undoGroup, action: onUndo)
                    .disabled(disabled)
                    .accessibilityLabel(Copy.Organize.undoGroupLabel(group.folderName))
            }
        }
    }
}
