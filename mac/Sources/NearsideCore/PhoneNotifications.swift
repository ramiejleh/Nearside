import Foundation
import UserNotifications

/// Shows the phone's notifications as macOS notifications, one per phone notification key
/// (so updates replace and phone-side removals clear them). Dismissing one here reports
/// back through `onDismiss` so the phone can dismiss it too.
@MainActor
final class PhoneNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onDismiss: ((String) -> Void)?

    private static let category = "phone-notification"

    // Lazy: UNUserNotificationCenter crashes outside an app bundle (e.g. under `swift test`).
    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // customDismissAction makes macOS tell us when the user closes a notification.
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [], intentIdentifiers: [], options: [.customDismissAction]),
        ])
        return center
    }()

    func activate() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func show(key: String, package: String, app: String, title: String, text: String, iconPNG: Data?) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? app : title
        if !title.isEmpty { content.subtitle = app }
        content.body = text
        content.threadIdentifier = package
        content.categoryIdentifier = Self.category
        if let url = iconFile(package: package, png: iconPNG),
           let attachment = try? UNNotificationAttachment(identifier: "icon", url: url) {
            content.attachments = [attachment]
        }
        center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    func remove(key: String) {
        center.removeDeliveredNotifications(withIdentifiers: [key])
    }

    func removeAll() {
        center.removeAllDeliveredNotifications()
    }

    /// The app icon, cached per package. macOS moves attachment files into its own store,
    /// so each notification gets a fresh temporary copy.
    private func iconFile(package: String, png: Data?) -> URL? {
        let safe = package.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
        guard !safe.isEmpty else { return nil }
        let dir = Paths.support.appendingPathComponent("icons", isDirectory: true)
        let cached = dir.appendingPathComponent("\(safe).png")
        let fm = FileManager.default
        if let png {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? png.write(to: cached, options: .atomic)
        }
        guard fm.fileExists(atPath: cached.path) else { return nil }
        let copy = fm.temporaryDirectory.appendingPathComponent("nearside-\(UUID().uuidString).png")
        return (try? fm.copyItem(at: cached, to: copy)) != nil ? copy : nil
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Show banners even while the panel is open (the app counts as active then).
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDismissActionIdentifier else { return }
        let key = response.notification.request.identifier
        await dismissed(key)
    }

    private func dismissed(_ key: String) {
        onDismiss?(key)
    }
}
