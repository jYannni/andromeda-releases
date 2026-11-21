import Darwin
import AndromedaCore
import Foundation

public enum DestinationVerdict: Equatable, Sendable {
    case usable
    case blocked(String)
}

/// Whether a rule's destination outside the picked folder may receive files: inside home, on the picked
/// folder's volume, and not under ~/Library, a cloud root, an iCloud-synced Desktop or Documents (R-C15),
/// a package, app library or code project, or below a symlink. The destination need not exist yet:
/// the first ancestor that does is judged.
///
/// For a picked folder on a drive, the drive root takes home's place (plan 7 Task 7): every walk and the on-disk
    /// spelling stop at the drive root, and a destination outside the drive is refused (`outsideDriveText`).
public enum DestinationGuard {
    public static let otherDiskText = "On another disk"
    public static let outsideDriveText = "Outside this drive"
    public static let unreadableText = "Can't read this folder"

    /// Used by one recursive observation. Operations on files run fresh checks.
    final class ObservationCache {
        private struct DirectoryNames {
            let exact: Set<String>
            let folded: [String: String]

            init(_ names: [String]) {
                exact = Set(names)
                folded = Dictionary(names.map { (NamingRules.key($0), $0) }, uniquingKeysWith: { first, _ in first })
            }

            func spelling(of name: String) -> String? {
                exact.contains(name) ? name : folded[NamingRules.key(name)]
            }
        }

        let markers = OrganizeGuard.Cache()
        private var names: [String: DirectoryNames] = [:]
        private var databases: [String: Bool] = [:]
        private var cloudFolders: [String: Bool] = [:]

        func spelling(of name: String, in directory: String) -> String? {
            if let cached = names[directory] { return cached.spelling(of: name) }
            guard let listing = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
            let lookup = DirectoryNames(listing)
            names[directory] = lookup
            return lookup.spelling(of: name)
        }

        func holdsAppDatabase(_ path: String) -> Bool {
            if let cached = databases[path] { return cached }
            let found = OrganizeGuard.holdsAppDatabase(path)
            databases[path] = found
            return found
        }

        func isUbiquitous(_ url: URL, check: (URL) -> Bool) -> Bool {
            let path = url.path
            if let cached = cloudFolders[path] { return cached }
            let found = check(url)
            cloudFolders[path] = found
            return found
        }
    }

    public static func check(
        _ url: URL, env: ScanEnvironment, cloudRoots: [CloudRoot], isUbiquitous: (URL) -> Bool,
        deviceOf: (URL) -> Int32?, pickedFolder: URL, withinCloudFolder: Bool = false
    ) -> DestinationVerdict {
        check(url, env: env, cloudRoots: cloudRoots, isUbiquitous: isUbiquitous,
              deviceOf: deviceOf, pickedFolder: pickedFolder, cache: nil, withinCloudFolder: withinCloudFolder)
    }

    static func check(
        _ url: URL, env: ScanEnvironment, cloudRoots: [CloudRoot], isUbiquitous: (URL) -> Bool,
        deviceOf: (URL) -> Int32?, pickedFolder: URL, cache: ObservationCache?, withinCloudFolder: Bool = false
    ) -> DestinationVerdict {
        if withinCloudFolder, !FolderPlanner.isInside(url.standardizedFileURL.path, pickedFolder.standardizedFileURL.path) {
            return .blocked(FolderPlanner.cloudScopeText)
        }
        // Home, or the root of the picked folder's drive: the bound of every walk below.
        let drive = OrganizeGuard.driveRoot(containing: pickedFolder, env: env)?.standardizedFileURL
        let home = drive ?? env.home.standardizedFileURL
        let rootURLs = cloudRoots.map { $0.url.standardizedFileURL }

        var anchor = url.standardizedFileURL
        while !exists(anchor.path) {
            let parent = anchor.deletingLastPathComponent()
            if parent.path == anchor.path { return .blocked(OrganizeGuard.reasonText(.notInHome)) }
            anchor = parent
        }
        // Judged as it is spelled on disk: `~/library/Caches` is `~/Library/Caches`.
        anchor = onDiskSpelling(anchor, home: home, cache: cache)
        if let drive, PlanAssembler.components(of: anchor.path, under: drive.path) == nil {
            return .blocked(outsideDriveText)
        }

        let isTopLevel = OrganizeGuard.isTopLevel(anchor, env: env)
        let exclusion = isTopLevel
            ? OrganizeGuard.folderExclusion(for: anchor, env: env, cloudRoots: rootURLs, cache: cache?.markers)
            : OrganizeGuard.exclusion(for: anchor, env: env, cloudRoots: rootURLs, cache: cache?.markers,
                                      allowExactCloudRoot: withinCloudFolder && anchor.path == pickedFolder.standardizedFileURL.path)
        if let exclusion { return .blocked(OrganizeGuard.reasonText(exclusion)) }

        // An app library by its database (Calibre's `metadata.db`): the anchor or any existing folder above it,
        // up to (not including) home or the drive root. The picked folder is never one: there a `.db` is just a
        // loose file.
        let picked = NamingRules.key(pickedFolder.standardizedFileURL.path)
        var dbNode = anchor
        while dbNode.path.hasPrefix(home.path + "/") {
            if NamingRules.key(dbNode.path) != picked,
               cache?.holdsAppDatabase(dbNode.path) ?? OrganizeGuard.holdsAppDatabase(dbNode.path) {
                return .blocked(OrganizeGuard.reasonText(.appLibrary))
            }
            dbNode = dbNode.deletingLastPathComponent()
        }

        if MoveToCloudPlanner.hasSymlinkAncestor(anchor, below: home) {
            return .blocked(OrganizeGuard.reasonText(.symlink))
        }

        // R-C15: any existing folder from the anchor up to (not including) home (or the drive root) may be an
        // iCloud Desktop/Documents.
        var node = anchor
        while !withinCloudFolder && node.path.hasPrefix(home.path + "/") {
            if cache?.isUbiquitous(node, check: isUbiquitous) ?? isUbiquitous(node) {
                return .blocked(OrganizeGuard.reasonText(.cloudRoot))
            }
            node = node.deletingLastPathComponent()
        }

        guard let here = deviceOf(anchor), let there = deviceOf(pickedFolder.standardizedFileURL), here == there
        else { return .blocked(otherDiskText) }
        return .usable
    }

    /// `url` with each existing component below home in its on-disk spelling, so every prefix check (`~/Library`,
    /// `~/Applications`, …) and every move URL sees the folder as it really is named: APFS finds `~/library` as
    /// `~/Library`. On a case-sensitive volume a different spelling is a different folder. Components from
    /// the first missing one on keep their spelling. A link is never entered: the walk stops after it.
    public static func onDiskSpelling(_ url: URL, home: URL) -> URL {
        onDiskSpelling(url, home: home, cache: nil)
    }

    private static func onDiskSpelling(_ url: URL, home: URL, cache: ObservationCache?) -> URL {
        let url = url.standardizedFileURL, home = home.standardizedFileURL
        guard let rest = PlanAssembler.components(of: url.path, under: home.path) else { return url }
        var out = home
        var used = 0
        for part in rest {
            let candidate = out.appendingPathComponent(part)
            var st = stat()
            guard lstat(candidate.path, &st) == 0 else { break }
            let name: String?
            if let cache {
                name = cache.spelling(of: part, in: out.path)
            } else if let actual = diskName(at: candidate.path), NamingRules.key(actual) == NamingRules.key(part) {
                name = actual
            } else {
                let names = try? FileManager.default.contentsOfDirectory(atPath: out.path)
                name = names?.contains(part) == true ? part : names?.first(where: { NamingRules.key($0) == NamingRules.key(part) })
            }
            guard let name else { break }
            out.appendPathComponent(name)
            used += 1
            if (st.st_mode & S_IFMT) == S_IFLNK { break }
        }
        for part in rest.dropFirst(used) { out.appendPathComponent(part) }
        return out
    }

    /// Reads the basename without enumerating the parent. Volumes without the attribute use the listing path.
    private static func diskName(at path: String) -> String? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
        let referenceOffset = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
        let headerSize = referenceOffset + MemoryLayout<attrreference_t>.size
        // The returned UTF-8 basename is at most NAME_MAX * 3 bytes, plus its NUL and record padding.
        return withUnsafeTemporaryAllocation(byteCount: headerSize + Int(NAME_MAX) * 3 + 4, alignment: 4) { buffer in
            guard getattrlist(path, &request, buffer.baseAddress!, buffer.count, UInt32(FSOPT_NOFOLLOW)) == 0
            else { return nil }
            let length = Int(buffer.loadUnaligned(as: UInt32.self))
            guard length >= headerSize && length <= buffer.count else { return nil }
            let attrs = buffer.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: attribute_set_t.self)
            guard attrs.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
            let ref = buffer.loadUnaligned(fromByteOffset: referenceOffset, as: attrreference_t.self)
            let start = referenceOffset + Int(ref.attr_dataoffset)
            let count = Int(ref.attr_length)
            guard start >= headerSize, count > 1, start + count <= length, buffer[start + count - 1] == 0
            else { return nil }
            let name = buffer[start..<(start + count - 1)]
            guard !name.contains(0), !name.contains(47) else { return nil }
            return String(validating: name, as: UTF8.self)
        }
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}
