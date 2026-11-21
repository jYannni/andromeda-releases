import AndromedaAppModel
import AndromedaCore
import SwiftUI

struct SpaceBreakdownView: View {
    let model: AppModel
    let title: String
    let breakdown: SpaceBreakdown

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                if breakdown.unexplainedBytes > 0 {
                    evidence(
                        "Unattributed remainder", value: ByteFormat.string(breakdown.unexplainedBytes),
                        detail: "The gap between disk usage and the space Andromeda could attribute. Its exact contents are unknown.")
                }
                if let detail = breakdown.overcountDetail {
                    Text(detail).foregroundStyle(.secondary)
                }
                if !breakdown.sharedAllocationLocations.isEmpty {
                    DisclosureGroup {
                        ScrollablePathList(paths: breakdown.sharedAllocationLocations).padding(.top, 4)
                    } label: {
                        evidence(
                            "Locations with shared APFS data",
                            value: breakdown.sharedAllocationLocations.count.formatted(),
                            detail: "These locations contain files that share storage. Their full sizes may overlap.")
                    }
                }
                if !breakdown.unreadablePaths.isEmpty {
                    DisclosureGroup {
                        ScrollablePathList(paths: breakdown.unreadablePaths).padding(.top, 4)
                    } label: {
                        evidence(
                            "Locations Andromeda couldn’t read",
                            value: breakdown.unreadablePaths.count.formatted(),
                            detail: "Their size is unknown. Expand to see the paths.")
                    }
                }
                if let snapshots = breakdown.snapshots, !snapshots.isEmpty {
                    DisclosureGroup {
                        ForEach(Array(snapshots.enumerated()), id: \.offset) { _, snapshot in
                            Text(snapshot.name).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } label: {
                        evidence("APFS snapshots", value: snapshotValue, detail: snapshotDetail)
                    }
                } else {
                    evidence("APFS snapshots", value: snapshotValue, detail: snapshotDetail)
                }
                evidence("Purgeable space", value: purgeableValue, detail: purgeableDetail)
                ForEach(Array(breakdown.otherVolumes.enumerated()), id: \.offset) { _, volume in
                    evidence(
                        volume.name.isEmpty ? "Other APFS volume" : volume.name,
                        value: ByteFormat.string(volume.used),
                        detail: "macOS reports this volume’s usage separately. The figure can overlap with the unattributed remainder.")
                }
                ForEach(breakdown.notes, id: \.self) { Text($0).foregroundStyle(.secondary) }
                if breakdown.fullDiskAccess != .granted {
                    Text("Allow Full Disk Access, reopen Andromeda, then scan again to check protected folders.")
                        .foregroundStyle(.secondary)
                    if let steps = model.access.fallbackSteps {
                        Text(steps).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if breakdown.fullDiskAccess != .granted {
                        Button("Open Full Disk Access") { model.access.openSettings() }
                    }
                    Button("Scan Again") { Task { await model.scan() } }
                        .disabled(!model.canScan)
                }
            }
            .font(.callout)
            .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(breakdown.fullDiskAccess == .granted ? "Scan coverage and disk details" : "Scan coverage · Limited access")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var snapshotValue: String {
        breakdown.snapshots.map { $0.count.formatted() } ?? "Unavailable"
    }

    private var snapshotDetail: String {
        guard let snapshots = breakdown.snapshots else {
            return "macOS didn’t return a snapshot list. Scan again to retry."
        }
        guard !snapshots.isEmpty else { return "macOS reported no snapshots in this check." }
        let counts = [
            (LocalSnapshot.Kind.timeMachine, "Time Machine"),
            (.osUpdate, "macOS update"),
            (.other, "other"),
        ].compactMap { kind, name -> String? in
            let count = snapshots.count(where: { $0.kind == kind })
            return count == 0 ? nil : "\(count) \(name)"
        }
        return counts.joined(separator: ", ") + ". macOS didn’t report how much space these snapshots hold."
    }

    private var purgeableValue: String {
        if case .bytes(let bytes) = breakdown.purgeable { return ByteFormat.string(bytes) }
        return "Unavailable"
    }

    private var purgeableDetail: String {
        if case .bytes = breakdown.purgeable {
            return "macOS estimates what it can free on its own. Overview already excludes this estimate from used space."
        }
        return "macOS didn’t provide a usable estimate for this scan."
    }

    private func evidence(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(value).monospacedDigit()
            }
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
