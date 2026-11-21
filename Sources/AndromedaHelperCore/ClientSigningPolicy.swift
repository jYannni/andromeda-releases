import Foundation
import Security

/// The runtime half of client verification. The code-signing requirement (checked by XPC) pins
/// the certificate chain, team and identifier; it cannot say "hardened runtime" or "no
/// get-task-allow". A Developer ID build of the app signed without `--options runtime`, or with a
/// debugging/injection entitlement, satisfies the requirement yet can be attached to or fed a
/// `DYLD_INSERT_LIBRARIES` payload. This check refuses such a peer before its connection resumes.
///
/// The peer is looked up by PID: NSXPCConnection exposes no public audit token, and the C XPC
/// API that does cannot be reached from an NSXPCConnection. See `allows(pid:)` for the residual
/// race this leaves.
enum ClientSigningPolicy {
    /// Any of these, with any value, refuses the peer (Global Constraints).
    static let bannedEntitlements: Set<String> = [
        "com.apple.security.get-task-allow",
        "get-task-allow",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.allow-unsigned-executable-memory",
    ]

    /// Kernel code-signing status bits (`kern/cs_blobs.h`), read from `kSecCodeInfoStatus`.
    private static let csValid: UInt32 = 0x0000_0001
    private static let csGetTaskAllow: UInt32 = 0x0000_0004
    private static let csRuntime: UInt32 = 0x0001_0000
    private static let csDebugged: UInt32 = 0x1000_0000

    /// The production check, passed to `ListenerDelegate` by its public initializer.
    static func check(_ connection: NSXPCConnection) -> Bool {
        allows(pid: connection.processIdentifier)
    }

    /// Looks up the running code behind `pid` and applies `allows(_:)`; refuses when the lookup
    /// fails.
    ///
    /// Residual race (no public audit-token route): a PID names whatever process holds it *now*.
    /// A peer that queues messages and then `exec`s a clean, hardened binary keeps its PID and its
    /// connection, and would be judged as that binary. The requirement check XPC applies per
    /// message (by audit token) still holds; only the hardened-runtime/entitlement half is exposed.
    static func allows(pid: pid_t) -> Bool {
        guard let info = signingInformation(pid: pid) else { return false }
        return allows(info)
    }

    /// Signing information (static flags, entitlements, dynamic status) of the running process
    /// `pid`, or nil when there is no such process or it cannot be read.
    static func signingInformation(pid: pid_t) -> [String: Any]? {
        guard pid > 0 else { return nil }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return nil
        }
        // A SecCode is accepted where a SecStaticCode is expected (SecCode.h); dynamic
        // information is only returned for a SecCode.
        let flags = SecCSFlags(rawValue: kSecCSDynamicInformation | kSecCSRequirementInformation)
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), flags, &info)
            == errSecSuccess
        else { return nil }
        return info as? [String: Any]
    }

    /// The policy on a `SecCodeCopySigningInformation` dictionary. Fails closed: anything missing
    /// or unreadable refuses.
    static func allows(_ info: [String: Any]) -> Bool {
        // Static: signed with hardened runtime.
        guard let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value,
              flags & SecCodeSignatureFlags.runtime.rawValue != 0
        else { return false }

        // Dynamic: the running process is valid, hardened, not debuggable and never debugged.
        guard let status = (info[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value,
              status & csValid != 0, status & csRuntime != 0,
              status & (csGetTaskAllow | csDebugged) == 0
        else { return false }

        // Entitlements: none at all, or a dictionary with no banned key.
        if let raw = info[kSecCodeInfoEntitlementsDict as String] {
            guard let entitlements = raw as? [String: Any] else { return false }
            return bannedEntitlements.isDisjoint(with: entitlements.keys)
        }
        // A blob that is not in dictionary form cannot be checked.
        return info[kSecCodeInfoEntitlements as String] == nil
    }
}
