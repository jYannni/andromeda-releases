import CoreGraphics
import Darwin
import AndromedaCore
import AndromedaOrganize
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct CatalogPhotoDetails: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let camera: String?
    public let lens: String?
    public let exposureSeconds: Double?
    public let aperture: Double?
    public let iso: Int?
    public let focalLength: Double?

    fileprivate init?(_ properties: [CFString: Any]) {
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let make = Self.label(tiff[kCGImagePropertyTIFFMake])
        let model = Self.label(tiff[kCGImagePropertyTIFFModel])
        if let make, let model, !model.localizedStandardContains(make) { camera = make + " " + model }
        else { camera = model ?? make }
        lens = Self.label(exif[kCGImagePropertyExifLensModel])
        exposureSeconds = Self.positive(exif[kCGImagePropertyExifExposureTime])
        aperture = Self.positive(exif[kCGImagePropertyExifFNumber])
        let ratings = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int]
        let speed = (exif[kCGImagePropertyExifISOSpeed] as? Int) ?? ratings?.first
        iso = speed.flatMap { $0 > 0 ? $0 : nil }
        focalLength = Self.positive(exif[kCGImagePropertyExifFocalLength])
    }

    private static func label(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.utf8.count <= 160,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return text
    }

    private static func positive(_ value: Any?) -> Double? {
        guard let number = value as? Double, number.isFinite, number > 0 else { return nil }
        return number
    }
}

public struct SavedCatalogPreview: Equatable, Sendable {
    public let jpeg: Data
    public let photoDetails: CatalogPhotoDetails?
    public let videoDetails: CatalogVideoDetails?
}

enum CatalogImagePreview {
    static let maxBytes = 128 * 1024
    static let catalogBudget = 32 * 1024 * 1024
    static let maxAttempts = 2_000
    static let maxDetailsBytes = 2_048
    private static let sourceLimit = 24 * 1024 * 1024
    private static let thumbnailSize = 256
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp"]

    static func isPDF(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "pdf"
    }

    static func supports(_ path: String, includePDFs: Bool) -> Bool {
        if includePDFs, isPDF(path) { return true }
        guard let dot = path.lastIndex(of: ".") else { return false }
        return extensions.contains(path[path.index(after: dot)...].lowercased())
    }

    static func make(at path: String, identity: FileIdentity, modified: Date, control: ScanControl) -> SavedCatalogPreview? {
        var initial = stat()
        guard lstat(path, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_flags & UInt32(SF_DATALESS) == 0,
              FileIdentity(dev: initial.st_dev, ino: initial.st_ino) == identity else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_flags & UInt32(SF_DATALESS) == 0, before.st_size > 0, before.st_size <= sourceLimit,
              FileIdentity(dev: before.st_dev, ino: before.st_ino) == identity,
              Date(timeIntervalSince1970: Double(before.st_mtimespec.tv_sec)
                   + Double(before.st_mtimespec.tv_nsec) / 1e9) == modified,
              !control.isCancelled else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let bytes = try? file.read(upToCount: Int(before.st_size)), bytes.count == before.st_size,
              !control.isCancelled else { return nil }
        var details: CatalogPhotoDetails?
        let image = isPDF(path) ? pdfThumbnail(bytes) : DocumentRaster.image(bytes, maximumDimension: thumbnailSize) { properties in
            details = CatalogPhotoDetails(properties)
        }
        guard !control.isCancelled, let image, let preview = jpeg(image) else { return nil }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              FileIdentity(path: path) == identity else { return nil }
        return SavedCatalogPreview(jpeg: preview, photoDetails: details, videoDetails: nil)
    }

    private static func pdfThumbnail(_ bytes: Data) -> CGImage? {
        guard bytes.starts(with: "%PDF-".utf8),
              let provider = CGDataProvider(data: bytes as CFData),
              let document = CGPDFDocument(provider), !document.isEncrypted,
              let page = document.page(at: 1) else { return nil }
        return DocumentRaster.pdfPage(page, maximumDimension: thumbnailSize)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination), result.length <= maxBytes else { return nil }
        return result as Data
    }
}
