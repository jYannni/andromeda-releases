import AppKit
import AndromedaAppModel
import AndromedaCore
import SwiftUI

/// One external drive: its totals, then (after **Scan <name>**) the hidden space macOS keeps on it and
/// its large items. Disconnected drives show the saved comparison.
struct DrivePageView: View {
    private struct RetainedBrowser {
        let scope: StorageBrowseScope
        let index: StorageBrowser
    }

    let model: AppModel
    let ui: UIState
    let id: String
    @State private var browseScope: StorageBrowseScope?
    @State private var browseSeed: StorageBrowserView.Seed?
    @State private var retainedBrowser: RetainedBrowser?
    @State private var browseTask: Task<Void, Never>?
    @State private var pinTask: Task<Void, Never>?
    @State private var folderUnavailable = false
    @State private var pinUnavailable = false
    @State private var showsBrowseFolders = true

    private var volume: ExternalVolume? { model.drives.volumes.first { $0.id == id } }

    var body: some View {
        ZStack {
            if let scope = browseScope, let volume, volume.kind != .timeMachine {
                let root = scope.roots.first?.url ?? volume.url
                let entireDrive = root == volume.url.standardizedFileURL
                let isAPFS = DrivePage.StorageScope(volume: volume) != .fileSystem
                let location = entireDrive
                    ? (isAPFS ? "Search readable files on this volume by name or path." : "Search readable files on this drive by name or path.")
                    : root.path
                VStack(spacing: 0) {
                    if case .scanning = model.drives.state(id) {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Scanning \(volume.name) in the background")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Stop Drive Scan") { model.drives.cancel(id) }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        Divider()
                    }
                    StorageBrowserView(
                        model: model, title: entireDrive ? volume.name : root.lastPathComponent,
                        subtitle: isAPFS ? location + "\n" + UICopy.apfsFileAllocation : location,
                        scope: scope, openPlan: { ui.destination = .spacePlan },
                        archive: { url in
                            model.archives.pick(url)
                            ui.destination = .archives
                        },
                        shortcuts: shortcutMenu(on: volume, folder: root),
                        seed: browseSeed, indexChanged: { index in
                            guard browseScope?.roots.first?.url == root else { return }
                            retainedBrowser = index.map { RetainedBrowser(scope: scope, index: $0) }
                            browseSeed = nil
                        },
                        actionTitle: "Back to Drive") {
                            browseTask?.cancel()
                            browseScope = nil
                            browseSeed = nil
                        }
                        .id(root.path)
                }
            } else {
                driveDetails
            }
        }
        .onChange(of: volume?.url) { _, _ in resetBrowsing() }
        .onChange(of: model.access.fda) { _, _ in resetBrowsing() }
        .onDisappear { resetBrowsing() }
        .alert("Couldn’t Browse Folder", isPresented: $folderUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Choose an available folder on this drive.")
        }
        .alert("Couldn’t Pin Folder", isPresented: $pinUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Check that the folder and drive are still available.")
        }
    }

    private var driveDetails: some View {
        PageColumn {
            let saved = model.drives.comparison(id)
            if let volume, let page = model.drives.page(id) {
                connected(volume, page, saved: saved)
            } else {
                let absent = model.drives.absentPage(id)
                let title = Copy.Drives.notConnected(absent.name ?? UICopy.thisDrive)
                let automatic = model.drives.isAutomaticallyScanned(id)
                if saved != nil || automatic || model.drives.catalog(id) != nil || model.drives.storageLocation(for: id) != nil {
                    PageHeader(title: title, subtitle: "Reconnect to scan again.", symbol: "externaldrive.badge.xmark") {
                        if model.drives.catalog(id) != nil { catalogButton }
                    }
                    locationRow(absent.name ?? UICopy.thisDrive)
                    if automatic { automaticScanToggle }
                    comparison(saved, isOffline: true)
                } else {
                    EmptyState(title: title, symbol: "externaldrive.badge.xmark",
                               message: [absent.disconnectedNote, absent.lastSeenText, UICopy.driveNotConnectedBody]
                                   .compactMap { $0 }.joined(separator: "\n"))
                }
            }
        }
    }

    @ViewBuilder private func connected(_ volume: ExternalVolume, _ page: DrivePage, saved: DriveComparison?) -> some View {
        let state = model.drives.state(id)
        PageHeader(
            title: page.title, subtitle: UICopy.driveSubtitle(kind: page.kindLabel, format: page.formatText),
            symbol: "externaldrive.fill", icon: NSWorkspace.shared.icon(forFile: volume.url.path)
        ) {
            if volume.kind != .timeMachine {
                shortcutMenu(on: volume)
                Menu {
                    Button("Browse Entire Drive") { browseEntireDrive() }
                    Button("Browse a Folder…") { browseDriveFolder(volume.url, showPicker: true) }
                } label: {
                    Text("Browse Files")
                } primaryAction: {
                    browseEntireDrive()
                }
            }
            if model.drives.canCatalog(volume) { catalogButton }
            if case .scanning = state {
                Button(UICopy.cancelScan) { model.drives.cancel(id) }
            } else {
                Button(Copy.Drives.scan(page.title)) { Task { await model.drives.scan(id) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.drives.catalogingDriveID == id)
            }
        }
        ForEach(page.notes, id: \.self) { Banner(text: $0, tint: .secondary) }
        hero(page)
        locationRow(volume.name)
        if volume.hasStableIdentity { automaticScanToggle }
        browseFolders(on: volume)
        comparison(saved, isOffline: false)
        if case .scanning(let progress) = state {
            scanning(page.title, progress)
        }
        switch state {
        case .idle:
            Text(UICopy.driveIdleBody).font(.callout).foregroundStyle(.secondary)
        case .scanning:
            let found = model.drives.largeItemsFoundDuringScan(id)
            if !found.isEmpty {
                SectionHeading(title: "Largest items found so far", subtitle: "The ranking may change as the scan continues.")
                InsetGroup {
                    ForEach(found) { row in
                        LargeItemRowView(model: model, ui: ui, row: row, showsOrganize: false)
                    }
                }
            }
        case .done(let result):
            if result.rootWasUnreadable {
                Banner(text: "Andromeda couldn’t read this drive. Check macOS access and try scanning again.",
                       symbol: "exclamationmark.triangle", tint: .orange)
            } else if !result.unreadable.isEmpty {
                DisclosureGroup("Some locations couldn’t be read") {
                    ScrollablePathList(paths: result.unreadable.map(\.path)).padding(.top, 6)
                }
                .card()
            }
            results(page)
        }
    }

    @ViewBuilder private func browseFolders(on volume: ExternalVolume) -> some View {
        let folders = model.drives.browsableFolders(id)
        if !folders.isEmpty {
            DisclosureGroup("Browse Folders", isExpanded: $showsBrowseFolders) {
                InsetGroup {
                    ForEach(folders) { row in
                        let folder = row.url
                        let size = row.bytes.map(ByteFormat.string)
                        Button {
                            browseDriveFolder(folder)
                        } label: {
                            HStack {
                                Label(folder.lastPathComponent, systemImage: "folder")
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if let size {
                                    Text(size).monospacedDigit().foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Browse \(folder.lastPathComponent)")
                        .accessibilityValue(size ?? "")
                        .contextMenu {
                            if let pinned = model.pinnedStorageFolders.first(where: { $0.url.path == folder.path }) {
                                Button("Unpin Folder", systemImage: "pin.slash") { model.unpinStorageFolder(pinned) }
                            } else {
                                Button("Pin Folder", systemImage: "pin") { pinDriveFolder(folder) }
                            }
                        }
                    }
                    Button("Choose Another Folder…") { browseDriveFolder(volume.url, showPicker: true) }
                }
                .padding(.top, 8)
            }
            .card()
        }
    }

    private func browseEntireDrive() {
        browseTask?.cancel()
        browseSeed = nil
        browseScope = model.drives.browseScope(id, fda: model.access.fda)
    }

    private func browseDriveFolder(
        _ directory: URL, showPicker: Bool = false, reference: StorageBrowser.FolderReference? = nil
    ) {
        browseTask?.cancel()
        browseTask = Task {
            if browseScope == nil, let reference, let retainedBrowser,
               let trail = await retainedBrowser.scope.indexedShortcut(reference, in: retainedBrowser.index) {
                guard !Task.isCancelled else { return }
                browseSeed = .init(browser: retainedBrowser.index, trail: trail)
                browseScope = retainedBrowser.scope
                return
            }
            let chosen = showPicker ? await model.chooseStorageFolder(startingAt: directory) : directory
            guard let chosen, !Task.isCancelled else { return }
            let narrowed = await model.drives.browseFolder(chosen, on: id, fda: model.access.fda, reference: reference)
            guard !Task.isCancelled else { return }
            if let scope = narrowed {
                browseSeed = nil
                browseScope = scope
            } else {
                folderUnavailable = true
            }
        }
    }

    private func shortcutMenu(on volume: ExternalVolume, folder: URL? = nil) -> FolderShortcutMenu {
        FolderShortcutMenu(model: model, folder: folder, driveRoot: volume.url, open: { reference in
            browseDriveFolder(reference.url, reference: reference)
        }, pin: pinDriveFolder, cancelPendingOpen: { browseTask?.cancel() })
    }

    private func pinDriveFolder(_ folder: URL) {
        pinTask?.cancel()
        pinTask = Task {
            guard let drive = model.drives.browseScope(id, fda: model.access.fda) else { return }
            guard await drive.narrowedToDriveFolder(folder) != nil, !Task.isCancelled else {
                if !Task.isCancelled { pinUnavailable = true }
                return
            }
            let saved = await model.pinStorageFolder(folder)
            if !Task.isCancelled, !saved { pinUnavailable = true }
        }
    }

    private func resetBrowsing() {
        browseTask?.cancel()
        pinTask?.cancel()
        browseScope = nil
        browseSeed = nil
        retainedBrowser = nil
    }

    @ViewBuilder private func locationRow(_ name: String) -> some View {
        if model.drives.canSetStorageLocation(for: id) {
            HStack {
                if let note = model.drives.storageLocation(for: id) {
                    DriveStorageLocationLabel(note: note)
                }
                Spacer()
                DriveStorageLocationButton(drives: model.drives, id: id, name: name)
            }
        }
    }

    private var catalogButton: some View {
        Button("Drive Catalogs") {
            ui.destination = .driveCatalogs
            ui.catalogDriveID = model.drives.catalog(id)?.id
        }
    }

    private var automaticScanToggle: some View {
        Toggle("Keep this drive’s scans up to date", isOn: Binding(
            get: { model.drives.isAutomaticallyScanned(id) },
            set: { model.drives.setAutomaticScan($0, for: id) }
        ))
        .toggleStyle(.switch)
        .help("Scans on connection, at launch, and after file changes. Automatic scans wait in Low Power Mode or under high thermal pressure. macOS may ask for drive access.")
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private func comparison(_ saved: DriveComparison?, isOffline: Bool) -> some View {
        if let problem = model.drives.comparisonProblem {
            Banner(text: problem, symbol: "exclamationmark.triangle", tint: .orange)
        }
        if let comparison = saved {
            SectionHeading(title: "What changed on this drive?", subtitle: isOffline ? "Saved scans" : nil,
                           symbol: "arrow.up.arrow.down", tint: .purple)
            if comparison.hasPartialScan {
                Banner(text: "Unreadable locations were skipped. Only folders fully measured in both scans can be compared.",
                       symbol: "exclamationmark.triangle", tint: .orange)
            }
            if let baseline = comparison.baseline {
                let count = comparison.comparedCount
                let folderCount = "\(count.formatted()) top-level \(count == 1 ? "folder" : "folders")"
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(stamp(baseline)) → \(stamp(comparison.latest))").font(.callout.weight(.medium))
                    if count == 0 {
                        Text("Both scans must measure the same top-level folder to compare it.")
                    } else if comparison.changes.isEmpty {
                        Text("No size changes across \(folderCount) measured in both scans.")
                    } else {
                        Text("Compared \(folderCount) measured in both scans.")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).card()
                if !comparison.changes.isEmpty {
                    LazyInsetList(items: comparison.changes) { change in
                        HStack {
                            Label(change.name, systemImage: "folder").lineLimit(1)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text((change.bytes < 0 ? "−" : "+") + ByteFormat.string(abs(change.bytes)))
                                    .font(.headline)
                                Text("\(ByteFormat.string(change.before)) → \(ByteFormat.string(change.after))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .monospacedDigit()
                        }
                        .groupRow()
                    }
                }
            } else {
                Text("Baseline saved \(stamp(comparison.latest)). Scan this drive again to compare folder sizes.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).card()
            }
        }
    }

    private func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().second())
    }

    /// Used of capacity, like the Overview's headline: one segment for what is used, then the free track.
    private func hero(_ page: DrivePage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let heading = page.storageScope.heading {
                Label(heading, systemImage: "externaldrive")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(page.usedText ?? page.capacityText).font(.system(size: 40, weight: .bold)).monospacedDigit()
                Text(page.usedBytes == nil ? "reported capacity" : page.ofCapacityText)
                    .font(.title3).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(page.availableText).font(.title3.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            if let used = page.usedBytes {
                SpaceBarView(
                    segments: [BarSegment(kind: .bucket(.documents), label: UICopy.driveUsed, bytes: used, fraction: 1)],
                    usedFraction: page.usedFraction, height: 30) { _ in }
            }
            if !page.sharesWith.isEmpty {
                Text(Copy.Drives.sharesSpace(page.sharesWith)).font(.callout).foregroundStyle(.secondary)
            }
            if let volume = page.apfsVolume {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("Selected Volume").font(.headline)
                    LabeledContent("Allocated", value: volume.allocatedText)
                    if let available = volume.availableText {
                        LabeledContent("Available to this volume", value: available)
                    }
                    if let quota = volume.quotaText {
                        LabeledContent("Quota", value: quota)
                    }
                    if let reserve = volume.reserveText {
                        LabeledContent("Reserve", value: reserve)
                    }
                }
            }
        }
        .card(padding: 22)
    }

    private func scanning(_ name: String, _ progress: ScanProgress?) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(UICopy.driveScanning(name)).font(.headline)
                if let p = progress, p.itemsChecked > 0 {
                    Text(Copy.Scan.counts(items: p.itemsChecked, bytes: p.bytesMeasured))
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                if let path = progress?.currentPath {
                    Text(UICopy.nowReading(path.path)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(UICopy.scanningNote).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    @ViewBuilder private func results(_ page: DrivePage) -> some View {
        if page.storageScope != .fileSystem {
            Text(UICopy.apfsFileAllocation).font(.callout).foregroundStyle(.secondary)
        }
        if !page.hidden.isEmpty {
            SectionHeading(title: UICopy.driveHiddenHeading, subtitle: UICopy.driveHiddenSubtitle)
            InsetGroup {
                // The Trash row's hand-off opens <mount>/.Trashes in Finder; no row is selectable.
                ForEach(page.hidden) { ItemRowView(model: model, ui: ui, row: $0) }
            }
        }
        if !page.largeItems.isEmpty {
            SectionHeading(title: UICopy.driveLargeHeading, subtitle: UICopy.largeSubtitle)
            InsetGroup {
                // Organize these plans the item's folder on Organize a folder (Move to cloud only lists home);
                // a drive Organize refuses (read-only, Time Machine) offers none.
                ForEach(page.largeItems) {
                    LargeItemRowView(model: model, ui: ui, row: $0, showsOrganize: page.canOrganize, organizesOnDrive: true)
                }
            }
        }
        if let other = page.otherText {
            Text(other).font(.headline).frame(maxWidth: .infinity, alignment: .leading).card()
        }
    }
}
