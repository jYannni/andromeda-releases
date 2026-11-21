import Darwin

extension StorageBrowser {
    public struct WholeCloneAnalysis: Equatable, Sendable {
        public let allocatedBytes: Int64
        /// Extra allocations avoided by counting observed identical data forks once.
        public let countedSharedBytes: Int64
        public var adjustedBytes: Int64 { allocatedBytes - countedSharedBytes }
    }
}

struct WholeCloneMetadata {
    let id: UInt64
    let mainBytes: Int64?
    let flags: UInt64?
}

/// The walk calls this once per inode. Only main data can be grouped. The remaining
/// allocation is already included in the walk's ordinary per-inode total.
struct WholeCloneAccounting {
    private struct Group {
        let mainBytes: Int64
        let refs: UInt32
        var members: UInt32 = 1
        var exact: Bool
    }

    let root: FileIdentity
    // This analysis is confined to the verified root's device.
    private var groups: [UInt64: Group] = [:]
    private var allocatedBytes: Int64 = 0
    private var overBudget = false
    private var sawFile = false
    private var supportsWholeCloneMetadata = false
    private static let maximumGroups = 250_000
    private static let fullyShared = UInt64(EF_MAY_SHARE_BLOCKS | EF_SHARES_ALL_BLOCKS)

    init(root: FileIdentity) { self.root = root }

    mutating func record(_ entry: DirectoryEntry, allocated: Int64) {
        guard !overBudget, entry.device == root.dev else { return }
        sawFile = true
        let (total, overflow) = allocatedBytes.addingReportingOverflow(allocated)
        guard !overflow else {
            overBudget = true
            return
        }
        allocatedBytes = total
        guard let clone = entry.wholeClone else { return }
        let main = clone.mainBytes ?? -1
        let refs = entry.cloneRefCount ?? 0
        let usable = entry.inode != 0 && main > 0 && main <= (entry.allocated ?? -1)
            && clone.id != 0 && refs > 0 && clone.flags != nil
        // Empty data forks are neutral even if APFS reports no clone references.
        supportsWholeCloneMetadata = supportsWholeCloneMetadata || usable || main == 0
        guard clone.id != 0 else { return }
        let exact = usable && refs > 1
            && (clone.flags ?? 0) & Self.fullyShared == Self.fullyShared
        if var group = groups[clone.id] {
            group.members += 1
            group.exact = group.exact && exact && group.mainBytes == main && group.refs == refs && group.members <= refs
            groups[clone.id] = group
        } else if groups.count >= Self.maximumGroups {
            overBudget = true
            groups.removeAll()
        } else {
            groups[clone.id] = Group(mainBytes: main, refs: refs, exact: exact)
        }
    }

    var analysis: StorageBrowser.WholeCloneAnalysis? {
        guard let adjustment, adjustment <= allocatedBytes else { return nil }
        return StorageBrowser.WholeCloneAnalysis(allocatedBytes: allocatedBytes, countedSharedBytes: adjustment)
    }

    var adjustment: Int64? {
        guard !overBudget, !sawFile || supportsWholeCloneMetadata else { return nil }
        var total: Int64 = 0
        for group in groups.values where group.exact && group.members > 1 {
            let (bytes, overflow) = group.mainBytes.multipliedReportingOverflow(by: Int64(group.members - 1))
            let (sum, sumOverflow) = total.addingReportingOverflow(bytes)
            guard !overflow, !sumOverflow else { return nil }
            total = sum
        }
        return total
    }
}
