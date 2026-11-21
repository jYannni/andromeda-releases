import AndromedaAppModel
import AndromedaCore
import SwiftUI

/// What the receipt sheet shows: progress while the removal runs, then the receipt. Never "N GB freed" (R4).
struct ReceiptView: View {
    let model: AppModel
    let ui: UIState
    @State private var pendingDelete: PermanentDeleteConfirm?
    @State private var problem: String?

    private var removal: RemovalFlow { model.removal }
    private var doneTitle: String { ui.receiptRequest?.fromSpacePlan == true ? "Back to Space Plan" : UICopy.done }

    private func closeReceipt() {
        ui.receiptShowing = false
        if ui.receiptRequest?.fromSpacePlan == true { ui.returnToSpacePlan(model: model) }
    }

    private var isPreparing: Bool {
        guard let request = ui.receiptRequest else { return false }
        return removal.receipt?.batchID != request.batchID
    }

    var body: some View {
        Group {
            if removal.isExecuting || isPreparing {
                ProgressPanel(done: removal.progress?.done ?? 0,
                              total: removal.progress?.total ?? ui.receiptRequest?.itemCount ?? 0)
            } else if let receipt = removal.receipt {
                ReceiptBody(
                    receipt: receipt, problem: problem ?? removal.actionProblem, canAct: !removal.isExecuting,
                    onPutBack: { id in
                        Task {
                            problem = nil
                            do {
                                try await removal.restore(id)
                            } catch RestoreError.volumeNotConnected {
                                problem = Copy.History.restoreReconnect
                            } catch {
                                problem = Copy.History.restoreFailed
                            }
                        }
                    },
                    onDelete: { pendingDelete = removal.permanentDeleteConfirm() },
                    doneTitle: doneTitle, onDone: closeReceipt)
            } else {
                VStack(spacing: 12) {
                    Text(UICopy.nothingRemoved)
                    Button(doneTitle, action: closeReceipt).keyboardShortcut(.defaultAction)
                }
                .padding(24)
            }
        }
        .frame(minWidth: 520)
        .interactiveDismissDisabled(removal.isExecuting || isPreparing)
        .permanentDeleteAlert($pendingDelete) { Task { await removal.deletePermanently() } }
    }
}

struct ProgressPanel: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: UICopy.removing, symbol: "trash.fill", tint: .secondary)
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            Text(UICopy.progress(done: done, total: total)).font(.callout).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(Palette.canvas)
    }
}

struct ReceiptBody: View {
    let receipt: ReceiptSummary
    let problem: String?
    let canAct: Bool
    let onPutBack: (UUID) -> Void
    let onDelete: () -> Void
    var doneTitle = UICopy.done
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: receipt.headline, subtitle: receipt.inTrashText, symbol: "checkmark", tint: .green)
            if !receipt.measurements.isEmpty {
                CleanupSpaceReadingsView(measurements: receipt.measurements).card(padding: 12)
            } else if receipt.inTrashText != nil {
                Text("A free-space reading is unavailable for this run.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyInsetList(items: receipt.rows) { row in
                    OutcomeRowView(row: row, canAct: canAct, onPutBack: onPutBack)
                }
            }
            .frame(maxHeight: ConfirmSheet.listCap)
            .fixedSize(horizontal: false, vertical: true)
            if let note = receipt.commandsNote { Text(note).font(.callout).foregroundStyle(.secondary) }
            if let note = receipt.stoppedNote { Text(note).font(.callout).foregroundStyle(.orange) }
            if let problem { Text(problem).font(.callout).foregroundStyle(.orange) }
            Divider()
            HStack {
                if receipt.canDeletePermanently {
                    Button(UICopy.deletePermanently, action: onDelete).disabled(!canAct)
                }
                Spacer()
                Button(doneTitle, action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .background(Palette.canvas)
    }
}

struct CleanupSpaceReadingsView: View {
    let measurements: [CleanupSpaceMeasurement]
    var showsDates = false

    var body: some View {
        if !measurements.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(measurements.enumerated()), id: \.offset) { _, reading in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reading.operation == .cleanup ? "Startup disk free space after cleanup"
                             : "Startup disk free space after permanent deletion")
                            .font(.callout.weight(.medium))
                        Text("\(ByteFormat.string(reading.before)) → \(ByteFormat.string(reading.after)) · \(changeText(reading.change))")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        if showsDates {
                            Text(reading.measuredAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Other disk activity can affect these readings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func changeText(_ change: Int64) -> String {
        if change == 0 { return "No measured change" }
        if change > 0 { return "\(ByteFormat.string(change)) more free" }
        return "\(ByteFormat.string(-change)) less free"
    }
}
