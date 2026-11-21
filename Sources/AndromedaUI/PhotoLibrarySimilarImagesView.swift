import AppKit
import AndromedaAppModel
import AndromedaCore
import SwiftUI

struct PhotoLibrarySimilarImagesView: View {
    @State private var outcome: PhotoLibraryReview.Outcome?
    @State private var control: ScanControl?
    @State private var scanTask: Task<Void, Never>?
    @State private var selections: [String: Set<String>] = [:]
    @State private var review: RemovalReview?
    @State private var isMoving = false
    @State private var receipt: String?

    private struct RemovalReview: Identifiable {
        var id: String { plan.selected[0].id }
        let plan: PhotoLibraryReview.RemovalPlan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Andromeda compares photos available on this Mac.")
                    .foregroundStyle(.secondary)
                Spacer()
                if isMoving {
                    ProgressView().controlSize(.small)
                    Text("Moving selected photos…")
                } else if let control {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { control.cancel() }
                } else {
                    Button(outcome == nil ? "Scan Photos Library" : "Scan Again", action: scan)
                        .buttonStyle(.borderedProminent)
                }
            }
            .card()
            if let receipt {
                HStack {
                    Text(receipt).foregroundStyle(.secondary)
                    Spacer()
                    openPhotosButton
                }
                .card()
            }
            if let outcome { content(outcome) }
        }
        .sheet(item: $review) { review in
            reviewMove(review.plan)
        }
        .onDisappear {
            control?.cancel()
            scanTask?.cancel()
            control = nil
            scanTask = nil
        }
    }

    private func scan() {
        guard control == nil, !isMoving else { return }
        let current = ScanControl { _ in }
        control = current
        outcome = nil
        receipt = nil
        selections.removeAll()
        scanTask = Task {
            let result = await PhotoLibraryReview.scan(control: current)
            guard !Task.isCancelled, control === current else { return }
            outcome = result
            control = nil
            scanTask = nil
        }
    }

    @ViewBuilder
    private func content(_ outcome: PhotoLibraryReview.Outcome) -> some View {
        switch outcome {
        case .done(let result):
            results(result)
        case .cancelled:
            EmptyState(title: "Scan cancelled", symbol: "photo.stack", message: "Scan again to review the library.")
        case .accessDenied:
            EmptyState(title: "Photos access is off", symbol: "lock",
                       message: "Allow Andromeda in System Settings › Privacy & Security › Photos, then scan again.")
        case .restricted:
            EmptyState(title: "Photos access is restricted", symbol: "lock",
                       message: "This Mac currently restricts access to the Photos library.")
        case .unavailable:
            EmptyState(title: "Photos library unavailable", symbol: "photo.stack",
                       message: "Open Photos and check your System Photo Library, then scan again.")
        case .accessChanged:
            EmptyState(title: "Photos access changed", symbol: "lock",
                       message: "Scan again to review the photos currently shared with Andromeda.")
        }
    }

    @ViewBuilder
    private func results(_ result: PhotoLibraryReview.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(result.checkedCount) photos checked").font(.headline)
                Spacer()
                openPhotosButton
            }
            if result.limitedAccess {
                Text("The scan covers the photos you shared with Andromeda.")
            }
            if result.limitReached {
                Text("The scan reached its \(SimilarImageScanner.maximumLibraryPhotos)-photo limit.")
            }
            if result.unavailableCount > 0 {
                Text("\(result.unavailableCount) photos couldn’t be checked with locally available previews.")
            }
            if result.previewRequestsStalled {
                Text("Photos stopped responding to preview requests. These results cover the photos checked so far.")
            }
        }
        .foregroundStyle(.secondary)
        .card()

        if result.groups.isEmpty {
            EmptyState(title: "No similar photos found", symbol: "photo.stack",
                       message: "Andromeda didn’t find matching groups in the photos it checked.")
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(result.groups) { group in
                    groupCard(group)
                }
            }
        }
    }

    @ViewBuilder
    private var openPhotosButton: some View {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            Button("Open Photos") { NSWorkspace.shared.open(app) }
        }
    }

    private func groupCard(_ group: SimilarImageScanner.LibraryGroup) -> some View {
        let selected = selections[group.id, default: []]
        let suggested = Set(group.photos.dropFirst().map(\.id))
        let plan = PhotoLibraryReview.makeRemovalPlan(from: group, selectedIDs: selected)
        let selectable = PhotoLibraryReview.makeRemovalPlan(from: group, selectedIDs: suggested) != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(group.photos.count) similar photos").font(.headline)
                Spacer()
                if selectable {
                    Button("Keep Highest Resolution") { selections[group.id] = suggested }
                        .disabled(isMoving)
                    Button("Review Move…") {
                        if let plan { review = RemovalReview(plan: plan) }
                    }
                    .disabled(plan == nil || isMoving)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 124, maximum: 180))], spacing: 12) {
                ForEach(group.photos) { photo in
                    VStack(alignment: .leading, spacing: 4) {
                        photoTile(photo)
                        if selectable {
                            Toggle("Select \(photo.name)", isOn: selection(for: photo.id, in: group))
                                .labelsHidden()
                                .disabled(isMoving || (!selected.contains(photo.id) && selected.count == group.photos.count - 1))
                        }
                    }
                }
            }
        }
        .card()
    }

    private func photoTile(_ photo: SimilarImageScanner.LibraryPhoto) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let image = NSImage(data: photo.preview) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 112)
                    .accessibilityHidden(true)
            }
            Text(photo.name).lineLimit(1).truncationMode(.middle).help(photo.name)
            Text("\(photo.width) × \(photo.height)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func selection(for photoID: String, in group: SimilarImageScanner.LibraryGroup) -> Binding<Bool> {
        Binding {
            selections[group.id, default: []].contains(photoID)
        } set: { enabled in
            var selected = selections[group.id, default: []]
            if enabled {
                guard selected.count < group.photos.count - 1 else { return }
                selected.insert(photoID)
            } else {
                selected.remove(photoID)
            }
            selections[group.id] = selected
        }
    }

    private func reviewMove(_ plan: PhotoLibraryReview.RemovalPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Move selected photos?", symbol: "photo.stack", tint: .orange)
            Text("Photos will move your selection to Recently Deleted. You can recover the photos there. This change syncs if you use iCloud Photos.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Move \(plan.selected.count) photos").font(.headline)
                    ForEach(plan.selected) { photo in
                        HStack {
                            if let image = NSImage(data: photo.preview) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 40, height: 32)
                                    .accessibilityHidden(true)
                            }
                            Text(photo.name)
                            Spacer()
                            Text("\(photo.width) × \(photo.height)").foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Text("Keep \(plan.retained.count) photos").font(.headline)
                    ForEach(plan.retained) { photo in Text(photo.name) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 245)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { review = nil }
                Button("Move to Recently Deleted", role: .destructive) { move(plan) }
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func move(_ plan: PhotoLibraryReview.RemovalPlan) {
        guard !isMoving else { return }
        review = nil
        isMoving = true
        receipt = nil
        Task {
            switch await PhotoLibraryReview.remove(plan) {
            case .moved(let count):
                receipt = "Moved \(count) photos. Recover them in Photos › Recently Deleted."
                outcome = nil
            case .libraryChanged:
                receipt = "The group changed. Scan again before moving any photos."
                outcome = nil
            case .accessUnavailable:
                receipt = "Photos access is unavailable. Check System Settings and scan again."
                outcome = nil
            case .cancelled:
                receipt = "The move was cancelled."
            case .failed:
                receipt = "Photos couldn’t complete the move. Try again."
            }
            if outcome == nil { selections.removeAll() }
            isMoving = false
        }
    }
}
