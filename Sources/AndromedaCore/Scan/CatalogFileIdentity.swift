import Darwin

/// An APFS file ID is meaningful inside one volume. Creation time guards against inode reuse.
public struct CatalogFileIdentity: Codable, Hashable, Sendable {
    public let inode: UInt64
    public let birthTime: Int64
    public let singleLink: Bool

    public init(inode: UInt64, birthTime: Int64, singleLink: Bool) {
        self.inode = inode
        self.birthTime = birthTime
        self.singleLink = singleLink
    }

    public func isSameFile(as other: Self) -> Bool { inode == other.inode && birthTime == other.birthTime }

    public func matches(_ info: stat) -> Bool {
        UInt64(info.st_ino) == inode && Self.timestamp(info.st_birthtimespec) == birthTime
    }

    static func timestamp(_ value: timespec) -> Int64? {
        let (seconds, overflow) = Int64(value.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        let (result, additionOverflow) = seconds.addingReportingOverflow(Int64(value.tv_nsec))
        return !overflow && !additionOverflow && result != 0 ? result : nil
    }
}
