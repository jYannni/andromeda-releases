import Foundation
import Observation
import ServiceManagement

@MainActor
protocol AppLoginRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openSettings()
}

private struct SystemAppLoginRegistration: AppLoginRegistration {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor @Observable
public final class LoginItemModel {
    public enum Status: Equatable {
        case off, enabled, requiresApproval, unavailable
    }

    public private(set) var status: Status = .off
    public private(set) var isChanging = false
    public private(set) var problem: String?

    private let registration: any AppLoginRegistration

    public convenience init() { self.init(registration: SystemAppLoginRegistration()) }

    init(registration: any AppLoginRegistration) {
        self.registration = registration
        refresh()
    }

    public var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    public func refresh() {
        switch registration.status {
        // macOS can report no record for a main app that has never registered.
        case .notRegistered, .notFound: status = .off
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        @unknown default: status = .unavailable
        }
    }

    public func setRegistered(_ registered: Bool) async {
        guard !isChanging else { return }
        refresh()
        guard status != .unavailable, registered != isRegistered else { return }
        isChanging = true
        problem = nil
        defer {
            refresh()
            isChanging = false
        }
        do {
            if registered {
                try registration.register()
            } else {
                try await registration.unregister()
            }
        } catch {
            refresh()
            if isRegistered != registered { problem = error.localizedDescription }
        }
    }

    public func openSystemSettings() { registration.openSettings() }
}
