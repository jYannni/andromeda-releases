import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum SimilarImageScanner {
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp"]
    private static let maximumFileSize = 32 * 1_048_576
    private static let maximumImages = 2_500
    public static let maximumLibraryPhotos = 2_500
    private static let maximumLibraryPreviewSide = 256
    private static let maximumLibraryPreviewBytes = 256 * 1024
    private static let sampleSide = 12

    public struct Photo: Identifiable, Sendable {
        public var id: URL { url }
        public var url: URL { candidate.url }
        public var bytes: Int64 { candidate.bytes }
        public let width: Int
        public let height: Int
        public let preview: Data
        let candidate: DuplicateScanner.Candidate
        let scanStat: stat

        public func isCurrent() -> Bool {
            StorageBrowser.canPreview(url, identity: candidate.identity, expectedSize: bytes, allowsAncestorLinks: false)
                && DuplicateScanner.stillMatches(candidate, scanStat)
        }
    }

    public struct Group: Identifiable, Sendable {
        public var id: URL { photos[0].url }
        public let photos: [Photo]
        public let trashCandidates: Set<URL>
        public let totalBytes: Int64
        public let latestModification: Date

        /// Includes every reviewed path and file revision so changed or newly grouped photos reappear.
        public let reviewIdentifier: Data

        init(photos: [Photo], trashCandidates: Set<URL>) {
            self.photos = photos
            self.trashCandidates = trashCandidates
            totalBytes = photos.reduce(0) { $0 + $1.bytes }
            latestModification = photos.map { photo in
                let time = photo.scanStat.st_mtimespec
                return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
            }.max() ?? .distantPast
            var hash = SHA256()
            for photo in photos.sorted(by: { $0.url.path < $1.url.path }) {
                let info = photo.scanStat
                let revision = [Int64(info.st_dev), Int64(bitPattern: info.st_ino), info.st_size,
                                Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                                Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
                hash.update(data: Data(photo.url.path.utf8))
                hash.update(data: Data([0]))
                for attribute in revision {
                    withUnsafeBytes(of: attribute.bigEndian) { hash.update(bufferPointer: $0) }
                }
            }
            reviewIdentifier = Data(hash.finalize())
        }

        /// The scanner places a highest-resolution photo first. A readable photo can be kept
        /// even when it is outside the locations eligible for Trash.
        public func selectionKeepingHighestResolution() -> Set<URL>? {
            guard let keeper = photos.first, keeper.isCurrent() else { return nil }
            return trashCandidates.subtracting([keeper.url])
        }
    }

    /// A Photos asset and its normalized JPEG thumbnail. The identifier belongs to the Photos library.
    public struct LibraryPhoto: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let width: Int
        public let height: Int
        public let creationDate: Date?
        public let modificationDate: Date?
        public let preview: Data

        public init(id: String, name: String, width: Int, height: Int, creationDate: Date?,
                    modificationDate: Date? = nil, preview: Data) {
            self.id = id
            self.name = name
            self.width = width
            self.height = height
            self.creationDate = creationDate
            self.modificationDate = modificationDate
            self.preview = preview
        }
    }

    public struct LibraryGroup: Identifiable, Sendable {
        public var id: String { photos[0].id }
        public let photos: [LibraryPhoto]
    }

    public enum ReviewOrder: CaseIterable, Hashable, Sendable {
        case scanOrder, largest, smallest, nameAscending, nameDescending, newest, oldest
    }

    public struct Result: Sendable {
        public let groups: [Group]
        public let checkedCount: Int
        public let skippedCount: Int
        public let limitReached: Bool

        public func groupsForReview(search: String, excluding hidden: Set<Data>, order: ReviewOrder) -> [Group] {
            let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let matching = groups.filter { group in
                !hidden.contains(group.reviewIdentifier)
                    && (term.isEmpty || group.photos.contains { $0.url.path.localizedStandardContains(term) })
            }
            switch order {
            case .scanOrder: return matching
            case .largest: return matching.sorted { $0.totalBytes > $1.totalBytes }
            case .smallest: return matching.sorted { $0.totalBytes < $1.totalBytes }
            case .nameAscending:
                return matching.sorted {
                    $0.id.lastPathComponent.localizedStandardCompare($1.id.lastPathComponent) == .orderedAscending
                }
            case .nameDescending:
                return matching.sorted {
                    $0.id.lastPathComponent.localizedStandardCompare($1.id.lastPathComponent) == .orderedDescending
                }
            case .newest: return matching.sorted { $0.latestModification > $1.latestModification }
            case .oldest: return matching.sorted { $0.latestModification < $1.latestModification }
            }
        }
    }

    private struct Sample {
        let pixels: [UInt8]
        let mean: [Int]
        let aspect: Double

        init?(image: CGImage, width: Int, height: Int) {
            guard let pixels = samplePixels(image) else { return nil }
            self.pixels = pixels
            aspect = Double(width) / Double(height)
            var sums = [0, 0, 0]
            for index in stride(from: 0, to: pixels.count, by: 4) {
                for channel in sums.indices { sums[channel] += Int(pixels[index + channel]) }
            }
            mean = sums.map { $0 / Self.pixelCount }
        }

        func resembles(_ other: Sample) -> Bool {
            guard abs(aspect - other.aspect) <= 0.03 * max(aspect, other.aspect),
                  abs(mean[0] - other.mean[0]) <= 14,
                  abs(mean[1] - other.mean[1]) <= 14,
                  abs(mean[2] - other.mean[2]) <= 14 else { return false }
            let pixelCount = Self.pixelCount
            var error = 0
            var changed = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let red = abs(Int(pixels[index]) - Int(other.pixels[index]))
                let green = abs(Int(pixels[index + 1]) - Int(other.pixels[index + 1]))
                let blue = abs(Int(pixels[index + 2]) - Int(other.pixels[index + 2]))
                error += red + green + blue
                if max(red, green, blue) > 34 { changed += 1 }
                if error > 30 * pixelCount || changed > pixelCount / 8 { return false }
            }
            return true
        }

        private static let pixelCount = sampleSide * sampleSide
    }

    public static func scan(
        _ scopes: [DuplicateScanner.Scope], env: ScanEnvironment, control: ScanControl
    ) -> Result? {
        var attempts = 0
        var unreadableImages = 0
        var samples: [(photo: Photo, sample: Sample)] = []
        let walk = DuplicateScanner.walkCandidates(scopes, env: env, control: control, includesFile: {
            extensions.contains($0.pathExtension.lowercased())
        }) { candidate in
            guard attempts < maximumImages else { return false }
            attempts += 1
            if let sample = autoreleasepool(invoking: { Self.sample(candidate, control: control) }) {
                samples.append(sample)
            } else {
                unreadableImages += 1
            }
            return !control.isCancelled
        }
        guard let walk, !control.isCancelled else { return nil }

        // Prefer the highest-resolution image as the first photo for review.
        samples.sort {
            let left = $0.photo.width * $0.photo.height
            let right = $1.photo.width * $1.photo.height
            return left == right ? $0.photo.url.path < $1.photo.url.path : left > right
        }
        guard let groups = matchingGroups(samples, control: control) else { return nil }
        let matches = groups.map { photos in
            let candidates = photos.filter { SimilarImageCleanup.canTrash($0, env: env) }.map(\.url)
            return Group(photos: photos, trashCandidates: Set(candidates))
        }
        guard !control.isCancelled else { return nil }
        return Result(groups: matches,
                      checkedCount: samples.count, skippedCount: walk.skipped + unreadableImages,
                      limitReached: walk.stoppedEarly)
    }

    /// Compares up to `maximumLibraryPhotos` entries. Skips unsupported or unreadable thumbnails.
    /// Returns nil when cancelled. Results are for reviewing Photos assets by their library identifiers.
    public static func matchLibraryPhotos(_ images: [LibraryPhoto], control: ScanControl) -> [LibraryGroup]? {
        var seenIDs: Set<String> = []
        var samples: [(photo: LibraryPhoto, sample: Sample)] = []
        for photo in images.prefix(maximumLibraryPhotos) {
            guard !control.isCancelled else { return nil }
            guard !photo.id.isEmpty, !seenIDs.contains(photo.id),
                  photo.width >= sampleSide, photo.height >= sampleSide, photo.width <= Int.max / photo.height,
                  let sample = autoreleasepool(invoking: { librarySample(photo.preview) }) else { continue }
            seenIDs.insert(photo.id)
            samples.append((photo, sample))
        }
        samples.sort {
            let left = $0.photo.width * $0.photo.height
            let right = $1.photo.width * $1.photo.height
            return left == right ? $0.photo.id < $1.photo.id : left > right
        }
        guard let groups = matchingGroups(samples, control: control) else { return nil }
        let result = groups.map { LibraryGroup(photos: $0) }
        return control.isCancelled ? nil : result
    }

    private static func matchingGroups<Photo>(
        _ samples: [(photo: Photo, sample: Sample)], control: ScanControl
    ) -> [[Photo]]? {
        var groups: [[(photo: Photo, sample: Sample)]] = []
        for entry in samples {
            guard !control.isCancelled else { return nil }
            // Check all group members so a sequence of weak matches cannot join unrelated endpoints.
            if let index = groups.firstIndex(where: { $0.allSatisfy { entry.sample.resembles($0.sample) } }) {
                groups[index].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups.filter { $0.count > 1 }.map { $0.map(\.photo) }
    }

    private static func librarySample(_ data: Data) -> Sample? {
        guard !data.isEmpty, data.count <= maximumLibraryPreviewBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), type as String == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (sampleSide...maximumLibraryPreviewSide).contains(width),
              (sampleSide...maximumLibraryPreviewSide).contains(height),
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // Photos supplies a thumbnail with the displayed orientation already applied.
        return Sample(image: image, width: width, height: height)
    }

    private static func sample(
        _ candidate: DuplicateScanner.Candidate, control: ScanControl
    ) -> (photo: Photo, sample: Sample)? {
        var initial = stat()
        guard candidate.bytes <= maximumFileSize, !control.isCancelled,
              lstat(candidate.url.path, &initial) == 0, DuplicateScanner.matches(candidate, initial) else { return nil }
        let fd = open(candidate.url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, DuplicateScanner.matches(candidate, before) else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? file.read(upToCount: Int(candidate.bytes)), data.count == candidate.bytes,
              !control.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= sampleSide, height >= sampleSide, width <= 80_000_000 / height else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128
        ]
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        let displayedWidth = rotated ? height : width
        let displayedHeight = rotated ? width : height
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let sample = Sample(image: thumbnail, width: displayedWidth, height: displayedHeight),
              let jpeg = preview(thumbnail),
              !control.isCancelled else { return nil }
        var after = stat()
        guard fstat(fd, &after) == 0, DuplicateScanner.matches(candidate, after),
              DuplicateScanner.unchanged(before, after),
              DuplicateScanner.stillMatches(candidate, before) else { return nil }

        let photo = Photo(width: displayedWidth, height: displayedHeight, preview: jpeg,
                          candidate: candidate, scanStat: after)
        return (photo, sample)
    }

    private static func samplePixels(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: sampleSide * sampleSide * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: sampleSide, height: sampleSide,
                                          bitsPerComponent: 8, bytesPerRow: sampleSide * 4, space: space,
                                          bitmapInfo: bitmap) else { return false }
            let bounds = CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(bounds)
            context.interpolationQuality = .high
            context.draw(image, in: bounds)
            return true
        }
        return drawn ? pixels : nil
    }

    private static func preview(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
