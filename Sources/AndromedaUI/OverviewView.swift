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
        if !o.quickWins.isEmpty {
            cleanupSuggestions(o.quickWins)
        }
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
            // Its own row, not a quick win (ruling P8): it opens the Cloud view, where the hand-off is.
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
            SectionHeading(title: UICopy.cardsHeading)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(o.cards) { ExplainerCardView(card: $0) }
            }
        }
        if !o.couldntCheck.isEmpty {
            SectionHeading(title: Copy.Overview.couldntCheckHeading)
            InsetGroup {
                ForEach(o.couldntCheck) { ItemRowView(model: model, ui: ui, row: $0) }
            }
        }
    }

    private func cleanupSuggestions(_ rows: [ItemRow]) -> some View {
        let selection = model.removal.selected
        let visibleSelection = selection.intersection(rows.map(\.id))
        let selectedElsewhere = selection.count - visibleSelection.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                SectionHeading(title: UICopy.quickWinsTitle, subtitle: UICopy.quickWinsSubtitle)
                Spacer()
                Button(visibleSelection.isEmpty ? "Review Selected" : Copy.Confirm.review(visibleSelection.count)) {
                    reviewCleanupSuggestions(rows)
                }
                .buttonStyle(.borderedProminent)
                .disabled(visibleSelection.isEmpty || !model.removal.canEditSelection || model.removal.removalDisabledReason != nil)
            }
            InsetGroup {
                ForEach(rows) { ItemRowView(model: model, ui: ui, row: $0, bucketTag: bucketTag(for: $0)) }
            }
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

    func reviewCleanupSuggestions(_ rows: [ItemRow]) {
        let ids = model.removal.selected.intersection(rows.map(\.id))
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
