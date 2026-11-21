import Darwin
import Foundation

private var fileMetadataTokens: Regex<(Substring, Substring)> { /\{(name|created|modified)\}/ }

private func hasOnlyKnownMetadataTokens(_ pattern: String) -> Bool {
    let literals = pattern.replacing(fileMetadataTokens, with: "")
    return !literals.contains("{") && !literals.contains("}")
}

private func metadataRenderer(_ pattern: String, timeZone: TimeZone) -> (String, Date?, Date) -> String? {
    let style = Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day().dateSeparator(.dash)
    let requiresCreation = pattern.contains("{created}")
    return { name, created, modified in
        if requiresCreation, created == nil { return nil }
        return pattern.replacing(fileMetadataTokens) { match in
            switch match.1 {
            case "name": return (name as NSString).deletingPathExtension
            case "created": return created.map(style.format) ?? ""
            default: return style.format(modified)
            }
        }
    }
}

/// Formats a file's stem and keeps its final extension, including the original case.
public struct AutomationFilenameTemplate: Codable, Equatable, Sendable {
    public let pattern: String
    private let timeZoneIdentifier: String

    public init?(_ pattern: String, timeZone: TimeZone = .current) {
        guard Self.isValid(pattern) else { return nil }
        self.pattern = pattern
        timeZoneIdentifier = timeZone.identifier
    }

    private static func isValid(_ pattern: String) -> Bool {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pattern.hasPrefix("."), pattern.utf16.count <= NAME_MAX,
              !pattern.contains("/"), !pattern.contains(":"),
              !pattern.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return false }
        return hasOnlyKnownMetadataTokens(pattern)
    }

    func renderer() -> ((String, Date?, Date) -> String?)? {
        guard Self.isValid(pattern), let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        let render = metadataRenderer(pattern, timeZone: timeZone)
        return { name, created, modified in
            guard let stem = render(name, created, modified),
                  !stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !stem.hasPrefix(".") else { return nil }
            let ext = (name as NSString).pathExtension
            return ext.isEmpty ? stem : stem + "." + ext
        }
    }
}

public struct AutomationFinderTagTemplate: Codable, Equatable, Sendable {
    public let pattern: String
    private let timeZoneIdentifier: String

    public init?(_ pattern: String, timeZone: TimeZone = .current) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard Self.isValid(trimmed) else { return nil }
        self.pattern = trimmed
        timeZoneIdentifier = timeZone.identifier
    }

    private static func isValid(_ pattern: String) -> Bool {
        !pattern.isEmpty && FolderAutomationRule.isValidFinderTag(pattern) && hasOnlyKnownMetadataTokens(pattern)
    }

    func renderer() -> ((String, Date?, Date) -> String?)? {
        guard Self.isValid(pattern), let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        let render = metadataRenderer(pattern, timeZone: timeZone)
        return { name, created, modified in
            guard let tag = render(name, created, modified)?.trimmingCharacters(in: .whitespaces),
                  Self.isValidRenderedTag(tag) else { return nil }
            return tag
        }
    }

    private static func isValidRenderedTag(_ value: String) -> Bool {
        !value.isEmpty && FolderAutomationRule.isValidFinderTag(value)
    }
}

/// Generates folders beneath the approved destination from the chosen file date.
public struct AutomationSubfolderTemplate: Codable, Equatable, Sendable {
    public enum DateBasis: String, CaseIterable, Codable, Sendable { case modified, created, added }

    public let pattern: String
    private let timeZoneIdentifier: String
    private let savedDateBasis: DateBasis?
    public var dateBasis: DateBasis { savedDateBasis ?? .modified }
    private static var token: Regex<(Substring, Substring)> { /\{(year|month|day|name)\}/ }

    public init?(_ pattern: String, timeZone: TimeZone = .current, dateBasis: DateBasis = .modified) {
        guard Self.components(of: pattern) != nil else { return nil }
        self.pattern = pattern
        timeZoneIdentifier = timeZone.identifier
        savedDateBasis = dateBasis == .modified ? nil : dateBasis
    }

    public func usingDateBasis(_ basis: DateBasis) -> Self? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        return Self(pattern, timeZone: timeZone, dateBasis: basis)
    }

    private static func components(of pattern: String) -> [String]? {
        let parts = pattern.components(separatedBy: "/")
        guard pattern.utf8.count < PATH_MAX, parts.allSatisfy({ part in
            let literals = part.replacing(token, with: "")
            return isFolderComponent(part) && !literals.contains("{") && !literals.contains("}")
        }) else { return nil }
        return parts
    }

    static func isFolderComponent(_ part: String) -> Bool {
        !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !part.hasPrefix(".")
            && !part.contains("/") && !part.contains(":") && part.utf16.count <= NAME_MAX
            && !part.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    var needsDateAdded: Bool { dateBasis == .added && Self.usesDate(in: pattern) }

    func renderer() -> ((String, Date?, Date, Date?) -> [String]?)? {
        guard let parts = Self.components(of: pattern), let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        let token = Self.token
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let basis = dateBasis
        let usesDate = Self.usesDate(in: pattern)
        return { name, created, modified, added in
            let timestamp: Date? = switch basis {
            case .modified: modified
            case .created: created
            case .added: added
            }
            let date = calendar.dateComponents([.year, .month, .day], from: timestamp ?? modified)
            guard (!usesDate || timestamp != nil), let year = date.year, let month = date.month, let day = date.day else {
                return nil
            }
            let result = parts.map { part in
                part.replacing(token) { match in
                    switch match.1 {
                    case "year": String(format: "%04d", year)
                    case "month": String(format: "%02d", month)
                    case "day": String(format: "%02d", day)
                    default: (name as NSString).deletingPathExtension
                    }
                }
            }
            return result.allSatisfy(Self.isFolderComponent) ? result : nil
        }
    }

    public static func usesDate(in pattern: String) -> Bool {
        pattern.contains("{year}") || pattern.contains("{month}") || pattern.contains("{day}")
    }
}
