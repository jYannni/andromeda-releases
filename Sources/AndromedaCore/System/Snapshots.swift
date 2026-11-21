import Foundation

public struct LocalSnapshot: Equatable, Sendable {
    public enum Kind: Sendable { case timeMachine, osUpdate, other }

    public let name: String
    public let kind: Kind
    /// `yyyy-MM-dd-HHmmss` captured from a `com.apple.TimeMachine.*` name, else nil.
    public let tmutilDate: String?

    public init(name: String, kind: Kind, tmutilDate: String?) {
        self.name = name
        self.kind = kind
        self.tmutilDate = tmutilDate
    }

    init(name: String) {
        self.name = name
        if name.hasPrefix("com.apple.os.update-") {
            kind = .osUpdate
            tmutilDate = nil
        } else if let m = name.firstMatch(of: /com\.apple\.TimeMachine\.(\d{4}-\d{2}-\d{2}-\d{6})/) {
            kind = .timeMachine
            tmutilDate = String(m.1)
        } else {
            kind = .other
            tmutilDate = nil
        }
    }
}

public enum SnapshotParser {
    public enum ParseError: Error { case malformedPlist }

    /// Parses `diskutil apfs listSnapshots <vol> -plist`; entries are keyed by `SnapshotName`.
    public static func parseDiskutil(_ plist: Data) throws -> [LocalSnapshot] {
        let any = try PropertyListSerialization.propertyList(from: plist, options: [], format: nil)
        guard let root = any as? [String: Any] else { throw ParseError.malformedPlist }
        let entries = root["Snapshots"] as? [[String: Any]] ?? []
        return entries.compactMap { ($0["SnapshotName"] as? String).map(LocalSnapshot.init(name:)) }
    }

    /// Parses `tmutil listlocalsnapshots /`. Only `com.apple.` lines count; the header and blanks are skipped.
    public static func parseTmutil(_ text: String) -> [LocalSnapshot] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") }
            .map(LocalSnapshot.init(name:))
    }
}

public protocol SnapshotLister: Sendable {
    func localSnapshots() throws -> [LocalSnapshot]
}

/// Uses `tmutil` because `diskutil apfs listSnapshots /System/Volumes/Data` is empty on macOS 27.2:
/// the os.update snapshots live on the System volume (docs/research/macos27-checks.md).
public struct LiveSnapshotLister: SnapshotLister {
    private let runner: any ToolRunner

    public init(runner: any ToolRunner = LiveToolRunner()) { self.runner = runner }

    public func localSnapshots() throws -> [LocalSnapshot] {
        let exe = URL(fileURLWithPath: "/usr/bin/tmutil")
        let result = try runner.run(exe, ["listlocalsnapshots", "/"])
        guard result.exitCode == 0 else {
            throw ToolError.failed(executable: exe.path, exitCode: result.exitCode, stderr: result.stderr)
        }
        return SnapshotParser.parseTmutil(result.stdout)
    }
}
