import AppKit
import AndromedaAppModel
import AndromedaCore
import SwiftUI

struct SimilarImageResults: View {
    enum FileAction {
        case preview, reveal
    }

    let result: SimilarImageScanner.Result
    let hiddenIdentifiers: Set<Data>
    @Binding var search: String
    @Binding var order: SimilarImageScanner.ReviewOrder
    @Binding var selections: [URL: Set<URL>]
    let reviewDisabled: Bool
    let review: (SimilarImageScanner.Group, Set<URL>) -> Void
    let hide: (SimilarImageScanner.Group) -> Void
    let open: (SimilarImageScanner.Photo, FileAction) -> Void

    var body: some View {
        Text("\(result.checkedCount.formatted()) images checked")
            .foregroundStyle(.secondary)
        if result.limitReached {
            Label("This scan reached its image limit. Choose a smaller folder to check more of its contents.",
                  systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
        if result.skippedCount > 0 {
            Text("Some items were unavailable or unsupported and couldn’t be checked.")
                .foregroundStyle(.secondary)
        }
        if result.groups.isEmpty {
            EmptyState(title: "No similar images found", symbol: "photo.on.rectangle",
                       message: "Add another folder to compare its images with this scan.")
        } else {
            let groups = result.groupsForReview(search: search, excluding: hiddenIdentifiers, order: order)
            TextField("Search similar images by name or path", text: $search)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Sort Groups", selection: $order) {
                    ForEach(SimilarImageScanner.ReviewOrder.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                Spacer()
            }
            if result.groups.allSatisfy({ hiddenIdentifiers.contains($0.reviewIdentifier) }) {
                Label("All similar image groups from this scan are hidden", systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
                    .card()
            } else if groups.isEmpty {
                Label("No similar image groups match this search", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .card()
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        SimilarImageGroup(group: group, reviewDisabled: reviewDisabled,
                                          review: { review(group, $0) }, hide: { hide(group) }, open: open,
                                          selected: Binding(
                                              get: { selections[group.id, default: []] },
                                              set: { selections[group.id] = $0 }
                                          ))
                    }
                }
            }
        }
    }
}

private struct SimilarImageGroup: View {
    let group: SimilarImageScanner.Group
    let reviewDisabled: Bool
    let review: (Set<URL>) -> Void
    let hide: () -> Void
    let open: (SimilarImageScanner.Photo, SimilarImageResults.FileAction) -> Void
    @Binding var selected: Set<URL>
    @State private var selectionTask: Task<Void, Never>?
    @State private var keeperUnavailable = false

    private var selectionDisabled: Bool { reviewDisabled || selectionTask != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(group.photos.count) similar images")
                    .font(.headline)
                Text("\(ByteFormat.string(group.totalBytes)) total")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Hide Group", action: hide).disabled(selectionDisabled)
                if !group.trashCandidates.isEmpty {
                    Menu("Select") {
                        Button("Keep Highest Resolution", action: selectKeepingHighestResolution)
                            .disabled(!group.trashCandidates.contains { $0 != group.id })
                        Button("Clear Selection") { selected.removeAll() }
                            .disabled(selected.isEmpty)
                    }
                    .disabled(selectionDisabled)
                    Button("Review Trash Move…") { review(selected) }
                        .disabled(selected.isEmpty || selectionDisabled)
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(group.photos) { photo in
                        let canTrash = group.trashCandidates.contains(photo.url)
                        SimilarImageCard(photo: photo, selection: canTrash ? selection(for: photo.url) : nil,
                                         selectionDisabled: selectionDisabled || (!selected.contains(photo.url)
                                             && selected.count >= group.photos.count - 1)) { open(photo, $0) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .card()
        .alert("Photo unavailable", isPresented: $keeperUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The highest-resolution photo may have moved or changed. Scan again to refresh the group.")
        }
        .onDisappear {
            selectionTask?.cancel()
            selectionTask = nil
        }
    }

    private func selectKeepingHighestResolution() {
        guard !selectionDisabled else { return }
        let group = group
        selectionTask = Task {
            let proposed = try? await BackgroundWork.run("andromeda.duplicates.choose-keeper") {
                group.selectionKeepingHighestResolution()
            }
            guard !Task.isCancelled else { return }
            selectionTask = nil
            if let proposed {
                selected = proposed
            } else {
                keeperUnavailable = true
            }
        }
    }

    private func selection(for url: URL) -> Binding<Bool> {
        Binding(get: { selected.contains(url) }, set: { checked in
            if checked, selected.count < group.photos.count - 1 {
                selected.insert(url)
            } else if !checked {
                selected.remove(url)
            }
        })
    }
}

private extension SimilarImageScanner.ReviewOrder {
    var title: String {
        switch self {
        case .scanOrder: "Scan Order"
        case .largest: "Largest Total Size"
        case .smallest: "Smallest Total Size"
        case .nameAscending: "Name A–Z"
        case .nameDescending: "Name Z–A"
        case .newest: "Most Recently Modified"
        case .oldest: "Least Recently Modified"
        }
    }
}

struct SimilarImageCard: View {
    let photo: SimilarImageScanner.Photo
    var selection: Binding<Bool>? = nil
    var selectionDisabled = false
    let open: (SimilarImageResults.FileAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                open(.preview)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    if let image = NSImage(data: photo.preview) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(width: 152, height: 116)
                .clipShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(photo.url.lastPathComponent)")

            Text(photo.url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(photo.url.path)
            Text("\(photo.width) × \(photo.height) · \(ByteFormat.string(photo.bytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Show in Finder") { open(.reveal) }
                .buttonStyle(.link)
                .accessibilityLabel("Show \(photo.url.lastPathComponent) in Finder")
            if let selection {
                Toggle("Select for Trash", isOn: selection)
                    .toggleStyle(.checkbox)
                    .disabled(selectionDisabled)
                    .accessibilityLabel("Select \(photo.url.path) for Trash")
            }
        }
        .frame(width: 152, alignment: .leading)
    }
}
