import AppKit

public protocol RunningAppsProvider: Sendable {
    func isRunning(bundleID: String) -> Bool
}

public struct LiveRunningApps: RunningAppsProvider {
    public init() {}

    public func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
