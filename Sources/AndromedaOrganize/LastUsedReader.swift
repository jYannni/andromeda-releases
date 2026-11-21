import CoreServices
import Foundation

/// When an item was last used: opened (Spotlight) or, failing that, last changed.
public struct LastUse: Equatable, Sendable {
    public enum Kind: Sendable { case opened, changed }
    public let date: Date
    public let kind: Kind

    public init(date: Date, kind: Kind) {
        self.date = date
        self.kind = kind
    }
}

/// Reads when a file or folder was last opened, falling back to last changed. Local reads only.
public struct LastUsedReader {
    /// Ruling O7: a folder reads at most this many files.
    static let fileCap = 2_000

    private let spotlight: (URL) -> Date?
    private let attributes: (URL) -> (modified: Date?, added: Date?)
    /// Test seam: `lstat` of a listed child; 0 on success, else the errno. FileManager won't list a folder
    /// whose children it can't reach, so a non-ENOENT failure here can't be staged on disk.
    var lstatChild: (String, inout stat) -> Int32 = { path, st in lstat(path, &st) == 0 ? 0 : errno }

    public init(
        spotlight: @escaping (URL) -> Date? = LastUsedReader.liveLastUsed,
        attributes: @escaping (URL) -> (modified: Date?, added: Date?) = LastUsedReader.liveAttributes
    ) {
        self.spotlight = spotlight
        self.attributes = attributes
    }

    /// `ignoringAdded` drops the "date added" input (a move resets it): Spotlight opened, else modified.
    public func lastUse(of url: URL, ignoringAdded: Bool = false) -> LastUse? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return fileUse(url, lstatMTime: Self.date(st), ignoringAdded: ignoringAdded)
        case S_IFDIR:
            // A dataless folder is never entered.
            if st.st_flags & UInt32(SF_DATALESS) != 0 { return nil }
            return folderUse(url, ignoringAdded: ignoringAdded)
        default: return nil
        }
    }

    private func fileUse(_ url: URL, lstatMTime: Date? = nil, ignoringAdded: Bool = false) -> LastUse? {
        if let opened = spotlight(url) { return LastUse(date: opened, kind: .opened) }
        let a = attributes(url)
        let changed = [a.modified, ignoringAdded ? nil : a.added].compactMap { $0 }.max() ?? lstatMTime ?? Self.mtime(of: url)
        return changed.map { LastUse(date: $0, kind: .changed) }
    }

    private static func mtime(of url: URL) -> Date? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return date(st)
    }

    private static func date(_ st: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    private struct Walk {
        var files: [(url: URL, mtime: Date)] = []  // first `fileCap` files only
        var capped = false
        var unreadable = false
        var latestMTime: Date?  // over every file walked
    }

    private func folderUse(_ dir: URL, ignoringAdded: Bool) -> LastUse? {
        var walk = Walk()
        collect(dir, into: &walk)
        // P14: a directory that can't be listed means the answer is unknown.
        if walk.unreadable { return nil }

        var latest: Date?
        var changed = walk.capped
        for (file, mtime) in walk.files {
            guard let use = fileUse(file, lstatMTime: mtime, ignoringAdded: ignoringAdded) else { changed = true; continue }
            if use.kind == .changed { changed = true }
            if latest.map({ use.date > $0 }) ?? true { latest = use.date }
        }
        // Past the cap: the walk's latest modification date also counts (O7).
        if walk.capped, let m = walk.latestMTime, latest.map({ m > $0 }) ?? true { latest = m }
        guard let date = latest else { return nil }
        return LastUse(date: date, kind: changed ? .changed : .opened)
    }

    /// lstat-based walk of the whole tree: skips symlinks and `.DS_Store`, never enters dataless
    /// directories. Keeps the first `fileCap` files for full reads; the rest only feed `latestMTime`.
    private func collect(_ dir: URL, into walk: inout Walk) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            walk.unreadable = true
            return
        }
        for name in names {
            let child = dir.appendingPathComponent(name)
            var st = stat()
            let failure = lstatChild(child.path, &st)
            guard failure == 0 else {
                // Gone since the listing: skip it. Any other failure means the answer is unknown (P14).
                if failure != ENOENT { walk.unreadable = true }
                continue
            }
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                if name == ".DS_Store" { continue }
                let m = Self.date(st)
                if walk.latestMTime.map({ m > $0 }) ?? true { walk.latestMTime = m }
                if walk.files.count >= Self.fileCap { walk.capped = true } else { walk.files.append((child, m)) }
            case S_IFDIR:
                if st.st_flags & UInt32(SF_DATALESS) != 0 { continue }
                collect(child, into: &walk)
            default: continue
            }
        }
    }

    /// Spotlight's last-used date. nil when the item isn't indexed or was never opened.
    public static func liveLastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    public static func liveAttributes(_ url: URL) -> (modified: Date?, added: Date?) {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .addedToDirectoryDateKey])
        return (v?.contentModificationDate, v?.addedToDirectoryDate)
    }
}
