import Foundation

/// One report-only line for space outside the home folder (spec rev H §2.1).
public enum OutsideRow: String, Codable, CaseIterable, Sendable {
    case sharedFolder, homebrew, usrLocal, library, appleDownloads, privateFiles, otherSystemFolders

    public var bucket: AppleBucket { self == .sharedFolder ? .otherUsers : .systemData }

    /// What the app and the report call the row.
    public var title: String {
        switch self {
        case .sharedFolder: "Shared folder"
        case .homebrew: "Homebrew"
        case .usrLocal: "Command-line tools in /usr/local"
        case .library: "Apps' shared files"
        case .appleDownloads: "Other Apple downloads"
        case .privateFiles: "macOS working files"
        case .otherSystemFolders: "Other folders on the system disk"
        }
    }

    /// What Reveal in Finder opens. nil for the catch-all row, which has no single folder.
    public var revealPath: URL? {
        let path: String
        switch self {
        case .sharedFolder: path = "/Users/Shared"
        case .homebrew: path = "/opt/homebrew"
        case .usrLocal: path = "/usr/local"
        case .library: path = "/Library"
        case .appleDownloads: path = "/System/Library/AssetsV2"
        case .privateFiles: path = "/private/var"
        case .otherSystemFolders: return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

public struct OutsideMeasurement: Equatable, Sendable {
    public var row: OutsideRow
    public var bytes: Int64
    public var clonesPresent: Bool
    public var unreadableCount: Int
    /// Paths skipped by the unprivileged walk. The helper only returns counts.
    public var unreadablePaths: [URL]
    /// Roots attempted by the unprivileged walk, for read-only category browsing.
    public var browsableRoots: [URL]
    /// Directories the helper's walk refused to enter (R21). Always 0 for the non-root pass.
    public var skippedCount: Int
    /// The walk stopped early, so `bytes` is a lower bound ("at least").
    public var truncated: Bool

    public init(
        row: OutsideRow, bytes: Int64, clonesPresent: Bool = false, unreadableCount: Int = 0, skippedCount: Int = 0,
        truncated: Bool = false, unreadablePaths: [URL] = [], browsableRoots: [URL] = []
    ) {
        self.row = row
        self.bytes = bytes
        self.clonesPresent = clonesPresent
        self.unreadableCount = unreadableCount
        self.unreadablePaths = unreadablePaths
        self.browsableRoots = browsableRoots
        self.skippedCount = skippedCount
        self.truncated = truncated
    }

    /// `bytes` is a lower bound ("at least"): cut short, unreadable entries, or refused subtrees.
    public var isLowerBound: Bool { truncated || unreadableCount > 0 || skippedCount > 0 }
}

/// Walks the Data volume outside the home folder, without root, and totals it per `OutsideRow`.
/// Skipping is by directory identity, not path: a firmlink gives one folder two names.
public struct OutsideHomeScanner {
    private let env: ScanEnvironment
    private let sizer: AllocatedSizer

    /// Top-level entries never walked whole: other stages or the helper count them (Applications, the
    /// hidden folders), they're mount points (Volumes), or `roots` splits them into rows (Users, opt, usr).
    /// `System` is only walked through its firmlinks.
    private static let skippedTopLevel: Set<String> = [
        "Applications", "Volumes", "System", "Users", "opt", "usr",
        ".Spotlight-V100", ".DocumentRevisions-V100", ".fseventsd",
    ]
    /// Root-only folders the helper measures; skipped wherever they turn up.
    private static let helperOwned = [".DocumentRevisions-V100", ".fseventsd"]

    public init(env: ScanEnvironment, sizer: AllocatedSizer = AllocatedSizer()) {
        self.env = env
        self.sizer = sizer
    }

    /// What the outside pass skips: every catalog item, the Applications roots, and the user's own var
    /// folder unless a catalog item already covers it (the pass skips home itself).
    public static func claims(catalogItems: [URL], env: ScanEnvironment) -> [URL] {
        var claimed = catalogItems + env.applicationsRoots
        if let mine = env.userVarFolder {
            let parts = mine.standardizedFileURL.pathComponents
            let covered = catalogItems.contains {
                let item = $0.standardizedFileURL.pathComponents
                return item.count <= parts.count && Array(parts.prefix(item.count)) == item
            }
            if !covered { claimed.append(mine) }
        }
        return claimed
    }

    /// `claimed`: folders and files other stages count (catalog items, Applications roots, home).
    /// A cancelled `control` stops the pass; every row it didn't finish comes back `truncated`.
    /// Rows with nothing in them are left out; the rest keep `OutsideRow.allCases` order.
    public func scan(skipping claimed: [URL], control: ScanControl? = nil) -> [OutsideMeasurement] {
        let data = env.dataVolumeRoot
        let users = data.appendingPathComponent("Users", isDirectory: true)
        // Other stages may share the sizer and run at the same time: this pass gets its own view, and its
        // skip set is passed per call, never stored on the sizer.
        let sizer = self.sizer.reporting(to: control)

        var excluded = claimed + [env.home] + Self.helperOwned.map { data.appendingPathComponent($0) }
        // Other accounts' homes: the helper measures them, never this pass.
        excluded += children(of: users).filter { $0.lastPathComponent != "Shared" }
        var skipping = Set(excluded.compactMap { FileIdentity(path: $0.path) })

        var results = Dictionary(uniqueKeysWithValues: OutsideRow.allCases.map { ($0, OutsideMeasurement(row: $0, bytes: 0)) })
        for (row, root) in roots(data: data, users: users) {
            if let control, control.isCancelled {
                results[row]?.truncated = true
                continue
            }
            let id = FileIdentity(path: root.path)
            guard let id, !skipping.contains(id) else { continue }
            let r = sizer.size(of: root, skipping: skipping)
            // Reached again under another name (a second firmlink), it's skipped, not recounted.
            skipping.insert(id)
            var m = results[row] ?? OutsideMeasurement(row: row, bytes: 0)
            m.bytes += r.bytes
            m.clonesPresent = m.clonesPresent || r.clonesPresent
            m.unreadableCount += r.unreadable.count
            m.unreadablePaths += r.unreadable
            m.browsableRoots.append(root)
            if let control, control.isCancelled { m.truncated = true }
            results[row] = m
        }
        return OutsideRow.allCases.compactMap { results[$0] }
            .filter { $0.bytes > 0 || $0.unreadableCount > 0 || $0.truncated }
    }

    /// Every folder the pass walks, with its row, in row order.
    private func roots(data: URL, users: URL) -> [(OutsideRow, URL)] {
        let opt = data.appendingPathComponent("opt", isDirectory: true)
        let usr = data.appendingPathComponent("usr", isDirectory: true)
        let device = FileIdentity(path: data.path)?.dev
        var out: [(OutsideRow, URL)] = [
            (.sharedFolder, users.appendingPathComponent("Shared", isDirectory: true)),
            (.homebrew, opt.appendingPathComponent("homebrew", isDirectory: true)),
            (.usrLocal, usr.appendingPathComponent("local", isDirectory: true)),
            (.library, data.appendingPathComponent("Library", isDirectory: true)),
        ]
        out += firmlinkedSystemLibrary().map { (.appleDownloads, data.appendingPathComponent($0, isDirectory: true)) }
        out.append((.privateFiles, data.appendingPathComponent("private", isDirectory: true)))

        let claimedByName: Set<String> = ["homebrew", "local", "Library", "private"]
        var other = children(of: opt).filter { $0.lastPathComponent != "homebrew" }
        other += children(of: usr).filter { $0.lastPathComponent != "local" }
        other += children(of: data).filter {
            !Self.skippedTopLevel.contains($0.lastPathComponent) && !claimedByName.contains($0.lastPathComponent)
        }
        // A top-level entry on another device is a mount point, not this volume's space.
        other = other.filter { device == nil || FileIdentity(path: $0.path)?.dev == device }
        out += other.map { (.otherSystemFolders, $0) }
        return out
    }

    /// Data-volume relative paths of the firmlinks under `System/Library/`. A missing file means none.
    private func firmlinkedSystemLibrary() -> [String] {
        guard let text = try? String(contentsOf: env.firmlinksFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { return nil }
            let relative = fields[1].trimmingCharacters(in: .whitespaces)
            return relative.hasPrefix("System/Library/") ? relative : nil
        }
    }

    /// Entries of `url`, hidden ones included; empty when it can't be listed.
    private func children(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }
}
