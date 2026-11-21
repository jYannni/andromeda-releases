import AVFoundation
import Darwin
import AndromedaCore
import AndromedaOrganize
import Foundation

public struct CatalogVideoDetails: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let codec: String?
    public let frameRate: Double?
    public let durationSeconds: Double?
}

enum CatalogVideoPreview {
    private static let extensions: Set<String> = ["mov", "mp4", "m4v"]
    private static let maxFrameAttempts = 128
    static let maxMetadataAttempts = 2_000

    struct Capture: Sendable {
        var details: [String: CatalogVideoDetails] = [:]
        var frames: [String: SavedCatalogPreview] = [:]
    }

    private struct Candidate: Sendable {
        let relativePath: String
        let identity: FileIdentity
        let modified: Date
    }

    static func supports(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func capture(_ snapshot: StorageBrowser.CatalogSnapshot, drive: ExternalVolume,
                        control: ScanControl) async throws -> Capture {
        let candidates = try await BackgroundWork.run("andromeda.drive-catalog.video-candidates", qos: .utility) {
            var candidates: [Candidate] = []
            try snapshot.forEachEntry { path, folder, _, modified, identity in
                if control.isCancelled { throw CancellationError() }
                guard candidates.count < maxMetadataAttempts, !folder, let identity, let modified, supports(path) else { return }
                candidates.append(Candidate(relativePath: path, identity: identity, modified: modified))
            }
            return candidates
        }
        guard !candidates.isEmpty else { return Capture() }
        control.entry("Saving video details and previews")
        control.flush()
        let root = SafetyGuard.withoutSystemPathAlias(drive.url.standardizedFileURL.path)
        var result = Capture()
        for (index, candidate) in candidates.enumerated() {
            if control.isCancelled || Task.isCancelled { throw CancellationError() }
            let path = root + "/" + candidate.relativePath
            if let (details, jpeg) = try? await make(path: path, candidate: candidate,
                                                    includeFrame: index < maxFrameAttempts, control: control) {
                result.details[candidate.relativePath] = details
                if let jpeg {
                    result.frames[candidate.relativePath] = .init(jpeg: jpeg, photoDetails: nil, videoDetails: details)
                }
            }
            control.file(bytes: 0)
        }
        if control.isCancelled || Task.isCancelled { throw CancellationError() }
        return result
    }

    private static func make(path: String, candidate: Candidate, includeFrame: Bool, control: ScanControl)
        async throws -> (CatalogVideoDetails, Data?)? {
        var initial = stat()
        guard lstat(path, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_flags & UInt32(SF_DATALESS) == 0,
              FileIdentity(dev: initial.st_dev, ino: initial.st_ino) == candidate.identity else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0,
              before.st_flags & UInt32(SF_DATALESS) == 0,
              FileIdentity(dev: before.st_dev, ino: before.st_ino) == candidate.identity,
              date(before.st_mtimespec) == candidate.modified else { return nil }

        let asset = AVURLAsset(url: URL(fileURLWithPath: path), options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var mainTrack: AVAssetTrack?
        for track in tracks where try await track.load(.isEnabled) {
            mainTrack = track
            break
        }
        guard let track = mainTrack, !control.isCancelled else { return nil }
        let (size, transform, formats, frameRate) = try await track.load(
            .naturalSize, .preferredTransform, .formatDescriptions, .nominalFrameRate)
        let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
        guard (1...65_536).contains(bounds.width), (1...65_536).contains(bounds.height) else { return nil }
        let duration = try await asset.load(.duration).seconds
        guard !control.isCancelled else { return nil }
        var jpeg: Data?
        if includeFrame {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 256, height: 256)
            generator.appliesPreferredTrackTransform = true
            if let frame = try? await generator.image(at: .zero) { jpeg = CatalogImagePreview.jpeg(frame.image) }
        }
        let details = CatalogVideoDetails(
            width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded()),
            codec: formats.first.map(CMFormatDescriptionGetMediaSubType).flatMap(codec),
            frameRate: frameRate.isFinite && frameRate > 0 ? Double(frameRate) : nil,
            durationSeconds: duration.isFinite && duration > 0 ? duration : nil)
        var after = stat()
        guard !control.isCancelled, !Task.isCancelled, fstat(fd, &after) == 0, after.st_size == before.st_size,
              same(after.st_mtimespec, before.st_mtimespec), same(after.st_ctimespec, before.st_ctimespec),
              FileIdentity(path: path) == candidate.identity else { return nil }
        return (details, jpeg)
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
    }

    private static func same(_ a: timespec, _ b: timespec) -> Bool {
        a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec
    }

    private static func codec(_ code: FourCharCode) -> String? {
        switch code {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_AppleProRes422: return "Apple ProRes 422"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
            guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
