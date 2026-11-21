import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum DocumentRaster {
    public static func image(_ bytes: Data, maximumDimension: Int, singleFrame: Bool = false,
                             readProperties: (([CFString: Any]) -> Void)? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              !singleFrame || CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0,
              width <= 100_000_000 / height else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        readProperties?(properties)
        return image
    }

    public static func pdfPage(_ page: CGPDFPage, maximumDimension: Int) -> CGImage? {
        guard page.rotationAngle % 90 == 0 else { return nil }
        let box = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
        guard !box.isEmpty, box.width.isFinite, box.height.isFinite else { return nil }
        let rotated = page.rotationAngle % 180 != 0
        let longest = max(box.width, box.height)
        let width = max(1, Int(((rotated ? box.height : box.width) / longest * CGFloat(maximumDimension)).rounded()))
        let height = max(1, Int(((rotated ? box.width : box.height) / longest * CGFloat(maximumDimension)).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let transform = page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true)
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.concatenate(transform)
        context.clip(to: box)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
