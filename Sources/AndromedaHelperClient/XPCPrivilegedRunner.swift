import Foundation
import AndromedaCore
import AndromedaHelperProtocol

/// Carries out `Executor`'s privileged items through the helper.
///
/// Synchronous, because `Executor` is: each call blocks its thread on a semaphore until the helper
/// answers or the client's timeout passes. It uses the completion-based XPC path, not
/// `HelperClient`'s async methods. **Never call it from a Swift-concurrency context** (an actor or
/// task): blocking a cooperative thread can deadlock. Run `Executor` on a detached `Thread`.
public struct XPCPrivilegedRunner: PrivilegedRunner {
    private let client: HelperClient

    public init(client: HelperClient) {
        self.client = client
    }

    public func run(_ op: PrivilegedOperation) -> Outcome {
        switch op {
        case .rebuildSpotlightIndex:
            // `version` and the operation travel on one connection, so the build check vouches
            // for the very helper process that runs the operation.
            switch wait({ helper, reply in helper.rebuildSpotlightIndex(reply: reply) }) {
            case .success(nil): return .done
            case .success(let code?): return Self.outcome(HelperClient.rejection(code))
            case .failure(let error): return Self.outcome(error)
            }
        }
    }

    private func wait<T: Sendable>(_ send: @escaping XPCCall<T>.Send) -> Result<T, HelperClientError> {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        client.call(checkVersion: true, send) { result in
            box.set(result)
            done.signal()
        }
        // The call itself resolves within the client's timeout, retry included; the extra second
        // is only a backstop.
        guard done.wait(timeout: .now() + client.timeout + 1) == .success, let result = box.get() else {
            return .failure(.timeout)
        }
        return result
    }

    private static func outcome(_ error: HelperClientError) -> Outcome {
        switch error {
        case .notRegistered, .awaitingApproval: .skipped(.helperUnavailable)
        case .needsRelogin: .failed("The helper is enabled but not reachable. Log out and back in, then try again.")
        case .versionMismatch(let v): .failed("The helper is a different version (\(v)). Reinstall it, then try again.")
        case .timeout: .failed("The helper didn't answer in time.")
        case .rejected(.alreadyDoneThisBoot): .skipped(.alreadyDoneThisBoot)
        case .rejected(let code): .failed("The helper refused: \(code.rawValue).")
        case .connection(let message): .failed(String(message.prefix(500)))
        }
    }
}

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, HelperClientError>?

    func set(_ v: Result<T, HelperClientError>) { lock.withLock { value = v } }
    func get() -> Result<T, HelperClientError>? { lock.withLock { value } }
}
