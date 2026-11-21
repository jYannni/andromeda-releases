import AndromedaAppModel
import AndromedaCore
import AndromedaOrganize
import SwiftUI

/// One section per cloud folder. Hand-off only (decision 19a): the action is
/// Show in Finder plus what to click there; Andromeda itself changes nothing in the cloud folders.
struct CloudView: View {
    let cloud: CloudModel

    var body: some View {
        PageColumn {
            PageHeader(
                title: Copy.Organize.cloudTitle, subtitle: Copy.Organize.cloudSubtitle,
                symbol: "icloud.and.arrow.down.fill", tint: .blue)
            if cloud.providers.isEmpty {
                EmptyState(title: UICopy.noCloudTitle, symbol: "icloud.slash", message: Copy.Organize.noCloudFolders)
            }
            ForEach(cloud.providers) { ProviderSectionView(cloud: cloud, section: $0) }
        }
        .task { await cloud.appear() }
    }
}

private struct ProviderSectionView: View {
    let cloud: CloudModel
    let section: ProviderSection

    private var provider: CloudProvider { section.root.provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ProviderIconView(provider: provider, size: 36)
                Text(section.title).font(.headline)
                Spacer()
                if let total = section.totalFreesAtLeast, total > 0 {
                    Text(Copy.Organize.total(ByteFormat.string(total))).font(.headline.monospacedDigit())
                }
            }
            if let access = cloud.accessText(for: provider) {
                Text(access).foregroundStyle(.secondary)
            }
            if cloud.isScanning(provider) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.Organize.checking).foregroundStyle(.secondary)
                    Button(Copy.Organize.stopChecking) { cloud.cancel(provider) }
                }
            } else if !section.checked {
                HStack(alignment: .center, spacing: 12) {
                    Text(Copy.Organize.uncheckedNote(provider)).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button(Copy.Organize.checkProvider(provider)) { Task { await cloud.check(provider) } }
                }
            } else {
                checkedBody
            }
        }
        .card(padding: 18)
    }

    @ViewBuilder private var checkedBody: some View {
        if let text = cloud.handOffText(for: provider) {
            HStack {
                Text(text)
                Spacer()
                if cloud.canCheckAgain(provider) { checkAgainButton }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        if cloud.handOffText(for: provider) == nil, cloud.canCheckAgain(provider) {
            checkAgainButton
        }
        if section.totalFreesAtLeast != nil, section.rows.isEmpty {
            Text(Copy.Organize.nothingToSuggest).foregroundStyle(.secondary)
        }
        ForEach(section.groups) { group in
            Text(group.header).font(.subheadline.weight(.semibold)).padding(.top, 4)
            ForEach(group.entries) { entry in
                switch entry {
                case .row(let row): OffloadRowView(cloud: cloud, row: row)
                case .folder(let parent, let rows):
                    FolderGroupView(cloud: cloud, parent: parent, rows: rows)
                }
            }
        }
        if !section.rows.isEmpty {
            HStack {
                Text(Copy.Organize.rowNote(provider: provider)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(Copy.Organize.showInFinder) { cloud.showInFinder(provider) }
                    .accessibilityLabel("Show selected \(section.title) files in Finder")
                    .disabled(!cloud.canShowInFinder(provider))
            }
        }
    }

    private var checkAgainButton: some View {
        Button(Copy.Organize.checkAgain) { Task { await cloud.rescan(provider) } }
            .accessibilityLabel("Check \(section.title) again")
    }
}

private struct FolderGroupView: View {
    let cloud: CloudModel
    let parent: URL
    let rows: [OffloadRow]

    private var anySelectable: Bool { rows.contains(where: \.isSelectable) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if anySelectable {
                    Toggle(parent.lastPathComponent, isOn: Binding(
                        get: { cloud.isGroupTicked(parent) }, set: { _ in cloud.toggleGroup(parent) }))
                        .toggleStyle(.checkbox).labelsHidden()
                }
                Image(systemName: "folder")
                Text(Copy.Organize.folderRow(parent.lastPathComponent, items: rows.count)).font(.headline)
            }
            ForEach(rows) { OffloadRowView(cloud: cloud, row: $0).padding(.leading, 24) }
        }
    }
}

private struct OffloadRowView: View {
    let cloud: CloudModel
    let row: OffloadRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(row.id.lastPathComponent, isOn: Binding(
                get: { cloud.ticked.contains(row.id) }, set: { _ in cloud.toggle(row.id) }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!row.isSelectable)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.id.lastPathComponent).font(.body.weight(.medium))
                Text(Copy.Organize.lastUse(row.lastUse)).font(.callout).foregroundStyle(.secondary)
                if let status = Copy.Organize.statusText(row.status) {
                    Text(status).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Copy.Rows.uses(ByteFormat.string(row.state.usesBytes))).font(.body.monospacedDigit())
                Text(row.state.freesAtLeast.map { Copy.Organize.frees(ByteFormat.string($0)) } ?? Copy.Organize.freesUnknown)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
