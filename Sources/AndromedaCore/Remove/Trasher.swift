import Foundation

/// Moves one item to the Trash and returns where it landed.
public protocol Trasher: Sendable {
    func trash(_ url: URL) throws -> URL
}

public enum TrashError: Error, Equatable {
    /// The system reported success but gave no Trash location, so the item can't be tracked.
    case noResultingURL(String)
}

/// Uses the system Trash via `FileManager.trashItem(at:resultingItemURL:)`.
public struct LiveTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let result = resulting as URL? else { throw TrashError.noResultingURL(url.path) }
        return result
    }
}
