/// The `catalogEntryID`s Organize writes to the journal. The values are on disk in old journal lines:
/// never change them.
public enum OrganizeCatalogID {
    public static let move = "organize.move"
    public static let createFolder = "organize.createFolder"
    /// A move into a cloud provider's folder; its batch is a move to cloud.
    public static let cloudMove = "organize.cloudMove"
    public static let evict = "organize.evict"
    public static let automation = "organize.automation"
}
