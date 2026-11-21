import AndromedaCore
import AndromedaOrganize
import Foundation
import Observation

/// Settings › Rules (plan 6): the saved organize rules, in store order. Rules never run on their own: they
/// only shape the next folder plan, which still goes through review and the confirm sheet. Deleting or
/// editing a rule changes nothing on disk but the rules file.
@MainActor @Observable
public final class RulesModel {
    public private(set) var rules: [OrganizeRule] = []
    /// The rules file exists but can't be read: no rule is used, and nothing is saved over it until the
    /// user starts over (`replaceUnreadable()`).
    public private(set) var unreadable = false
    /// Rules the last folder plan didn't use, by id → why (`FolderPlanResult.blockedRules`).
    public internal(set) var blocked: [UUID: String] = [:]

    @ObservationIgnored private let store: any OrganizeRuleStore

    public init(store: any OrganizeRuleStore) {
        self.store = store
        reload()
    }

    /// Reads the rules file again (a small file; the folder model calls it before each plan).
    public func reload() {
        switch store.load() {
        case .rules(let r):
            rules = r
            unreadable = false
        case .unreadable:
            rules = []
            unreadable = true
        }
    }

    /// Saves a new rule after the others. Returns why it can't be (its problem, or the file is unreadable), or nil.
    public func add(_ rule: OrganizeRule) -> String? {
        if let problem = RuleValidator.validate(rule) { return Copy.Organize.ruleProblem(problem) }
        reload()
        return save(rules + [rule])
    }

    /// Replaces the rule with `rule.id`, checked by `RuleValidator`. Returns the problem (nothing is saved), or nil.
    public func update(_ rule: OrganizeRule) -> String? {
        if let problem = RuleValidator.validate(rule) { return Copy.Organize.ruleProblem(problem) }
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return nil }
        var next = rules
        next[i] = rule
        guard let problem = save(next) else {
            // The edited rule is judged afresh by the next plan.
            blocked[rule.id] = nil
            return nil
        }
        return problem
    }

    /// Settings' edit: the rule's pattern and its destination's folders (`a/b`, below the organized folder
    /// or below home, as the rule already had it). Checked by `RuleValidator`; returns the problem, or nil.
    public func edit(id: UUID, pattern: String, destinationPath: String) -> String? {
        guard var rule = rules.first(where: { $0.id == id }) else { return nil }
        let components = destinationPath.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        rule.pattern = pattern
        switch rule.destination {
        case .relative: rule.destination = .relative(components)
        case .inHome: rule.destination = .inHome(components)
        }
        return update(rule)
    }

    /// The destination's folders as `edit(id:pattern:destinationPath:)` takes them.
    public static func destinationPath(_ rule: OrganizeRule) -> String {
        switch rule.destination {
        case .relative(let c), .inHome(let c): c.joined(separator: "/")
        }
    }

    /// Settings › Rules' drive line for a rule made on a drive: "On <name>" while one of `volumes` (the mounted
    /// drives) has its UUID, else "On a drive that isn't connected". Nil for a startup-disk rule.
    public static func driveText(_ rule: OrganizeRule, volumes: [ExternalVolume]) -> String? {
        guard let uuid = rule.volumeUUID else { return nil }
        guard let volume = volumes.first(where: { $0.id == uuid }) else { return Copy.Drives.ruleOnMissingDrive }
        return Copy.Drives.ruleOnDrive(volume.name)
    }

    /// Deletes a saved rule. Nothing on disk changes but the rules file, so there is no confirm. Returns why it
    /// couldn't be saved (Settings shows it; the rule stays), or nil.
    @discardableResult
    public func delete(id: UUID) -> String? {
        guard rules.contains(where: { $0.id == id }) else { return nil }
        return save(rules.filter { $0.id != id })
    }

    /// **Start over with no rules**, after the Cancel-default confirm: an empty rules file replaces the
    /// unreadable one. The file is read again first: if it is readable now (restored meanwhile), nothing is
    /// written and its rules are shown. Returns why it couldn't be written, or nil.
    @discardableResult
    public func replaceUnreadable() -> String? {
        reload()
        guard unreadable else { return nil }
        do {
            try store.replacingUnreadableStore().save([])
        } catch {
            return Copy.Organize.rulesNotSaved
        }
        blocked = [:]
        reload()
        return nil
    }

    private func save(_ next: [OrganizeRule]) -> String? {
        if unreadable { return Copy.Organize.rulesUnreadable }
        do {
            try store.save(next)
        } catch RuleStoreError.wouldReplaceUnreadable {
            reload()
            return Copy.Organize.rulesUnreadable
        } catch {
            return Copy.Organize.rulesNotSaved
        }
        rules = next
        blocked = blocked.filter { id, _ in next.contains { $0.id == id } }
        return nil
    }
}
