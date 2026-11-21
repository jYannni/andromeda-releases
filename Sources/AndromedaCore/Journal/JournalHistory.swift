import Foundation

public struct HistoryItem: Identifiable, Equatable, Sendable {
    /// The original journal entry's ID.
    public let id: UUID
    public let catalogEntryID: String
    public let originalPath: String?
    public let command: [String]?
    /// Allocated bytes ("uses").
    public let bytes: Int64?
    /// The floor of what deleting it frees; nil when not measurable or not recorded.
    public let privateBytes: Int64?
    /// nil when the entry was written before clone figures were recorded.
    public let clonesPresent: Bool?
    /// The latest outcome, after any restore, delete or gone-from-Trash follow-up.
    public let outcome: Outcome
    /// The latest undo-time skipped/failed follow-up of an organize item that is still applied
    /// (`outcome == .done`); cleared by a later restore. Audit only (rulings R8, R10).
    public let undoProblem: Outcome?
    public let action: JournalAction
    public let destinationPath: String?
    /// Raw value of `CloudProvider`, when recorded.
    public let provider: String?
    public var isCloudOrganize = false
}

public enum BatchKind: Equatable, Sendable { case removal, organize, moveToCloud
    /// Direct eviction rows (`.evict`, flagged builds only). No History UI: shown like nothing-to-undo.
    case offload
}

public struct HistoryBatch: Identifiable, Equatable, Sendable {
    /// The batch ID.
    public let id: UUID
    public let started: Date
    public let items: [HistoryItem]
    /// Items in this batch that can still be restored from the Trash.
    public let restorableIDs: Set<UUID>
    public let kind: BatchKind
    /// Some original's latest outcome is still `.planned`: the run stopped before settling it.
    public let interrupted: Bool
    public let planID: UUID?
}

/// An original's state after its follow-ups.
public struct JournalResolution: Equatable, Sendable {
    public let outcome: Outcome
    /// The follow-up that set `outcome`; nil while the original's own outcome stands.
    public let settle: JournalEntry?
    public let undoProblem: Outcome?
}

public enum JournalHistory {
    /// Organize rows (rulings R8, R10, R11): follow-ups match within the same batch, and once applied
    /// a row ends only on `restored`.
    public static func isOrganize(_ e: JournalEntry) -> Bool {
        switch e.resolvedAction {
        case .move, .copy, .createFolder, .evict: true
        case .trash, .command: false
        }
    }

    /// Follow-ups per original, in journal (load) order. Entries whose original is missing are dropped; a
    /// follow-up of an organize original must share its batch. v1 originals match by id alone, as before.
    public static func followUps(entries: [JournalEntry]) -> [UUID: [JournalEntry]] {
        var originals: [UUID: JournalEntry] = [:]
        for e in entries where e.relatesTo == nil { originals[e.id] = e }
        var out: [UUID: [JournalEntry]] = [:]
        for e in entries {
            guard let target = e.relatesTo, let o = originals[target] else { continue }
            if isOrganize(o), o.batchID != e.batchID { continue }
            out[target, default: []].append(e)
        }
        return out
    }

    /// The one resolution used by History and by `BatchUndo`. `followUps` are in journal order.
    public static func resolve(_ original: JournalEntry, followUps: [JournalEntry]) -> JournalResolution {
        var state = original.outcome
        var settle: JournalEntry?
        var problem: Outcome?
        let organize = isOrganize(original)
        for f in followUps {
            if organize, state == .done {
                switch f.outcome {
                case .skipped, .failed: problem = f.outcome; continue
                default: break
                }
            }
            state = f.outcome
            settle = f
            problem = nil
        }
        return JournalResolution(outcome: state, settle: settle, undoProblem: problem)
    }

    /// Groups journal entries into batches, newest first. Follow-up entries (`relatesTo`) replace
    /// their original's outcome and never appear as items of their own.
    public static func batches(entries: [JournalEntry], restorable: [JournalEntry]) -> [HistoryBatch] {
        let followUps = followUps(entries: entries)
        func resolve(_ original: JournalEntry) -> JournalResolution {
            Self.resolve(original, followUps: followUps[original.id] ?? [])
        }
        let restorableIDs = Set(restorable.map(\.id))

        var order: [UUID] = []
        var grouped: [UUID: [JournalEntry]] = [:]
        for e in entries where e.relatesTo == nil {
            if grouped[e.batchID] == nil { order.append(e.batchID) }
            grouped[e.batchID, default: []].append(e)
        }

        return order.compactMap { batchID -> HistoryBatch? in
            guard let members = grouped[batchID], let started = members.map(\.timestamp).min() else { return nil }
            let items = members.map { e -> HistoryItem in
                let r = resolve(e)
                let outcome = r.outcome == .planned && restorableIDs.contains(e.id) ? Outcome.done : r.outcome
                return HistoryItem(
                    id: e.id, catalogEntryID: e.catalogEntryID, originalPath: e.originalPath,
                    command: e.command, bytes: e.bytes, privateBytes: e.privateBytes,
                    clonesPresent: e.clonesPresent, outcome: outcome, undoProblem: r.undoProblem,
                    action: e.resolvedAction, destinationPath: e.destinationPath, provider: e.provider,
                    isCloudOrganize: e.cloudOrganizeFolder != nil)
            }
            let kind: BatchKind =
                members.contains { $0.catalogEntryID == OrganizeCatalogID.cloudMove } ? .moveToCloud
                : members.contains { [.move, .copy, .createFolder].contains($0.resolvedAction) } ? .organize
                : members.contains { $0.resolvedAction == .evict } ? .offload
                : .removal
            return HistoryBatch(
                id: batchID, started: started, items: items,
                restorableIDs: Set(items.map(\.id)).intersection(restorableIDs),
                kind: kind, interrupted: items.contains { $0.outcome == .planned },
                planID: members.lazy.compactMap(\.planID).first)
        }
        .sorted { $0.started > $1.started }
    }
}
