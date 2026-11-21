import AndromedaCore

/// Hidden build check behind `Andromeda --self-test-catalog`: proves the bundled catalog
/// resources resolve inside a built .app. Reads only; removes nothing.
public enum SelfTest {
    public static func catalogCount() throws -> Int {
        try BundledCatalog.load().count
    }
}
