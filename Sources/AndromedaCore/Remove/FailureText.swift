import Foundation

/// The sentence a failed move to the Trash stores in the journal. Permission refusals get plain copy
/// (plan 3.2 #3); anything else keeps its raw description, so an unfamiliar error still says something.
/// Only `Executor.moveToTrash` uses it: the copy is about moving an item.
public enum FailureText {
    /// The item belongs to another user, usually root (for example a macOS installer).
    public static let notAllowed = "macOS didn't let Andromeda move this. It belongs to the system, not to you."
    /// The item is the user's own, but macOS still refused (a locked file, a protected container).
    public static let notAllowedOwnItem = "macOS didn't let Andromeda move this."

    /// `ownedByCurrentUser` decides which permission sentence fits; it doesn't affect other errors.
    public static func describe(_ error: Error, ownedByCurrentUser: Bool) -> String {
        if isPermission(error as NSError, depth: 0) { return ownedByCurrentUser ? notAllowedOwnItem : notAllowed }
        return raw(error)
    }

    /// The raw description, capped, for errors that aren't about a move.
    public static func raw(_ error: Error) -> String { String(String(describing: error).prefix(500)) }

    /// Follows `NSUnderlyingErrorKey` a few levels down (Cocoa 4 → Cocoa 513 → POSIX EPERM, say).
    private static func isPermission(_ e: NSError, depth: Int) -> Bool {
        let direct: Bool
        switch e.domain {
        case NSCocoaErrorDomain: direct = e.code == NSFileWriteNoPermissionError || e.code == NSFileReadNoPermissionError
        case NSOSStatusErrorDomain: direct = e.code == -5000  // afpAccessDenied
        case NSPOSIXErrorDomain: direct = e.code == Int(EACCES) || e.code == Int(EPERM)
        default: direct = false
        }
        if direct { return true }
        guard depth < 3, let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isPermission(underlying, depth: depth + 1)
    }
}
