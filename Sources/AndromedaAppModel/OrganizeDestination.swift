import AndromedaOrganize
import Foundation

/// A Settings row: where files for one cloud folder go.
public struct OrganizeDestination: Equatable, Identifiable, Sendable {
    public let provider: CloudProvider
    public let account: String?
    public let path: String
    public var id: String { provider.rawValue + "|" + (account ?? "") }
    /// "Google Drive (a@b.com)", or just the provider name.
    public var title: String {
        account.map { "\(provider.displayName) (\($0))" } ?? provider.displayName
    }
}
