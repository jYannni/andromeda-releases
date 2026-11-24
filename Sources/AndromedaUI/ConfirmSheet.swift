import AndromedaAppModel
import SwiftUI

/// Spec 6.1 step 4: every item and every command, then a destructive-styled button that names the
/// amount. Cancel is the default action; the confirm button has no shortcut.
struct ConfirmSheet: View {
    let summary: ConfirmSummary
    let onCancel: () -> Void
    let onConfirm: () -> Void
    /// The row list scrolls beyond this, so the buttons are always on screen.
    static let listCap: CGFloat = 360

    var body: some View {
        let movesFiles = summary.rows.contains(where: \.reversible)
        let maintenance = summary.plan.removals.contains { $0.catalogEntryID.hasPrefix("maintenance-") }
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: movesFiles ? UICopy.confirmHeading : summary.confirmTitle,
                        subtitle: movesFiles ? UICopy.confirmSubtitle : nil,
                        symbol: maintenance ? "wrench.and.screwdriver" : "trash.fill", tint: maintenance ? .teal : .red)
            ScrollView { InsetGroup {
                ForEach(Array(summary.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.body.weight(.semibold))
                            if let location = row.location {
                                Text(location).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Text(row.howRemoved).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Text(row.sizeText).font(.body.weight(.semibold)).monospacedDigit()
                    }
                    .groupRow()
                }
            } }
            .frame(maxHeight: Self.listCap)
            if let line = summary.quitFirstLine {
                Banner(text: line, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            if summary.rows.contains(where: \.reversible) {
                Text("Items in Trash still use space. You can put them back from History while they’re there.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let note = summary.irreversibleNote { Text(note).font(.callout).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Spacer()
                Button(UICopy.cancel, action: onCancel).keyboardShortcut(.defaultAction)
                Button(summary.confirmTitle, role: .destructive, action: onConfirm)
            }
        }
        .padding(24)
        .frame(minWidth: 540)
        .background(Palette.canvas)
    }
}
