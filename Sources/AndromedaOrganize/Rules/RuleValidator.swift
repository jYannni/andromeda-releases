import Foundation

public enum RuleProblem: Equatable, Sendable {
    case emptyPattern, slashInPattern, badFolderName(GroupRules.NameProblem), tooDeep, outsideHome
}

/// Pure checks on a rule's own fields. No UI, no file system: the seam a future rule editor validates through.
public enum RuleValidator {
    public static let maxDepth = 8

    public static func validate(_ rule: OrganizeRule) -> RuleProblem? {
        if rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyPattern }
        if rule.pattern.contains("/") { return .slashInPattern }

        let components: [String]
        switch rule.destination {
        case .relative(let c): components = c
        case .inHome(let c):
            // A home destination must stay below home; `.`/`..` would not (validFolderName calls them leadingDot).
            if c.contains(where: { isDotSegment($0) }) { return .outsideHome }
            components = c
        }
        if components.count > maxDepth { return .tooDeep }
        if components.isEmpty { return .badFolderName(.empty) }
        for component in components {
            guard let problem = GroupRules.validFolderName(component) else { continue }
            // Kind folder names are Andromeda's own only below the picked folder; in home, `~/Documents`
            // (or `~/Pictures/Screenshots`) is the user's folder, a natural Move to… destination.
            if problem == .kindName, case .inHome = rule.destination { continue }
            return .badFolderName(problem)
        }
        return nil
    }

    /// Why a saved rule isn't used, as the plan reports it (`FolderPlanResult.blockedRules`).
    public static func problemText(_ problem: RuleProblem) -> String {
        switch problem {
        case .emptyPattern: "The rule has no pattern"
        case .slashInPattern: "A pattern can't contain “/”"
        case .badFolderName: "The rule's folder name can't be used"
        case .tooDeep: "The rule's folder is more than \(maxDepth) folders deep"
        case .outsideHome: OrganizeGuard.reasonText(.notInHome)
        }
    }

    private static func isDotSegment(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "." || t == ".."
    }
}
