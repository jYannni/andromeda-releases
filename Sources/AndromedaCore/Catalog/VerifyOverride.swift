#if ANDROMEDA_VERIFY
import Foundation

/// Verification builds only (scripts/build-app.sh --verify, `-Xswiftc -DANDROMEDA_VERIFY`): entry IDs listed
/// in $ANDROMEDA_VERIFY_ENTRIES (comma-separated) count as verified on any macOS, so plan 3.1 can exercise
/// them for real before `verified_on` is filled. Tier and missing-tool checks are unaffected.
public enum VerifyOverride {
    public static func treatsAsVerified(
        _ entryID: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment["ANDROMEDA_VERIFY_ENTRIES"] else { return false }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { !$0.isEmpty && $0 == entryID }
    }
}
#endif
