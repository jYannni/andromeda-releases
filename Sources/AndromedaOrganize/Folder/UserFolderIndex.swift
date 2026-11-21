import AndromedaCore
import Foundation

/// One of the picked folder's own folders, as far as matching loose files to it needs to know.
public struct UserFolder: Equatable, Sendable {
    /// Relative to the picked folder, for example "Work/Clients/Acme".
    public let relativePath: String
    /// The stems of the folder's own name (`GroupRules.tokens`).
    public let tokens: Set<String>
    /// The shapes of the names directly inside: `NamingRules.key` with every digit run turned into `#`.
    public let skeletons: Set<String>
}

/// Names inside the picked folder's own (user) folders, so a loose file can be offered a home that already
/// exists (rev 4.4 as reworded by 5.3). Planning only: lstat and directory listings, nothing opened or read,
/// links never followed, and never a code project, package, app library, cloud folder or dataless folder.
public struct UserFolderIndex: Sendable {
    public static let maxDepth = 3
    public static let maxEntries = 5_000

    public let folders: [UserFolder]
    /// True when listing stopped at `maxEntries`; what lies beyond the cap is simply not indexed.
    public let capped: Bool

    public static let empty = UserFolderIndex(folders: [], capped: false)

    /// Breadth-first from `topLevel` (the folders `FolderScan` listed as staying where they are). Those are
    /// level 1; their subfolders are levels 2 and 3. A folder that fails a check is skipped, not entered.
    public static func build(
        folder: URL, topLevel: [URL], env: ScanEnvironment, cloudRoots: [CloudRoot],
        isUbiquitous: (URL) -> Bool = FolderPlanner.liveIsUbiquitous
    ) -> UserFolderIndex {
        let folder = folder.standardizedFileURL
        let rootURLs = cloudRoots.map { $0.url.standardizedFileURL }
        let cache = OrganizeGuard.Cache()
        let kindNames = Set(Kind.allCases.map { NamingRules.key($0.folderName) })

        var count = 0
        var capped = false
        var found: [UserFolder] = []
        var queue: [(url: URL, relative: String, depth: Int)] = []

        /// Counts one entry; false once the cap is reached.
        func take() -> Bool {
            if count >= maxEntries { capped = true; return false }
            count += 1
            return true
        }

        /// A folder is entered only when it is a plain directory that is not a link, dataless, a kind folder,
        /// excluded, an app library by its database (Calibre's `metadata.db`) or iCloud-synced.
        func admits(_ url: URL, name: String, _ st: stat) -> Bool {
            guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_flags & UInt32(SF_DATALESS) == 0,
                !kindNames.contains(NamingRules.key(name)),
                OrganizeGuard.exclusion(for: url, env: env, cloudRoots: rootURLs, cache: cache) == nil,
                !OrganizeGuard.holdsAppDatabase(url.path),
                !isUbiquitous(url)
            else { return false }
            return true
        }

        for url in topLevel.map({ $0.standardizedFileURL }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard take() else { break }
            var st = stat()
            let name = url.lastPathComponent
            guard lstat(url.path, &st) == 0, admits(url, name: name, st) else { continue }
            queue.append((url, name, 1))
        }

        var head = 0
        while head < queue.count, !capped {
            let (url, relative, depth) = queue[head]
            head += 1
            guard let listing = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { continue }
            var skeletons: Set<String> = []
            for name in FolderPlanner.sortedNames(listing) where !name.hasPrefix(".") {
                guard take() else { break }
                let child = url.appendingPathComponent(name)
                var st = stat()
                guard lstat(child.path, &st) == 0, st.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFREG:
                    skeletons.insert(skeleton(name))
                case S_IFDIR:
                    if depth < maxDepth, admits(child, name: name, st) {
                        queue.append((child, relative + "/" + name, depth + 1))
                    }
                default: break  // links and specials are never followed
                }
            }
            found.append(
                UserFolder(
                    relativePath: relative,
                    tokens: Set(GroupRules.tokens(baseName: url.lastPathComponent).map(\.stem)),
                    skeletons: skeletons))
        }
        return UserFolderIndex(folders: found, capped: capped)
    }

    /// `NamingRules.key` with every maximal run of ASCII digits replaced by one `#`.
    static func skeleton(_ name: String) -> String {
        var out = ""
        var inDigits = false
        for c in NamingRules.key(name).unicodeScalars {
            if c.value >= 0x30 && c.value <= 0x39 {
                if !inDigits { out.append("#") }
                inDigits = true
            } else {
                out.unicodeScalars.append(c)
                inDigits = false
            }
        }
        return out
    }

    /// Folders whose name tokens all appear in the file's, or beside whose files this one has the same shape.
    /// A shape counts only when the file's base name holds a letter token: `0002.pdf` or `IMG_0002.jpg` is
    /// shaped like far too many names to say where it belongs. Evidence is ranked: a folder matched by both
    /// token and shape beats folders matched by only one of them; only the strongest level is returned (one
    /// folder is a clear answer, several stay ambiguous). Within a level, when a folder and one of its
    /// subfolders both match, only the deepest is returned.
    public func matches(fileName: String) -> [UserFolder] {
        let fileTokens = Set(GroupRules.tokens(fileName).map(\.stem))
        let shape = fileTokens.isEmpty ? nil : Self.skeleton(fileName)
        var both: [UserFolder] = []
        var one: [UserFolder] = []
        for f in folders {
            let byToken = !f.tokens.isEmpty && f.tokens.isSubset(of: fileTokens)
            let byShape = shape.map(f.skeletons.contains) == true
            if byToken && byShape { both.append(f) } else if byToken || byShape { one.append(f) }
        }
        return Self.deepest(both.isEmpty ? one : both)
    }

    /// Relative paths of folders beside whose files this one has the same shape (same letter-token guard as
    /// `matches(fileName:)`). Evidence for ranking a group's name matches.
    public func shapeMatches(fileName: String) -> Set<String> {
        guard !GroupRules.tokens(fileName).isEmpty else { return [] }
        let shape = Self.skeleton(fileName)
        return Set(folders.filter { $0.skeletons.contains(shape) }.map(\.relativePath))
    }

    /// Folders whose name tokens equal the group's.
    public func matches(groupName: String) -> [UserFolder] {
        let tokens = Set(GroupRules.tokens(baseName: groupName).map(\.stem))
        guard !tokens.isEmpty else { return [] }
        return Self.deepest(folders.filter { $0.tokens == tokens })
    }

    private static func deepest(_ hits: [UserFolder]) -> [UserFolder] {
        hits.filter { hit in
            !hits.contains { $0.relativePath.hasPrefix(hit.relativePath + "/") }
        }
    }
}
