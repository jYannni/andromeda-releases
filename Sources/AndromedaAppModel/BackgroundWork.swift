import Foundation

public enum BackgroundWork {
    /// Runs blocking `body` on a dedicated `Thread` named `label` and awaits the result.
    /// Never blocks the cooperative pool or the main actor: the continuation is resumed from the thread.
    public static func run<T: Sendable>(
        _ label: String, qos: QualityOfService = .userInitiated,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let thread = Thread {
                cont.resume(with: Result { try body() })
            }
            thread.name = label
            thread.qualityOfService = qos
            thread.start()
        }
    }
}
