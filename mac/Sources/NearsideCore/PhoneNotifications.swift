import CryptoKit
import Foundation
import OSLog
import UserNotifications

/// Shows the phone's notifications as macOS notifications, one per phone notification key
/// (so updates replace and phone-side removals clear them). Dismissing one here reports
/// back through `onDismiss` so the phone can dismiss it too; buttons and replies come back
/// through `onAction`.
@MainActor
final class PhoneNotifications: NSObject, UNUserNotificationCenterDelegate {
    struct Action: Equatable {
        let title: String
        let isReply: Bool
    }

    var onDismiss: ((String) -> Void)?
    /// Clicked: open it on the phone.
    var onOpen: ((String) -> Void)?
    /// (phone notification key, action index, typed reply text if it was a reply)
    var onAction: ((String, Int, String?) -> Void)?

    private static let plainCategory = "phone-notification"
    /// Phone notifications we put in Notification Center, with when; see `reconcile()`.
    private var shown: [String: Date] = [:]
    /// One category per distinct set of buttons; macOS needs them registered up front.
    private var categories: [String: UNNotificationCategory] = [:]

    // Lazy: UNUserNotificationCenter crashes outside an app bundle (e.g. under `swift test`).
    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    /// The category for this set of buttons, registering it if it's new.
    private func category(for actions: [Action]) -> String {
        // Titles come from phone apps, so hash an unambiguous encoding rather than joining
        // strings: no title can make two different button sets share a category.
        let encoded = (try? JSONSerialization.data(withJSONObject: actions.map { [$0.isReply ? "R" : "B", $0.title] })) ?? Data()
        let id = actions.isEmpty ? Self.plainCategory
            : "phone:" + SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        if categories[id] == nil {
            let buttons: [UNNotificationAction] = actions.enumerated().map { index, action in
                action.isReply
                    ? UNTextInputNotificationAction(identifier: "a\(index)", title: action.title, options: [],
                                                    textInputButtonTitle: "Send", textInputPlaceholder: "Reply…")
                    : UNNotificationAction(identifier: "a\(index)", title: action.title, options: [])
            }
            // customDismissAction makes macOS tell us when the user closes a notification.
            categories[id] = UNNotificationCategory(identifier: id, actions: buttons, intentIdentifiers: [],
                                                    options: [.customDismissAction])
            center.setNotificationCategories(Set(categories.values))
        }
        return id
    }

    func activate() {
        _ = category(for: [])
        adoptDelivered()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `quiet`: add to Notification Center without a banner or sound (catch-up, own replies).
    func show(key: String, package: String, app: String, title: String, text: String,
              iconPNG: Data?, actions: [Action], quiet: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? app : title
        if !title.isEmpty { content.subtitle = app }
        content.body = text
        content.threadIdentifier = package
        content.categoryIdentifier = category(for: actions)
        if quiet { content.interruptionLevel = .passive }
        if let url = iconFile(package: package, png: iconPNG),
           let attachment = try? UNNotificationAttachment(identifier: "icon", url: url) {
            content.attachments = [attachment]
        }
        center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        shown[key] = Date()
    }

    /// Notifications from an earlier run of the app are still in Notification Center: track
    /// them too, or clearing them after a restart (or login) would never reach the phone.
    private var adopted = false
    private func adoptDelivered() {
        guard !adopted else { return }
        adopted = true
        center.getDeliveredNotifications { [weak self] delivered in
            let ids = delivered.map(\.request.identifier)
            Task { @MainActor in
                guard let self else { return }
                for id in ids where self.shown[id] == nil { self.shown[id] = .distantPast }
            }
        }
    }

    func remove(key: String) {
        shown[key] = nil
        center.removeDeliveredNotifications(withIdentifiers: [key])
    }

    /// macOS only reports a dismissal for Alert-style notifications (with a Close button); with
    /// the default Banner style, clearing one in Notification Center (✕ or Clear All) is silent.
    /// So: anything we showed that's no longer delivered was cleared by the user. Only done when
    /// Notification Center keeps our notifications at all, else everything would look cleared.
    func reconcile() {
        guard !shown.isEmpty else { return }
        center.getNotificationSettings { [weak self] settings in
            guard settings.notificationCenterSetting == .enabled else { return }
            Task { @MainActor in self?.collectCleared() }
        }
    }

    private func collectCleared() {
        center.getDeliveredNotifications { [weak self] delivered in
            let present = Set(delivered.map(\.request.identifier))
            Task { @MainActor in
                guard let self else { return }
                let settled = Date().addingTimeInterval(-3) // just-added ones may not be listed yet
                let cleared = self.shown.filter { !present.contains($0.key) && $0.value < settled }.map(\.key)
                for key in cleared {
                    self.shown[key] = nil
                    Self.log.notice("cleared in Notification Center; dismissing on the phone")
                    self.onDismiss?(key)
                }
            }
        }
    }

    /// After catch-up: clear anything the phone no longer shows (dismissed while we were away).
    func keepOnly(_ keys: Set<String>) {
        center.getDeliveredNotifications { [weak self] delivered in
            let stale = delivered.map(\.request.identifier).filter { !keys.contains($0) }
            guard !stale.isEmpty else { return }
            Task { @MainActor in
                stale.forEach { self?.shown[$0] = nil }
                self?.center.removeDeliveredNotifications(withIdentifiers: stale)
            }
        }
    }

    func removeAll() {
        shown.removeAll()
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
        // Show banners even while the panel is open (the app counts as active then),
        // except for quiet ones.
        notification.request.content.interruptionLevel == .passive ? [.list] : [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.identifier
        let action = response.actionIdentifier
        Self.log.notice("notification response: \(action, privacy: .public)")
        if action == UNNotificationDismissActionIdentifier {
            await dismissed(key)
        } else if action == UNNotificationDefaultActionIdentifier {
            await opened(key)
        } else if action.hasPrefix("a"), let index = Int(action.dropFirst()) {
            let text = (response as? UNTextInputNotificationResponse)?.userText
            await acted(key, index, text)
        }
    }

    private func dismissed(_ key: String) {
        // Always forward: it may predate this run, and a repeat dismiss is harmless on the phone.
        shown[key] = nil
        onDismiss?(key)
    }

    // Clicking removes it from Notification Center: that isn't a dismissal.
    private func opened(_ key: String) {
        shown[key] = nil
        onOpen?(key)
    }

    nonisolated private static let log = Logger(subsystem: "dev.nearside.mac", category: "notifications")

    private func acted(_ key: String, _ index: Int, _ text: String?) {
        shown[key] = nil
        onAction?(key, index, text)
    }
}
