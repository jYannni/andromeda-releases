#if ANDROMEDA_DIRECT_EVICT
import AndromedaCore
import Foundation

/// Direct eviction (decision 19a). Compiled only with `-DANDROMEDA_DIRECT_EVICT`.
///
/// Refuses unless the item is fully synced, frees at least one private byte and is confirmed not pinned.
/// Organize 1 never reads pin state (always `.unknown`), so even a flagged build refuses every real item.
/// Refusals are not journaled; a successful eviction journals `.evict` with the provider and bytes.
public struct Evictor {
    public enum Reason: Equatable, Sendable { case notSynced, freesNothing, pinNotConfirmed }

    public enum Outcome: Equatable, Sendable {
        case evicted
        case refused(Reason)
        case failed(String)
    }

    private let journal: Journal
    private let evictItem: (URL) throws -> Void

    public init(
        journal: Journal,
        evict: @escaping (URL) throws -> Void = { try FileManager.default.evictUbiquitousItem(at: $0) }
    ) {
        self.journal = journal
        self.evictItem = evict
    }

    public func evict(_ state: CloudItemState, batchID: UUID) -> Outcome {
        guard state.sync == .synced else { return .refused(.notSynced) }
        guard (state.freesAtLeast ?? 0) > 0 else { return .refused(.freesNothing) }
        guard state.pin == .notPinned else { return .refused(.pinNotConfirmed) }
        do {
            try evictItem(state.url)
        } catch {
            return .failed(String(describing: error))
        }
        let entry = JournalEntry(
            batchID: batchID, catalogEntryID: OrganizeCatalogID.evict, originalPath: state.url.path,
            bytes: state.usesBytes, privateBytes: state.freesAtLeast, clonesPresent: state.clonesPresent,
            outcome: .done, action: .evict, provider: state.provider.rawValue)
        do {
            try journal.append(entry)
        } catch {
            return .failed("evicted, but the journal write failed: \(error)")
        }
        return .evicted
    }
}
#endif
