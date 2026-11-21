import AndromedaAppModel
import SwiftUI

/// The opt-in explainer (spec 8.1). Nothing is registered until the user presses the action button.
struct HelperSheet: View {
    let helper: HelperModel
    let onDismiss: () -> Void
    @State private var working = false

    var body: some View {
        HelperSheetContent(
            state: helper.state, note: helper.sheetNote, working: working || !helper.canChangeHelper, onAction: { action in
            Task {
                working = true
                await helper.perform(action)
                working = false
            }
        }, onDismiss: onDismiss)
    }
}

struct HelperSheetContent: View {
    let state: HelperState
    /// The model's note under the explainer; defaults to the state's own.
    var note: String??
    let working: Bool
    let onAction: (HelperAction) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: Copy.Helper.title, symbol: "lock.shield.fill", tint: .gray)
            Text(Copy.Helper.explainer).fixedSize(horizontal: false, vertical: true)
            if let note = note ?? state.sheetNote { Text(note).font(.callout).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Spacer()
                Button(state.dismissTitle, action: onDismiss).keyboardShortcut(.cancelAction)
                if let action = state.action {
                    Button(action.sheetTitle) { onAction(action) }
                        .buttonStyle(.borderedProminent).disabled(working)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480)
        .background(Palette.canvas)
    }
}
