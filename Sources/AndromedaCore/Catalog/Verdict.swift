import Foundation

public enum NotActionableReason: Equatable, Sendable {
    case tierNotRemovable
    case unverified(osMajor: Int)
    case toolMissing(String)
}

/// Whether a catalog entry may be acted on for the running macOS version.
public struct Verdict: Equatable, Sendable {
    public let tier: Tier
    public let actionable: Bool
    public let reason: NotActionableReason?

    public static func make(
        entry: CatalogEntry, osMajor: Int, toolExists: (String) -> Bool
    ) -> Verdict {
        let reason: NotActionableReason?
        if entry.tier == .leaveIt || entry.tier == .cantRemove {
            reason = .tierNotRemovable
        } else if let tool = entry.requiresTool, !toolExists(tool) {
            reason = .toolMissing(tool)
        } else if !entry.verifiedOn.contains(osMajor) && !overridden(entry.id) {
            reason = .unverified(osMajor: osMajor)
        } else {
            reason = nil
        }
        return Verdict(tier: entry.tier, actionable: reason == nil, reason: reason)
    }

    /// Verification build only: the entry counts as verified without `verified_on` being filled.
    private static func overridden(_ id: String) -> Bool {
        #if ANDROMEDA_VERIFY
        return VerifyOverride.treatsAsVerified(id)
        #else
        return false
        #endif
    }
}
