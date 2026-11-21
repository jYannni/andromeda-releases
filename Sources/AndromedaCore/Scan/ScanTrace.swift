#if ANDROMEDA_TRACE
import Foundation

/// Debug-only: appends one line per filesystem access, written and fsynced BEFORE the access, so that
/// when a privacy prompt blocks the scanning thread the last line names the culprit. Compiled in only
/// with `-Xswiftc -DANDROMEDA_TRACE` (scripts/build-app.sh --trace). Output file: $ANDROMEDA_TRACE_FILE.
public enum ScanTrace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fd: Int32 = {
        guard let p = ProcessInfo.processInfo.environment["ANDROMEDA_TRACE_FILE"], !p.isEmpty else { return -1 }
        return open(p, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    }()
    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func note(_ op: StaticString, _ url: URL) { note(op, path: url.path) }

    public static func note(_ op: StaticString, path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        let line = "\(stamp.string(from: Date())) \(op) \(path)\n"
        var bytes = Array(line.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeMutableBytes { write(fd, $0.baseAddress! + off, $0.count - off) }
            if n <= 0 { break }
            off += n
        }
        _ = fsync(fd)
    }
}
#endif
