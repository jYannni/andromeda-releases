import AndromedaAppModel
import AndromedaCore
import AppKit
import SwiftUI

struct MaintenanceView: View {
    let model: AppModel
    let ui: UIState

    var body: some View {
        PageColumn {
            PageHeader(title: "Maintenance Tasks", subtitle: "Choose a task for the problem you’re troubleshooting.",
                       symbol: "wrench.and.screwdriver", tint: .teal) { ToolBackButton(ui: ui) }
            if let reason = model.removal.removalDisabledReason { Banner(text: reason, symbol: "lock.fill") }
            InsetGroup {
                ForEach(MaintenanceTask.allCases) { task in
                    row(task.title, detail: task.detail) {
                        if task.requiresHelper && !model.helper.isReady {
                            Button("Set Up Helper…") { ui.requestHelperSheet() }
                        } else {
                            Button("Review…") {
                                ui.confirm = model.removal.prepareMaintenance(task)
                                if ui.confirm == nil { ui.problem = "This task is unavailable. Check the helper and try again." }
                            }
                            .disabled(model.removal.isExecuting || model.removal.removalDisabledReason != nil)
                        }
                    }
                }
                row("Rebuild a Mailbox",
                    detail: "In Apple Mail, select the affected mailbox and choose Mailbox → Rebuild.") {
                    Button("Open Mail") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app")) }
                }
                row("Disk Utility First Aid",
                    detail: "Use Disk Utility if verification finds errors or your Mac reports disk problems.") {
                    Button("Open Disk Utility") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                    }
                }
                row("Purgeable Space", detail: "macOS reclaims purgeable space as it is needed. Use Space Plan to review files you can clear yourself.") {
                    Button("Open Space Plan") { ui.destination = .spacePlan }
                }
                row("Local Time Machine Snapshots", detail: "Review restore points that Time Machine keeps on the startup disk.") {
                    Button("Review Snapshots") { ui.destination = .tool(.snapshots) }
                }
            }
        }
        .task { await model.helper.refresh() }
    }

    private func row<Content: View>(_ title: String, detail: String, @ViewBuilder action: () -> Content) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action().fixedSize()
        }
        .groupRow()
    }
}

struct SnapshotToolView: View {
    let model: AppModel
    let ui: UIState

    @State private var finding: Finding?
    @State private var scanning = false
    @State private var tried = false
    @State private var refresh = 0
    @State private var selected: Set<String> = []

    private var dates: [String] {
        Array(Set(finding?.snapshots.filter { $0.kind == .timeMachine }.compactMap(\.tmutilDate) ?? [])).sorted(by: >)
    }

    var body: some View {
        PageColumn {
            PageHeader(title: "Time Machine Snapshots", subtitle: "Review local restore points kept on the startup disk.",
                       symbol: "clock.arrow.circlepath", tint: .indigo) {
                ToolBackButton(ui: ui)
                Button("Check Snapshots", systemImage: "arrow.clockwise") { refresh += 1 }
                    .buttonStyle(.borderedProminent).disabled(scanning)
            }
            if scanning {
                ProgressView("Checking local snapshots…").card()
            } else if dates.isEmpty {
                EmptyState(title: tried ? "No local snapshots to review" : "Check local snapshots",
                           symbol: "clock.arrow.circlepath",
                           message: "Your backups on other drives are separate from these restore points.")
            } else if let finding {
                HStack {
                    Button("Select All") { selected = Set(dates) }
                    Spacer()
                    Button("Review Selected…") {
                        ui.confirm = model.removal.prepareLocalSnapshots(finding, selected: selected)
                        if ui.confirm == nil { ui.problem = "Snapshot deletion is unavailable for the current scan or macOS version." }
                    }
                    .buttonStyle(.borderedProminent).disabled(selected.isEmpty || !finding.verdict.actionable || model.removal.isExecuting)
                }
                if !finding.verdict.actionable {
                    Banner(text: "This version of macOS can list these snapshots. Deletion is unavailable.",
                           symbol: "info.circle")
                }
                LazyInsetList(items: dates) { date in
                    Toggle(date, isOn: Binding(get: { selected.contains(date) },
                                               set: { if $0 { selected.insert(date) } else { selected.remove(date) } }))
                        .groupRow()
                }
            }
        }
        .task(id: refresh) {
            guard refresh > 0 else { return }
            scanning = true
            selected = []
            let control = ScanControl { _ in }
            let result = await withTaskCancellationHandler {
                await model.removal.scanLocalSnapshots(control: control)
            } onCancel: { control.cancel() }
            guard !Task.isCancelled else { return }
            finding = result
            tried = true
            scanning = false
        }
        .onChange(of: ui.receiptShowing) { _, shown in
            if !shown, tried { refresh += 1 }
        }
    }
}
