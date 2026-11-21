import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
private struct SystemFolderAutomationRegistration: AppLoginRegistration {
    private let service = SMAppService.agent(plistName: FolderAutomationWorker.plistName)

    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Coordinates the user's macOS registration with the app's durable rule ownership.
@MainActor @Observable
public final class FolderAutomationServiceModel {
    public private(set) var status: LoginItemModel.Status = .off
    public private(set) var isChanging = false
    public private(set) var problem: String?

    private let registration: any AppLoginRegistration
    private let bundled: Bool
    private let isOwnedByWorker: () -> Bool
    private let hasEligibleRules: () -> Bool
    private let changeOwner: (Bool) -> String?
    private let hasOtherInstances: () -> Bool

    init(automation: FolderAutomationModel) {
        let bundle = Bundle.main.bundleURL
        let plist = bundle.appendingPathComponent("Contents/Library/LaunchAgents/\(FolderAutomationWorker.plistName)")
        let worker = bundle.appendingPathComponent("Contents/MacOS/diskplain-automation-worker")
        bundled = FileManager.default.isReadableFile(atPath: plist.path)
            && FileManager.default.isExecutableFile(atPath: worker.path)
        registration = SystemFolderAutomationRegistration()
        isOwnedByWorker = { automation.runsAfterQuit }
        hasEligibleRules = { automation.hasAfterQuitEligibleRules }
        changeOwner = { automation.setRunsAfterQuit($0) }
        hasOtherInstances = {
            guard let id = Bundle.main.bundleIdentifier else { return false }
            let pid = ProcessInfo.processInfo.processIdentifier
            return NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .contains {
                    $0.processIdentifier != pid && !$0.isTerminated
                        && $0.executableURL?.lastPathComponent != "diskplain-automation-worker"
                }
        }
        refresh()
    }

    init(registration: any AppLoginRegistration, bundled: Bool, isOwnedByWorker: @escaping () -> Bool,
         hasEligibleRules: @escaping () -> Bool, changeOwner: @escaping (Bool) -> String?,
         hasOtherInstances: @escaping () -> Bool = { false }) {
        self.registration = registration
        self.bundled = bundled
        self.isOwnedByWorker = isOwnedByWorker
        self.hasEligibleRules = hasEligibleRules
        self.changeOwner = changeOwner
        self.hasOtherInstances = hasOtherInstances
        refresh()
    }

    public var isEnabled: Bool { isOwnedByWorker() }
    public var isRegistered: Bool { status == .enabled || status == .requiresApproval }
    public var canEnable: Bool { bundled && hasEligibleRules() }

    public func refresh() {
        guard bundled else { status = .unavailable; return }
        switch registration.status {
        case .notRegistered, .notFound: status = .off
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        @unknown default: status = .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) async {
        guard !isChanging else { return }
        isChanging = true
        problem = nil
        defer { refresh(); isChanging = false }
        refresh()

        if enabled {
            guard !isEnabled else { return }
            guard canEnable else {
                problem = "Add an eligible rule before enabling background automation."
                return
            }
            guard !hasOtherInstances() else {
                problem = "Quit the other copy of Andromeda before enabling background automation."
                return
            }
            let registeredHere = status == .off
            do {
                if registeredHere { try registration.register() }
                refresh()
                if status == .requiresApproval { return }
                guard status == .enabled else {
                    problem = "macOS hasn’t enabled the background worker."
                    return
                }
                let error = hasOtherInstances()
                    ? "Quit the other copy of Andromeda before enabling background automation."
                    : changeOwner(true)
                if let error {
                    problem = error
                    if registeredHere {
                        do {
                            try await registration.unregister()
                        } catch let unregisterError {
                            problem = "\(error) macOS couldn’t unregister the worker. \(unregisterError.localizedDescription)"
                        }
                    }
                }
            } catch {
                problem = error.localizedDescription
            }
        } else {
            do {
                if isRegistered { try await registration.unregister() }
                refresh()
                guard !isRegistered else {
                    problem = "macOS hasn’t stopped the background worker."
                    return
                }
                if isEnabled { problem = changeOwner(false) }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    public func openSystemSettings() { registration.openSettings() }
}
