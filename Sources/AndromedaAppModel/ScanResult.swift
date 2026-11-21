import AndromedaCore
import AndromedaHelperProtocol
import Foundation

public enum ScanStage: Equatable, Sendable {
    case checkingAccess, catalog, helperMeasure, largeItems, applications, outsideHome, volume, reconciling
}

public struct ScanResult: Equatable, Sendable {
    public var env: ScanEnvironment
    public var findings: [Finding]
    public var largeItems: [LargeItem]
    public var usage: VolumeUsage?
    /// False when the volume could not be read. Consumers gate every volume-total display on this.
    public var usedKnown: Bool
    public var fda: FDAStatus
    /// When `usedKnown == false` it was built from a zero volume. Only `measured`, `freesAtLeast`
    /// and `clonesPresent` stay meaningful. `used`, `unaccounted`, `overcount`, `purgeable` and
    /// `reasons` are all volume-derived and must not be shown.
    public var reconciliation: Reconciliation
    public var finishedAt: Date
    /// Entry IDs whose helper measurement came back truncated; the UI says "at least".
    public var rootMeasureTruncated: Set<String>
    /// Top-level entries of the Applications folders, largest first (zero-byte entries left out).
    public var appItems: [AppItem]
    /// Individually reviewable bundles whose bytes are included in an Applications folder row.
    var nestedAppItems: [AppItem]
    var applicationIDsByPath: [URL: String]
    /// Allocated bytes in home that no catalog entry or large item lists, per probable bucket.
    public var unlisted: [AppleBucket: Int64]
    /// The helper was on for this scan; picks the reason copy.
    public var helperOn: Bool
    /// The helper refused other accounts' sizes because this user isn't an administrator.
    public var standardUser: Bool
    /// Nil when the snapshot listing failed. An empty list means the check succeeded.
    public var snapshots: [LocalSnapshot]?

    public init(
        env: ScanEnvironment, findings: [Finding], largeItems: [LargeItem], usage: VolumeUsage?,
        usedKnown: Bool, fda: FDAStatus, reconciliation: Reconciliation, finishedAt: Date,
        rootMeasureTruncated: Set<String> = [], appItems: [AppItem] = [], unlisted: [AppleBucket: Int64] = [:],
        helperOn: Bool = false, standardUser: Bool = false, snapshots: [LocalSnapshot]? = nil,
        applicationIDsByPath: [URL: String] = [:], nestedAppItems: [AppItem] = []
    ) {
        self.env = env
        self.findings = findings
        self.largeItems = largeItems
        self.usage = usage
        self.usedKnown = usedKnown
        self.fda = fda
        self.reconciliation = reconciliation
        self.finishedAt = finishedAt
        self.rootMeasureTruncated = rootMeasureTruncated
        self.appItems = appItems
        self.nestedAppItems = nestedAppItems
        self.applicationIDsByPath = applicationIDsByPath
        self.unlisted = unlisted
        self.helperOn = helperOn
        self.standardUser = standardUser
        self.snapshots = snapshots
    }
}

/// What the helper said about other accounts' folders.
public enum OtherAccountsAnswer: Equatable, Sendable {
    case measured([AccountSizeReply])
    /// The calling user isn't an administrator.
    case notPermitted
    /// Not asked, or the call failed.
    case unavailable
}

public struct RootMeasurements: Equatable, Sendable {
    /// The helper was on and took the request; false means nothing was asked.
    public var helperOn: Bool
    /// Entries it could not measure are absent.
    public var entries: [String: RootMeasurement]
    public var otherAccounts: OtherAccountsAnswer

    public init(
        helperOn: Bool = false, entries: [String: RootMeasurement] = [:], otherAccounts: OtherAccountsAnswer = .unavailable
    ) {
        self.helperOn = helperOn
        self.entries = entries
        self.otherAccounts = otherAccounts
    }
}

/// Measures root-owned entries, and other accounts' folders, through the privileged helper. The
/// implementation makes its calls one at a time, on one connection: the helper exits when its last
/// connection closes, and launchd is slow to start it again.
/// `shouldContinue` is checked before each call: once it says no, nothing more is asked, so a
/// cancel waits for at most the call in flight.
public protocol RootMeasuring: Sendable {
    func measureAll(
        _ entryIDs: [String], includingOtherAccounts: Bool, shouldContinue: @escaping @MainActor @Sendable () -> Bool
    ) async -> RootMeasurements
}

extension RootMeasuring {
    public func measureAll(_ entryIDs: [String], includingOtherAccounts: Bool) async -> RootMeasurements {
        await measureAll(entryIDs, includingOtherAccounts: includingOtherAccounts, shouldContinue: { true })
    }

    public func measureAll(_ entryIDs: [String]) async -> [String: RootMeasurement] {
        await measureAll(entryIDs, includingOtherAccounts: false).entries
    }
}
