import AndromedaCore
import Foundation
import Photos
import Synchronization

extension PhotoLibraryReview {
    public enum RemovalOutcome: Sendable {
        case moved(Int)
        case libraryChanged
        case accessUnavailable
        case cancelled
        case failed
    }

    // Do not queue a previously confirmed plan behind another Photos transaction.
    private static let removalInProgress = Mutex(false)

    public static func remove(_ plan: RemovalPlan) async -> RemovalOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard !plan.selected.isEmpty, !plan.retained.isEmpty else { return .libraryChanged }
        guard removalInProgress.withLock({ inProgress in
            guard !inProgress else { return false }
            inProgress = true
            return true
        }) else { return .failed }
        defer { removalInProgress.withLock { $0 = false } }

        let transaction = RemovalTransaction()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .cancelled }
            let library = PHPhotoLibrary.shared()
            guard hasRemovalAccess(library) else { return .accessUnavailable }
            do {
                try await library.performChanges {
                    // Fetch fresh objects in the same block that submits the removal request.
                    guard transaction.isWaiting else { return }
                    guard hasRemovalAccess(library) else {
                        transaction.stop(.accessUnavailable)
                        return
                    }
                    guard let selected = currentSelection(for: plan) else {
                        transaction.stop(hasRemovalAccess(library) ? .libraryChanged : .accessUnavailable)
                        return
                    }
                    guard selected.allSatisfy({ $0.canPerform(.delete) }) else {
                        transaction.stop(.failed)
                        return
                    }
                    guard hasRemovalAccess(library) else {
                        transaction.stop(.accessUnavailable)
                        return
                    }
                    guard transaction.submit() else { return }
                    PHAssetChangeRequest.deleteAssets(selected as NSArray)
                }
                return transaction.outcome(ifSubmitted: .moved(plan.selected.count), otherwise: .failed)
            } catch {
                let outcome = response(to: error, library: library)
                return transaction.outcome(ifSubmitted: outcome, otherwise: outcome)
            }
        } onCancel: {
            transaction.stop(.cancelled)
        }
    }

    private static func hasRemovalAccess(_ library: PHPhotoLibrary) -> Bool {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return (access == .authorized || access == .limited) && library.unavailabilityReason == nil
    }

    private static func currentSelection(for plan: RemovalPlan) -> [PHAsset]? {
        let reviewed = plan.selected + plan.retained
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = true
        options.includeAssetSourceTypes = .typeUserLibrary
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: reviewed.map(\.id), options: options)
        guard assets.count == reviewed.count else { return nil }
        var byID: [String: PHAsset] = [:]
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            byID[asset.localIdentifier] = asset
        }
        for photo in reviewed {
            guard let asset = byID[photo.id], asset.mediaType == .image, !asset.isHidden,
                  asset.sourceType.contains(.typeUserLibrary),
                  asset.pixelWidth == photo.width, asset.pixelHeight == photo.height,
                  asset.creationDate == photo.creationDate, let revision = photo.modificationDate,
                  asset.modificationDate == revision, photoName(for: asset) == photo.name else { return nil }
        }
        return plan.selected.compactMap { byID[$0.id] }
    }

    private static func response(to error: Error, library: PHPhotoLibrary) -> RemovalOutcome {
        if let photoError = error as? PHPhotosError {
            switch photoError.code {
            case .userCancelled: return .cancelled
            case .identifierNotFound: return .libraryChanged
            case .accessRestricted, .accessUserDenied, .libraryVolumeOffline, .relinquishingLibraryBundleToWriter,
                 .switchingSystemPhotoLibrary, .libraryInFileProviderSyncRoot: return .accessUnavailable
            default: break
            }
        }
        if (error as? CocoaError)?.code == .userCancelled { return .cancelled }
        return hasRemovalAccess(library) ? .failed : .accessUnavailable
    }

    private final class RemovalTransaction: Sendable {
        private enum State: Sendable {
            case waiting
            case stopped(RemovalOutcome)
            case submitted
        }

        private let state = Mutex<State>(.waiting)

        var isWaiting: Bool {
            state.withLock {
                if case .waiting = $0 { return true }
                return false
            }
        }

        func stop(_ outcome: RemovalOutcome) {
            state.withLock { state in
                if case .waiting = state { state = .stopped(outcome) }
            }
        }

        func submit() -> Bool {
            state.withLock { state in
                guard case .waiting = state else { return false }
                state = .submitted
                return true
            }
        }

        func outcome(ifSubmitted: RemovalOutcome, otherwise: RemovalOutcome) -> RemovalOutcome {
            state.withLock { state in
                switch state {
                case .waiting: return otherwise
                case .stopped(let outcome): return outcome
                case .submitted: return ifSubmitted
                }
            }
        }
    }
}
