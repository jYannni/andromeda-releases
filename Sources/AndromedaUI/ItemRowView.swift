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
    /// "Probably counted as <bucket>", shown on Overview cleanup suggestions.
    var bucketTag: String?
    var showsVerdictBadge = true
    var showsSelection = true
    @State private var showsOllamaModels = false

    var body: some View {
        let simulators = SimulatorInventory.Group(rawValue: row.id)
        HStack(alignment: .top, spacing: 12) {
            if row.selectable && showsSelection {
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
                    if showsVerdictBadge && simulators == nil {
                        VerdictBadge(label: row.verdictLabel, kind: row.verdictKind)
                    }
                    if let bucketTag { Text(bucketTag).font(.caption).foregroundStyle(.tertiary) }
                    if let details = removalDetails {
                        RemovalDetailsButton(title: row.title, afterwards: details.afterwards, howRemoved: details.howRemoved)
                    }
                }
                Text(row.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let simulators {
                    SimulatorInventoryView(model: model, ui: ui, group: simulators)
                } else {
                    if let text = row.notVerifiedNote { note(text) }
                    if let text = row.toolMissingNote { note(text) }
                    actions
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(row.sizeText).font(.title3.weight(.semibold)).monospacedDigit()
                if simulators == .runtimes || simulators == .systemRuntimes {
                    Text("On-disk scan").font(.caption).foregroundStyle(.secondary)
                }
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

    private var removalDetails: (afterwards: String, howRemoved: String)? {
        switch SimulatorInventory.Group(rawValue: row.id) {
        case .devices:
            return ("The selected simulators and their installed apps and data are deleted.",
                    "Andromeda asks Xcode to delete each selected device.")
        case .runtimes, .systemRuntimes:
            return ("Simulators that depend on a removed runtime become unavailable.",
                    "Andromeda asks Xcode to remove the selected registered runtimes.")
        case nil:
            guard row.verdictKind != .reportOnly else { return nil }
            return (row.afterwards, row.howRemoved)
        }
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


private struct RemovalDetailsButton: View {
    let title: String
    let afterwards: String
    let howRemoved: String

    @State private var showingDetails = false

    var body: some View {
        Button { showingDetails.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Removal details for \(title)")
        .help("\(UICopy.afterwardsLabel)\n\(afterwards)\n\n\(UICopy.howRemovedLabel)\n\(howRemoved)")
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 10) {
                detail(UICopy.afterwardsLabel, value: afterwards)
                detail(UICopy.howRemovedLabel, value: howRemoved)
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }

    private func detail(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.callout.weight(.semibold))
            Text(value).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
