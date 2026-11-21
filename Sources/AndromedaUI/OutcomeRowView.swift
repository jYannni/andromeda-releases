import AndromedaAppModel
import SwiftUI

/// One receipt or history row: the item, what happened to it, and "Put back" when it can be.
struct OutcomeRowView: View {
    let row: ReceiptRow
    let canAct: Bool
    let onPutBack: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.ok ? "checkmark.circle.fill" : "minus.circle.fill")
                .font(.title3)
                .foregroundStyle(row.ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.body.weight(.medium))
                Text(row.outcomeText).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let size = row.recordedSizeText {
                Text(size).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if let id = row.restorableEntryID {
                Button(UICopy.putBack) { onPutBack(id) }.disabled(!canAct).controlSize(.small)
                    .accessibilityLabel("\(UICopy.putBack) \(row.title)")
            }
        }
        .groupRow()
    }
}

/// The second confirm for deleting from the Trash. Cancel comes first and is the default.
struct PermanentDeleteAlert: ViewModifier {
    @Binding var pending: PermanentDeleteConfirm?
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content.alert(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
        ) {
            Button(UICopy.cancel, role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button(UICopy.deleteConfirm, role: .destructive, action: onDelete)
        } message: {
            Text(pending?.body ?? "")
        }
    }
}

extension View {
    func permanentDeleteAlert(_ pending: Binding<PermanentDeleteConfirm?>, onDelete: @escaping () -> Void) -> some View {
        modifier(PermanentDeleteAlert(pending: pending, onDelete: onDelete))
    }
}
