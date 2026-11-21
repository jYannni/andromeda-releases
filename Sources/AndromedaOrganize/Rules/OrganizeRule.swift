import Foundation

/// A saved "file names like this go there" rule (organize 3b). A value only: rules never run on their
/// own, they just shape the next plan, which still goes through review, the confirm sheet and the journal.
///
/// A rule belongs to a volume (plan 7 decision 7): `volumeUUID` nil is the startup disk, else the drive it was
/// made on. On a drive, "home" in `Destination.inHome` and `Scope.folder` means that drive's root: their
/// components are relative to the drive root, never to the home folder (the UUID makes the base unambiguous).
public struct OrganizeRule: Codable, Equatable, Sendable, Identifiable {
    /// Folder-name components for where matching files go.
    public enum Destination: Codable, Equatable, Sendable {
        /// Below the picked folder.
        case relative([String])
        /// Below the home folder, outside the picked folder (checked by `DestinationGuard`). For a rule on a
        /// drive (`volumeUUID` set), below that drive's root instead.
        case inHome([String])
    }

    public enum Scope: Codable, Equatable, Sendable {
        case anyFolder
        /// A home-relative folder path; for a rule on a drive, relative to the drive root.
        case folder(String)
    }

    public let id: UUID
    /// A glob (`fnmatch`) on the file name only.
    public var pattern: String
    public var kind: Kind?
    public var destination: Destination
    public var scope: Scope
    public var created: Date
    /// The drive the rule was made on (`ExternalVolume.id`); nil is the startup disk. A rule applies only on its
    /// own volume. Absent from rules files written before plan 7, which decode as startup-disk rules.
    public var volumeUUID: String?

    public init(
        id: UUID = UUID(), pattern: String, kind: Kind? = nil, destination: Destination,
        scope: Scope = .anyFolder, created: Date = Date(), volumeUUID: String? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.kind = kind
        self.destination = destination
        self.scope = scope
        self.volumeUUID = volumeUUID
        // Whole seconds, so a rule equals itself after the store's ISO-8601 round trip.
        self.created = Date(timeIntervalSince1970: created.timeIntervalSince1970.rounded(.down))
    }

    /// Case- and normalization-insensitive glob on the file name, as APFS compares names. Flags 0, so a
    /// backslash escapes a metacharacter (`\*`, `\[`) and matches it literally. A kind filter, when set,
    /// must equal the file's kind.
    public func matches(fileName: String, kind fileKind: Kind?) -> Bool {
        if let kind, kind != fileKind { return false }
        return Self.matchesName(fileName, pattern: pattern)
    }

    static func matchesName(_ name: String, pattern: String) -> Bool {
        fnmatch(NamingRules.key(pattern), NamingRules.key(name), 0) == 0
    }
}
