import AndromedaCore
import AndromedaOrganize
import Foundation

/// Report-only planning behind `Andromeda --plan-groups <folder>`: the group plan for a folder as JSON,
/// with no UI, no apply and no journal. Reads the folder's listing and metadata; changes nothing.
public enum GroupReport {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// `PlanExport.json` plus `"unsorted"`, `"parentSuggestions"`, `"blockedRules"` and `"userFoldersCapped"` (`"leftAlone"` is already
    /// in it), with `"groups"` always present and each group's `"startsTicked"`, reasons and (for a rule
    /// group) destination. Plans with no edits, the automatic Sort-the-rest choice and the saved rules, read
    /// from `ruleStore` (only read: an unreadable store plans with no rules and is left as it is).
    public static func run(
        folder: URL, env: ScanEnvironment,
        ruleStore: any OrganizeRuleStore = FileOrganizeRuleStore(directory: FileOrganizeRuleStore.liveDirectory())
    ) throws -> Data {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure(description: "not a folder: \(folder.path)")
        }
        guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil else {
            throw Failure(description: "can't read \(folder.path)")
        }
        let rules: [OrganizeRule]
        switch ruleStore.load() {
        case .rules(let r): rules = r
        case .unreadable: rules = []
        }
        let result = GroupPlanner(env: env, cloudRoots: CloudRootLocator.roots(env: env))
            .plan(folder: folder, options: NamingOptions(), edits: GroupEdits(), sortRestByKind: nil, rules: rules)

        let base = try PlanExport.json(result.plan, groups: result.groups)
        guard var doc = try JSONSerialization.jsonObject(with: base) as? [String: Any] else {
            throw Failure(description: "unexpected export shape")
        }
        // Every group the planner found, with whether it starts ticked (a suggestion doesn't); the export
        // only lists groups with steps, so the report builds its own list. Always present, maybe empty.
        let exported = (doc["groups"] as? [[String: Any]]) ?? []
        doc["groups"] = result.groups.map { g -> [String: Any] in
            var entry = exported.first { ($0["id"] as? String) == g.id } ?? [
                "id": g.id, "name": g.name, "steps": g.stepIDs.count, "reasons": g.reasons.map(PlanExport.reasonToken),
            ]
            if entry["parent"] == nil, let parent = g.parent { entry["parent"] = parent }
            if entry["destination"] == nil, let destination = g.destination { entry["destination"] = destination.path }
            entry["startsTicked"] = g.startsTicked
            return entry
        }
        doc["unsorted"] = result.unsorted.map { ["path": $0.url.path, "reason": $0.reason] }
        doc["blockedRules"] = Dictionary(uniqueKeysWithValues: result.blockedRules.map { ($0.key.uuidString, $0.value) })
        doc["userFoldersCapped"] = result.userFoldersCapped
        doc["parentSuggestions"] = result.parentSuggestions.map { ["name": $0.name, "groupIDs": $0.groupIDs] }
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }
}
