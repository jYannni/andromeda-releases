/// A catalog entry ID as sent by the client, validated before anything else happens.
///
/// Accepts only `^[a-z0-9]+(-[a-z0-9]+)*$`, 1 to 64 bytes, checked against the raw UTF-8 bytes
/// with no normalisation: path separators, `..`, NUL, whitespace, uppercase, lookalike Unicode
/// and combining marks are all refused.
public struct EntryID: Hashable, Sendable {
    public let rawValue: String

    public init?(validating raw: String) {
        let bytes = Array(raw.utf8.prefix(65))
        guard (1...64).contains(bytes.count) else { return nil }
        var previousWasHyphen = true  // a leading hyphen is refused
        for b in bytes {
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                previousWasHyphen = false
            case UInt8(ascii: "-"):
                guard !previousWasHyphen else { return nil }  // leading or doubled hyphen
                previousWasHyphen = true
            default:
                return nil
            }
        }
        guard !previousWasHyphen else { return nil }  // trailing hyphen
        rawValue = raw
    }
}
