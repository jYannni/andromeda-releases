import Foundation

public struct ToolResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ToolError: Error, Equatable {
    case relativeExecutable(String)
    case failed(executable: String, exitCode: Int32, stderr: String)
}

/// Every real command goes through this, so the rest of the core can be tested with fakes.
public protocol ToolRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String]) throws -> ToolResult
}

/// Runs a process directly (no shell). The executable must be an absolute path.
public struct LiveToolRunner: ToolRunner {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String]) throws -> ToolResult {
        try run(executable, arguments, shouldContinue: nil)
    }

    public func run(
        _ executable: URL, _ arguments: [String], wakeOnExit: Bool = false, shouldContinue: (() -> Bool)?
    ) throws -> ToolResult {
        // `URL(fileURLWithPath: "ls").path` resolves against the cwd, so check the URL's own shape.
        guard executable.isFileURL, executable.baseURL == nil,
              executable.relativePath == executable.path, executable.path.hasPrefix("/")
        else {
            throw ToolError.relativeExecutable(executable.path)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let completion = wakeOnExit && shouldContinue != nil ? DispatchSemaphore(value: 0) : nil
        if let completion {
            process.terminationHandler = { _ in completion.signal() }
        }

        try process.run()

        // Drain both pipes concurrently so a full pipe buffer can never block the child.
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
        if let shouldContinue {
            var completed = false
            while process.isRunning && shouldContinue() {
                if let completion {
                    if completion.wait(timeout: .now() + .milliseconds(50)) == .success {
                        completed = true
                        break
                    }
                } else {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            if !completed && process.isRunning { process.terminate() }
        }
        group.wait()
        process.waitUntilExit()

        return ToolResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outBox.get(), as: UTF8.self),
            stderr: String(decoding: errBox.get(), as: UTF8.self))
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
