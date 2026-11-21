import Foundation

public enum RemovalAction: Equatable, Sendable {
    case moveToTrash(URL)
    case runTool(executable: URL, arguments: [String])
    /// Carried out by the privileged helper. Never reversible.
    case privileged(PrivilegedOperation)
}

/// What a trash item looked like at scan time. The executor refuses to act if it no longer matches.
public struct ItemExpectation: Equatable, Sendable {
    public let bytes: Int64
    public let modified: Date

    public init(bytes: Int64, modified: Date) {
        self.bytes = bytes
        self.modified = modified
    }
}

public struct PlannedRemoval: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let catalogEntryID: String
    public let action: RemovalAction
    /// Allocated bytes ("uses"). With clones present this is not what removal gives back.
    public let expectedBytes: Int64?
    /// The bytes that belong to this item alone (spec §7.1 rev 2): the floor of what removal frees.
    /// nil when not measurable; never stands in for the allocated figure.
    public let privateBytes: Int64?
    /// Some of the item's space is shared with clones, so `privateBytes` is an estimate.
    public let clonesPresent: Bool
    /// Required for `.moveToTrash`: without it the executor skips the item.
    public let expectation: ItemExpectation?
    public let appsMustBeQuit: [String]
    let duplicateCheck: DuplicateScanner.TrashCheck?
    let applicationCheck: ApplicationCleanup.TrashCheck?
    let browserFileCheck: BrowserFileCleanup.TrashCheck?
    let similarImageCheck: SimilarImageCleanup.TrashCheck?
    public var retainedDuplicate: URL? { duplicateCheck?.keeperURL }
    public var allowsPermanentDeletion: Bool { TrashLedger.allowsPermanentDeletion(catalogEntryID) }
    public var isBrowserFileCleanup: Bool { browserFileCheck != nil }
    public var retainedSimilarImage: URL? { similarImageCheck?.keeper.url }

    public var reversible: Bool {
        if case .moveToTrash = action { true } else { false }
    }

    /// Internal on purpose: plans come only from `PlanBuilder`, which applies the actionable gate.
    init(
        id: UUID = UUID(), catalogEntryID: String, action: RemovalAction, expectedBytes: Int64?,
        privateBytes: Int64? = nil, clonesPresent: Bool = false,
        expectation: ItemExpectation?, appsMustBeQuit: [String], duplicateCheck: DuplicateScanner.TrashCheck? = nil,
        applicationCheck: ApplicationCleanup.TrashCheck? = nil, browserFileCheck: BrowserFileCleanup.TrashCheck? = nil,
        similarImageCheck: SimilarImageCleanup.TrashCheck? = nil
    ) {
        self.id = id
        self.catalogEntryID = catalogEntryID
        self.action = action
        self.expectedBytes = expectedBytes
        self.privateBytes = privateBytes
        self.clonesPresent = clonesPresent
        self.expectation = expectation
        self.appsMustBeQuit = appsMustBeQuit
        self.duplicateCheck = duplicateCheck
        self.applicationCheck = applicationCheck
        self.browserFileCheck = browserFileCheck
        self.similarImageCheck = similarImageCheck
    }
}

public struct RemovalPlan: Equatable, Sendable {
    public let batchID: UUID
    public let removals: [PlannedRemoval]

    /// Internal on purpose: plans come only from `PlanBuilder`, which applies the actionable gate.
    init(batchID: UUID = UUID(), removals: [PlannedRemoval]) {
        self.batchID = batchID
        self.removals = removals
    }

    /// Sum of the sizes we know; tool actions with an unknown size add nothing.
    public var totalExpectedBytes: Int64 {
        removals.reduce(0) { $0 + ($1.expectedBytes ?? 0) }
    }

    public var containsIrreversible: Bool {
        removals.contains { !$0.reversible }
    }

    /// The confirm button's label. It names the amount so the user knows what they're agreeing to.
    public var confirmTitle: String {
        let total = totalExpectedBytes
        guard total > 0 else { return "Remove selected items" }
        if removals.allSatisfy(\.reversible) {
            return "Move \(ByteFormat.string(total)) to Trash"
        }
        return "Remove \(ByteFormat.string(total))"
    }
}

public enum PlanError: Error, Equatable {
    /// Carries the catalog entry ID.
    case notActionable(String)
}

/// Turns the user's selected findings into concrete actions. Pure: touches nothing on disk.
public enum PlanBuilder {
    public static func buildSimilarImageCleanup(
        group: SimilarImageScanner.Group, selected: Set<URL>, env: ScanEnvironment
    ) -> RemovalPlan? {
        guard let checks = SimilarImageCleanup.checks(group: group, selected: selected, env: env) else { return nil }
        return RemovalPlan(removals: checks.map { check in
            PlannedRemoval(catalogEntryID: SimilarImageCleanup.catalogID, action: .moveToTrash(check.url),
                           expectedBytes: check.allocatedBytes, expectation: nil, appsMustBeQuit: [],
                           similarImageCheck: check)
        })
    }

    public static func buildInstallerCleanup(_ entries: [StorageBrowser.Entry], env: ScanEnvironment) -> RemovalPlan? {
        buildBrowserCleanup(entries, scope: .installers, env: env)
    }

    public static func allowsBrowserCleanup(in folder: URL, home: URL) -> Bool {
        BrowserFileCleanup.Scope.allowsFolder(folder, home: home)
    }

    public static func canSelectBrowserFile(_ entry: StorageBrowser.Entry, in folder: StorageBrowser.FolderReference,
                                            home: URL) -> Bool {
        BrowserFileCleanup.Scope.folder(folder).canSelect(entry, home: home)
    }

    public static func buildBrowserFileCleanup(_ entries: [StorageBrowser.Entry], in folder: StorageBrowser.FolderReference,
                                               env: ScanEnvironment) -> RemovalPlan? {
        buildBrowserCleanup(entries, scope: .folder(folder), env: env)
    }

    private static func buildBrowserCleanup(_ entries: [StorageBrowser.Entry], scope: BrowserFileCleanup.Scope,
                                            env: ScanEnvironment) -> RemovalPlan? {
        guard !entries.isEmpty else { return nil }
        var removals: [PlannedRemoval] = []
        var identities: Set<FileIdentity> = []
        for entry in entries {
            guard let check = BrowserFileCleanup.TrashCheck(entry, scope: scope, env: env),
                  identities.insert(check.identity).inserted else { return nil }
            removals.append(PlannedRemoval(catalogEntryID: scope.catalogID,
                action: .moveToTrash(check.url), expectedBytes: check.bytes, expectation: nil,
                appsMustBeQuit: [], browserFileCheck: check))
        }
        return RemovalPlan(removals: removals)
    }

    public static func buildLeftoverCleanup(_ review: ApplicationCleanup.Leftovers, selected: Set<URL>) -> RemovalPlan? {
        buildLeftoverCleanup([review], selected: selected)
    }

    public static func buildLeftoverCleanup(_ reviews: [ApplicationCleanup.Leftovers], selected: Set<URL>) -> RemovalPlan? {
        guard !selected.isEmpty, selected.isSubset(of: Set(reviews.flatMap { $0.items.map(\.url) })) else { return nil }
        var removals: [PlannedRemoval] = []
        var paths = Set<String>()
        for review in reviews {
            let urls = selected.intersection(review.items.map(\.url))
            if urls.isEmpty { continue }
            guard urls.allSatisfy({ paths.insert(SafetyGuard.withoutSystemPathAlias($0.path)).inserted }),
                  let group = review.removals(selected: urls) else { return nil }
            removals += group
        }
        return RemovalPlan(removals: removals)
    }

    public static func buildApplicationCleanup(
        _ review: ApplicationCleanup, selected: Set<URL>, action: ApplicationCleanup.Action = .uninstall
    ) -> RemovalPlan? {
        review.removals(selected: selected, action: action).map { RemovalPlan(removals: $0) }
    }

    public static func buildApplicationUninstall(_ reviews: [ApplicationCleanup], selected: Set<URL>) -> RemovalPlan? {
        guard !reviews.isEmpty, selected.isSubset(of: Set(reviews.flatMap { $0.related.map(\.url) })) else { return nil }
        var removals: [PlannedRemoval] = []
        var paths: Set<String> = []
        for review in reviews {
            let related = selected.intersection(review.related.map(\.url))
            guard let group = review.removals(selected: related, action: .uninstall) else { return nil }
            for removal in group {
                guard case .moveToTrash(let url) = removal.action,
                      paths.insert(SafetyGuard.withoutSystemPathAlias(url.path)).inserted else { return nil }
                removals.append(removal)
            }
        }
        return RemovalPlan(removals: removals)
    }

    public static func buildDuplicateCleanup(
        group: DuplicateScanner.Group, selected: Set<URL>, env: ScanEnvironment
    ) -> RemovalPlan? {
        guard let checks = DuplicateScanner.trashChecks(in: group, selected: selected, env: env) else { return nil }
        return RemovalPlan(removals: checks.map { check in
            PlannedRemoval(catalogEntryID: DuplicateScanner.cleanupCatalogID, action: .moveToTrash(check.targetURL),
                           expectedBytes: nil, expectation: nil, appsMustBeQuit: [], duplicateCheck: check)
        })
    }

    public static func build(_ selected: [Finding]) throws -> RemovalPlan {
        var removals: [PlannedRemoval] = []
        for finding in selected {
            let entry = finding.entry
            guard finding.verdict.actionable else { throw PlanError.notActionable(entry.id) }

            switch entry.removal {
            case .trash:
                for item in finding.items {
                    removals.append(PlannedRemoval(
                        catalogEntryID: entry.id, action: .moveToTrash(item.url),
                        expectedBytes: item.bytes, privateBytes: item.privateBytes, clonesPresent: item.clonesPresent,
                        expectation: ItemExpectation(bytes: item.bytes, modified: item.modified),
                        appsMustBeQuit: entry.appsMustBeQuit))
                }
            case .tool(let executable, let arguments):
                removals.append(PlannedRemoval(
                    catalogEntryID: entry.id,
                    action: .runTool(executable: URL(fileURLWithPath: executable), arguments: arguments),
                    expectedBytes: finding.bytes, privateBytes: finding.freeableBytes,
                    clonesPresent: finding.clonesPresent, expectation: nil,
                    appsMustBeQuit: entry.appsMustBeQuit))
            case .deleteLocalSnapshots:
                let tmutil = URL(fileURLWithPath: "/usr/bin/tmutil")
                for snapshot in finding.snapshots where snapshot.kind == .timeMachine {
                    guard let date = snapshot.tmutilDate else { continue }
                    removals.append(PlannedRemoval(
                        catalogEntryID: entry.id,
                        action: .runTool(executable: tmutil, arguments: ["deletelocalsnapshots", date]),
                        expectedBytes: nil, expectation: nil,
                        appsMustBeQuit: entry.appsMustBeQuit))
                }
            case .handoff, .terminalCommand, .restart, .none:
                // The app can't carry these out itself; they're shown as instructions instead.
                throw PlanError.notActionable(entry.id)
            }
        }
        return RemovalPlan(removals: removals)
    }
}
