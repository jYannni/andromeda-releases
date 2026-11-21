import AndromedaAppModel
import AndromedaCore
import AndromedaOrganize
import SwiftUI

/// Move to Cloud (§4.1). Pick one cloud folder, tick items, review. Nothing moves until the
/// review sheet's confirm button; the sheet's default is Cancel.
struct MoveToCloudView: View {
    let model: AppModel

    private var move: MoveToCloudModel { model.moveToCloud }
    private var flow: OrganizeFlow { model.organize }

    var body: some View {
        PageColumn {
            PageHeader(
                title: Copy.Organize.moveToCloudTitle, subtitle: Copy.Organize.moveToCloudSubtitle,
                symbol: "icloud.and.arrow.up.fill", tint: .cyan
            ) {
                if !move.ticked.isEmpty {
                    Button(Copy.Confirm.review(move.ticked.count)) { Task { await move.review() } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!move.canReview)
                }
            }
            if move.roots.isEmpty {
                EmptyState(title: UICopy.noCloudTitle, symbol: "icloud.slash", message: Copy.Organize.noCloudFolders)
            } else {
                destinationPicker
            }
            if let note = move.notSuggestedNote { Banner(text: note, symbol: "exclamationmark.triangle.fill", tint: .orange) }
            if move.isFinding {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.Organize.finding).foregroundStyle(.secondary)
                }
            } else if move.hasFound {
                if move.candidates.isEmpty {
                    Banner(text: Copy.Organize.nothingToSuggest, symbol: "checkmark.circle.fill", tint: .green)
                } else {
                    InsetGroup {
                        ForEach(move.candidates) { CandidateRowView(move: move, candidate: $0, home: model.scanHome) }
                    }
                }
                Button(Copy.Organize.findAgain) { Task { await move.findAgain() } }
            }
        }
        .task { await move.appear() }
        // A folder organize plan has its own page; only a move to cloud opens here.
        .sheet(isPresented: Binding(get: { flow.review != nil && flow.review?.folderName == nil }, set: { if !$0 { flow.cancel() } })) {
            if let review = flow.review, review.folderName == nil {
                OrganizeConfirmSheet(
                    review: review, isApplying: flow.isApplying, progress: flow.progress, onCancel: { flow.cancel() },
                    onExport: { json in Task { _ = await flow.exportPlan(json: json) } },
                    onConfirm: { [planID = review.plan.planID] in
                        Task { _ = await flow.apply(planID: planID); await move.findAgain() }
                    })
            }
        }
        .sheet(isPresented: Binding(get: { flow.receipt != nil && flow.receipt?.folderName == nil }, set: { if !$0 { flow.closeReceipt() } })) {
            if let receipt = flow.receipt, receipt.folderName == nil { OrganizeReceiptView(receipt: receipt) { flow.closeReceipt() } }
        }
    }

    private var destinationPicker: some View {
        HStack(spacing: 12) {
            if let provider = move.selectedRoot?.provider { ProviderIconView(provider: provider, size: 32) }
            Picker(Copy.Organize.destinationLabel, selection: Binding(
                get: { move.selectedRoot?.url },
                set: { url in if let root = move.roots.first(where: { $0.url == url }) { move.select(root) } }
            )) {
                ForEach(move.roots, id: \.url) { root in
                    Text(Copy.Organize.sectionTitle(root.provider, account: root.account)).tag(Optional(root.url))
                }
            }
            .fixedSize()
            Spacer()
        }
        .card(padding: 12)
    }
}

private struct CandidateRowView: View {
    let move: MoveToCloudModel
    let candidate: MoveCandidate
    let home: URL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(candidate.id.lastPathComponent, isOn: Binding(
                get: { move.ticked.contains(candidate.id) }, set: { _ in move.toggle(candidate.id) }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: FileIcon.image(for: candidate.id, revealable: true))
                .resizable().frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.id.lastPathComponent).font(.body.weight(.medium))
                Text(Copy.Scan.displayPath(candidate.id, home: home)).font(.caption).foregroundStyle(.secondary)
                Text(Copy.Organize.lastUse(candidate.lastUse)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Copy.Rows.uses(ByteFormat.string(candidate.usesBytes))).font(.body.weight(.semibold)).monospacedDigit()
                Text(candidate.freesAtLeast.map { Copy.Organize.frees(ByteFormat.string($0)) } ?? Copy.Organize.freesUnknown)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .groupRow()
    }
}
