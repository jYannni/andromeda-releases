import AppKit
import AndromedaCore
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Review images in the Mac's System Photo Library.
public enum PhotoLibraryReview {
    public struct Result: Sendable {
        public let groups: [SimilarImageScanner.LibraryGroup]
        public let checkedCount: Int
        public let unavailableCount: Int
        public let limitReached: Bool
        public let limitedAccess: Bool
        public let previewRequestsStalled: Bool
    }

    public enum Outcome: Sendable {
        case done(Result)
        case cancelled
        case accessDenied
        case restricted
        case unavailable
        case accessChanged
    }

    /// Call only when the user chooses to scan Apple Photos.
    public static func scan(control: ScanControl) async -> Outcome {
        await withTaskCancellationHandler {
            guard let status = await authorization(control: control), !control.isCancelled else { return .cancelled }
            switch status {
            case .authorized, .limited:
                return await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: readLibrary(limitedAccess: status == .limited, control: control))
                    }
                }
            case .denied: return .accessDenied
            case .restricted, .notDetermined: return .restricted
            @unknown default: return .restricted
            }
        } onCancel: {
            control.cancel()
        }
    }

    @MainActor private static func authorization(control: ScanControl) async -> PHAuthorizationStatus? {
        guard !control.isCancelled else { return nil }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status != .notDetermined { return status }
        // PhotoKit uses the same authorization level for reading and changing a library.
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    private static func readLibrary(limitedAccess: Bool, control: ScanControl) -> Outcome {
        guard !control.isCancelled else { return .cancelled }
        let library = PHPhotoLibrary.shared()
        guard library.unavailabilityReason == nil else { return .unavailable }
        let cap = SimilarImageScanner.maximumLibraryPhotos
        let fetch = PHFetchOptions()
        fetch.fetchLimit = cap + 1
        fetch.includeHiddenAssets = false
        fetch.includeAllBurstAssets = true
        fetch.includeAssetSourceTypes = .typeUserLibrary
        fetch.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: fetch)
        guard library.unavailabilityReason == nil else { return .unavailable }

        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact

        var photos: [SimilarImageScanner.LibraryPhoto] = []
        var unavailableCount = 0
        var consecutiveTimeouts = 0
        for index in 0..<min(assets.count, cap) {
            guard !control.isCancelled else { return .cancelled }
            let reading = autoreleasepool {
                libraryPhoto(assets.object(at: index), manager: manager, options: options, control: control)
            }
            guard !control.isCancelled else { return .cancelled }
            if let photo = reading.photo {
                photos.append(photo)
            } else {
                unavailableCount += 1
            }
            control.file(bytes: 0)
            consecutiveTimeouts = reading.timedOut ? consecutiveTimeouts + 1 : 0
            if consecutiveTimeouts == 3 { break }
        }

        guard !control.isCancelled,
              let groups = SimilarImageScanner.matchLibraryPhotos(photos, control: control),
              !control.isCancelled else { return .cancelled }
        guard library.unavailabilityReason == nil else { return .unavailable }
        let currentAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard currentAccess == (limitedAccess ? .limited : .authorized) else { return .accessChanged }
        if limitedAccess, !groups.isEmpty {
            let identifiers = groups.flatMap { $0.photos.map(\.id) }
            guard PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).count == identifiers.count
            else { return .accessChanged }
        }
        guard !control.isCancelled else { return .cancelled }
        control.flush()
        return .done(Result(groups: groups, checkedCount: photos.count, unavailableCount: unavailableCount,
                            limitReached: assets.count > cap && consecutiveTimeouts < 3, limitedAccess: limitedAccess,
                            previewRequestsStalled: consecutiveTimeouts == 3))
    }

    private static func libraryPhoto(
        _ asset: PHAsset, manager: PHImageManager, options: PHImageRequestOptions, control: ScanControl
    ) -> (photo: SimilarImageScanner.LibraryPhoto?, timedOut: Bool) {
        guard asset.pixelWidth >= 12, asset.pixelHeight >= 12 else { return (nil, false) }
        let request = PreviewRequest()
        let id = manager.requestImage(for: asset, targetSize: CGSize(width: 240, height: 240), contentMode: .aspectFit,
                                      options: options) { image, info in
            if info?[PHImageErrorKey] != nil || info?[PHImageCancelledKey] as? Bool == true
                || info?[PHImageResultIsInCloudKey] as? Bool == true {
                request.complete(nil)
            } else if info?[PHImageResultIsDegradedKey] as? Bool != true {
                request.complete(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
        let result = request.wait(control: control)
        if !result.finished { manager.cancelImageRequest(id) }
        guard let image = result.image, !control.isCancelled, let preview = jpegPreview(image)
        else { return (nil, !result.finished) }
        let photo = SimilarImageScanner.LibraryPhoto(id: asset.localIdentifier, name: photoName(for: asset), width: asset.pixelWidth,
                                                     height: asset.pixelHeight, creationDate: asset.creationDate,
                                                     modificationDate: asset.modificationDate,
                                                     preview: preview)
        return (photo, false)
    }

    static func photoName(for asset: PHAsset) -> String {
        PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo })?.originalFilename ?? "Photo"
    }

    private static func jpegPreview(_ image: CGImage) -> Data? {
        guard (12...256).contains(image.width), (12...256).contains(image.height) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 256 * 1_024 else { return nil }
        return data as Data
    }

    /// PhotoKit can deliver a result on another queue and can omit callbacks after cancellation.
    private final class PreviewRequest: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var completed = false
        private var image: CGImage?

        func complete(_ image: CGImage?) {
            lock.withLock {
                guard !completed else { return }
                completed = true
                self.image = image
                done.signal()
            }
        }

        func wait(control: ScanControl) -> (finished: Bool, image: CGImage?) {
            let deadline = DispatchTime.now() + .seconds(5)
            while !control.isCancelled, DispatchTime.now() < deadline {
                if done.wait(timeout: min(deadline, DispatchTime.now() + .milliseconds(100))) == .success {
                    return (true, lock.withLock { image })
                }
            }
            return (false, nil)
        }
    }
}
