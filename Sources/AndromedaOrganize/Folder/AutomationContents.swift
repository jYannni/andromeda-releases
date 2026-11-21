import Darwin
import Foundation
import PDFKit
import Vision

public final class AutomationRecognitionCache: @unchecked Sendable {
    // NSCache supports concurrent lookup and eviction. Keys and values are immutable.
    private let results = NSCache<NSString, NSArray>()

    public init() {
        results.countLimit = 256
        results.totalCostLimit = 2 * 1_048_576
    }

    func text(for info: stat, extension ext: String, read: () -> [String]) -> [String] {
        let key = [
            String(info.st_dev), String(info.st_ino), String(info.st_size), ext,
            String(info.st_birthtimespec.tv_sec), String(info.st_birthtimespec.tv_nsec),
            String(info.st_mtimespec.tv_sec), String(info.st_mtimespec.tv_nsec),
            String(info.st_ctimespec.tv_sec), String(info.st_ctimespec.tv_nsec)
        ].joined(separator: ":") as NSString
        if let found = results.object(forKey: key) as? [String] { return found }
        let text = read()
        if !text.isEmpty {
            let bytes = text.reduce(0) { $0 + 2 * $1.utf16.count + 64 }
            results.setObject(text as NSArray, forKey: key, cost: bytes)
        }
        return text
    }
}

struct AutomationContents {
    private enum RecognitionInput {
        case image(Data)
        case pdf(PDFDocument, [Int])
    }

    private let sections: [String]
    private let complete: Bool
    private let recognitionInput: RecognitionInput?

    func contains(_ phrase: String) -> Bool? {
        if Self.contains(phrase, in: sections) { return true }
        return complete ? false : nil
    }

    static func contains(_ phrase: String, in sections: [String]) -> Bool {
        sections.contains { $0.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    func recognizeText() -> [String] {
        switch recognitionInput {
        case .image(let data):
            guard let image = DocumentRaster.image(data, maximumDimension: 2_048, singleFrame: true) else { return [] }
            return Self.recognize(image)
        case .pdf(let document, let pages):
            return pages.flatMap { index -> [String] in
                autoreleasepool {
                    guard let page = document.page(at: index)?.pageRef,
                          let image = DocumentRaster.pdfPage(page, maximumDimension: 2_048) else { return [] }
                    return Self.recognize(image)
                }
            }
        case nil:
            return []
        }
    }

    private static func recognize(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5 else { return nil }
            return candidate.string
        }
    }

    static func read(name: String, at url: URL, in directory: Int32, expected: stat, mayRecognizeText: Bool) -> Self? {
        let ext = url.pathExtension.lowercased()
        let isPDF = ext == "pdf"
        let isImage = mayRecognizeText && imageExtensions.contains(ext)
        guard isPDF || isImage || textExtensions.contains(ext) else { return nil }
        let byteLimit = (isPDF || isImage ? 16 : 4) * 1_048_576
        guard expected.st_size >= 0, expected.st_size <= byteLimit,
              !FolderPlanner.liveIsUbiquitous(url) else { return nil }

        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, matches(info, expected) else { return nil }

        let size = Int(expected.st_size)
        var data = Data(count: size)
        let finished = data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < size {
                let count = Darwin.read(fd, buffer.baseAddress?.advanced(by: offset), size - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard finished, fstat(fd, &info) == 0, matches(info, expected) else { return nil }
        if isPDF { return pdfContents(data, mayRecognizeText: mayRecognizeText) }
        if isImage { return Self(sections: [], complete: false, recognitionInput: .image(data)) }

        let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
            ? .utf16 : .utf8
        guard let text = String(data: data, encoding: encoding),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return Self(sections: [text], complete: true, recognitionInput: nil)
    }

    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "log", "json", "xml", "yaml", "yml"
    ]

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff"]

    private static func pdfContents(_ data: Data, mayRecognizeText: Bool) -> Self? {
        guard let document = PDFDocument(data: data), !document.isLocked, document.allowsCopying,
              (1...100).contains(document.pageCount) else { return nil }
        var sections: [String] = []
        var scannedPages: [Int] = []
        var remainingBytes = 4 * 1_048_576
        for index in 0..<document.pageCount {
            guard let text = document.page(at: index)?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if mayRecognizeText, scannedPages.count < 8 { scannedPages.append(index) }
                continue
            }
            remainingBytes -= text.utf8.count
            guard remainingBytes >= 0 else { return nil }
            sections.append(text)
        }
        return Self(sections: sections, complete: sections.count == document.pageCount,
                    recognitionInput: scannedPages.isEmpty ? nil : .pdf(document, scannedPages))
    }

    private static func matches(_ info: stat, _ expected: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_flags & UInt32(SF_DATALESS | UF_HIDDEN) == 0
            && info.st_dev == expected.st_dev && info.st_ino == expected.st_ino && info.st_uid == expected.st_uid
            && info.st_size == expected.st_size && same(info.st_birthtimespec, expected.st_birthtimespec)
            && same(info.st_mtimespec, expected.st_mtimespec) && same(info.st_ctimespec, expected.st_ctimespec)
    }

    private static func same(_ a: timespec, _ b: timespec) -> Bool {
        a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec
    }
}
