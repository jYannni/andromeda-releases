import AndromedaCore
import Foundation

public enum RuleLoad: Equatable, Sendable {
    case rules([OrganizeRule])
    /// The file exists but can't be read or decoded. Never treated as "no rules".
    case unreadable
}

public enum RuleStoreError: Error, Equatable, Sendable {
    /// Saving would overwrite a file that can't be read, losing whatever it holds.
    case wouldReplaceUnreadable
}

public protocol OrganizeRuleStore: Sendable {
    func load() -> RuleLoad
    func save(_ rules: [OrganizeRule]) throws
    /// The same store, allowed to overwrite an unreadable file: Settings › Rules' **Start over with no rules**,
    /// behind a confirm whose default is Cancel.
    func replacingUnreadableStore() -> any OrganizeRuleStore
}

/// `organize-rules.json` in a directory: `{ "version": 1, "rules": [...] }`, written atomically.
public struct FileOrganizeRuleStore: OrganizeRuleStore {
    public static let fileName = "organize-rules.json"
    static let version = 1

    private struct Document: Codable {
        var version: Int
        var rules: [OrganizeRule]
    }

    private let directory: URL
    private let replacingUnreadable: Bool

    public init(directory: URL, replacingUnreadable: Bool = false) {
        self.directory = directory
        self.replacingUnreadable = replacingUnreadable
    }

    /// The app's support folder (the journal's parent), where the live rules file lives.
    public static func liveDirectory() -> URL {
        Journal.liveDirectory().deletingLastPathComponent()
    }

    public func replacingUnreadableStore() -> any OrganizeRuleStore {
        FileOrganizeRuleStore(directory: directory, replacingUnreadable: true)
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public func load() -> RuleLoad {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return .rules([]) }
        guard let data = try? Data(contentsOf: fileURL),
            let doc = try? Self.decoder.decode(Document.self, from: data),
            doc.version == Self.version
        else { return .unreadable }
        return .rules(doc.rules)
    }

    public func save(_ rules: [OrganizeRule]) throws {
        if !replacingUnreadable, load() == .unreadable { throw RuleStoreError.wouldReplaceUnreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(Document(version: Self.version, rules: rules))
        try data.write(to: fileURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
