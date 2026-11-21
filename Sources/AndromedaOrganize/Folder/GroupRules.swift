import Foundation

/// Name rules for grouping loose files into folders. Pure string logic, no file system access.
public enum GroupRules {
    /// Why a folder name can't be used. The text shown for each is `Copy.Organize.nameProblem`.
    public enum NameProblem: Equatable, Sendable {
        case empty, tooLong, badCharacters, leadingDot, kindName
    }

    /// Stems too generic to name a group: screenshot-ish words, copy/final markers, and the stemmed kind folder names.
    static let genericStems: Set<String> = [
        "screenshot", "screen", "recording", "untitled", "copy", "final", "image", "photo", "scan",
        "document", "note", "file", "download", "export", "draft", "version", "backup", "temp", "test", "page", "part",
        // Kind.folderName, stemmed
        "spreadsheet", "video", "archive", "installer", "code", "other",
    ]

    /// The name without its extension (split as `NamingRules` does).
    static func base(_ name: String) -> String {
        NamingRules.split(name).base
    }

    /// The lowercased extension without the dot; "" when there is none.
    static func ext(_ name: String) -> String {
        String(NamingRules.split(name).ext.dropFirst()).lowercased()
    }

    /// Letter runs of the base name, stemmed; short and generic stems dropped.
    static func tokens(_ name: String) -> [(stem: String, spelling: String)] {
        tokens(baseName: base(name))
    }

    /// The same tokens for a name that is all base, with no extension to drop (a folder name such as
    /// `Acme 2.0 Project`).
    static func tokens(baseName: String) -> [(stem: String, spelling: String)] {
        var runs: [String] = []
        var current = ""
        for c in baseName {
            if c.isLetter {
                current.append(c)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }

        return runs.compactMap { run in
            let stem = stemmed(run.lowercased())
            guard stem.count >= 4, !genericStems.contains(stem) else { return nil }
            return (stem, run)
        }
    }

    private static func stemmed(_ word: String) -> String {
        guard word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("is"), !word.hasSuffix("us"),
            word.count - 1 >= 4
        else { return word }
        return String(word.dropLast())
    }

    /// `book3_4_7_no_note.txt` → key `book#_#_#`, prefix `book`. Nil for kinds that number themselves
    /// (images, screenshots, videos), when there are no digits, or when fewer than 2 letters lead the name.
    static func seriesSkeleton(_ name: String, kind: Kind?) -> (key: String, prefix: String)? {
        if let kind, kind == .images || kind == .screenshots || kind == .videos { return nil }
        let chars = Array(base(name))
        guard let lastDigit = chars.lastIndex(where: { $0.isNumber }) else { return nil }

        var skeleton = ""
        var inDigits = false
        for c in chars[...lastDigit] {
            if c.isNumber {
                if !inDigits { skeleton.append("#") }
                inDigits = true
            } else {
                skeleton.append(c)
                inDigits = false
            }
        }
        let prefix = String(chars.prefix(while: { $0.isLetter }))
        guard prefix.count >= 2 else { return nil }
        return (NamingRules.key(skeleton), prefix)
    }

    static func displayName(fromBase base: String) -> String {
        let cleaned = base.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return uppercasingFirst(cleaned)
    }

    static func displayName(fromSpellings spellings: [String]) -> String {
        spellings.map(uppercasingFirst).joined(separator: " ")
    }

    private static func uppercasingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// Nil when `s` is a usable folder name, otherwise the problem.
    public static func validFolderName(_ s: String) -> NameProblem? {
        let name = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .empty }
        if name.count > 100 { return .tooLong }
        if name.contains("/") || name.contains(":") { return .badCharacters }
        if name.hasPrefix(".") { return .leadingDot }
        let key = NamingRules.key(name)
        if Kind.allCases.contains(where: { NamingRules.key($0.folderName) == key }) { return .kindName }
        return nil
    }
}
