import AndromedaCore
import Foundation

/// A cloud provider's local sync folder.
public struct CloudRoot: Equatable, Sendable {
    public let provider: CloudProvider
    public let url: URL
    /// The account part of the folder name (`GoogleDrive-a@b.com` gives `a@b.com`); nil when the name carries none.
    public let account: String?

    public init(provider: CloudProvider, url: URL, account: String?) {
        self.provider = provider
        self.url = url
        self.account = account
    }
}

/// Finds the sync folders of the supported providers. Reads folder names only: nothing inside a provider root is touched.
public enum CloudRootLocator {
    public static func roots(env: ScanEnvironment) -> [CloudRoot] {
        var result: [CloudRoot] = []
        let fm = FileManager.default
        let icloud = env.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: icloud.path, isDirectory: &isDir), isDir.boolValue {
            result.append(CloudRoot(provider: .iCloudDrive, url: icloud, account: nil))
        }
        let storage = env.home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let names = ((try? fm.contentsOfDirectory(atPath: storage.path)) ?? []).sorted()
        for name in names {
            guard let (provider, account) = classify(name) else { continue }
            result.append(CloudRoot(
                provider: provider, url: storage.appendingPathComponent(name, isDirectory: true), account: account))
        }
        return result
    }

    private static func classify(_ name: String) -> (CloudProvider, String?)? {
        if name.hasPrefix("GoogleDrive-") { return (.googleDrive, String(name.dropFirst("GoogleDrive-".count))) }
        if name.hasPrefix("OneDrive-") { return (.oneDrive, String(name.dropFirst("OneDrive-".count))) }
        if name == "Dropbox" { return (.dropbox, nil) }
        if name.hasPrefix("Dropbox-") { return (.dropbox, String(name.dropFirst("Dropbox-".count))) }
        return nil
    }
}
