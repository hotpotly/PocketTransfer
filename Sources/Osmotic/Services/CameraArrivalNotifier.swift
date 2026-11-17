import AppKit
import UserNotifications

@MainActor
final class CameraArrivalNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var pendingResponse: UUID?
    var onImport: ((UUID) -> Void)? {
        didSet {
            if let pendingResponse, let onImport {
                self.pendingResponse = nil
                onImport(pendingResponse)
            }
        }
    }
    var openMain: (() -> Void)?
    private(set) var authorized = false

    override init() {
        super.init()
        center.delegate = self
        let action = UNNotificationAction(identifier: "import-new", title: String(localized: "Import New Now"), options: .foreground)
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "camera-arrival", actions: [action], intentIdentifiers: [])
        ])
    }

    func requestPermission() async -> Bool {
        authorized = await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { @Sendable granted, error in
                if let error { log("notify: authorization failed: \(error.localizedDescription)") }
                continuation.resume(returning: granted)
            }
        }
        return authorized
    }

    func refreshPermission() async -> Bool {
        authorized = await withCheckedContinuation { continuation in
            center.getNotificationSettings { @Sendable settings in
                continuation.resume(returning: settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            }
        }
        return authorized
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Pocket Transfer Test")
        content.body = String(localized: "Click to open Pocket Transfer.")
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "camera-notification-test", content: content, trigger: nil)) { @Sendable error in
            log("notify: test request \(error.map { $0.localizedDescription } ?? "accepted")")
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            center.getDeliveredNotifications { @Sendable notifications in
                let delivered = notifications.contains { $0.request.identifier == "camera-notification-test" }
                log("notify: test delivered to Notification Center: \(delivered)")
            }
        }
    }

    func arrived(_ id: UUID, name: String, folder: URL) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(name) is nearby")
        content.body = String(localized: "Click to import all new media to \(folder.lastPathComponent). Wi-Fi will switch to the camera.")
        content.categoryIdentifier = "camera-arrival"
        content.userInfo = ["cameraID": id.uuidString]
        content.sound = .default
        center.add(UNNotificationRequest(identifier: Self.identifier(id), content: content, trigger: nil)) { @Sendable error in
            if let error { log("notify: camera arrival failed: \(error.localizedDescription)") }
        }
    }

    func remove(_ ids: [UUID]) {
        center.removeDeliveredNotifications(withIdentifiers: ids.map(Self.identifier))
        center.removePendingNotificationRequests(withIdentifiers: ids.map(Self.identifier))
    }

    private static func identifier(_ id: UUID) -> String { "camera-arrival-" + id.uuidString }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = (response.notification.request.content.userInfo["cameraID"] as? String).flatMap(UUID.init(uuidString:))
        let accepted = response.actionIdentifier == UNNotificationDefaultActionIdentifier || response.actionIdentifier == "import-new"
        Task { @MainActor in
            if accepted {
                log("notify: \(id == nil ? "app-open" : "camera-import") action received")
                self.openMain?()
                NSApp.activate(ignoringOtherApps: true)
                if let id {
                    if let onImport = self.onImport { onImport(id) } else { self.pendingResponse = id }
                }
            }
        }
        completionHandler()
    }
}
