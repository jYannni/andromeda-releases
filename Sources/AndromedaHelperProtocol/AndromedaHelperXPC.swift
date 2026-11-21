import Foundation

/// The complete operation set the privileged helper exposes. Every reply
/// block is called exactly once.
// Keep the Objective-C protocol name used by previously installed helpers.
@objc(DiskplainHelperXPC) public protocol AndromedaHelperXPC {
    func version(reply: @escaping @Sendable (String) -> Void)

    /// The `Data` is a JSON-encoded `MeasureReply`; the `String` is a
    /// `HelperErrorCode` raw value.
    func measure(entryID: String, reply: @escaping @Sendable (Data?, String?) -> Void)

    /// Administrators only. The `Data` is a JSON-encoded `[AccountSizeReply]`: per-account totals,
    /// no names or paths. The `String` is a `HelperErrorCode` raw value.
    func measureOtherAccounts(reply: @escaping @Sendable (Data?, String?) -> Void)

    /// `nil` means success; otherwise a `HelperErrorCode` raw value.
    func rebuildSpotlightIndex(reply: @escaping @Sendable (String?) -> Void)
}
