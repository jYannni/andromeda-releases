import AndromedaAppModel
import AndromedaOrganize
import SwiftUI

struct FolderAutomationCopyReview: View {
    let automation: FolderAutomationModel
    let rule: FolderAutomationRule
    @Environment(\.dismiss) private var dismiss
    @State private var review: FolderAutomationModel.ReplayReview?
    @State private var selected: Set<String> = []
    @State private var problem: String?
    @State private var search = ""
    @State private var reload = 0
    @State private var reviewedRequest: ReviewRequest?

    private struct ReviewRequest: Equatable {
        let query: String
        let attempt: Int
    }

    private var request: ReviewRequest { ReviewRequest(query: search, attempt: reload) }

    var body: some View {
        let request = request
        let isCurrent = reviewedRequest == request
        let review = isCurrent ? self.review : nil
        let problem = isCurrent ? self.problem : nil
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "Reapply Copy Rule",
                        subtitle: "Select files to copy with this rule. You can undo copies in History.",
                        symbol: "document.on.document", tint: .indigo)
            TextField("Search eligible files", text: $search)
                .textFieldStyle(.roundedBorder)
            if !isCurrent {
                ProgressView("Checking previously processed files…")
                    .controlSize(.small)
                    .padding(.vertical, 8)
            } else if let review {
                if review.candidates.isEmpty {
                    Text(request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "No previously processed files are eligible under this rule right now."
                         : "No eligible files match your search.")
                        .padding(.vertical, 8)
                } else {
                    if review.totalCandidates > review.candidates.count {
                        Text("Showing \(review.candidates.count) of \(review.totalCandidates) eligible files. Narrow your search to find another file.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(review.candidates, id: \.id) { candidate in
                                candidateRow(candidate)
                            }
                        }
                        .padding(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                if problem != nil {
                    Button("Refresh Review") { reload += 1 }
                } else if isCurrent && !selected.isEmpty {
                    Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(review?.candidates.isEmpty == true ? "Close" : "Cancel", role: .cancel) { dismiss() }
                if review?.candidates.isEmpty == false {
                    Button("Copy Selected Files", action: apply)
                        .disabled(selected.isEmpty || problem != nil)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Palette.canvas)
        .task(id: request) { await loadReview(request) }
    }

    private func candidateRow(_ candidate: FolderAutomationModel.ReplayCandidate) -> some View {
        Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { checked in
            if checked { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
        })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: candidate.source.lastPathComponent).font(.headline)
                Text("From \(candidate.source.path)")
                Text("To \(candidate.destination.path)")
                if !candidate.addedTags.isEmpty {
                    Text("Adds Finder tags \(candidate.addedTags.joined(separator: ", "))")
                }
                if !candidate.removedTags.isEmpty {
                    Text("Removes Finder tags \(candidate.removedTags.joined(separator: ", "))")
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel("Select \(candidate.source.path)")
        .accessibilityHint(accessibilitySummary(candidate))
        .card()
    }

    private func accessibilitySummary(_ candidate: FolderAutomationModel.ReplayCandidate) -> String {
        var summary = "Copy to \(candidate.destination.path)."
        if !candidate.addedTags.isEmpty { summary += " Add Finder tags \(candidate.addedTags.joined(separator: ", "))." }
        if !candidate.removedTags.isEmpty { summary += " Remove Finder tags \(candidate.removedTags.joined(separator: ", "))." }
        return summary
    }

    private func loadReview(_ request: ReviewRequest) async {
        reviewedRequest = nil
        problem = nil
        review = nil
        selected = []
        if !request.query.isEmpty {
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
        }
        let result = await automation.reviewReplay(ruleID: rule.id, matching: request.query)
        guard !Task.isCancelled else { return }
        review = result
        reviewedRequest = request
        if result == nil {
            problem = "Andromeda couldn’t review previously processed files. Keep this folder paused and try again."
        }
    }

    private func apply() {
        guard let review, !selected.isEmpty, reviewedRequest == request else { return }
        if automation.reapply(review, selectedIDs: selected) {
            dismiss()
        } else {
            problem = "This review is out of date or the rule is unavailable. Refresh the review before trying again."
        }
    }
}
