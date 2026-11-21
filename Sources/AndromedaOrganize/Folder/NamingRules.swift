import Foundation

/// The §6.1 "Rename files" toggles.
public struct NamingOptions: Equatable, Sendable {
    public var datePhotos = true
    public var leaveSensible = true
    public var tidySuffixes = true

    public init(datePhotos: Bool = true, leaveSensible: Bool = true, tidySuffixes: Bool = true) {
        self.datePhotos = datePhotos
        self.leaveSensible = leaveSensible
        self.tidySuffixes = tidySuffixes
    }
}

/// Metadata-only naming rules (rev 4.3). Pure string logic, no file system access.
public enum NamingRules {
    /// The new name, or nil for no change.
    public static func proposedName(
        for name: String, kind: Kind?, dateTaken: Date?, options: NamingOptions
    ) -> String? {
        if options.leaveSensible, isSensible(name) { return nil }

        var (base, ext) = split(name)
        if options.tidySuffixes { base = tidy(base) }
        var result = base + ext

        // A name that already starts with a day never gets a second one (even with leaveSensible off).
        if options.datePhotos, kind == .images || kind == .screenshots, let date = dateTaken,
            !hasDate(result, from: result.startIndex)
        {
            result = datePrefix(date) + result
        }
        return result == name ? nil : result
    }

    /// Case- and Unicode-normalization-insensitive collision handling, as APFS compares names.
    public static func resolveCollisions(
        _ proposals: [(URL, String)], existing: Set<String>
    ) -> (renames: [(URL, String)], collisions: [URL]) {
        let existingKeys = Set(existing.map(key))
        // A proposal equal to its own current name ignoring case/normalization is never a rename.
        let live = proposals.filter { key($0.1) != key($0.0.lastPathComponent) }
        var counts: [String: Int] = [:]
        for p in live { counts[key(p.1), default: 0] += 1 }

        var renames: [(URL, String)] = []
        var collisions: [URL] = []
        for p in live {
            let k = key(p.1)
            if existingKeys.contains(k) || counts[k, default: 0] > 1 {
                collisions.append(p.0)
            } else {
                renames.append(p)
            }
        }
        return (renames, collisions)
    }

    // MARK: - Helpers

    /// The APFS-style comparison key (case- and normalization-insensitive). Shared with `FolderPlanner`.
    public static func key(_ name: String) -> String {
        name.decomposedStringWithCanonicalMapping.lowercased()
    }

    private static func isDigits(_ s: Substring) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// `\d{4}-\d{2}-\d{2}` at the given offset.
    private static func hasDate(_ s: String, from start: String.Index) -> Bool {
        let u = Array(s[start...].utf8.prefix(10))
        guard u.count == 10 else { return false }
        for (i, b) in u.enumerated() {
            if i == 4 || i == 7 {
                if b != 0x2D { return false }
            } else if b < 0x30 || b > 0x39 {
                return false
            }
        }
        return true
    }

    private static func isSensible(_ name: String) -> Bool {
        if hasDate(name, from: name.startIndex) { return true }
        let prefix = "Screenshot "
        if name.hasPrefix(prefix) {
            let rest = name.index(name.startIndex, offsetBy: prefix.count)
            if hasDate(name, from: rest) {
                let afterDate = name.index(rest, offsetBy: 10)
                return name[afterDate...].hasPrefix(" at")
            }
        }
        return false
    }

    /// Extension is the text after the last "." when the base before it is non-empty.
    static func split(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
            name.index(after: dot) != name.endIndex
        else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    private static func datePrefix(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date) + " "
    }

    private static func tidy(_ input: String) -> String {
        var base = input
        while true {
            let before = base
            base = stripCopy(base)
            base = stripNumber(base)
            base = stripFinals(base)
            if base == before { return base }
        }
    }

    private static func dropping(_ s: String, suffixOf n: Int) -> String? {
        guard s.count > n else { return nil }  // never produce an empty base
        return String(s.dropLast(n))
    }

    private static func stripCopy(_ s: String) -> String {
        guard s.count >= 5, String(s.suffix(5)).lowercased() == " copy" else { return s }
        return dropping(s, suffixOf: 5) ?? s
    }

    private static func stripNumber(_ s: String) -> String {
        guard s.hasSuffix(")"), let open = s.lastIndex(of: "("), open != s.startIndex else { return s }
        let before = s.index(before: open)
        guard s[before] == " " else { return s }
        let digits = s[s.index(after: open)..<s.index(before: s.endIndex)]
        guard isDigits(digits), digits.count <= 2, let n = Int(digits), (1...99).contains(n) else { return s }
        let stripped = String(s[..<before])
        return stripped.isEmpty ? s : stripped
    }

    /// Rev 4.3(b): repeated `-final`/`_final` suffixes collapse to one (`report-final-final` → `report-final`);
    /// a single one is kept, so "Semi-final" and "report_final" are left alone (ruling R-C16).
    private static func stripFinals(_ s: String) -> String {
        var cur = Substring(s)
        var count = 0
        while cur.count > 6 {
            let tail = String(cur.suffix(6)).lowercased()
            guard tail == "-final" || tail == "_final" else { break }
            cur = cur.dropLast(6)
            count += 1
        }
        return count > 1 ? String(s.dropLast(6 * (count - 1))) : s
    }
}
