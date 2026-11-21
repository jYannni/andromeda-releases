import AndromedaAppModel
import AndromedaOrganize
import SwiftUI

/// Past runs, newest first as the model orders them. Removals: Put back per item, Delete permanently
/// per batch. Organize runs: upload status per item and **Undo this run**, behind a Cancel-default confirm.
struct HistoryView: View {
    let model: AppModel
    var focusedBatch: UUID?
    var onOpenArchives: () -> Void = {}
    private static let maximumInlineRunItems = 20
    @State private var runDetailExpansion: [UUID: Bool] = [:]
    @State private var pendingDelete: (batch: UUID, confirm: PermanentDeleteConfirm)?
    @State private var pendingUndo: HistoryBatchView?
    @State private var pendingGroupUndo: (batch: UUID, group: UndoableGroup)?
    @State private var pendingItemUndo: (batch: UUID, row: MoveHistoryRow)?

    private var history: HistoryModel { model.history }
    private var batches: [HistoryBatchView] {
        guard let focusedBatch, let batch = history.batches.first(where: { $0.id == focusedBatch }) else {
            return history.batches
        }
        return [batch] + history.batches.filter { $0.id != focusedBatch }
    }

    private var notes: [String] {
        [history.recordUnavailableNote, history.unreadableNote, history.actionProblem,
         model.organize.undoProblem]
            .compactMap { $0 }
    }

    var body: some View {
        PageColumn {
            PageHeader(title: UICopy.history, subtitle: UICopy.historySubtitle, symbol: "clock.arrow.circlepath", tint: .gray)
            ForEach(notes, id: \.self) { Banner(text: $0, symbol: "exclamationmark.triangle.fill", tint: .orange) }
            if history.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.History.loading).foregroundStyle(.secondary)
                }
            } else if history.showsEmptyState && model.archives.records.isEmpty {
                EmptyState(title: UICopy.historyEmptyTitle, symbol: "clock.arrow.circlepath", message: Copy.History.empty)
            }
            if focusedBatch == nil && !model.archives.records.isEmpty {
                HStack {
                    SectionHeading(title: "External archives")
                    Spacer()
                    Button("Open Archives", action: onOpenArchives)
                }
                LazyInsetList(items: model.archives.records) { record in
                    ArchiveRecordSummary(record: record).groupRow()
                }
            }
            ForEach(batches) { batch in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(batch.dateText).font(.headline)
                                if batch.interruptedNote != nil {
                                    Chip(text: Copy.Organize.interruptedLabel, tint: .orange)
                                }
                            }
                            Text(batch.summary).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if batch.canDeletePermanently {
                            Button(UICopy.deletePermanently) {
                                if let c = history.permanentDeleteConfirm(batch.id) { pendingDelete = (batch.id, c) }
                            }
                        }
                        if batch.canUndo {
                            Button(Copy.Organize.undoRun) { pendingUndo = batch }
                                .disabled(model.organize.isUndoing || model.organize.isApplying)
                        }
                    }
                    CleanupSpaceReadingsView(measurements: batch.measurements, showsDates: true)
                    if let note = batch.interruptedNote { Text(note).font(.callout).foregroundStyle(.secondary) }
                    if let note = batch.notConnectedNote { Text(note).font(.callout).foregroundStyle(.secondary) }
                    if !batch.groups.isEmpty {
                        InsetGroup {
                            ForEach(batch.groups, id: \.id) { group in
                                GroupUndoRow(group: group, disabled: model.organize.isUndoing || model.organize.isApplying) {
                                    pendingGroupUndo = (batch.id, group)
                                }
                                .groupRow()
                            }
                        }
                    }
                    batchItems(batch)
                }
                .padding(.top, 6)
            }
        }
        .task {
            await history.reload()
            await model.archives.reload()
        }
        // A load taken mid-apply shows the run as still going; reload once it has finished.
        .onChange(of: model.organize.applyingBatchID) { _, now in
            if now == nil { Task { await history.reload() } }
        }
        .onChange(of: focusedBatch) { _, now in
            if let now { runDetailExpansion.removeValue(forKey: now) }
        }
        .permanentDeleteAlert(
            Binding(get: { pendingDelete?.confirm }, set: { if $0 == nil { pendingDelete = nil } })
        ) {
            if let batch = pendingDelete?.batch { Task { await history.deletePermanently(batch) } }
        }
        .alert(
            Copy.Organize.undoConfirmTitle,
            isPresented: Binding(get: { pendingUndo != nil }, set: { if !$0 { pendingUndo = nil } })
        ) {
            Button(UICopy.cancel, role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button(Copy.Organize.undoConfirm) {
                if let batch = pendingUndo { Task { await model.undo(batchID: batch.id) } }
            }
        } message: {
            Text(pendingUndo?.containsCopies == true
                 ? "Andromeda moves unchanged copies from this run to Trash. Source files and edited copies stay in place."
                 : Copy.Organize.undoConfirmBody)
        }
        .alert(
            Copy.Organize.undoGroupConfirmTitle(pendingGroupUndo?.group.folderName ?? ""),
            isPresented: Binding(get: { pendingGroupUndo != nil }, set: { if !$0 { pendingGroupUndo = nil } })
        ) {
            Button(UICopy.cancel, role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button(Copy.Organize.undoConfirm) {
                if let p = pendingGroupUndo { Task { await model.undo(batchID: p.batch, groupID: p.group.id) } }
            }
        } message: {
            Text(Copy.Organize.undoGroupConfirmBody)
        }
        .alert(
            pendingItemUndo?.row.title ?? "Undo item",
            isPresented: Binding(get: { pendingItemUndo != nil }, set: { if !$0 { pendingItemUndo = nil } })
        ) {
            Button(UICopy.cancel, role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button(pendingItemUndo?.row.undoAction ?? "Undo item") {
                if let item = pendingItemUndo {
                    Task { await model.undo(batchID: item.batch, entryID: item.row.id) }
                }
            }
        } message: {
            Text(pendingItemUndo?.row.undoNote ?? (pendingItemUndo?.row.undoAction == "Remove copy"
                 ? "Andromeda moves the unchanged copy to Trash and keeps the original."
                 : "Andromeda will put only this item back in its original location."))
        }
    }

    @ViewBuilder private func batchItems(_ batch: HistoryBatchView) -> some View {
        if batch.rows.isEmpty, batch.moves.count > Self.maximumInlineRunItems {
            let expanded = Binding(
                get: { runDetailExpansion[batch.id] ?? (focusedBatch == batch.id) },
                set: { runDetailExpansion[batch.id] = $0 })
            let count = batch.moves.count.formatted()
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    Label(expanded.wrappedValue ? "Hide \(count) run items" : "Show \(count) run items",
                          systemImage: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("history-run-items-\(batch.id.uuidString)")
                if expanded.wrappedValue {
                    itemRows(batch)
                }
            }
        } else if !batch.rows.isEmpty || !batch.moves.isEmpty {
            itemRows(batch)
        }
    }

    private func itemRows(_ batch: HistoryBatchView) -> some View {
        InsetGroup {
            ForEach(Array(batch.rows.enumerated()), id: \.offset) { _, row in
                OutcomeRowView(row: row, canAct: true) { id in Task { await history.restore(id) } }
            }
            ForEach(batch.moves) { row in
                MoveHistoryRowView(row: row, reveal: model.reveal,
                                   canUndo: batch.canUndo && !model.organize.isUndoing && !model.organize.isApplying) {
                    pendingItemUndo = (batch.id, row)
                }
            }
        }
    }
}

/// One item of an organize or move-to-cloud run: where it is, what undo would do, and any undo problem.
private struct MoveHistoryRowView: View {
    let row: MoveHistoryRow
    let reveal: (URL) -> Void
    let canUndo: Bool
    let undo: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.ok ? "checkmark.circle.fill" : "minus.circle.fill")
                .font(.title3)
                .foregroundStyle(row.ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.body.weight(.medium))
                Text(row.outcomeText).font(.callout).foregroundStyle(.secondary)
                if let tag = row.sharedTag { Text(tag).font(.caption).foregroundStyle(.secondary) }
                if let handOff = row.handOff { Text(handOff).font(.callout) }
                if let url = row.handOffURL {
                    Button(UICopy.showInFinder) { reveal(url) }
                        .accessibilityLabel("Show \(row.title) in Finder")
                }
                if let note = row.undoNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                if let problem = row.undoProblem { Text(problem).font(.callout).foregroundStyle(.orange) }
            }
            Spacer(minLength: 12)
            if let size = row.recordedSizeText {
                Text(size).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if let action = row.undoAction, canUndo {
                Button(action, action: undo)
                    .accessibilityLabel("\(action) \(row.title)")
            }
        }
        .groupRow()
    }
}
