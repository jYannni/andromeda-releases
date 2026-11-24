import AndromedaAppModel
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    let ui: UIState

    /// The page a row lives on, for the "Probably counted as" tag.
    private func bucketTag(for row: ItemRow) -> String? {
        model.pages.first { $0.rows.contains { $0.id == row.id } }.map { UICopy.probablyCounted($0.title) }
    }

    var body: some View {
        PageColumn {
            if let o = model.overview { content(o) }
        }
    }

    @ViewBuilder private func content(_ o: OverviewSummary) -> some View {
        PageHeader(title: UICopy.overviewTitle, subtitle: UICopy.overviewSubtitle, symbol: "chart.pie.fill") {
            Button("What changed?", systemImage: "arrow.up.arrow.down") { ui.destination = .scanComparison }
            Button(model.spacePlanner.builtAt == nil ? "Plan to Free Up Space" : "Resume Space Plan", systemImage: "target") {
                ui.destination = .spacePlan
            }
            .buttonStyle(.borderedProminent)
        }
        hero(o)
        cleanupSuggestions(o.cleanupSuggestions)
        if let text = o.unaccountedText {
            if let breakdown = o.spaceBreakdown {
                SpaceBreakdownView(model: model, title: text, breakdown: breakdown)
            } else { Text(text).font(.headline) }
        } else if let result = model.scan.lastResult, result.fda != .granted {
            Banner(text: "The scan used limited access. Full Disk Access lets Andromeda check protected folders.",
                   symbol: "lock", tint: .secondary, actionTitle: "Open Full Disk Access") {
                model.access.openSettings()
            }
        }
        if let text = o.onlineOnlyText {
            // Opens the Cloud view, where the hand-off is (ruling P8).
            Button { ui.destination = .cloud } label: {
                HStack(spacing: 12) {
                    SymbolTile(symbol: "icloud.and.arrow.down", tint: .blue, size: 30)
                    Text(text).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .card(padding: 12)
        }
        if !o.cards.isEmpty {
            DisclosureGroup {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(o.cards) { ExplainerCardView(card: $0) }
                }
                .padding(.top, 12)
            } label: {
                Text(UICopy.cardsHeading).font(.headline).accessibilityAddTraits(.isHeader)
            }
            .card()
        }
        if !o.couldntCheck.isEmpty {
            SectionHeading(title: Copy.Overview.couldntCheckHeading)
            InsetGroup {
                ForEach(o.couldntCheck) { ItemRowView(model: model, ui: ui, row: $0) }
            }
        }
    }

    @ViewBuilder private func cleanupSuggestions(_ suggestions: CleanupSuggestions) -> some View {
        if !suggestions.safe.isEmpty || !suggestions.withCare.isEmpty {
            let selectableRows = suggestions.selectableRows
            let selection = model.removal.selected
            let selectedSuggestions = selection.intersection(selectableRows.map(\.id))
            let selectedElsewhere = selection.count - selectedSuggestions.count
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    SectionHeading(title: UICopy.cleanupSuggestionsTitle, subtitle: UICopy.cleanupSuggestionsSubtitle)
                    Spacer()
                    if !selectableRows.isEmpty {
                        Button(selectedSuggestions.isEmpty ? "Review Selected" : Copy.Confirm.review(selectedSuggestions.count)) {
                            reviewCleanupSuggestions(suggestions)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedSuggestions.isEmpty || !model.removal.canEditSelection || model.removal.removalDisabledReason != nil)
                    }
                }
                cleanupGroup(suggestions.safe, title: Copy.Verdicts.safe, symbol: "checkmark.shield", tint: .green)
                cleanupGroup(suggestions.withCare, title: UICopy.cleanupReviewFirst, symbol: "exclamationmark.triangle", tint: .orange)
                if selectedElsewhere > 0, model.removal.removalDisabledReason == nil {
                    HStack {
                        Text(selectedElsewhere == 1 ? "1 more item selected in storage categories."
                             : "\(selectedElsewhere) more items selected in storage categories.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Review All Selected…") { ui.requestReview() }
                            .buttonStyle(.link)
                            .disabled(!model.removal.canEditSelection)
                    }
                }
            }
        }
    }

    @ViewBuilder private func cleanupGroup(_ sectors: [CleanupSector], title: String, symbol: String, tint: Color) -> some View {
        if !sectors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                }
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                InsetGroup {
                    ForEach(sectors) { cleanupSector($0) }
                }
            }
        }
    }

    private func cleanupSector(_ sector: CleanupSector) -> some View {
        let selected = sector.id.offersTrash ? sector.rows.count { model.removal.selected.contains($0.id) } : 0
        return DisclosureGroup {
            if sector.id == .downloads {
                HStack(spacing: 12) {
                    Text(UICopy.cleanupDownloadsDetail).foregroundStyle(.secondary)
                    Spacer()
                    Button(UICopy.showInFinder) {
                        model.reveal(model.scanHome.appendingPathComponent("Downloads", isDirectory: true))
                    }
                }
                .font(.callout)
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sector.rows) { row in
                        ItemRowView(model: model, ui: ui, row: row, bucketTag: bucketTag(for: row),
                                    showsVerdictBadge: false, showsSelection: sector.id.offersTrash)
                    }
                    if sector.id == .iosSimulators {
                        Button(UICopy.cleanupOpenDeveloper) { ui.destination = .page(.developer) }
                            .buttonStyle(.link)
                            .padding(.leading, 16)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: Style.cleanupSectorSymbol(sector.id))
                    .foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
                Text(Copy.Overview.cleanupSectorTitle(sector.id)).fontWeight(.semibold)
                Spacer(minLength: 12)
                if selected > 0 {
                    Text(UICopy.cleanupSelected(selected)).font(.caption).foregroundStyle(.secondary)
                }
                Text(sector.sizeText).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
        .groupRow()
    }

    func reviewCleanupSuggestions(_ suggestions: CleanupSuggestions) {
        let ids = model.removal.selected.intersection(suggestions.selectableRows.map(\.id))
        if let summary = model.removal.prepareConfirm(ids: ids) {
            ui.confirm = summary
        } else {
            ui.problem = "Scan again to review these cleanup suggestions."
        }
    }

    /// The headline: how full the disk is, then the bar of what fills it.
    @ViewBuilder private func hero(_ o: OverviewSummary) -> some View {
        if !o.bar.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                if let g = o.gauge {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(g.used).font(.system(size: 40, weight: .bold)).monospacedDigit()
                        Text(g.ofCapacity).font(.title3).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(g.available).font(.title3.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                } else if let used = o.usedText {
                    Text(used).font(.title2.weight(.semibold))
                }
                SpaceBarView(segments: o.bar, usedFraction: o.gauge?.usedFraction ?? 1, height: 30) { bucket in
                    // Same selection the sidebar makes; only categories that have a page can be opened.
                    if model.pages.contains(where: { $0.id == bucket }) { ui.destination = .browseCategory(bucket) }
                }
                if o.foundText != nil || o.allocationNote != nil || o.purgeableText != nil {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        if let found = o.foundText { Text(found).font(.callout.weight(.medium)) }
                        if let note = o.allocationNote { Text(note).font(.callout).foregroundStyle(.secondary) }
                        if let note = o.purgeableText { Text(note).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
            .card(padding: 22)
        } else if let note = o.totalsUnknownNote {
            Banner(text: note, symbol: "questionmark.circle.fill", tint: .secondary)
        }
    }
}
