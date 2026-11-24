import Foundation

/// Each command has a fixed purpose and target. Descriptions also appear in the confirmation sheet.
public enum MaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case spotlight, dns, verifyDisk

    public var id: Self { self }
    public var title: String {
        switch self {
        case .spotlight: "Rebuild Spotlight Index"
        case .dns: "Flush DNS Cache"
        case .verifyDisk: "Verify Startup Disk"
        }
    }
    public var detail: String {
        switch self {
        case .spotlight: "Use when search misses known files. Search results may be incomplete while macOS reindexes."
        case .dns: "Clear cached DNS answers when a changed network address hasn’t taken effect."
        case .verifyDisk: "Check the startup data volume for filesystem errors. The check does not run repairs."
        }
    }
    public var requiresHelper: Bool { self != .verifyDisk }

    public func plan(osMajor: Int, helperReady: Bool) -> RemovalPlan? {
        let action: RemovalAction
        switch self {
        case .spotlight:
            guard helperReady, let catalog = try? BundledCatalog.load(),
                  let entry = catalog.first(where: { $0.id == "spotlight-index" }),
                  PlanBuilder.helperCanRebuildSpotlight(entry, osMajor: osMajor) else { return nil }
            action = .privileged(.rebuildSpotlightIndex)
        case .dns:
            guard helperReady else { return nil }
            action = .privileged(.flushDNSCache)
        case .verifyDisk:
            action = .runTool(executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),
                              arguments: ["verifyVolume", "/System/Volumes/Data"])
        }
        return RemovalPlan(removals: [PlannedRemoval(catalogEntryID: "maintenance-" + rawValue,
                                                      action: action, expectedBytes: nil,
                                                      expectation: nil, appsMustBeQuit: [])])
    }
}
