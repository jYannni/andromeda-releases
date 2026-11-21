import AndromedaAppModel
import SwiftUI

/// §4.1 step 3: every move with its size and from → to, what is left alone, the warnings, then the
/// confirm button. Cancel is the default action; the confirm button has no shortcut. Export saves
/// the plan without applying it.
struct OrganizeConfirmSheet: View {
    let review: OrganizeReview
    /// While the plan is being applied: no Cancel, no export, a progress line instead of the buttons.
    var isApplying = false
    /// "Moving N of M" while applying; nil shows the plain progress line.
    var progress: OrganizeProgress? = nil
    let onCancel: () -> Void
    let onExport: (_ json: Bool) -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: review.title, subtitle: Copy.Organize.reviewSubtitle, symbol: "arrow.right.doc.on.clipboard")
            ScrollView { LazyVStack(alignment: .leading, spacing: 8) {
                LazyInsetList(items: review.rows) { row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.body.weight(.semibold))
                            Text(row.fromTo).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Text(row.sizeText).font(.body.weight(.semibold)).monospacedDigit()
                    }
                    .groupRow()
                }
                if !review.leftAlone.isEmpty {
                    Text(Copy.Organize.leftAloneHeading).font(.subheadline.weight(.semibold)).padding(.top, 4)
                    ForEach(Array(review.leftAlone.enumerated()), id: \.offset) { _, left in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(left.name).font(.body.weight(.medium))
                            Text(left.reason).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            } }
            .frame(maxHeight: ConfirmSheet.listCap)
            ForEach(review.warnings, id: \.self) { Banner(text: $0, symbol: "exclamationmark.triangle.fill", tint: .orange) }
            Divider()
            if isApplying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress.map { Copy.Organize.moving($0.done, of: $0.total) } ?? Copy.Organize.applying)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                buttons
            }
        }
        .padding(24)
        .frame(minWidth: 560)
        .background(Palette.canvas)
        .interactiveDismissDisabled(isApplying)
    }

    private var buttons: some View {
        HStack {
            Menu(Copy.Organize.exportPlan) {
                Button(Copy.Organize.exportText) { onExport(false) }
                Button(Copy.Organize.exportJSON) { onExport(true) }
            }
            .fixedSize()
            Spacer()
            Button(UICopy.cancel, action: onCancel).keyboardShortcut(.defaultAction)
            Button(review.confirmTitle, action: onConfirm).disabled(!review.canConfirm)
        }
    }
}

/// After a run: what happened to each item. Undo lives in History.
struct OrganizeReceiptView: View {
    let receipt: OrganizeReceipt
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: receipt.headline, subtitle: receipt.note, symbol: "checkmark", tint: .green)
            ScrollView {
                LazyInsetList(items: receipt.rows) { row in OutcomeRowView(row: row, canAct: false) { _ in } }
            }
            .frame(maxHeight: ConfirmSheet.listCap)
            if let note = receipt.stoppedNote { Text(note).font(.callout).foregroundStyle(.orange) }
            Divider()
            HStack {
                Spacer()
                Button(UICopy.done, action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520)
        .background(Palette.canvas)
    }
}
