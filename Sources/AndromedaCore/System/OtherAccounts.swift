import Foundation
import OpenDirectory
import os

/// One record from the local user directory.
public struct DirectoryAccount: Sendable, Equatable {
    public let uid: uid_t
    public let name: String
    public let home: String

    public init(uid: uid_t, name: String, home: String) {
        self.uid = uid
        self.name = name
        self.home = home
    }
}

/// Another account's folder size, as the report shows it. `bytes == nil` means not measured.
public struct OtherAccountSize: Sendable, Equatable {
    public let uid: UInt32
    public let name: String
    public let bytes: Int64?
    /// The walk was cut short or hit unreadable folders, so the figure is a lower bound.
    public let atLeast: Bool

    public init(uid: UInt32, name: String, bytes: Int64?, atLeast: Bool) {
        self.uid = uid
        self.name = name
        self.bytes = bytes
        self.atLeast = atLeast
    }
}

/// The other user accounts on this Mac, so the report can name them.
public enum OtherAccounts {
    /// Accounts from the directory, not folders in `/Users`: `/Users/root` is a folder but not an account.
    /// Kept: UID 501 or more, not `currentUID`, and a home that is a real directory (not a symlink) directly
    /// in `env.root/Users`, other than `Shared` and `env.home`, owned by that UID. Comparisons are
    /// case-insensitive (APFS default). Sorted by name, one record per UID (the first by name). The same
    /// rule as the helper's `OtherAccountsOperation` (R5, R16), so every account named here is one the
    /// helper measures. nil when the directory couldn't be listed (R25), which is not the same as no accounts.
    public static func list(
        env: ScanEnvironment, currentUID: uid_t = getuid(),
        source: () -> [DirectoryAccount]? = localDirectory,
        directoryOwner: (String) -> uid_t? = lstatDirectoryOwner
    ) -> [(uid: uid_t, name: String)]? {
        guard let records = source() else { return nil }
        let users = env.root.appendingPathComponent("Users", isDirectory: true).standardizedFileURL.path.lowercased()
        let home = env.home.standardizedFileURL.path.lowercased()
        var seen = Set<uid_t>()
        return records
            .sorted { $0.name < $1.name }
            .filter { account in
                guard account.uid >= 501, account.uid != currentUID else { return false }
                let url = URL(fileURLWithPath: account.home, isDirectory: true).standardizedFileURL
                let path = url.path.lowercased()
                guard url.deletingLastPathComponent().path.lowercased() == users, path != home,
                      url.lastPathComponent.caseInsensitiveCompare("Shared") != .orderedSame
                else { return false }
                #if ANDROMEDA_TRACE
                ScanTrace.note("lstat", url)
                #endif
                guard directoryOwner(url.path) == account.uid else { return false }
                // The helper replies once per UID, so a second record for it is not another account.
                return seen.insert(account.uid).inserted
            }
            .map { (uid: $0.uid, name: $0.name) }
    }

    /// The owner of `path` if `lstat` says it is a directory, so a symlink is never one. `/Users`
    /// is world-readable, so this needs no privilege.
    public static func lstatDirectoryOwner(_ path: String) -> uid_t? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        return st.st_uid
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "andromeda", category: "accounts")

    /// Every user record of the local directory node, or nil if the directory doesn't answer in
    /// time or fails (the helper's R24 N4 timeout; R25 tells it apart from no accounts):
    /// `opendirectoryd` is another process, and the scan must not hang on it. The query runs on its
    /// own thread; past `timeout` seconds its result is dropped and the thread is left to finish on its own.
    public static func localDirectory() -> [DirectoryAccount]? {
        localDirectory(query: queryLocalNode, timeout: 2)
    }

    /// Test seam: inject the directory query and the wait.
    static func localDirectory(
        query: @escaping @Sendable () -> [DirectoryAccount]?, timeout: Double
    ) -> [DirectoryAccount]? {
        let answer = Answer<[DirectoryAccount]>()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            if let records = query() { answer.set(records) }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            log.notice("op=localDirectory result=timeout")
            return nil
        }
        if answer.value == nil { log.notice("op=localDirectory result=failed") }
        return answer.value
    }

    /// Every user record of the local directory node, and only that node (the helper's R22, the same
    /// rule): `getpwent` walks the whole search policy, network directories included, which can
    /// stall and names accounts whose homes aren't on this Mac. A record without a numeric UID or a
    /// home is skipped. Any error is nil: the accounts are unknown, not absent.
    static func queryLocalNode() -> [DirectoryAccount]? {
        guard let node = try? ODNode(session: .default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let query = try? ODQuery(
                node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeRecordName,
                matchType: ODMatchType(kODMatchAny), queryValues: nil,
                returnAttributes: [kODAttributeTypeUniqueID, kODAttributeTypeNFSHomeDirectory], maximumResults: 0),
              let records = try? query.resultsAllowingPartial(false) as? [ODRecord]
        else { return nil }
        return records.compactMap { record in
            guard let uidText = (try? record.values(forAttribute: kODAttributeTypeUniqueID))?.first as? String,
                  let uid = uid_t(uidText),
                  let home = (try? record.values(forAttribute: kODAttributeTypeNFSHomeDirectory))?.first as? String
            else { return nil }
            return DirectoryAccount(uid: uid, name: record.recordName, home: home)
        }
    }
}

/// A value handed from the query thread to the waiting one.
private final class Answer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? { lock.withLock { _value } }
    func set(_ v: T) { lock.withLock { _value = v } }
}
