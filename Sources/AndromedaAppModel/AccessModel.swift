import AndromedaCore
import Foundation
import Observation

/// Full Disk Access state (spec §8). The probe lists one small directory, so it runs on the main actor.
@MainActor @Observable
public final class AccessModel {
    public static let deepLink = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    public static let securityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security")!

    public private(set) var fda: FDAStatus
    /// Set when the deep link failed and the user has to find the pane by hand.
    public private(set) var fallbackSteps: String?
    /// Set when access flips from denied to granted during this run; macOS only applies it after a relaunch.
    public var relaunchNote: String?

    @ObservationIgnored private let deps: AppDependencies

    public init(deps: AppDependencies) {
        self.deps = deps
        fda = deps.fda()
    }

    /// Called by the app when it becomes active again (the user may have just changed the setting).
    public func recheck() {
        let now = deps.fda()
        if fda == .denied && now == .granted { relaunchNote = Copy.App.relaunch }
        fda = now
    }

    /// v1 §8 rev 4: on macOS 27, the first refused protected read posts a one-time "Data Access Blocked" notice,
    /// and the access check needs one such read; say so before access is granted.
    public var blockedNoticeNote: String? {
        deps.env.osMajor >= 27 && fda != .granted ? Copy.App.blockedNotice : nil
    }

    public func openSettings() {
        fallbackSteps = nil
        if deps.workspace.open(Self.deepLink) { return }
        _ = deps.workspace.open(Self.securityPane)
        fallbackSteps = Copy.App.fallbackSteps
    }
}
