import Foundation

/// The cloud-storage providers Organize can move files into. Local folders only: no network.
public enum CloudProvider: String, Codable, CaseIterable, Sendable {
    case iCloudDrive, googleDrive, oneDrive, dropbox

    public var displayName: String {
        switch self {
        case .iCloudDrive: "iCloud Drive"
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        case .dropbox: "Dropbox"
        }
    }
}
