import AndromedaAppModel
import AndromedaCore
import UserNotifications

@MainActor
final class StorageNotifications: NSObject, StorageNotificationDelivery, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func status() async -> StorageNotificationStatus {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .needsPermission
        case .authorized, .provisional: .allowed
        default: .denied
        }
    }

    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert])
    }

    func send(_ alert: StorageAlert) async {
        let content = UNMutableNotificationContent()
        switch alert.kind {
        case .lowSpace:
            content.title = "Low disk space"
            content.body = "Your startup disk has \(ByteFormat.string(alert.bytes)) free."
        case .folderReturned:
            content.title = "A cleaned folder grew back"
            content.body = "It now uses at least \(ByteFormat.string(alert.bytes)). Open Storage Trends for details."
        case .rapidDrop:
            content.title = "Free space dropped quickly"
            content.body = "Your startup disk has \(ByteFormat.string(alert.bytes)) less free space than a reading in the last 24 hours."
        case .watchedFolderLimit:
            content.title = "A watched folder reached its size limit"
            content.body = "The folder uses \(ByteFormat.string(alert.bytes)) on disk. Open Storage Trends for details."
        }
        try? await center.add(UNNotificationRequest(
            identifier: alert.id.uuidString, content: content, trigger: nil))
    }

    func sendAutomationCompletion(fileCount: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "Folder automation finished"
        let count = fileCount.formatted()
        let summary = fileCount == 1 ? "Andromeda organized 1 file." : "Andromeda organized \(count) files."
        content.body = "\(summary) Open History for details."
        try? await center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
