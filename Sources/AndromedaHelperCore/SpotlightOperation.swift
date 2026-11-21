import Foundation
import AndromedaHelperProtocol

/// `kern.bootsessionuuid`, read with `sysctlbyname` (no subprocess).
public func currentBootSessionID() -> String? {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

/// `rebuildSpotlightIndex`: runs `mdutil -E /System/Volumes/Data` at most once per boot session. The marker is a
/// root-owned 0600 file holding the boot session UUID, so a compromised-but-valid client cannot
/// loop full-disk reindexes. The marker is written before the command runs: a failed or timed-out
/// attempt still counts, because a killed `mdutil` may already have started a reindex.
public struct SpotlightOperation: Sendable {
    static let productionMarkerDirectory = URL(
        fileURLWithPath: "/Library/Application Support/io.github.jyannni.diskplain.helper",
        isDirectory: true)

    /// Serializes check/write/run across every instance (the marker is process-global state).
    private static let lock = NSLock()

    private let runner: any CommandRunner
    private let bootID: @Sendable () -> String?
    private let markerDirectory: URL

    public init(
        runner: any CommandRunner = LiveCommandRunner(),
        bootID: @escaping @Sendable () -> String? = { currentBootSessionID() }
    ) {
        self.init(runner: runner, bootID: bootID, markerDirectory: Self.productionMarkerDirectory)
    }

    /// Test seam: inject the marker directory.
    init(runner: any CommandRunner, bootID: @escaping @Sendable () -> String?, markerDirectory: URL) {
        self.runner = runner
        self.bootID = bootID
        self.markerDirectory = markerDirectory
    }

    public func run() -> HelperErrorCode? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // Without a boot ID the once-per-boot limit cannot be enforced, so refuse.
        guard let boot = bootID(), !boot.isEmpty else { return .toolFailed }
        let marker = markerDirectory.appendingPathComponent("spotlight-rebuilt")
        if let existing = try? String(contentsOf: marker, encoding: .utf8), existing == boot {
            return .alreadyDoneThisBoot
        }
        do {
            try FileManager.default.createDirectory(
                at: markerDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try Data(boot.utf8).write(to: marker, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        } catch {
            return .toolFailed  // cannot record, so do not run
        }
        return runner.run(.rebuildSpotlight).exitCode == 0 ? nil : .toolFailed
    }
}
