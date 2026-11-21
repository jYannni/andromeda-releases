import Foundation

/// The user's Organize thresholds, cloud destinations and checked providers (decision 5, ruling O9).
///
/// Ages are stored as `TimeInterval` seconds. JSON keys are fixed; `destinations` encodes as an object
/// keyed by the provider's raw value and `checkedProviders` as a sorted array of raw values (Swift would
/// encode a non-String-keyed dictionary as a flat array). Decoding tolerates missing keys (defaults) and
/// unknown provider names (dropped), so an older or newer file never resets the rest.
public struct OrganizeSettings: Codable, Equatable, Sendable {
    public static let day: TimeInterval = 86_400

    /// Smallest allocated size worth offering to offload.
    /// The Settings steppers' lowest values; decoding never loads less.
    public static let minOffloadBytes: Int64 = 50_000_000
    public static let minMoveBytes: Int64 = 100_000_000
    public static let minAge: TimeInterval = day

    public var offloadMinBytes: Int64 = 100_000_000
    public var offloadMinAge: TimeInterval = 182 * OrganizeSettings.day
    public var moveMinBytes: Int64 = 500_000_000
    public var moveMinAge: TimeInterval = 182 * OrganizeSettings.day
    /// Projects excluded from local move suggestions and from plans made from an earlier suggestion.
    public var moveProtectedFolders: [String] = []
    /// Provider to destination path; a missing or empty entry means `defaultDestination(for:)`.
    public var destinations: [CloudProvider: String] = [:]
    public var checkedProviders: Set<CloudProvider> = []

    public init() {}

    /// `<root>/From this Mac`.
    public static func defaultDestination(for root: CloudRoot) -> URL {
        root.url.appendingPathComponent("From this Mac", isDirectory: true)
    }

    /// The destination to use for `root`: the custom path when set, else the default.
    public func destination(for root: CloudRoot) -> URL {
        if let custom = destinations[root.provider], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return Self.defaultDestination(for: root)
    }

    private enum Key: String, CodingKey {
        case offloadMinBytes, offloadMinAge, moveMinBytes, moveMinAge, moveProtectedFolders, destinations, checkedProviders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let v = try c.decodeIfPresent(Int64.self, forKey: .offloadMinBytes) { offloadMinBytes = v }
        if let v = try c.decodeIfPresent(TimeInterval.self, forKey: .offloadMinAge) { offloadMinAge = v }
        if let v = try c.decodeIfPresent(Int64.self, forKey: .moveMinBytes) { moveMinBytes = v }
        if let v = try c.decodeIfPresent(TimeInterval.self, forKey: .moveMinAge) { moveMinAge = v }
        moveProtectedFolders = (try c.decodeIfPresent([String].self, forKey: .moveProtectedFolders) ?? [])
            .filter { $0.hasPrefix("/") }
        offloadMinBytes = max(offloadMinBytes, Self.minOffloadBytes)
        moveMinBytes = max(moveMinBytes, Self.minMoveBytes)
        offloadMinAge = max(offloadMinAge, Self.minAge)
        moveMinAge = max(moveMinAge, Self.minAge)
        let raw = try c.decodeIfPresent([String: String].self, forKey: .destinations) ?? [:]
        for (name, path) in raw { if let p = CloudProvider(rawValue: name) { destinations[p] = path } }
        let names = try c.decodeIfPresent([String].self, forKey: .checkedProviders) ?? []
        checkedProviders = Set(names.compactMap(CloudProvider.init(rawValue:)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(offloadMinBytes, forKey: .offloadMinBytes)
        try c.encode(offloadMinAge, forKey: .offloadMinAge)
        try c.encode(moveMinBytes, forKey: .moveMinBytes)
        try c.encode(moveMinAge, forKey: .moveMinAge)
        if !moveProtectedFolders.isEmpty { try c.encode(moveProtectedFolders, forKey: .moveProtectedFolders) }
        try c.encode(Dictionary(uniqueKeysWithValues: destinations.map { ($0.key.rawValue, $0.value) }), forKey: .destinations)
        try c.encode(checkedProviders.map(\.rawValue).sorted(), forKey: .checkedProviders)
    }
}

/// Where the settings live. Injected through `AppDependencies` so tests don't touch the real defaults.
public protocol OrganizeSettingsStore: Sendable {
    func load() -> OrganizeSettings
    func save(_ settings: OrganizeSettings)
}

/// `UserDefaults` under `organize.settings`, as JSON. A missing or unreadable value loads as the defaults.
public struct UserDefaultsOrganizeSettingsStore: OrganizeSettingsStore, @unchecked Sendable {
    public static let key = "organize.settings"
    // UserDefaults is documented thread-safe, but isn't marked Sendable.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> OrganizeSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(OrganizeSettings.self, from: data) else { return OrganizeSettings() }
        return settings
    }

    public func save(_ settings: OrganizeSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(settings) { defaults.set(data, forKey: Self.key) }
    }
}
