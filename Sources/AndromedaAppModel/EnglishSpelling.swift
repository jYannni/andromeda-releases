import Foundation

public enum EnglishSpelling: String, CaseIterable, Identifiable, Sendable {
    case us, uk

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .us: "English (US)"
        case .uk: "English (UK)"
        }
    }

    static func preferred(locale: Locale = .current) -> Self {
        switch locale.region?.identifier {
        case "AU", "GB", "IE", "NZ": .uk
        default: .us
        }
    }

    /// Apply only to app copy. Paths, filenames and format identifiers must keep their exact spelling.
    public func wording(_ copy: String) -> String {
        guard self == .uk else { return copy }
        return copy
            .replacingOccurrences(of: "Organiz", with: "Organis")
            .replacingOccurrences(of: "organiz", with: "organis")
    }
}
