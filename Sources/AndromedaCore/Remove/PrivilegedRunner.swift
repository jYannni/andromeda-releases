import Foundation

/// An operation only the privileged helper can carry out. Core knows the operation, not the
/// transport: the XPC runner lives in AndromedaHelperClient.
public enum PrivilegedOperation: Equatable, Sendable {
    case rebuildSpotlightIndex
    case flushDNSCache

    /// What the journal records as the item's `command`.
    public var journalCommand: [String] {
        switch self {
        case .rebuildSpotlightIndex: ["diskplain-helper", "rebuildSpotlightIndex"]
        case .flushDNSCache: ["diskplain-helper", "flushDNSCache"]
        }
    }
}

/// Carries out a privileged operation synchronously and reports its outcome.
public protocol PrivilegedRunner: Sendable {
    func run(_ op: PrivilegedOperation) -> Outcome
}
