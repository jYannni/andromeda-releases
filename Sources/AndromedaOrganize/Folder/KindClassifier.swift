import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The kind of file a folder-organize plan sorts into. Local reads only.
public enum Kind: String, CaseIterable, Sendable, Codable {
    case documents, spreadsheets, images, screenshots, videos, archives, installers, code, other

    public var folderName: String {
        switch self {
        case .documents: "Documents"
        case .spreadsheets: "Spreadsheets"
        case .images: "Images"
        case .screenshots: "Screenshots"
        case .videos: "Videos"
        case .archives: "Archives"
        case .installers: "Installers"
        case .code: "Code"
        case .other: "Other"
        }
    }
}

/// Classifies a file into a `Kind` and reads when a picture was taken.
public struct KindClassifier {
    /// Read-only after init; DateFormatter.date(from:) is thread-safe.
    nonisolated(unsafe) private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private let isScreenCapture: (URL) -> Bool

    public init(isScreenCapture: @escaping (URL) -> Bool = KindClassifier.liveIsScreenCapture) {
        self.isScreenCapture = isScreenCapture
    }

    /// nil when the type is unknown or dynamic; the planner sends those to Unsorted.
    public func kind(of url: URL) -> Kind? {
        Self.classify(contentType(of: url), screenshot: isScreenshot(url))
    }

    /// Watched folders can match file kinds without opening the file or querying Spotlight.
    static func kind(named name: String) -> Kind? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return classify(UTType(filenameExtension: ext), screenshot: hasScreenshotName(name))
    }

    /// Classify saved filenames without opening the file. Images include screenshots.
    public static func kind(forExtension extensionName: String) -> Kind? {
        guard !extensionName.isEmpty else { return nil }
        return classify(UTType(filenameExtension: extensionName), screenshot: false)
    }

    private static func classify(_ contentType: UTType?, screenshot: @autoclosure () -> Bool) -> Kind? {
        guard let type = contentType, !type.identifier.hasPrefix("dyn.") else { return nil }
        if type.conforms(to: UTType("com.apple.disk-image") ?? .diskImage)
            || type.conforms(to: UTType("com.apple.installer-package-archive") ?? .package)
        {
            return .installers
        }
        if type.conforms(to: .image) { return screenshot() ? .screenshots : .images }
        if type.conforms(to: .movie) { return .videos }
        if type.conforms(to: .archive) { return .archives }
        // CSV/TSV are plain text to UTType; people expect them with their spreadsheets (ruling R-C18).
        if type.conforms(to: .spreadsheet) || type.conforms(to: .commaSeparatedText)
            || type.conforms(to: .tabSeparatedText)
        {
            return .spreadsheets
        }
        if type.conforms(to: .sourceCode) { return .code }
        if type.conforms(to: .audio) { return .other }
        if type.conforms(to: .content) || type.conforms(to: .compositeContent) || type.conforms(to: .pdf) {
            return .documents
        }
        return .other
    }

    /// EXIF DateTimeOriginal (no time zone, read in the current one); a screenshot's creation date.
    public func dateTaken(of url: URL) -> Date? {
        if contentType(of: url)?.conforms(to: .image) == true, isScreenshot(url) {
            return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        return Self.exifFormatter.date(from: text)
    }

    private func contentType(of url: URL) -> UTType? {
        if let t = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType { return t }
        return url.pathExtension.isEmpty ? nil : UTType(filenameExtension: url.pathExtension)
    }

    private func isScreenshot(_ url: URL) -> Bool {
        Self.hasScreenshotName(url.lastPathComponent) || isScreenCapture(url)
    }

    /// `Screenshot YYYY-MM-DD at …`
    static func hasScreenshotName(_ name: String) -> Bool {
        name.range(of: #"^Screenshot \d{4}-\d{2}-\d{2} at "#, options: .regularExpression) != nil
    }

    public static func liveIsScreenCapture(_ url: URL) -> Bool {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
            let v = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString)
        else { return false }
        return (v as? NSNumber)?.boolValue ?? false
    }
}
