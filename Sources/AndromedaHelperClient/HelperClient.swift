import Foundation
import ServiceManagement
import AndromedaHelperProtocol

public enum HelperClientError: Error, Equatable, Sendable {
    /// The daemon isn't registered (or its plist is missing from the bundle).
    case notRegistered
    /// Registered, but the user hasn't approved it in System Settings > Login Items yet.
    case awaitingApproval
    /// Registered and enabled, yet unreachable: launchd usually needs a log out / restart.
    case needsRelogin
    /// The running helper is a different build; the caller re-registers.
    case versionMismatch(helper: String)
    case timeout
    /// The helper answered with an error code.
    case rejected(HelperErrorCode)
    /// Anything else, e.g. an unreadable reply or a failed helper signature check.
    case connection(String)
}

/// Talks to the privileged helper over XPC.
///
/// Calls share one connection until it is interrupted or invalidated: the helper exits when its
/// last connection closes, and launchd throttles a respawn for about 10 s, so a connection per
/// call would stall back-to-back calls. Every call resolves exactly once: on the reply, on a
/// connection error, or on the timeout, whichever comes first.
///
/// An interrupted connection may reconnect to a different helper process, so the version check
/// belongs to the connection, never to the client: the first operation on each new connection
/// sends `version` first, and the operation only once that process has answered with this
/// build's version. A lost connection is dropped (invalidated), never reused.
///
/// A connection lost before the operation was sent (during the version exchange) is retried once
/// on a new connection, repeating the version check. Once the operation is sent, a lost connection
/// is not retried: the helper may already have run it. Timeouts, helper error replies, version
/// mismatches and signature-check failures are never retried. The whole call, retry included,
/// resolves within `timeout`.
public final class HelperClient: @unchecked Sendable {
    public let registration: HelperRegistration
    public let timeout: TimeInterval
    /// For the long walks: `measureOtherAccounts` and the `longWalkEntryIDs` entries, whose walks
    /// share a 25 s deadline in the helper.
    public let longWalkTimeout: TimeInterval
    public static let longWalkTimeout: TimeInterval = 40
    /// Measure-table entries with the helper's longer outside budget.
    public static let longWalkEntryIDs: Set<String> = ["outside-library", "outside-private", "system-hidden"]
    private let connect: () -> NSXPCConnection

    /// Runs each call's deadline. Private and serial (so overcommit): `DispatchQueue.global()` is
    /// width-limited, and when other work saturates it a timeout scheduled there fires seconds late.
    private let timerQueue = DispatchQueue(label: "\(HelperIdentity.helperBundleID).client.timeout")

    /// Guards `cached`.
    private let lock = NSLock()
    private var cached: HelperSession?

    public init(
        registration: HelperRegistration,
        connect: @escaping () -> NSXPCConnection = HelperClient.liveConnection,
        timeout: TimeInterval = 15,
        longWalkTimeout: TimeInterval = HelperClient.longWalkTimeout
    ) {
        self.registration = registration
        self.connect = connect
        self.timeout = timeout
        self.longWalkTimeout = longWalkTimeout
    }

    deinit {
        cached?.connection.invalidate()
    }

    /// The only place the app connects to the helper's Mach service, and the only place the
    /// helper's code-signing requirement is applied. Tests inject plain anonymous connections.
    public static func liveConnection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: HelperIdentity.helperBundleID, options: .privileged)
        c.setCodeSigningRequirement(HelperIdentity.helperRequirement)
        return c
    }

    // MARK: Async API

    public func version() async throws -> String {
        // `version` does no work, so a lost reply may always be retried.
        try await call(checkVersion: false, idempotent: true) { helper, reply in helper.version(reply: reply) }
    }

    /// `version` without the registration check: connects even when this bundle's own
    /// registration reads `notRegistered`, and reports a lost or refused connection as
    /// `.connection(<XPC error>)` rather than a registration state. For `andromeda-helperctl
    /// probe` (Task 7 Step 5 negatives), whose callers are deliberately not the registering app.
    public func probeVersion() async throws -> String {
        try await call(checkVersion: false, idempotent: true, checkRegistration: false) { helper, reply in
            helper.version(reply: reply)
        }
    }

    /// How long a `measure(entryID:)` call may take.
    public func timeout(forEntry entryID: String) -> TimeInterval {
        Self.longWalkEntryIDs.contains(entryID) ? longWalkTimeout : timeout
    }

    public func measure(entryID: String) async throws -> MeasureReply {
        let answer: MeasureAnswer = try await call(checkVersion: true, timeout: timeout(forEntry: entryID)) { helper, reply in
            helper.measure(entryID: entryID) { data, code in reply(MeasureAnswer(data: data, code: code)) }
        }
        return try Self.decode(answer)
    }

    /// Other accounts' home-folder totals. Administrators only: a standard user gets
    /// `.rejected(.notPermitted)`.
    public func measureOtherAccounts() async throws -> [AccountSizeReply] {
        let answer: MeasureAnswer = try await call(checkVersion: true, timeout: longWalkTimeout) { helper, reply in
            helper.measureOtherAccounts { data, code in reply(MeasureAnswer(data: data, code: code)) }
        }
        if let code = answer.code { throw Self.rejection(code) }
        guard let data = answer.data, let rows = try? JSONDecoder().decode([AccountSizeReply].self, from: data) else {
            throw HelperClientError.connection("Unreadable other-accounts reply")
        }
        return rows
    }

    public func rebuildSpotlightIndex() async throws {
        let code: String? = try await call(checkVersion: true) { helper, reply in
            helper.rebuildSpotlightIndex(reply: reply)
        }
        if let code { throw Self.rejection(code) }
    }

    private func call<T: Sendable>(
        checkVersion: Bool, idempotent: Bool = false, checkRegistration: Bool = true,
        timeout: TimeInterval? = nil, _ send: @escaping XPCCall<T>.Send
    ) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            call(
                checkVersion: checkVersion, idempotent: idempotent, checkRegistration: checkRegistration,
                timeout: timeout, send
            ) { result in
                cont.resume(with: result.mapError { $0 as Error })
            }
        }
    }

    // MARK: Completion-based core (also used by XPCPrivilegedRunner)

    /// Checks registration, then sends on the shared connection (retrying once on a connection
    /// lost before the operation was sent, or at any point when `idempotent`) and maps the
    /// outcome. With `checkVersion`, `version` is sent first on a connection not yet verified, and
    /// the operation only if it matches. `completion` runs exactly once, on an arbitrary queue,
    /// within `timeout` (the client's own when nil).
    func call<T: Sendable>(
        checkVersion: Bool,
        idempotent: Bool = false,
        checkRegistration: Bool = true,
        timeout: TimeInterval? = nil,
        _ send: @escaping XPCCall<T>.Send,
        completion: @escaping @Sendable (Result<T, HelperClientError>) -> Void
    ) {
        if checkRegistration, let error = registrationError() {
            completion(.failure(error))
            return
        }
        attempt(
            retryAllowed: true, deadline: .now() + (timeout ?? self.timeout), checkVersion: checkVersion, idempotent: idempotent,
            send: send
        ) { outcome in
            switch outcome {
            case .reply(let value): completion(.success(value))
            case .timedOut: completion(.failure(.timeout))
            case .versionMismatch(let v): completion(.failure(.versionMismatch(helper: v)))
            case .signatureFailed: completion(.failure(.connection("helper signature check failed")))
            case .connectionLost(let message, _) where !checkRegistration:
                completion(.failure(.connection(String(message.prefix(500)))))
            case .connectionLost: completion(.failure(self.registrationError() ?? .needsRelogin))
            }
        }
    }

    private func attempt<T: Sendable>(
        retryAllowed: Bool, deadline: DispatchTime, checkVersion: Bool, idempotent: Bool,
        send: @escaping XPCCall<T>.Send, completion: @escaping @Sendable (XPCCall<T>.Outcome) -> Void
    ) {
        let session = currentSession()
        XPCCall<T>.perform(
            on: session, deadline: deadline, timerQueue: timerQueue, checkVersion: checkVersion, send: send
        ) { outcome in
            // Only a reply leaves the connection trustworthy; anything else retires it, so the
            // next call starts on a fresh, unverified connection.
            if case .reply = outcome {} else { self.drop(session) }
            if retryAllowed, case .connectionLost(_, let opSent) = outcome, idempotent || !opSent {
                // Same deadline: the retry never extends the overall timeout.
                self.attempt(
                    retryAllowed: false, deadline: deadline, checkVersion: checkVersion, idempotent: idempotent,
                    send: send, completion: completion)
                return
            }
            completion(outcome)
        }
    }

    /// The shared connection, opened (and resumed) on first use or after the last one was lost.
    private func currentSession() -> HelperSession {
        lock.lock()
        defer { lock.unlock() }
        if let s = cached { return s }
        let connection = connect()
        let session = HelperSession(connection)
        connection.remoteObjectInterface = NSXPCInterface(with: AndromedaHelperXPC.self)
        // After an interruption XPC would silently reconnect, possibly to another helper process:
        // retire the connection instead, so its version check can never carry over.
        let retire: @Sendable () -> Void = { [weak self, weak session] in
            guard let session else { return }
            self?.drop(session)
        }
        connection.interruptionHandler = retire
        connection.invalidationHandler = retire
        connection.resume()
        cached = session
        return session
    }

    /// Forgets `session` if it is still the shared one, and invalidates its connection.
    private func drop(_ session: HelperSession) {
        lock.lock()
        if cached === session { cached = nil }
        lock.unlock()
        // Outside the lock: invalidation runs the handler above, which calls back in here.
        session.connection.invalidate()
    }

    /// Invalidates the shared connection, if any. Safe while idle and from any thread. The next
    /// call opens a new connection and repeats the version check; calls in flight on the old
    /// connection resolve as a lost connection (retried only where a retry is allowed).
    public func disconnect() {
        lock.lock()
        let session = cached
        cached = nil
        lock.unlock()
        // Outside the lock: invalidation runs the handler, which calls back into `drop`.
        session?.connection.invalidate()
    }

    /// True while a shared connection is open. For tests.
    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cached != nil
    }

    /// `nil` when the daemon is enabled and worth connecting to.
    func registrationError() -> HelperClientError? {
        switch registration.status {
        case .enabled: nil
        case .requiresApproval: .awaitingApproval
        case .notRegistered, .notFound: .notRegistered
        @unknown default: .notRegistered
        }
    }

    static func rejection(_ raw: String) -> HelperClientError {
        HelperErrorCode(rawValue: raw).map { .rejected($0) } ?? .connection("Unknown helper error '\(raw)'")
    }

    private static func decode(_ answer: MeasureAnswer) throws -> MeasureReply {
        if let code = answer.code { throw rejection(code) }
        guard let data = answer.data, let reply = try? JSONDecoder().decode(MeasureReply.self, from: data) else {
            throw HelperClientError.connection("Unreadable measure reply")
        }
        return reply
    }
}

private struct MeasureAnswer: Sendable {
    let data: Data?
    let code: String?
}

/// One open connection to the helper, and whether *this* connection's peer has answered with this
/// build's version.
final class HelperSession: @unchecked Sendable {
    let connection: NSXPCConnection
    private let lock = NSLock()
    private var _verified = false

    init(_ connection: NSXPCConnection) { self.connection = connection }

    var verified: Bool { lock.withLock { _verified } }
    func markVerified() { lock.withLock { _verified = true } }
}

/// One XPC request on one connection.
enum XPCCall<T: Sendable> {
    typealias Send = @Sendable (AndromedaHelperXPC, @escaping @Sendable (T) -> Void) -> Void

    enum Outcome: Sendable {
        case reply(T)
        case versionMismatch(String)
        /// The peer failed the code-signing requirement. Retrying cannot help.
        case signatureFailed
        /// `opSent`: the operation message had already been sent when the connection was lost.
        case connectionLost(String, opSent: Bool)
        case timedOut
    }

    /// Sends on `session`'s connection (after a matching `version` when `checkVersion` and the
    /// connection is not yet verified) and resolves exactly once. Does not invalidate the
    /// connection: the caller decides whether to keep it.
    ///
    /// Connection loss is observed only through the proxy's error handler, which XPC calls for
    /// every message still awaiting a reply. An interruption after the reply is therefore ignored
    /// here (the connection's own handlers retire it).
    static func perform(
        on session: HelperSession, deadline: DispatchTime, timerQueue: DispatchQueue, checkVersion: Bool,
        send: @escaping Send,
        completion: @escaping @Sendable (Outcome) -> Void
    ) {
        let once = Once<Outcome>()
        let opSent = Flag()
        let timeout = TimeoutBox(DispatchWorkItem { once.fire(.timedOut) })
        once.body = { outcome in
            timeout.item.cancel()
            completion(outcome)
        }

        let proxy = session.connection.remoteObjectProxyWithErrorHandler { error in
            once.fire(classify(error, opSent: opSent.isSet))
        }
        guard let helper = proxy as? AndromedaHelperXPC else {
            once.fire(.connectionLost("Remote object has the wrong interface", opSent: false))
            return
        }
        timerQueue.asyncAfter(deadline: deadline, execute: timeout.item)

        let remote = ProxyBox(helper)
        let sendOperation: @Sendable () -> Void = {
            opSent.set()
            send(remote.helper) { value in once.fire(.reply(value)) }
        }
        guard checkVersion, !session.verified else { return sendOperation() }
        remote.helper.version { v in
            guard v == HelperIdentity.version else { return once.fire(.versionMismatch(v)) }
            session.markVerified()
            sendOperation()
        }
    }

    /// A code-signing requirement failure is final; everything else is a lost connection.
    static func classify(_ error: Error, opSent: Bool = false) -> Outcome {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSXPCConnectionCodeSigningRequirementFailure {
            return .signatureFailed
        }
        return .connectionLost(String(describing: error), opSent: opSent)
    }
}

/// A one-way flag, set at most once.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// DispatchWorkItem is thread-safe (cancel/perform) but not annotated Sendable.
private final class TimeoutBox: @unchecked Sendable {
    let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
}

/// The remote proxy is thread-safe but not annotated Sendable.
private final class ProxyBox: @unchecked Sendable {
    let helper: AndromedaHelperXPC
    init(_ helper: AndromedaHelperXPC) { self.helper = helper }
}

/// Runs `body` for the first value only, then drops it (and everything it captured: the
/// caller's completion), so a cancelled timeout that dispatch keeps until its
/// deadline holds only this empty shell. `body` is set once, before any `fire`.
private final class Once<V: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _body: (@Sendable (V) -> Void)?
    private var fired = false

    var body: (@Sendable (V) -> Void)? {
        get { lock.withLock { _body } }
        set { lock.withLock { _body = newValue } }
    }

    func fire(_ value: V) {
        let run = lock.withLock { () -> (@Sendable (V) -> Void)? in
            if fired { return nil }
            fired = true
            defer { _body = nil }
            return _body
        }
        run?(value)
    }
}
