import Foundation

/// Why files were put in a group.
public enum GroupReason: Equatable, Sendable {
    case sameName
    case sharesToken(String)
    case series
    case madeWithin(minutes: Int)
    /// The group goes into one of the user's own folders (relative to the organized folder).
    case intoYourFolder(String)
    /// A single loose file shaped or named like one of the user's own folders (relative path).
    case matchesYourFolder(String)
    /// The files match one of the user's saved rules (its pattern).
    case rule(String)
    /// The user moved these files with Move to….
    case movedByYou
}

/// A loose file as the finder sees it: its name, kind, and birth time.
public struct GroupFile: Sendable {
    public let name: String
    public let kind: Kind?
    public let birth: Date?

    public init(name: String, kind: Kind?, birth: Date?) {
        self.name = name
        self.kind = kind
        self.birth = birth
    }
}

/// A set of files that belong together. `files` are names in `NamingRules.key` order.
public struct FoundGroup: Equatable, Sendable {
    public let id: String
    public var name: String
    public var reasons: [GroupReason]
    public let isSuggestion: Bool
    public let files: [String]
}

/// A suggested folder to hold several groups that share a word (e.g. "Lessons").
public struct ParentSuggestion: Equatable, Sendable {
    public let name: String
    public let groupIDs: [String]
}

/// Finds groups in loose files from their names and birth times. Pure logic, no file system access.
public enum GroupFinder {
    public static func find(_ input: [GroupFile]) -> (groups: [FoundGroup], parents: [ParentSuggestion]) {
        // Files in NamingRules.key order, so "first file" and group file lists are deterministic.
        let files = input.map(Info.init).sorted { ($0.sortKey, $0.name) < ($1.sortKey, $1.name) }
        var claimed = [Bool](repeating: false, count: files.count)

        // 1. Same name.
        var nameGroups: [Draft] = []
        var byBase: [String: [Int]] = [:]
        var baseOrder: [String] = []
        for (i, f) in files.enumerated() {
            let key = NamingRules.key(f.base)
            if byBase[key] == nil { baseOrder.append(key) }
            byBase[key, default: []].append(i)
        }
        for key in baseOrder {
            let members = byBase[key]!
            guard members.count >= 2, files[members[0]].base.filter(\.isLetter).count >= 4 else { continue }
            nameGroups.append(
                Draft(
                    id: "name:" + key, name: GroupRules.displayName(fromBase: files[members[0]].base),
                    reasons: [.sameName], isSuggestion: false, members: members))
            for i in members { claimed[i] = true }
        }

        // 1b. A file whose base holds a same-name group's whole multi-word base as a run of words
        //     ("README-tidy-up" holds "tidy-up") joins that group, before any token candidate.
        //     The longest base wins; ties go to the first group. One-word bases ("kafka") pull in nothing.
        let nameWords = nameGroups.map { words(files[$0.members[0]].base) }
        for i in files.indices where !claimed[i] {
            let mine = words(files[i].base)
            var best: Int?
            for (g, run) in nameWords.enumerated() where run.count >= 2 && contains(mine, run) {
                if best.map({ nameWords[$0].count < run.count }) ?? true { best = g }
            }
            guard let best else { continue }
            nameGroups[best].members.append(i)
            claimed[i] = true
        }

        // 2. Token candidates over unclaimed files.
        let candidates = tokenCandidates(files, among: files.indices.filter { !claimed[$0] })

        // 3. Hubs: strong candidates with ≥2 strictly smaller strong candidates sharing ≥2 files.
        //    Hubs make no group; they're kept for parents (step 9).
        let strong = candidates.filter(\.isStrong)
        let strongByFile = index(strong)
        var hubs: [Candidate] = []
        var nonHubStrong: [Candidate] = []
        for (h, c) in strong.enumerated() {
            var overlap: [Int: Int] = [:]
            for i in c.members { for o in strongByFile[i, default: []] where o != h { overlap[o, default: 0] += 1 } }
            let smaller = overlap.filter { $0.value >= 2 && strong[$0.key].members.count < c.members.count }
            if smaller.count >= 2 { hubs.append(c) } else { nonHubStrong.append(c) }
        }

        // 4. Subsets: drop strong candidates that are a strict subset of a non-hub strong candidate.
        //    (Weak candidates are recomputed in step 7.)
        let nonHubByFile = index(nonHubStrong)
        let rest = nonHubStrong.filter { c in
            !containingStrong(c, strong: nonHubStrong, byFile: nonHubByFile)
                .contains { nonHubStrong[$0].members.count > c.members.count }
        }

        // 5. Assign each unclaimed file to its largest remaining strong candidate (ties: by stem).
        let ranked = rest.indices.sorted { a, b in
            let (x, y) = (rest[a], rest[b])
            return x.members.count != y.members.count ? x.members.count > y.members.count : x.stems.lexicographicallyPrecedes(y.stems)
        }
        let rank = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, $0) })
        let restByFile = index(rest)
        var assigned: [Int: [Int]] = [:]
        for i in files.indices where !claimed[i] {
            guard let best = restByFile[i]?.min(by: { rank[$0]! < rank[$1]! }) else { continue }
            assigned[best, default: []].append(i)
        }
        var tokenGroups: [Draft] = []
        for c in rest.indices {
            let members = assigned[c, default: []]
            guard members.count >= 2, Set(members.map { files[$0].ext }).count >= 2 else { continue }
            let stems = rest[c].stems
            tokenGroups.append(
                Draft(
                    id: "token:" + stems.joined(separator: "+"),
                    name: GroupRules.displayName(fromSpellings: spellings(of: stems, in: members, files)),
                    reasons: stems.map { .sharesToken($0) }, isSuggestion: false, members: members))
            for i in members { claimed[i] = true }
        }

        // 6. Series.
        var seriesGroups: [Draft] = []
        var bySkeleton: [String: (prefix: String, members: [Int])] = [:]
        var skeletonOrder: [String] = []
        for i in files.indices where !claimed[i] {
            guard let s = GroupRules.seriesSkeleton(files[i].name, kind: files[i].kind) else { continue }
            if bySkeleton[s.key] == nil {
                skeletonOrder.append(s.key)
                bySkeleton[s.key] = (s.prefix, [])
            }
            bySkeleton[s.key]!.members.append(i)
        }
        for key in skeletonOrder {
            let (prefix, members) = bySkeleton[key]!
            guard members.count >= 3 else { continue }
            seriesGroups.append(
                Draft(
                    id: "series:" + key, name: GroupRules.displayName(fromSpellings: [prefix]) + " series",
                    reasons: [.series], isSuggestion: false, members: members))
            for i in members { claimed[i] = true }
        }

        // 7. Weak suggestions over what's still unclaimed, largest first; a file joins only one.
        let weak = tokenCandidates(files, among: files.indices.filter { !claimed[$0] }).filter(\.isWeak)
            .sorted { x, y in
                x.members.count != y.members.count ? x.members.count > y.members.count : x.stems.lexicographicallyPrecedes(y.stems)
            }
        var suggestionGroups: [Draft] = []
        for c in weak {
            let members = c.members.filter { !claimed[$0] }
            guard members.count >= 2 else { continue }
            suggestionGroups.append(
                Draft(
                    id: "suggestion:" + c.stems.joined(separator: "+"),
                    name: GroupRules.displayName(fromSpellings: spellings(of: c.stems, in: members, files)),
                    reasons: c.stems.map { .sharesToken($0) }, isSuggestion: true, members: members))
            for i in members { claimed[i] = true }
        }
        suggestionGroups.sort { $0.members[0] < $1.members[0] }

        // 8. Session chip.
        var drafts = nameGroups + tokenGroups + seriesGroups + suggestionGroups
        for g in drafts.indices {
            if let span = birthSpan(drafts[g].members, files), span <= 30 * 60 {
                drafts[g].reasons.append(.madeWithin(minutes: max(1, Int((span / 60).rounded(.up)))))
            }
        }

        // 9. Parents: a hub's word over ≥3 non-suggestion groups that share a file with it.
        var groupOf: [Int: [Int]] = [:]
        for (g, d) in drafts.enumerated() where !d.isSuggestion { for i in d.members { groupOf[i, default: []].append(g) } }
        var parents: [ParentSuggestion] = []
        for hub in hubs.sorted(by: { $0.stems.lexicographicallyPrecedes($1.stems) }) {
            let touched = Set(hub.members.flatMap { groupOf[$0, default: []] })
            guard touched.count >= 3 else { continue }
            parents.append(
                ParentSuggestion(
                    name: GroupRules.displayName(fromSpellings: spellings(of: hub.stems, in: hub.members, files)),
                    groupIDs: touched.map { drafts[$0].id }.sorted()))
        }

        // 10. Uniqueness, in group order.
        var used: Set<String> = []
        for g in drafts.indices {
            var name = drafts[g].name
            var n = 2
            while used.contains(NamingRules.key(name)) {
                name = drafts[g].name + " \(n)"
                n += 1
            }
            used.insert(NamingRules.key(name))
            drafts[g].name = name
        }

        let groups = drafts.map { d in
            FoundGroup(
                id: d.id, name: d.name, reasons: d.reasons, isSuggestion: d.isSuggestion,
                files: d.members.sorted().map { files[$0].name })
        }
        return (groups, parents)
    }

    // MARK: - Pieces

    private struct Info {
        let name: String
        let kind: Kind?
        let birth: Date?
        let sortKey: String
        let base: String
        let ext: String
        let tokens: [(stem: String, spelling: String)]

        init(_ f: GroupFile) {
            name = f.name
            kind = f.kind
            birth = f.birth
            sortKey = NamingRules.key(f.name)
            base = GroupRules.base(f.name)
            ext = GroupRules.ext(f.name)
            tokens = GroupRules.tokens(f.name)
        }
    }

    private struct Draft {
        let id: String
        var name: String
        var reasons: [GroupReason]
        let isSuggestion: Bool
        var members: [Int]
    }

    private struct Candidate {
        var stems: [String]
        let members: [Int]
        let isStrong: Bool
        let isWeak: Bool
    }

    /// Step 2's rule over `among` (indices in key order): stems shared by ≥2 files that are strong
    /// (≥2 exts) or weak (one ext, all births known, span ≤60 min); identical file sets merged.
    private static func tokenCandidates(_ files: [Info], among: [Int]) -> [Candidate] {
        var byStem: [String: [Int]] = [:]
        for i in among {
            var seen: Set<String> = []
            for t in files[i].tokens where seen.insert(t.stem).inserted { byStem[t.stem, default: []].append(i) }
        }
        var bySet: [[Int]: [String]] = [:]
        for (stem, members) in byStem where members.count >= 2 { bySet[members, default: []].append(stem) }

        var out: [Candidate] = []
        for (members, stems) in bySet {
            let exts = Set(members.map { files[$0].ext })
            let strong = exts.count >= 2
            let weak = !strong && (birthSpan(members, files).map { $0 <= 60 * 60 } ?? false)
            guard strong || weak else { continue }
            let order = files[members[0]].tokens.map(\.stem)
            let sorted = stems.sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
            out.append(Candidate(stems: sorted, members: members, isStrong: strong, isWeak: weak))
        }
        return out.sorted { $0.stems.lexicographicallyPrecedes($1.stems) }
    }

    /// A base's words, split on `_ - . space`, each folded by `NamingRules.key`.
    private static func words(_ base: String) -> [String] {
        base.split(whereSeparator: { "_-. ".contains($0) }).map { NamingRules.key(String($0)) }
    }

    /// Whether `run` appears in `words` as consecutive words.
    private static func contains(_ words: [String], _ run: [String]) -> Bool {
        guard !run.isEmpty, words.count >= run.count else { return false }
        return (0...(words.count - run.count)).contains { Array(words[$0..<($0 + run.count)]) == run }
    }

    /// File index → indices of the candidates containing it.
    private static func index(_ candidates: [Candidate]) -> [Int: [Int]] {
        var out: [Int: [Int]] = [:]
        for (c, cand) in candidates.enumerated() { for i in cand.members { out[i, default: []].append(c) } }
        return out
    }

    /// Indices of strong candidates that contain every file of `c`.
    private static func containingStrong(_ c: Candidate, strong: [Candidate], byFile: [Int: [Int]]) -> [Int] {
        var counts: [Int: Int] = [:]
        for i in c.members { for s in byFile[i, default: []] { counts[s, default: 0] += 1 } }
        return counts.filter { $0.value == c.members.count }.map(\.key)
    }

    /// The most common spelling of each stem in `members` (ties: the first file's).
    private static func spellings(of stems: [String], in members: [Int], _ files: [Info]) -> [String] {
        stems.map { stem in
            var counts: [String: Int] = [:]
            var order: [String] = []
            for i in members {
                for t in files[i].tokens where t.stem == stem {
                    if counts[t.spelling] == nil { order.append(t.spelling) }
                    counts[t.spelling, default: 0] += 1
                }
            }
            return order.max { counts[$0]! < counts[$1]! || (counts[$0]! == counts[$1]! && order.firstIndex(of: $0)! > order.firstIndex(of: $1)!) } ?? stem
        }
    }

    /// Seconds between the earliest and latest birth; nil when any birth is unknown.
    private static func birthSpan(_ members: [Int], _ files: [Info]) -> TimeInterval? {
        let births = members.compactMap { files[$0].birth }
        guard births.count == members.count, let lo = births.min(), let hi = births.max() else { return nil }
        return hi.timeIntervalSince(lo)
    }
}
