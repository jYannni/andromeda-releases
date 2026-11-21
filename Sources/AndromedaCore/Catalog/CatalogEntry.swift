import Foundation

/// How confident we are that removing something is harmless, and who does the removing.
public enum Tier: String, Codable, Sendable {
    case safe
    case withCare = "with-care"
    case leaveIt = "leave-it"
    case cantRemove = "cant-remove"
}

/// The categories macOS shows in its own Storage settings.
public enum AppleBucket: String, Codable, Sendable, CaseIterable {
    case systemData = "system-data"
    case documents
    case developer
    case iosFiles = "ios-files"
    case mail
    case messages
    case photos
    case icloudDrive = "icloud-drive"
    case macOS = "macos"
    case otherUsers = "other-users"
    case applications

    /// The order macOS Storage settings lists them in (rev G, G-R1). Contains every case once.
    public static let displayOrder: [AppleBucket] = [
        .applications, .documents, .photos, .mail, .messages, .icloudDrive,
        .iosFiles, .developer, .otherUsers, .macOS, .systemData,
    ]
}

/// How an entry's size is measured.
public enum Sizing: String, Codable, Sendable {
    case allocatedWalk = "allocated-walk"
    case snapshots
    case none
}

/// What happens when the user acts on an entry.
public enum Removal: Codable, Equatable, Sendable {
    case trash
    case tool(executable: String, arguments: [String])
    case deleteLocalSnapshots
    case handoff(instructions: String, url: String?)
    case terminalCommand(String)
    case restart
    case none

    private enum CodingKeys: String, CodingKey {
        case kind, executable, arguments, instructions, url, command
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "trash": self = .trash
        case "tool":
            self = .tool(
                executable: try c.decode(String.self, forKey: .executable),
                arguments: try c.decode([String].self, forKey: .arguments))
        case "delete-local-snapshots": self = .deleteLocalSnapshots
        case "handoff":
            self = .handoff(
                instructions: try c.decode(String.self, forKey: .instructions),
                url: try c.decodeIfPresent(String.self, forKey: .url))
        case "terminal-command":
            self = .terminalCommand(try c.decode(String.self, forKey: .command))
        case "restart": self = .restart
        case "none": self = .none
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown removal kind '\(kind)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trash: try c.encode("trash", forKey: .kind)
        case .tool(let executable, let arguments):
            try c.encode("tool", forKey: .kind)
            try c.encode(executable, forKey: .executable)
            try c.encode(arguments, forKey: .arguments)
        case .deleteLocalSnapshots: try c.encode("delete-local-snapshots", forKey: .kind)
        case .handoff(let instructions, let url):
            try c.encode("handoff", forKey: .kind)
            try c.encode(instructions, forKey: .instructions)
            try c.encodeIfPresent(url, forKey: .url)
        case .terminalCommand(let command):
            try c.encode("terminal-command", forKey: .kind)
            try c.encode(command, forKey: .command)
        case .restart: try c.encode("restart", forKey: .kind)
        case .none: try c.encode("none", forKey: .kind)
        }
    }
}

/// One known disk-space culprit.
public struct CatalogEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var explanation: String
    public var consequence: String
    public var paths: [String]
    /// Patterns whose matches (and anything inside them) this entry never claims. Optional in JSON.
    public var exclude: [String] = []
    public var sizing: Sizing
    public var bucket: AppleBucket
    public var tier: Tier
    public var removal: Removal
    /// Bundle IDs of apps that must be quit before removal.
    public var appsMustBeQuit: [String]
    /// Absolute path of a tool this entry needs, if any.
    public var requiresTool: String?
    /// macOS major versions this entry has been checked against.
    public var verifiedOn: [Int]
    public var sources: [URL]
    /// `yyyy-MM-dd`.
    public var lastVerified: String

    private enum CodingKeys: String, CodingKey {
        case id, title, explanation, consequence, paths, exclude, sizing, bucket, tier, removal, sources
        case appsMustBeQuit = "apps_must_be_quit"
        case requiresTool = "requires_tool"
        case verifiedOn = "verified_on"
        case lastVerified = "last_verified"
    }
}

extension CatalogEntry {
    /// Written out so `exclude` can be absent from JSON; kept in an extension so the memberwise init survives.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        explanation = try c.decode(String.self, forKey: .explanation)
        consequence = try c.decode(String.self, forKey: .consequence)
        paths = try c.decode([String].self, forKey: .paths)
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        sizing = try c.decode(Sizing.self, forKey: .sizing)
        bucket = try c.decode(AppleBucket.self, forKey: .bucket)
        tier = try c.decode(Tier.self, forKey: .tier)
        removal = try c.decode(Removal.self, forKey: .removal)
        appsMustBeQuit = try c.decode([String].self, forKey: .appsMustBeQuit)
        requiresTool = try c.decodeIfPresent(String.self, forKey: .requiresTool)
        verifiedOn = try c.decode([Int].self, forKey: .verifiedOn)
        sources = try c.decode([URL].self, forKey: .sources)
        lastVerified = try c.decode(String.self, forKey: .lastVerified)
    }
}
