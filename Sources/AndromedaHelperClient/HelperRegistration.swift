import Foundation
import ServiceManagement
import AndromedaHelperProtocol

/// The app's view of the helper's launchd registration. Tests use a fake; only
/// `LiveHelperRegistration` touches SMAppService.
public protocol HelperRegistration: Sendable {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openSettings()
}

/// Wraps `SMAppService.daemon(plistName:)` for the bundled helper plist.
public struct LiveHelperRegistration: HelperRegistration {
    public init() {}

    private var service: SMAppService { SMAppService.daemon(plistName: HelperIdentity.plistName) }

    public var status: SMAppService.Status {
        Self.effectiveStatus(rawStatus, plistBundled: Self.helperBundled(in: Bundle.main.bundleURL))
    }

    /// What SMAppService itself reports, before the `.notFound` mapping (for diagnostics).
    public var rawStatus: SMAppService.Status { service.status }

    /// A daemon that has never been registered reads `.notFound` on macOS 27, the same as one whose
    /// plist is missing. With the plist in the bundle it is just not registered yet.
    public static func effectiveStatus(_ raw: SMAppService.Status, plistBundled: Bool) -> SMAppService.Status {
        raw == .notFound && plistBundled ? .notRegistered : raw
    }

    /// Both the launchd plist and the helper binary it names are in the bundle.
    public static func helperBundled(in app: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: bundledPlistURL(in: app).path)
            && fm.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/diskplain-helper").path)
    }

    public static func bundledPlistURL(in app: URL) -> URL {
        app.appendingPathComponent("Contents/Library/LaunchDaemons").appendingPathComponent(HelperIdentity.plistName)
    }

    public func register() throws { try service.register() }

    public func unregister() async throws { try await service.unregister() }

    /// Opens System Settings > General > Login Items, where the user approves the helper.
    public func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
