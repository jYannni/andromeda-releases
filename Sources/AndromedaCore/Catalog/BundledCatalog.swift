import Foundation

/// The catalog shipped inside the app, from `Catalog/Entries`.
public enum BundledCatalog {
    /// Validated entries, most specific first.
    public static func load() throws -> [CatalogEntry] {
        try CatalogLoader.load(directory: directory)
    }

    static var directory: URL {
        Bundle.module.url(forResource: "Entries", withExtension: nil)!
    }
}
