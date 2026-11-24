import Foundation
import os
import AndromedaHelperProtocol

/// The exported XPC object. Every reply block is called exactly once.
///
/// Work runs on one serial queue, one request at a time. A `measure`, `measureOtherAccounts` or
/// `rebuildSpotlightIndex` that arrives while another is running is refused with `.busy` rather
/// than queued, so a client cannot pile up root work. `version` does no work and replies immediately.
public final class HelperService: NSObject, AndromedaHelperXPC, @unchecked Sendable {
    private let measureOp: @Sendable (String, uid_t) -> Result<MeasureReply, HelperErrorCode>
    private let spotlightOp: @Sendable () -> HelperErrorCode?
    private let dnsOp: @Sendable () -> HelperErrorCode?
    private let otherAccountsOp: @Sendable (uid_t) -> Result<[AccountSizeReply], HelperErrorCode>
    private let queue = DispatchQueue(label: "\(HelperIdentity.helperBundleID).work")
    private let log = Logger(subsystem: HelperIdentity.helperBundleID, category: "service")

    /// Guards `inFlight` and `drained`.
    private let lock = NSLock()
    private var inFlight = false
    /// Run once when the in-flight operation finishes (armed by `whenIdle`).
    private var drained: (@Sendable () -> Void)?

    public convenience init(
        measure: MeasureOperation = .init(), spotlight: SpotlightOperation = .init(),
        otherAccounts: OtherAccountsOperation = .init()
    ) {
        self.init(
            measure: { measure.run(entryIDRaw: $0, callerUID: $1) },
            rebuildSpotlight: { spotlight.run() },
            measureOtherAccounts: { otherAccounts.run(callerUID: $0) },
            flushDNS: {
                let runner = LiveCommandRunner()
                guard runner.run(.flushDNSDirectoryCache).exitCode == 0 else { return .toolFailed }
                if runner.run(.flushMulticastDNSCache).exitCode == 0 { return nil }
                return runner.run(.flushLegacyMulticastDNSCache).exitCode == 0 ? nil : .toolFailed
            })
    }

    /// Test seam: inject the operations.
    init(
        measure: @escaping @Sendable (String, uid_t) -> Result<MeasureReply, HelperErrorCode>,
        rebuildSpotlight: @escaping @Sendable () -> HelperErrorCode?,
        measureOtherAccounts: @escaping @Sendable (uid_t) -> Result<[AccountSizeReply], HelperErrorCode>,
        flushDNS: @escaping @Sendable () -> HelperErrorCode? = { .toolFailed }
    ) {
        self.measureOp = measure
        self.spotlightOp = rebuildSpotlight
        self.dnsOp = flushDNS
        self.otherAccountsOp = measureOtherAccounts
    }

    public func version(reply: @escaping @Sendable (String) -> Void) {
        log.info("op=version pid=\(Peer.current().pid, privacy: .public) result=ok")
        reply(HelperIdentity.version)
    }

    public func measure(entryID: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
        let peer = Peer.current()
        let pid = peer.pid
        guard begin() else {
            log.notice("op=measure pid=\(pid, privacy: .public) result=busy")
            reply(nil, HelperErrorCode.busy.rawValue)
            return
        }
        queue.async { [self] in
            let data: Data?
            let code: HelperErrorCode?
            switch measureOp(entryID, peer.uid) {
            case .success(let r):
                if let encoded = try? JSONEncoder().encode(r) {
                    (data, code) = (encoded, nil)
                } else {
                    (data, code) = (nil, .toolFailed)
                }
                // r.entryID passed EntryID validation, so it is a short [a-z0-9-] catalog ID.
                log.info("op=measure pid=\(pid, privacy: .public) entry=\(r.entryID, privacy: .public) result=\(code?.rawValue ?? "ok", privacy: .public)")
            case .failure(let e):
                (data, code) = (nil, e)
                // The raw ID failed validation or lookup: never logged.
                log.notice("op=measure pid=\(pid, privacy: .public) result=\(e.rawValue, privacy: .public)")
            }
            let hook = end()
            reply(data, code?.rawValue)
            hook?()
        }
    }

    public func measureOtherAccounts(reply: @escaping @Sendable (Data?, String?) -> Void) {
        let peer = Peer.current()
        let pid = peer.pid
        guard begin() else {
            log.notice("op=measureOtherAccounts pid=\(pid, privacy: .public) result=busy")
            reply(nil, HelperErrorCode.busy.rawValue)
            return
        }
        queue.async { [self] in
            let data: Data?
            let code: HelperErrorCode?
            switch otherAccountsOp(peer.uid) {
            case .success(let rows):
                if let encoded = try? JSONEncoder().encode(rows) {
                    (data, code) = (encoded, nil)
                } else {
                    (data, code) = (nil, .toolFailed)
                }
                // A count only: never UIDs, names or home paths.
                log.info("op=measureOtherAccounts pid=\(pid, privacy: .public) accounts=\(rows.count, privacy: .public) result=\(code?.rawValue ?? "ok", privacy: .public)")
            case .failure(let e):
                (data, code) = (nil, e)
                log.notice("op=measureOtherAccounts pid=\(pid, privacy: .public) result=\(e.rawValue, privacy: .public)")
            }
            let hook = end()
            reply(data, code?.rawValue)
            hook?()
        }
    }

    public func rebuildSpotlightIndex(reply: @escaping @Sendable (String?) -> Void) {
        runMaintenance(spotlightOp, name: "rebuildSpotlightIndex", reply: reply)
    }

    public func flushDNSCache(reply: @escaping @Sendable (String?) -> Void) {
        runMaintenance(dnsOp, name: "flushDNSCache", reply: reply)
    }

    private func runMaintenance(_ operation: @escaping @Sendable () -> HelperErrorCode?, name: String,
                                reply: @escaping @Sendable (String?) -> Void) {
        let pid = Peer.current().pid
        guard begin() else {
            log.notice("op=\(name, privacy: .public) pid=\(pid, privacy: .public) result=busy")
            reply(HelperErrorCode.busy.rawValue)
            return
        }
        queue.async { [self] in
            let code = operation()
            log.notice("op=\(name, privacy: .public) pid=\(pid, privacy: .public) result=\(code?.rawValue ?? "ok", privacy: .public)")
            let hook = end()
            reply(code?.rawValue)
            hook?()
        }
    }

    /// Claims the single in-flight slot; false if a request is already running.
    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlight { return false }
        inFlight = true
        return true
    }

    /// Releases the slot before replying, so a client may send its next request from the reply
    /// block. Returns the armed drained hook (if any) for the caller to run after the reply.
    private func end() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        inFlight = false
        let hook = drained
        drained = nil
        return hook
    }

    /// Runs `body` now if no operation is in flight, otherwise once the running one finishes.
    /// A later call replaces an earlier, still-pending one. `body` runs outside the lock.
    func whenIdle(_ body: @escaping @Sendable () -> Void) {
        lock.lock()
        if inFlight {
            drained = body
            lock.unlock()
            return
        }
        lock.unlock()
        body()
    }
}

/// Who sent the current XPC message. Must be read on the thread delivering the message, before
/// hopping to `queue`: `NSXPCConnection.current()` is nil anywhere else.
struct Peer: Sendable {
    let pid: Int32
    let uid: uid_t

    /// When called directly (tests) there is no peer: pid -1 and `uid_t.max`, which is no
    /// account. Never root, so a missing connection can't pass for a privileged caller.
    static func current() -> Peer {
        guard let c = NSXPCConnection.current() else { return Peer(pid: -1, uid: .max) }
        return Peer(pid: c.processIdentifier, uid: c.effectiveUserIdentifier)
    }
}
