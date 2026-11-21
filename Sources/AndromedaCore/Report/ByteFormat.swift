import Foundation

/// The one way sizes are shown: decimal units, Finder's `.file` style (e.g. "1.5 GB").
/// Always numeric, so 0 is "0 bytes", never "Zero KB".
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
