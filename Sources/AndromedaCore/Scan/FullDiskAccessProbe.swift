import Foundation

public enum FDAStatus: Sendable { case granted, denied, unknown }

/// Detects Full Disk Access by listing a folder that only Full Disk Access opens.
///
/// v1 §8 rev 4: the system TCC folder comes first: it exists on every Mac and only Full Disk Access opens it.
/// Safari and Mail stay as fallbacks. On macOS 27 the first refused read of ANY of these (or of any other
/// protected folder) posts a one-time "Data Access Blocked … your data from other apps" notification; no probe
/// avoids it (the VM, 27.2: the Safari folder and the TCC folder both triggered it within 7 ms).
public enum FullDiskAccessProbe {
    public static func check(
        env: ScanEnvironment,
        list: (URL) throws -> [String] = { try FileManager.default.contentsOfDirectory(atPath: $0.path) }
    ) -> FDAStatus {
        let candidates = [
            env.root.appendingPathComponent("Library/Application Support/com.apple.TCC", isDirectory: true),
            env.home.appendingPathComponent("Library/Safari", isDirectory: true),
            env.home.appendingPathComponent("Library/Mail", isDirectory: true),
        ]
        for dir in candidates {
            #if ANDROMEDA_TRACE
            ScanTrace.note("stat", dir)
            #endif
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            do {
                #if ANDROMEDA_TRACE
                ScanTrace.note("list", dir)
                #endif
                _ = try list(dir)
                return .granted
            } catch {
                return isPermissionDenied(error) ? .denied : .unknown
            }
        }
        return .unknown
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if (error as? CocoaError)?.code == .fileReadNoPermission { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileReadNoPermission.rawValue { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(underlying) }
        return false
    }
}
