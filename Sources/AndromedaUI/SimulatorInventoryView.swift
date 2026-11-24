import AndromedaAppModel
import AndromedaCore
import SwiftUI

struct SimulatorInventoryView: View {
    let model: AppModel
    let ui: UIState
    let group: SimulatorInventory.Group

    @State private var expanded = false
    @State private var inventory: SimulatorInventory?
    @State private var selected: Set<String> = []

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                entries
                    .padding(.top, 6)
                    .task(id: model.scan.lastResult?.finishedAt) {
                        inventory = nil
                        selected = []
                        let reading = await model.removal.loadSimulators(group)
                        if !Task.isCancelled { inventory = reading }
                    }
            }
        } label: {
            Text(label).font(.callout.weight(.medium))
        }
    }

    private var label: String {
        switch group {
        case .devices: "Installed Simulator Devices"
        case .runtimes: "Installed Runtimes"
        case .systemRuntimes: "Runtimes in System Assets"
        }
    }

    @ViewBuilder private var entries: some View {
        if let inventory {
            let rows = inventory[group]
            let lookupFailed = group == .devices ? !inventory.devicesAvailable : !inventory.runtimeImagesAvailable
            VStack(alignment: .leading, spacing: 8) {
                if lookupFailed {
                    message("Xcode’s simulator inventory could not be fully read. Check that Xcode is installed and selected.")
                } else if rows.isEmpty {
                    message(group == .devices ? "Xcode reports no simulator devices." : "Xcode reports no runtimes here.")
                }
                if !rows.isEmpty {
                    if group == .devices {
                        message("\(rows.count) \(rows.count == 1 ? "simulator" : "simulators") in Xcode’s device set")
                    }
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if row.canRemove {
                                Toggle(row.name, isOn: Binding(
                                    get: { selected.contains(row.id) },
                                    set: { if $0 { selected.insert(row.id) } else { selected.remove(row.id) } }))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .accessibilityLabel("\(row.name), \(row.detail)")
                                    .disabled(!canEdit)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).font(.callout.weight(.medium))
                                message(row.detail)
                                if !row.canRemove { message("Manage in Xcode Settings › Components") }
                            }
                            Spacer(minLength: 8)
                            if let bytes = row.systemAssetBytes ?? row.bytes, bytes > 0 {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(ByteFormat.string(bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    if group != .devices {
                                        message(row.systemAssetBytes == nil ? "Xcode image size" : "On disk")
                                    }
                                }
                                .help(row.systemAssetBytes != nil && row.bytes != nil
                                      ? "Xcode image size: \(ByteFormat.string(row.bytes ?? 0))" : "")
                            }
                        }
                    }
                    if rows.contains(where: \.canRemove) {
                        Button("Review Selected…") {
                            if let summary = model.removal.prepareSimulatorConfirm(inventory, group: group, selected: selected) {
                                ui.confirm = summary
                            }
                        }
                        .disabled(selected.isEmpty || !canEdit)
                    }
                }
                if let bytes = inventory.unlistedSystemAssetBytes, bytes > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        message("System assets outside Xcode’s list")
                        Spacer(minLength: 8)
                        Text(ByteFormat.string(bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            ProgressView("Reading Xcode’s simulator inventory…").controlSize(.small)
        }
    }

    private var canEdit: Bool {
        model.removal.canEditSelection && model.removal.removalDisabledReason == nil
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
