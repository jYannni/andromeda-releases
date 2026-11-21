import Foundation

public struct MeasureReply: Codable, Equatable, Sendable {
    public var entryID: String
    /// Allocated bytes: what the item "uses".
    public var bytes: Int64
    /// What deleting it "frees at least"; nil when unknown.
    public var privateBytes: Int64?
    public var clonesPresent: Bool
    public var unreadableCount: Int
    /// Directories the walk's descent policy refused to enter (user-owned or writable by
    /// non-administrators, R21): their contents are not in `bytes`. A count only.
    public var skippedCount: Int
    public var truncated: Bool
    public var measuredPaths: [String]

    public init(
        entryID: String, bytes: Int64, privateBytes: Int64?, clonesPresent: Bool,
        unreadableCount: Int, skippedCount: Int = 0, truncated: Bool, measuredPaths: [String]
    ) {
        self.entryID = entryID
        self.bytes = bytes
        self.privateBytes = privateBytes
        self.clonesPresent = clonesPresent
        self.unreadableCount = unreadableCount
        self.skippedCount = skippedCount
        self.truncated = truncated
        self.measuredPaths = measuredPaths
    }

    /// `bytes` is a lower bound: something was cut short, unreadable or refused.
    public var isLowerBound: Bool { truncated || unreadableCount > 0 || skippedCount > 0 }
}

/// One other account's home-folder total. Numbers only: the app turns the UID into a name itself,
/// so the helper never sends a name, a path or a listing.
public struct AccountSizeReply: Codable, Equatable, Sendable {
    public var uid: UInt32
    /// Allocated bytes of the home folder.
    public var bytes: Int64
    public var unreadableCount: Int
    /// Directories the walk refused to enter (world- or group-writable, R12/R21): not in `bytes`.
    public var skippedCount: Int
    /// The walk stopped on the shared deadline or its entry budget (or never started): `bytes`
    /// is a lower bound.
    public var truncated: Bool

    public init(uid: UInt32, bytes: Int64, unreadableCount: Int, skippedCount: Int = 0, truncated: Bool) {
        self.uid = uid
        self.bytes = bytes
        self.unreadableCount = unreadableCount
        self.skippedCount = skippedCount
        self.truncated = truncated
    }

    /// `bytes` is a lower bound: something was cut short, unreadable or refused.
    public var isLowerBound: Bool { truncated || unreadableCount > 0 || skippedCount > 0 }
}

public enum HelperErrorCode: String, Codable, Sendable, Error, CaseIterable {
    case invalidRequest, notFound, notPermitted, toolFailed, busy
    /// `rebuildSpotlightIndex` already ran in this boot session (the once-per-boot limit).
    case alreadyDoneThisBoot
}
