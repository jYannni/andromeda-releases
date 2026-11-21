import Foundation
import os
import AndromedaHelperProtocol

/// Accepts XPC connections only from a peer that satisfies the client code-signing requirement
/// and the runtime signing policy (hardened runtime, no banned entitlements), and calls `onIdle`
/// (production: `exit(0)`) once the helper has been idle for `linger` seconds: no open connection
/// and no operation in flight (spec §8.1 rev 3). Lingering keeps back-to-back calls clear of
/// launchd's 10 s respawn throttle.
public final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service: HelperService
    /// Always `HelperIdentity.clientRequirement` outside tests.
    let requirement: String
    /// Always `ClientSigningPolicy.check` outside tests.
    private let peerCheck: @Sendable (NSXPCConnection) -> Bool
    private let onIdle: @Sendable () -> Void
    /// Seconds of idleness before `onIdle`. Production: `productionLinger`.
    let linger: TimeInterval
    public static let productionLinger: TimeInterval = 30
    /// The linger timer's queue: never the global queues, which blocked work can saturate.
    private let lingerQueue = DispatchQueue(label: "\(HelperIdentity.helperBundleID).linger")
    private let log = Logger(subsystem: HelperIdentity.helperBundleID, category: "listener")

    /// Guards `open`, `nextToken` and `idleGeneration`.
    private let lock = NSLock()
    private var open = Set<Int>()
    private var nextToken = 0
    /// Bumped by every accepted connection and every arming: a linger that fires under a newer
    /// generation is stale and does nothing.
    private var idleGeneration = 0

    public convenience init(service: HelperService) {
        self.init(
            service: service, requirement: HelperIdentity.clientRequirement,
            peerCheck: ClientSigningPolicy.check, onIdle: { exit(0) }, linger: Self.productionLinger)
    }

    /// Test seam only: lets a test supply a requirement and a signing check its own (ad-hoc, not
    /// hardened) process satisfies, and observe idle.
    init(
        service: HelperService, requirement: String,
        peerCheck: @escaping @Sendable (NSXPCConnection) -> Bool,
        onIdle: @escaping @Sendable () -> Void,
        linger: TimeInterval = 0
    ) {
        self.service = service
        self.requirement = requirement
        self.peerCheck = peerCheck
        self.onIdle = onIdle
        self.linger = linger
    }

    /// Arms the linger at launch, so a helper launchd started for a peer it then refused (or
    /// that never connects) still exits.
    public func start() {
        armIdleExit()
    }

    var openConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return open.count
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The requirement must be in place before resume(): XPC then refuses every message from
        // a peer that does not satisfy it, and invalidates the connection.
        connection.setCodeSigningRequirement(requirement)

        // The requirement cannot express hardened runtime or banned entitlements: check the
        // running peer before resume(), so a refused peer never gets a message through.
        let pid = connection.processIdentifier
        guard peerCheck(connection) else {
            log.error("peer refused pid=\(pid, privacy: .public): signing policy (hardened runtime, entitlements)")
            connection.invalidate()
            // A refused peer neither ends nor extends the linger: it can't make us exit early,
            // and the launch-time arming bounds a helper it started.
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: AndromedaHelperXPC.self)
        connection.exportedObject = service

        lock.lock()
        let token = nextToken
        nextToken += 1
        open.insert(token)
        idleGeneration += 1  // cancels a pending linger
        lock.unlock()

        connection.interruptionHandler = { [log] in
            log.notice("connection interrupted pid=\(pid, privacy: .public)")
        }
        connection.invalidationHandler = { [weak self] in
            self?.connectionClosed(token: token, pid: pid)
        }
        log.info("connection accepted pid=\(pid, privacy: .public)")
        connection.resume()
        return true
    }

    private func connectionClosed(token: Int, pid: pid_t) {
        lock.lock()
        let removed = open.remove(token) != nil
        let idle = removed && open.isEmpty
        lock.unlock()
        log.info("connection invalidated pid=\(pid, privacy: .public)")
        guard idle else { return }
        armIdleExit()
    }

    private func armIdleExit() {
        lock.lock()
        idleGeneration += 1
        let generation = idleGeneration
        lock.unlock()
        lingerQueue.asyncAfter(deadline: .now() + linger) { [weak self] in
            // Never exit under a running operation (e.g. mdutil right after the client quits):
            // wait for it to finish, then re-check that nothing reopened in the meantime.
            self?.service.whenIdle { [weak self] in self?.exitIfStillIdle(generation: generation) }
        }
    }

    private func exitIfStillIdle(generation: Int) {
        lock.lock()
        let idle = open.isEmpty && idleGeneration == generation
        lock.unlock()
        guard idle else { return }
        log.info("no open connections and no work in flight, exiting")
        onIdle()
    }
}
