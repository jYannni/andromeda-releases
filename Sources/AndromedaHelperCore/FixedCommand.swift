import Foundation

/// The only commands the helper can ever run as root. Each is an absolute executable plus a
/// fixed argument array compiled in. No case carries a caller-supplied value.
public enum FixedCommand: Equatable, CaseIterable, Sendable {
    case rebuildSpotlight
    case spotlightStatus
    case flushDNSDirectoryCache
    case flushMulticastDNSCache
    case flushLegacyMulticastDNSCache

    public var executable: String {
        switch self {
        case .rebuildSpotlight, .spotlightStatus: return "/usr/bin/mdutil"
        case .flushDNSDirectoryCache: return "/usr/bin/dscacheutil"
        case .flushMulticastDNSCache, .flushLegacyMulticastDNSCache: return "/bin/launchctl"
        }
    }

    public var arguments: [String] {
        switch self {
        // `/` is the sealed System volume, whose index is small; the index that grows lives on the Data volume.
        case .rebuildSpotlight: return ["-E", "/System/Volumes/Data"]
        case .spotlightStatus: return ["-s", "/System/Volumes/Data"]
        case .flushDNSDirectoryCache: return ["-flushcache"]
        case .flushMulticastDNSCache: return ["kill", "SIGHUP", "system/com.apple.mDNSResponder.reloaded"]
        case .flushLegacyMulticastDNSCache: return ["kill", "SIGHUP", "system/com.apple.mDNSResponder"]
        }
    }
}

public protocol CommandRunner: Sendable {
    func run(_ command: FixedCommand) -> (exitCode: Int32, stdout: String, stderr: String)
}

/// Runs a `FixedCommand` directly (never a shell) with null stdin, a pinned environment and a
/// timeout. This file is the only place in the helper that spawns a process.
public struct LiveCommandRunner: CommandRunner {
    static let pinnedEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    private let timeout: TimeInterval

    public init() { self.timeout = 120 }

    /// Test seam: shorter timeout.
    init(timeout: TimeInterval) { self.timeout = timeout }

    public func run(_ command: FixedCommand) -> (exitCode: Int32, stdout: String, stderr: String) {
        runUnchecked(executable: command.executable, arguments: command.arguments)
    }

    /// Test-only escape hatch (internal, reachable via `@testable`); not part of `FixedCommand`
    /// and not callable from the XPC surface.
    func runUnchecked(executable: String, arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Self.pinnedEnvironment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        // Signalled by the termination handler, so child exit is bounded independently of pipe EOF.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return (-1, "", "launch failed: \(error)") }

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
            group.enter()
            // A dedicated thread, not DispatchQueue.global(): the read blocks until EOF, and blocked
            // reads would hold the width-limited global queue that timeouts and XPC replies need.
            Thread.detachNewThread {
                box.set(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }
        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        var hasExited = exited.wait(timeout: deadline) == .success
        if !hasExited || group.wait(timeout: deadline) == .timedOut {
            timedOut = true
            if !hasExited {
                process.terminate()
                hasExited = exited.wait(timeout: .now() + 2) == .success
                if !hasExited {
                    kill(process.processIdentifier, SIGKILL)
                    hasExited = exited.wait(timeout: .now() + 2) == .success
                }
            }
            // A grandchild may still hold the pipes; do not wait for them indefinitely.
            _ = group.wait(timeout: .now() + 2)
        }
        _ = hasExited
        return (
            (timedOut || !hasExited) ? -1 : process.terminationStatus,
            String(decoding: outBox.get(), as: UTF8.self),
            String(decoding: errBox.get(), as: UTF8.self))
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
