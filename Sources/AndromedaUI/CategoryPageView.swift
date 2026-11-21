import AndromedaAppModel
import SwiftUI

struct CategoryPageView: View {
    let model: AppModel
    let ui: UIState
    let page: CategoryPage
    @State private var appReview: ApplicationCleanupSheet.Mode?
    @State private var appConfirmation: ConfirmSummary?

    private var subtitle: String {
        if page.id == .applications { return "Review installed apps and look for leftover Library files." }
        if page.id == .documents || page.rows.isEmpty { return Copy.Page.readOnlySubtitle }
        return UICopy.pageSubtitle
    }

    var body: some View {
        PageColumn {
            PageHeader(
                title: UICopy.pageTitle(page.title),
                subtitle: subtitle,
                symbol: Style.symbol(page.id), tint: Style.bucketColor(page.id)
            ) {
                Button("Browse Files", systemImage: "folder") { ui.destination = .browseCategory(page.id) }
                if page.id == .applications {
                    Menu("App Cleanup", systemImage: "app.badge") {
                        Button("Manage Installed Apps…") { appReview = .installed }
                            .disabled(model.removal.applicationCleanupCandidates.isEmpty
                                      || model.removal.removalDisabledReason != nil || model.removal.isExecuting)
                        Button("Leftover App Files…") { appReview = .leftovers }
                            .disabled(model.removal.removalDisabledReason != nil || model.removal.isExecuting)
                        Button("Find Installer Files…") {
                            Task {
                                let downloads = model.scanHome.appendingPathComponent("Downloads", isDirectory: true)
                                if let folder = await model.chooseStorageFolder(startingAt: downloads) {
                                    ui.destination = .reviewInstallers(folder)
                                }
                            }
                        }
                    }
                }
                if page.hasSelectableCleanup { ReviewButton(model: model, ui: ui, allCategories: true) }
            }
            if let reason = model.removal.removalDisabledReason {
                Banner(text: reason, symbol: "lock.fill", tint: .secondary)
            }
            if !page.rows.isEmpty {
                InsetGroup {
                    ForEach(page.rows) { ItemRowView(model: model, ui: ui, row: $0) }
                }
            }
            if let volume = page.volumeRow {
                HStack(alignment: .firstTextBaseline) {
                    Text(volume.title).font(.headline)
                    Spacer()
                    Text(volume.sizeText).font(.headline.monospacedDigit())
                }
                .card()
            }
            if !page.appRows.isEmpty {
                InsetGroup {
                    ForEach(page.appRows) { LargeItemRowView(model: model, ui: ui, row: $0, showsOrganize: false) }
                }
            }
            if let unlisted = page.unlistedRow {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "folder.fill").font(.title2).foregroundStyle(.secondary)
                        .frame(width: 28).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unlisted.title).font(.body.weight(.medium))
                        Text(unlisted.note).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(UICopy.showInFinder) { model.reveal(unlisted.revealURL) }.controlSize(.small)
                    Text(unlisted.sizeText).font(.body.weight(.semibold)).monospacedDigit()
                        .frame(minWidth: 72, alignment: .trailing)
                }
                .card(padding: 14)
            }
            if !page.outsideLines.isEmpty {
                if let heading = page.outsideHeading { SectionHeading(title: heading) }
                InsetGroup {
                    ForEach(page.outsideLines) { OutsideLineView(model: model, line: $0) }
                }
            }
            if !page.largeItems.isEmpty {
                SectionHeading(title: UICopy.largeHeading, subtitle: UICopy.largeSubtitle)
                InsetGroup {
                    ForEach(page.largeItems) { LargeItemRowView(model: model, ui: ui, row: $0) }
                }
            }
        }
        .sheet(item: $appReview, onDismiss: {
            if let appConfirmation { ui.confirm = appConfirmation }
            appConfirmation = nil
        }) { mode in
            ApplicationCleanupSheet(removal: model.removal, mode: mode, cancel: { appReview = nil }) { summary in
                appConfirmation = summary
                appReview = nil
            }
        }
    }
}

/// A read-only line for a folder outside home or another account: no checkbox, nothing to remove.
struct OutsideLineView: View {
    let model: AppModel
    let line: OutsideLine

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: line.isAccount ? "person.crop.circle" : "folder.fill")
                .font(.title2).foregroundStyle(.secondary)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title).font(.body.weight(.medium))
                if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            if let url = line.revealURL {
                Button(UICopy.showInFinder) { model.reveal(url) }.controlSize(.small)
            }
            if let size = line.sizeText {
                Text(size).font(.body.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 72, alignment: .trailing)
            }
        }
        .groupRow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.accessibilityLabel)
    }
}
