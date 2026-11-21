import AndromedaCore
import AndromedaHelperClient
import AndromedaHelperProtocol
import Foundation
import Observation
import ServiceManagement

public enum HelperState: Equatable, Sendable {
    case off
    case waitingForApproval
    case checking
    case ready
    case dead
    case needsReapproval(reason: String)
    case failed(String)
}

/// The app's view of the opt-in root helper (spec §8.1). Nothing here registers the helper except
/// `turnOn()` and `recover()`, and nothing talks to it while its status is `.notRegistered`.
@MainActor @Observable
public final class HelperModel: RootMeasuring {
    public private(set) var state: HelperState = .off
    /// A sentence that replaces the state's own status text until the next lifecycle call: set when
    /// "Set up helper again" removed the helper but couldn't register it again (F8).
    public private(set) var note: String?

    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private let timeout: TimeInterval
    @ObservationIgnored private var cachedClient: HelperClient?
    private var isMeasuring = false
    /// Removals currently running with a runner from `privilegedRunner()` (see `beginPrivilegedUse`).
    private var privilegedUses = 0
    /// Bumped by every lifecycle call, so a measurement that started before one never overwrites its state.
    @ObservationIgnored private var lifecycle = 0
    /// Set after Andromeda registered its own helper (turn on, set up again). If the first helper that
    /// answers afterwards still has another version, it belongs to another copy of Andromeda (F5).
    @ObservationIgnored private var expectingOwnHelper = false

    /// `timeout` is how long one helper call may take before the helper counts as silent.
    public init(deps: AppDependencies, timeout: TimeInterval = 15) {
        self.deps = deps
        self.timeout = timeout
    }

    public var isReady: Bool { state == .ready }

    /// What Settings shows for the helper.
    public var statusText: String { note ?? state.statusText }

    /// What the helper sheet shows under the explainer.
    public var sheetNote: String? { note ?? state.sheetNote }

    /// True while `measureAll` runs or a removal is using a privileged runner.
    public var isInUse: Bool { isMeasuring || privilegedUses > 0 }

    /// Settings offers Remove helper and Set up helper again only while nothing is using the helper (P14).
    public var canChangeHelper: Bool { !isInUse }

    /// Built on first use, so constructing the model never touches XPC.
    private func client() -> HelperClient {
        if let cachedClient { return cachedClient }
        let c = HelperClient(registration: deps.registration, connect: deps.helperConnect, timeout: timeout)
        cachedClient = c
        return c
    }

    // MARK: Lifecycle

    /// Reads the registration status and, unless it is `.notRegistered`, asks the helper for its version.
    public func refresh() async {
        lifecycle += 1
        note = nil
        switch deps.registration.status {
        case .notRegistered:
            state = .off
        case .notFound:
            state = .failed(Copy.Helper.notFound)
        case .requiresApproval:
            // The status can lag behind the user's approval (F4), and `version()` refuses to try while
            // it reads requiresApproval. `probeVersion()` skips that check: if the helper answers, it is ready.
            state = .checking
            await probe(notAnswering: .waitingForApproval) { try await $0.probeVersion() }
        case .enabled:
            state = .checking
            // F3: enabled but silent means the service is dead.
            await probe(notAnswering: .dead) { try await $0.version() }
        @unknown default:
            state = .off
        }
    }

    /// Called when the app comes back to the front. Approving the helper in Login Items happens in
    /// System Settings, so while waiting for that approval, look again (plan 3.1 proposal 9).
    /// Every other state is left alone. Overlapping calls refresh once: `refresh()` leaves
    /// `.waitingForApproval` before its first suspension, so a second call finds another state.
    public func appBecameActive() async {
        guard state == .waitingForApproval else { return }
        await refresh()
    }

    /// Register, then read the status. `register()` reports "Operation not permitted" when the real
    /// state is "awaiting approval" (F4), so a throw is judged by the status that follows it.
    public func turnOn() async {
        lifecycle += 1
        note = nil
        do {
            try deps.registration.register()
        } catch {
            if deps.registration.status == .requiresApproval {
                expectingOwnHelper = true
                state = .waitingForApproval
                deps.registration.openSettings()
            } else {
                state = .failed(Copy.Helper.registerFailed)
            }
            return
        }
        expectingOwnHelper = true
        if deps.registration.status == .requiresApproval {
            state = .waitingForApproval
            deps.registration.openSettings()
        } else {
            await refresh()
        }
    }

    /// For a helper that is dead or out of date: unregister, register again, and send the user to Login Items.
    public func recover() async {
        lifecycle += 1
        note = nil
        disconnect()
        var removedOld = true
        do {
            try await deps.registration.unregister()
        } catch {
            removedOld = false
            // A service that was never registered can't be unregistered; registering is still the way on.
            // Otherwise nothing was unregistered, so nothing changed.
            let status = deps.registration.status
            guard status == .notRegistered || status == .notFound else {
                state = .failed(Copy.Helper.registerFailed)
                return
            }
        }
        do {
            try deps.registration.register()
        } catch {
            // The old helper is gone now; say where that leaves the user (F8).
            switch deps.registration.status {
            case .requiresApproval:
                break
            case .notRegistered where !removedOld:
                // Nothing was registered before and nothing is now.
                state = .failed(Copy.Helper.registerFailed)
                return
            case .notRegistered:
                state = .off
                note = Copy.Helper.recoverLeftOff
                return
            default:
                await refresh()
                return
            }
        }
        expectingOwnHelper = true
        state = .waitingForApproval
        deps.registration.openSettings()
    }

    public func remove() async {
        lifecycle += 1
        note = nil
        expectingOwnHelper = false
        disconnect()
        do {
            try await deps.registration.unregister()
            state = .off
        } catch {
            state = .failed(Copy.Helper.registerFailed)
        }
    }

    public func openSettings() { deps.registration.openSettings() }

    /// Drops the connection; the next call opens a new one and checks the version again.
    public func disconnect() {
        cachedClient?.disconnect()
        cachedClient = nil
    }

    // MARK: Using the helper

    /// Measures one entry at a time, in order, then (when asked) other accounts' folders, then
    /// disconnects. Entries whose call fails are left out. Returns an empty result unless the helper is ready.
    /// Stops asking once `shouldContinue` says no (a cancelled scan).
    public func measureAll(
        _ entryIDs: [String], includingOtherAccounts: Bool, shouldContinue: @escaping @MainActor @Sendable () -> Bool
    ) async -> RootMeasurements {
        // One run at a time: an overlapping call would hit the helper's busy answer, and this run's
        // disconnect() would cut the other's call off.
        guard isReady, !isMeasuring else { return RootMeasurements() }
        isMeasuring = true
        defer { isMeasuring = false }
        let started = lifecycle
        let c = client()
        var out = RootMeasurements(helperOn: true)
        var helperLost = false
        for id in entryIDs {
            // A lifecycle call (remove, set up again, refresh) owns the state now: stop, and write nothing.
            guard lifecycle == started, shouldContinue() else { break }
            do {
                let r = try await c.measure(entryID: id)
                out.entries[id] = RootMeasurement(
                    bytes: r.bytes, privateBytes: r.privateBytes, clonesPresent: r.clonesPresent,
                    unreadableCount: r.unreadableCount, skippedCount: r.skippedCount, truncated: r.truncated)
            } catch let error as HelperClientError {
                if let next = Self.state(afterMeasureError: error) {
                    if lifecycle == started { state = next }
                    helperLost = true
                    break
                }
            } catch {
                continue
            }
        }
        // Same connection as the entries: a new one would wait on launchd starting the helper again.
        if includingOtherAccounts, !helperLost, lifecycle == started, shouldContinue() {
            out.otherAccounts = await measureOtherAccounts(with: c, started: started)
        }
        // Drop only this run's connection; a lifecycle call may have opened a newer one.
        if cachedClient === c { disconnect() } else { c.disconnect() }
        return out
    }

    /// A standard user is refused (`.notPermitted`); any other failure reads as unavailable.
    private func measureOtherAccounts(with c: HelperClient, started: Int) async -> OtherAccountsAnswer {
        do {
            return .measured(try await c.measureOtherAccounts())
        } catch HelperClientError.rejected(.notPermitted) {
            return .notPermitted
        } catch let error as HelperClientError {
            if let next = Self.state(afterMeasureError: error), lifecycle == started { state = next }
            return .unavailable
        } catch {
            return .unavailable
        }
    }

    public func privilegedRunner() -> (any PrivilegedRunner)? {
        isReady ? XPCPrivilegedRunner(client: client()) : nil
    }

    /// RemovalFlow brackets a run whose plan contains a privileged removal with these, so Settings
    /// can't remove or re-register the helper underneath it.
    public func beginPrivilegedUse() { privilegedUses += 1 }
    public func endPrivilegedUse() { privilegedUses = max(0, privilegedUses - 1) }

    // MARK: Mapping

    private func probe(
        notAnswering: HelperState, _ ask: (HelperClient) async throws -> String
    ) async {
        let started = lifecycle
        var next: HelperState
        var answered = false
        do {
            let version = try await ask(client())
            answered = true
            next = version == HelperIdentity.version ? .ready : .needsReapproval(reason: Copy.Helper.updated)
        } catch let error as HelperClientError {
            if case .versionMismatch = error { answered = true }
            next = Self.state(afterVersionError: error, notAnswering: notAnswering)
        } catch {
            next = notAnswering
        }
        // A later lifecycle call (say, Remove helper pressed meanwhile) owns the state now.
        guard lifecycle == started else { return }
        if answered {
            // Andromeda just registered its own helper, yet another version answers (F5).
            if expectingOwnHelper, case .needsReapproval = next { next = .needsReapproval(reason: Copy.Helper.otherCopy) }
            expectingOwnHelper = false
        }
        state = next
        if state != .ready { disconnect() }
    }

    static func state(afterVersionError error: HelperClientError, notAnswering: HelperState) -> HelperState {
        switch error {
        case .versionMismatch: .needsReapproval(reason: Copy.Helper.updated)
        case .needsRelogin: .failed(Copy.Helper.relogin)
        case .awaitingApproval: .waitingForApproval
        case .notRegistered: .off
        case .timeout, .connection, .rejected: notAnswering
        }
    }

    /// nil: the call failed on its own and the helper is fine, so the next entry is tried.
    static func state(afterMeasureError error: HelperClientError) -> HelperState? {
        switch error {
        case .timeout, .connection: .dead
        case .versionMismatch: .needsReapproval(reason: Copy.Helper.updated)
        case .needsRelogin: .failed(Copy.Helper.relogin)
        case .awaitingApproval: .waitingForApproval
        case .notRegistered: .off
        case .rejected: nil
        }
    }
}
