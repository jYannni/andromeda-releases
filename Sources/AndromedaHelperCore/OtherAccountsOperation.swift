import Foundation
import Darwin.membership
import OpenDirectory
import os
import AndromedaHelperProtocol

/// `measureOtherAccounts()`: the home-folder total of every other local account, for an
/// administrator caller only (spec rev H, H1/H2). Replies with numbers only: UID, bytes, unreadable
/// count, truncated. An administrator could get the same totals with `sudo du`, so the helper gives
/// nobody a capability they didn't already have.
public struct OtherAccountsOperation: Sendable {
    /// Sizes one home within the budget left for it.
    typealias SizeFn = @Sendable (_ home: String, _ budget: Budget) -> RootSize

    /// One deadline for the whole call (R15), and an entry budget per home.
    static let budget = Budget.outside

    private let accounts: @Sendable () -> [(uid: uid_t, home: String)]
    private let isAdmin: @Sendable (uid_t) -> Bool
    private let sizer: SizeFn
    private let usersRoot: String
    private let directoryOwner: @Sendable (String) -> uid_t?
    private let now: @Sendable () -> Double

    public init() {
        self.init(
            accounts: Self.localAccounts,
            isAdmin: Self.isAdminMember,
            sizer: { home, budget in
                // Other users can write into a world-writable or staff-writable folder inside the
                // home: never descend into one, so they can't steer the walk (R12, R16, R21).
                RootSizer(budget: budget).size(ofPath: home, policy: .home)
            },
            usersRoot: "/Users",
            directoryOwner: Self.lstatDirectoryOwner)
    }

    /// Test seam: inject the directory, the admin check, the sizer, `/Users`, the ownership check
    /// and the clock (seconds).
    init(
        accounts: @escaping @Sendable () -> [(uid: uid_t, home: String)],
        isAdmin: @escaping @Sendable (uid_t) -> Bool,
        sizer: @escaping SizeFn,
        usersRoot: String,
        directoryOwner: @escaping @Sendable (String) -> uid_t?,
        now: @escaping @Sendable () -> Double = { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
    ) {
        self.accounts = accounts
        self.isAdmin = isAdmin
        self.sizer = sizer
        self.usersRoot = usersRoot
        self.directoryOwner = directoryOwner
        self.now = now
    }

    /// `callerUID` is the XPC peer's UID (`uid_t.max` when there is none, which is no account and
    /// never an administrator).
    public func run(callerUID: uid_t) -> Result<[AccountSizeReply], HelperErrorCode> {
        // First, before the directory or the filesystem is touched.
        guard isAdmin(callerUID) else { return .failure(.notPermitted) }

        let start = now()
        let homes = eligibleHomes(callerUID: callerUID)
        return .success(homes.map { account in
            let left = Self.budget.maxSeconds - (now() - start)
            // Not reached before the deadline: reported, with nothing counted.
            guard left > 0 else {
                return AccountSizeReply(uid: UInt32(account.uid), bytes: 0, unreadableCount: 0, skippedCount: 0, truncated: true)
            }
            let s = sizer(account.home, Budget(maxEntries: Self.budget.maxEntries, maxSeconds: left))
            return AccountSizeReply(
                uid: UInt32(account.uid), bytes: s.bytes, unreadableCount: s.unreadable, skippedCount: s.skipped,
                truncated: s.truncated)
        })
    }

    /// The account rule, a deliberate copy of `AndromedaCore.OtherAccounts.list` (R5: the helper
    /// never imports AndromedaCore). Kept: UID 501 or more, not the caller, a home directly in
    /// `/Users` other than `Shared` (case-insensitive, as APFS is by default) that is a real
    /// directory, not a symlink, owned by that UID (R16). The ownership check also drops a stale
    /// record pointing at someone else's home, the caller's included. One home per UID, ascending.
    func eligibleHomes(callerUID: uid_t) -> [(uid: uid_t, home: String)] {
        let users = URL(fileURLWithPath: usersRoot, isDirectory: true).standardizedFileURL.path.lowercased()
        var seen = Set<uid_t>()
        var out: [(uid: uid_t, home: String)] = []
        for account in accounts().sorted(by: { $0.uid < $1.uid }) {
            guard account.uid >= 501, account.uid != callerUID, !seen.contains(account.uid) else { continue }
            // Lexical only (no symlinks resolved): `..` and trailing slashes go, so the parent and
            // name checked below are the ones the walk uses.
            let url = URL(fileURLWithPath: account.home, isDirectory: true).standardizedFileURL
            guard url.deletingLastPathComponent().path.lowercased() == users,
                  url.lastPathComponent.caseInsensitiveCompare("Shared") != .orderedSame,
                  directoryOwner(url.path) == account.uid
            else { continue }
            seen.insert(account.uid)
            out.append((account.uid, url.path))
        }
        return out
    }

    /// The owner of `path` if `lstat` says it is a directory, so a symlink is never one.
    ///
    /// The walk then starts from this same path. A home swapped for a symlink after this check is
    /// still not followed: RootSizer opens its root with `O_NOFOLLOW` and requires the opened
    /// directory to be the one its own `lstat` saw. Below the root it holds descriptors and never
    /// re-opens anything by path (R20), so a folder the owner races into a symlink during the walk
    /// is counted as unreadable, not entered. The device is pinned from that same `lstat`.
    static func lstatDirectoryOwner(_ path: String) -> uid_t? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        return st.st_uid
    }

    /// Membership of the `admin` group (gid 80), nested groups included. Any error reads as not a
    /// member.
    static func isAdminMember(_ uid: uid_t) -> Bool {
        var user = [UInt8](repeating: 0, count: 16)
        var group = [UInt8](repeating: 0, count: 16)
        guard mbr_uid_to_uuid(uid, &user) == 0, mbr_gid_to_uuid(80, &group) == 0 else { return false }
        var member: Int32 = 0
        guard mbr_check_membership(&user, &group, &member) == 0 else { return false }
        return member == 1
    }

    private static let log = Logger(subsystem: HelperIdentity.helperBundleID, category: "accounts")

    /// Every user record of the local directory node (R22), or none if the directory doesn't
    /// answer in time (R24 N4): `opendirectoryd` is another process, and a stall there must not
    /// hold the helper's one busy slot. The query runs on its own thread; past `timeout` seconds
    /// its result is dropped and the thread is left to finish on its own.
    static func localAccounts() -> [(uid: uid_t, home: String)] {
        localAccounts(query: queryLocalNode, timeout: 2)
    }

    /// Test seam: inject the directory query and the wait.
    static func localAccounts(
        query: @escaping @Sendable () -> [(uid: uid_t, home: String)], timeout: Double
    ) -> [(uid: uid_t, home: String)] {
        let answer = Answer<[(uid: uid_t, home: String)]>()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            answer.set(query())
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            log.notice("op=localAccounts result=timeout")
            return []
        }
        return answer.value ?? []
    }

    /// Every user record of the local directory node, and only that node (R22): `getpwent` walks
    /// the whole search policy, network directories included, which can stall inside the busy
    /// slot and names accounts whose homes aren't here anyway. A record without a numeric UID or a
    /// home is skipped. Any error reads as no accounts.
    static func queryLocalNode() -> [(uid: uid_t, home: String)] {
        guard let node = try? ODNode(session: .default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let query = try? ODQuery(
                node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeRecordName,
                matchType: ODMatchType(kODMatchAny), queryValues: nil,
                returnAttributes: [kODAttributeTypeUniqueID, kODAttributeTypeNFSHomeDirectory], maximumResults: 0),
              let records = try? query.resultsAllowingPartial(false) as? [ODRecord]
        else { return [] }
        return records.compactMap { record in
            guard let uidText = (try? record.values(forAttribute: kODAttributeTypeUniqueID))?.first as? String,
                  let uid = uid_t(uidText),
                  let home = (try? record.values(forAttribute: kODAttributeTypeNFSHomeDirectory))?.first as? String
            else { return nil }
            return (uid, home)
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
