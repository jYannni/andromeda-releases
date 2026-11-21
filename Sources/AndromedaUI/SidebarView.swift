import AppKit
import AndromedaAppModel
import AndromedaCore
import SwiftUI

struct SidebarView: View {
    let model: AppModel
    @Bindable var ui: UIState
    let showUpdate: (() -> Void)?
    @FocusState private var focusedRow: UIState.Destination?

    private struct Item: Identifiable {
        let id: UIState.Destination
        let title: String
        let symbol: String
        let color: Color
        let driveIcon: NSImage?
        let badge: String?
        let help: String

        init(_ id: UIState.Destination, _ title: String, _ symbol: String, color: Color, badge: String? = nil,
             help: String? = nil) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.color = color
            driveIcon = nil
            self.badge = badge
            self.help = help ?? title
        }

        init(drive: ExternalVolume) {
            id = .drive(drive.id)
            title = drive.name
            symbol = "externaldrive"
            color = .brown
            driveIcon = NSWorkspace.shared.icon(forFile: drive.url.path)
            badge = ByteFormat.string(drive.used)
            help = drive.name
        }
    }

    private var groups: [(title: String?, items: [Item])] {
        let bar = model.overview?.bar ?? []
        let storage = model.pages.map { page in
            let bytes = bar.first { $0.kind == .bucket(page.id) }?.bytes
            return Item(.page(page.id), page.title, Style.symbol(page.id), color: Style.bucketColor(page.id),
                        badge: bytes.map { ByteFormat.string($0) })
        }
        let drives = model.drives.volumes.map(Item.init(drive:)) + model.drives.offlineDrives.map {
            Item(.drive($0.id), $0.name, "externaldrive.badge.xmark", color: .secondary, badge: "Offline")
        }
        return [
            (nil, [
                Item(.overview, UICopy.overview, "chart.pie", color: .orange),
                Item(.scanComparison, "What changed?", "arrow.up.arrow.down", color: .purple),
                Item(.storageTrends, "Storage Trends", "chart.xyaxis.line", color: .green),
                Item(.history, UICopy.history, "clock.arrow.circlepath", color: .indigo),
            ]),
            (UICopy.storageGroup, storage + [
                Item(.storageMap, "Storage Map", "square.grid.2x2", color: .teal),
                Item(.browseFolder, "Scan a Folder", "folder", color: .blue),
                Item(.duplicates, "Duplicates", "doc.on.doc", color: .purple),
            ]),
            (Copy.Drives.sidebarGroup, [Item(.driveCatalogs, "Drive Catalogs", "externaldrive", color: .teal)] + drives),
            ("Free Up Space", [
                Item(.spacePlan, "Space Plan", "target", color: .pink),
                Item(.cloud, Copy.Organize.cloudTitle, "icloud.and.arrow.down", color: .cyan,
                     help: Copy.Organize.cloudSubtitle),
                Item(.moveToCloud, Copy.Organize.moveToCloudTitle, "icloud.and.arrow.up", color: .mint,
                     help: Copy.Organize.moveToCloudSubtitle),
            ]),
            ("Folders & Archives", [
                Item(.organizeFolder, model.englishSpelling.wording(Copy.Organize.organizeFolderTitle),
                     "folder.badge.gearshape", color: .yellow),
                Item(.archives, UICopy.archivesTitle, "externaldrive.badge.checkmark", color: .brown,
                     help: UICopy.archivesSubtitle),
            ]),
        ].filter { !$0.items.isEmpty }
    }

    private var selection: UIState.Destination {
        if case .browseCategory(let bucket) = ui.destination { return .page(bucket) }
        if case .reviewFolder = ui.destination { return .spacePlan }
        if case .reviewInstallers = ui.destination { return .page(.applications) }
        return ui.destination
    }

    var body: some View {
        VStack(spacing: 0) {
            let groups = groups
            let destinations = groups.flatMap(\.items).map(\.id)
            header
            ScrollViewReader { scroll in
                navigation(groups) { item, offset in
                    guard let index = destinations.firstIndex(of: item) else { return }
                    let next = index + offset
                    if destinations.indices.contains(next) {
                        let destination = destinations[next]
                        scroll.scrollTo(destination)
                        focusedRow = destination
                        ui.destination = destination
                    }
                }
            }
            .clipped()
            footer
        }
    }

    @ViewBuilder private var header: some View {
        if ui.sidebarIsCompact {
            AppIconView(size: 28)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 4)
        } else {
            Masthead(scanned: model.scan.lastResult.map { UICopy.scannedAt($0.finishedAt) })
        }
    }

    @ViewBuilder private func navigation(
        _ groups: [(title: String?, items: [Item])],
        move: @escaping (UIState.Destination, Int) -> Void
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    VStack(alignment: .leading, spacing: 2) {
                        if ui.sidebarIsCompact {
                            if index > 0 { Divider().padding(.horizontal, 4).padding(.bottom, 2) }
                        } else if let title = group.title {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 6)
                                .padding(.top, 3)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.items) { item in navigationRow(item, move: move) }
                    }
                }
            }
            .padding(.horizontal, ui.sidebarIsCompact ? 8 : 12)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(ui.sidebarIsCompact ? .never : .automatic)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Divider()
            if let showUpdate {
                Button(action: showUpdate) {
                    SidebarLabel(title: "Update Available", symbol: "arrow.down.circle.fill",
                                 compact: ui.sidebarIsCompact, emphasisColor: .blue)
                }
                .buttonStyle(.plain)
                .help("Review the available update")
                .accessibilityLabel("Update Available")
            }
            SettingsLink {
                SidebarLabel(title: "Settings", symbol: "gearshape", compact: ui.sidebarIsCompact)
            }
            .buttonStyle(.plain)
            .help("Open Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, ui.sidebarIsCompact ? 8 : 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func navigationRow(
        _ item: Item,
        move: @escaping (UIState.Destination, Int) -> Void
    ) -> some View {
        let selected = selection == item.id
        let focused = focusedRow == item.id
        return Button {
            focusedRow = item.id
            ui.destination = item.id
        } label: {
            SidebarLabel(title: item.title, symbol: item.symbol, driveIcon: item.driveIcon,
                         badge: item.badge, compact: ui.sidebarIsCompact, emphasisColor: selected ? item.color : nil)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(focused ? 0.19 : 0.12))
                    } else if focused {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.38))
                    }
                }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedRow, equals: item.id)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
            move(item.id, press.key == .upArrow ? -1 : 1)
            return .handled
        }
        .id(item.id)
        .help(item.help)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.badge ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SidebarLabel: View {
    let title: String
    let symbol: String
    var driveIcon: NSImage?
    var badge: String?
    let compact: Bool
    var emphasisColor: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = 0

    var body: some View {
        HStack(spacing: 8) {
            SidebarGlyph(symbol: symbol, driveIcon: driveIcon, emphasisColor: emphasisColor, hover: hover)
            if !compact {
                if let badge {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        sizeBadge(badge).fixedSize()
                    }
                } else {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: compact ? .center : .leading)
        .contentShape(Rectangle())
        .onHover { if $0 && !reduceMotion { hover += 1 } }
    }

    private func sizeBadge(_ text: String) -> some View {
        Text(text).font(.caption).monospacedDigit().foregroundStyle(.secondary)
    }
}
