import AndromedaAppModel
import AndromedaCore
import SwiftUI

struct VerdictBadge: View {
    let label: String
    let kind: VerdictKind

    private var tint: Color {
        switch kind {
        case .safe: .green
        case .withCare: .orange
        case .leaveIt: .purple
        case .cantRemove, .reportOnly: .gray
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// One finding. A checkbox only when the row is selectable; there is no per-row Remove (R4).
struct ItemRowView: View {
    let model: AppModel
    let ui: UIState
    let row: ItemRow
    /// "Probably counted as <bucket>", shown on Overview quick wins.
    var bucketTag: String?
    @State private var showsOllamaModels = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if row.selectable {
                Toggle(row.title, isOn: Binding(
                    get: { model.removal.selected.contains(row.id) },
                    set: { _ in model.removal.toggle(row.id) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(!model.removal.canEditSelection)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title).font(.body.weight(.semibold))
                    VerdictBadge(label: row.verdictLabel, kind: row.verdictKind)
                    if let bucketTag { Text(bucketTag).font(.caption).foregroundStyle(.tertiary) }
                }
                Text(row.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if row.verdictKind != .reportOnly {
                    VStack(alignment: .leading, spacing: 3) {
                        fact(UICopy.afterwardsLabel, row.afterwards, symbol: "arrow.turn.down.right")
                        fact(UICopy.howRemovedLabel, row.howRemoved, symbol: "hand.raised")
                    }
                }
                if let text = row.notVerifiedNote { note(text) }
                if let text = row.toolMissingNote { note(text) }
                actions
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(row.sizeText).font(.title3.weight(.semibold)).monospacedDigit()
                if let frees = row.freesText { Text(frees).font(.caption).foregroundStyle(.secondary) }
                if let note = row.commandSizeNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                if let shared = row.sharedNote { Text(shared).font(.caption).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 170, alignment: .trailing)
        }
        .groupRow()
        .sheet(isPresented: $showsOllamaModels) {
            OllamaModelsSheet(home: model.scanHome)
        }
    }

    private func fact(_ label: String, _ value: String, symbol: String) -> some View {
        Label {
            (Text(label + "  ").foregroundStyle(.secondary) + Text(value)).font(.callout)
        } icon: {
            Image(systemName: symbol).font(.caption).foregroundStyle(.tertiary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
    }

    @ViewBuilder private var actions: some View {
        switch row.betterAction {
        case .restart, .none: EmptyView()
        default: HStack(spacing: 8) { betterAction }.controlSize(.small).padding(.top, 2)
        }
    }

    @ViewBuilder private var betterAction: some View {
        switch row.betterAction {
        case .copyCommand(let command):
            Button(UICopy.copyCommand) { model.copyCommand(command) }
            if row.helperCanDoThis { Button(UICopy.letAndromedaDoIt) { ui.requestHelperSheet() } }
        case .handoff(_, let url):
            if row.id == "ollama-model-store" {
                Button("View Models…") { showsOllamaModels = true }
            }
            if url != nil { Button(UICopy.open) { model.open(handoff: row.betterAction) } }
        case .privileged:
            Button(UICopy.rebuild) { ui.requestRebuild(row.id) }
                .disabled(!model.removal.canEditSelection)
        case .restart, .none:
            EmptyView()
        }
    }
}
