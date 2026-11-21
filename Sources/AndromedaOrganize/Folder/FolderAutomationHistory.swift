import AndromedaCore
import Foundation
import Synchronization

/// Resolves files already handled by automatic rules from one complete, readable journal.
public final class FolderAutomationHistory: Sendable {
    public struct Handled: Hashable, Sendable {
        private let path: String
        private let inode: UInt64
        private let changed: TimeInterval?

        public init(_ file: FolderAutomationRule.File, rule: FolderAutomationRule) {
            self.init(path: rule.directories.source.url.appendingPathComponent(file.relativePath).path,
                      inode: file.snapshot.fileID, changed: file.snapshot.changed?.timeIntervalSinceReferenceDate)
        }

        fileprivate init(path: String, inode: UInt64, changed: TimeInterval?) {
            self.path = path
            self.inode = inode
            self.changed = changed
        }

        public func exists(in history: Set<Self>) -> Bool {
            history.contains(self) || history.contains(.init(path: path, inode: inode, changed: nil))
        }
    }

    public init() {}

    private struct State: Sendable {
        let files: Set<Handled>
        let interruptedBatchIDs: Set<UUID>
    }

    private struct Cached: Sendable {
        let revision: Journal.Revision
        let state: State
        let entries: [JournalEntry]?
    }

    private let cache = Mutex<Cached?>(nil)

    public func files(in journal: Journal) -> Set<Handled>? {
        state(in: journal)?.files
    }

    public func interruptedBatchIDs(in journal: Journal) -> Set<UUID>? {
        state(in: journal)?.interruptedBatchIDs
    }

    private func state(in journal: Journal) -> State? {
        cache.withLock { cached in
            guard let snapshot = try? journal.snapshot(since: cached?.revision, readAppends: cached?.entries != nil) else {
                cached = nil
                return nil
            }
            let revision: Journal.Revision?
            let entries: [JournalEntry]
            let corruptLines: Int
            switch snapshot {
            case .unchanged:
                return cached?.state
            case .loaded(let current, let loaded, let corrupt):
                (revision, entries, corruptLines) = (current, loaded, corrupt)
            case .appended(let current, let added, let corrupt):
                guard let old = cached?.entries else { return nil }
                let replaced = Set(added.map(\.id))
                (revision, entries, corruptLines) = (current, old.filter { !replaced.contains($0.id) } + added, corrupt)
            }
            cached = nil
            guard corruptLines == 0 else { return nil }
            let state = Self.state(in: entries)
            if let revision {
                // Keep at most one decoded snapshot, including for logs with unusually small records.
                let retain = revision.supportsAppendRead && entries.count <= 60_000
                cached = Cached(revision: revision, state: state, entries: retain ? entries : nil)
            }
            return state
        }
    }

    private static func state(in entries: [JournalEntry]) -> State {
        let followUps = JournalHistory.followUps(entries: entries)
        var handled: Set<Handled> = []
        var interruptedBatchIDs: Set<UUID> = []
        for entry in entries {
            guard entry.relatesTo == nil, entry.catalogEntryID == OrganizeCatalogID.automation else { continue }
            let resolution = JournalHistory.resolve(entry, followUps: followUps[entry.id] ?? [])
            let state = resolution.outcome
            if state == .planned { interruptedBatchIDs.insert(entry.batchID) }
            guard let path = entry.originalPath, let inode = entry.fileID else { continue }
            if entry.resolvedAction == .copy {
                guard let changed = entry.automationSourceChanged else { continue }
                if state == .done || state == .restored
                    || (state == .planned && resolution.settle?.automationCopy?.fingerprint != nil) {
                    // Before the next run, History settles any prepared copy interrupted at publication.
                    handled.insert(Handled(path: path, inode: inode, changed: changed))
                }
                continue
            }
            // A file at its original path after a settled move was put back in History or by hand.
            if state == .restored || state == .done { handled.insert(Handled(path: path, inode: inode, changed: nil)) }
            // An in-place result is still in a watched folder. Protect it from other rules even
            // when the rename reached disk before its outcome was recorded.
            if state == .done || state == .planned, let folders = entry.automationDirectories,
               folders.source == folders.destination, let destination = entry.destinationPath {
                handled.insert(Handled(path: destination, inode: inode, changed: nil))
            }
        }
        return State(files: handled, interruptedBatchIDs: interruptedBatchIDs)
    }
}
