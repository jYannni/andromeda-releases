import AndromedaAppModel
import AndromedaCore
import AppKit
import SwiftUI

struct TrashBinsView: View {
    let model: AppModel
    let ui: UIState

    @State private var bins: [TrashBins.Bin]?
    @State private var selection: Set<URL> = []
    @State private var confirmation: [TrashBins.Item] = []
    @State private var confirming = false
    @State private var scanning = false
    @State private var refresh = 0
    @State private var receipt: TrashBins.Receipt?

    var body: some View {
        PageColumn {
            PageHeader(title: "Trash Bins", subtitle: "Review files in Trash on the startup disk and supported writable drives.",
                       symbol: "trash", tint: .orange) {
                ToolBackButton(ui: ui)
                Button("Scan Trash", systemImage: "arrow.clockwise") { scan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(scanning || model.removal.isExecuting || model.access.fda != .granted)
            }
            if let reason = model.removal.removalDisabledReason { Banner(text: reason, symbol: "lock.fill") }
            if model.access.fda != .granted {
                Banner(text: "Full Disk Access lets Andromeda list the files in Trash.",
                       symbol: "lock.fill", tint: .secondary, actionTitle: "Open Full Disk Access",
                       action: model.access.openSettings)
            }
            if let receipt {
                Banner(text: summary(receipt), symbol: receipt.failed + receipt.skipped > 0 || receipt.journalFailed
                       ? "exclamationmark.triangle" : "checkmark.circle",
                       tint: receipt.failed + receipt.skipped > 0 || receipt.journalFailed ? .orange : .green,
                       actionTitle: "History", action: { ui.destination = .history })
            }
            if scanning {
                ProgressView("Reading Trash bins…").card()
            } else if let bins {
                HStack {
                    Button("Select All Reviewed Files") { selection = Set(bins.flatMap(\.items).map(\.id)) }
                        .disabled(!bins.contains { !$0.items.isEmpty })
                    Button("Clear Selection") { selection = [] }.disabled(selection.isEmpty)
                    Spacer()
                    Button("Review Permanent Deletion…") {
                        confirmation = bins.flatMap(\.items).filter { selection.contains($0.id) }
                        confirming = !confirmation.isEmpty
                    }
                    .disabled(selection.isEmpty || model.removal.isExecuting || model.removal.removalDisabledReason != nil)
                }
                ForEach(bins) { bin in binSection(bin) }
            } else if model.access.fda == .granted {
                EmptyState(title: "Scan Trash bins", symbol: "trash",
                           message: "Scan to list the files available for review on each drive.")
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Mail Trash").font(.headline)
                    Text("To clear deleted mail, use Mailbox → Erase Deleted Items in Apple Mail.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Open Mail") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app")) }
            }
            .card()
        }
        .task(id: refresh) {
            guard refresh > 0 else { return }
            let control = ScanControl { _ in }
            let found = await withTaskCancellationHandler {
                await model.removal.scanTrashBins(control: control)
            } onCancel: { control.cancel() }
            guard !Task.isCancelled else { return }
            bins = found
            scanning = false
        }
        .sheet(isPresented: $confirming, onDismiss: { confirmation = [] }) { confirmSheet }
    }

    private func binSection(_ bin: TrashBins.Bin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading(title: bin.title, symbol: "externaldrive", tint: .orange)
                Spacer()
                if !bin.items.isEmpty {
                    Button("Select Bin") { selection.formUnion(bin.items.map(\.id)) }.controlSize(.small)
                }
            }
            if bin.unavailable {
                Text("This bin couldn’t be read.").foregroundStyle(.secondary).card()
            } else if bin.items.isEmpty && bin.preserved == 0 {
                Text("Empty").foregroundStyle(.secondary).card()
            } else {
                if bin.preserved > 0 {
                    Text("\(bin.preserved.formatted()) items couldn’t be verified and are kept.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !bin.items.isEmpty {
                    LazyInsetList(items: bin.items) { item in
                        HStack(spacing: 8) {
                            Toggle(item.url.lastPathComponent, isOn: Binding(
                                get: { selection.contains(item.id) },
                                set: { if $0 { selection.insert(item.id) } else { selection.remove(item.id) } }
                            ))
                            Spacer()
                            Text(ByteFormat.string(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }.groupRow()
                    }
                }
            }
        }
    }

    private var confirmSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Permanently Delete Selected Files?",
                        subtitle: "These files will be removed from Trash and can’t be restored from History.",
                        symbol: "trash.fill", tint: .orange)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(confirmation) { item in
                        HStack {
                            Text(item.url.lastPathComponent)
                            Spacer(minLength: 12)
                            Text(item.binTitle).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 70, maxHeight: 230)
            HStack {
                Text("\(confirmation.count.formatted()) items").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { confirming = false }.keyboardShortcut(.defaultAction)
                Button("Delete Permanently", role: .destructive) {
                    let reviewed = confirmation
                    confirming = false
                    Task {
                        receipt = await model.removal.emptyTrashBins(reviewed)
                        if receipt == nil { ui.problem = "Trash Bins couldn’t start. Finish the current storage work and try again." }
                        scan()
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private func scan() {
        guard !scanning else { return }
        selection = []
        scanning = true
        refresh += 1
    }

    private func summary(_ receipt: TrashBins.Receipt) -> String {
        var parts = ["Deleted \(receipt.deleted.formatted()) items."]
        if receipt.skipped > 0 { parts.append("Skipped \(receipt.skipped.formatted()) changed or unavailable items.") }
        if receipt.failed > 0 { parts.append("Couldn’t finish deleting \(receipt.failed.formatted()) items.") }
        if receipt.journalFailed { parts.append("Stopped because History couldn’t be written.") }
        return parts.joined(separator: " ")
    }
}
