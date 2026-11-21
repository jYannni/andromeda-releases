import AndromedaAppModel
import AndromedaCore
import AndromedaOrganize
import SwiftUI

/// After a folder run: pick which of the run's new group folders to hand to Move to cloud. Nothing is ticked.
/// **Review** opens the existing Move to cloud review, whose confirm sheet defaults to Cancel; this sheet
/// changes nothing itself.
struct CloudHandOffView: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var rows: [CloudHandOffRow] = []
    @State private var isLoading = true
    @State private var chosen: Set<URL> = []
    @State private var rootURL: URL?
    /// **Review** found nothing to plan.
    @State private var nothingToMove = false

    private var move: MoveToCloudModel { model.moveToCloud }

    private var root: CloudRoot? { move.roots.first { $0.url == rootURL } ?? move.roots.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: Copy.Organize.handOffTitle, symbol: "icloud.and.arrow.up.fill", tint: .cyan)
            Picker(Copy.Organize.destinationLabel, selection: Binding(get: { root?.url }, set: { rootURL = $0 })) {
                ForEach(move.roots, id: \.url) { root in
                    Text(Copy.Organize.sectionTitle(root.provider, account: root.account)).tag(Optional(root.url))
                }
            }
            .fixedSize()
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.Organize.finding).foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    InsetGroup {
                        ForEach(rows) { row in
                            HandOffRowView(
                                row: row,
                                isOn: Binding(
                                    get: { chosen.contains(row.id) },
                                    set: { on in if on { chosen.insert(row.id) } else { chosen.remove(row.id) } }))
                        }
                    }
                }
            }
            Text(Copy.Organize.handOffNote).font(.callout).foregroundStyle(.secondary)
            if nothingToMove {
                Text(Copy.Organize.handOffNothing).font(.callout).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Button(UICopy.cancel, action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(UICopy.cancel)
                Spacer()
                Button(Copy.Confirm.review(chosen.count)) {
                    guard let root else { return }
                    // Keeps the order the rows are shown in.
                    let urls = rows.map(\.id).filter { chosen.contains($0) }
                    nothingToMove = false
                    Task {
                        if await move.handOff(urls, to: root) { onClose() } else { nothingToMove = true }
                    }
                }
                .accessibilityLabel(Copy.Confirm.review(chosen.count))
                .disabled(chosen.isEmpty || root == nil || model.organize.isApplying)
            }
        }
        .padding(24)
        .frame(minWidth: 540, minHeight: 320)
        .task {
            model.refreshOrganizeRoots()
            rootURL = move.roots.first?.url
            rows = await model.organize.cloudHandOffRows()
            isLoading = false
        }
    }
}

private struct HandOffRowView: View {
    let row: CloudHandOffRow
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(row.name, isOn: $isOn).toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel(row.name)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).font(.body.weight(.medium))
                    if row.recommended {
                        Chip(text: Copy.Organize.recommended, tint: .accentColor)
                    }
                }
                Text(row.lastUsedText).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.usesText).font(.body.weight(.semibold)).monospacedDigit()
                Text(row.freesText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .groupRow()
    }
}
