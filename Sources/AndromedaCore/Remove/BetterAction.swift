import Foundation

/// What the app offers for a finding it can't simply move to the Trash.
public enum BetterAction: Equatable, Sendable {
    /// Carried out by the privileged helper.
    case privileged(RemovalPlan)
    case copyCommand(String)
    case handoff(instructions: String, url: URL?)
    case restart
    case none
}

extension PlanBuilder {
    /// Modern Foundation percent-encodes a malformed string instead of failing, so reject whitespace
    /// ourselves: a catalog URL with spaces is a typo, not something to open.
    private static func parse(_ string: String) -> URL? {
        string.contains(where: \.isWhitespace) ? nil : URL(string: string)
    }

    /// The helper may carry out the Spotlight rebuild for this entry on this macOS: spec §9 says
    /// nothing is acted on until the entry is verified on the running major (ruling P29).
    public static func helperCanRebuildSpotlight(_ entry: CatalogEntry, osMajor: Int) -> Bool {
        guard entry.id == "spotlight-index", case .terminalCommand = entry.removal else { return false }
        #if ANDROMEDA_VERIFY
        if VerifyOverride.treatsAsVerified(entry.id) { return true }
        #endif
        return entry.verifiedOn.contains(osMajor)
    }

    public static func betterAction(for finding: Finding, helperReady: Bool, osMajor: Int) -> BetterAction {
        switch finding.entry.removal {
        case .terminalCommand(let command):
            if helperReady && helperCanRebuildSpotlight(finding.entry, osMajor: osMajor) {
                return .privileged(RemovalPlan(removals: [PlannedRemoval(
                    catalogEntryID: finding.entry.id, action: .privileged(.rebuildSpotlightIndex),
                    expectedBytes: finding.bytes, privateBytes: finding.freeableBytes,
                    clonesPresent: finding.clonesPresent, expectation: nil, appsMustBeQuit: [])]))
            }
            return .copyCommand(command)
        case .handoff(let instructions, let url):
            return .handoff(instructions: instructions, url: url.flatMap(Self.parse))
        case .restart:
            return .restart
        case .trash, .tool, .deleteLocalSnapshots, .none:
            return .none
        }
    }
}
