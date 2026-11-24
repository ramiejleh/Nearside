import CryptoKit
import Foundation
import NearsideCore
import OSLog
import UserNotifications

/// Shows the phone's notifications as macOS notifications, one per phone notification key
/// (so updates replace and phone-side removals clear them). Dismissing one here reports
/// back through `onDismiss` so the phone can dismiss it too; buttons and replies come back
/// through `onAction`.
@MainActor
public final class PhoneNotifications: NSObject, SystemNotifications, UNUserNotificationCenterDelegate {
    public typealias Action = PhoneNotification.Action

    public var onDismiss: ((String) -> Void)?
    /// Clicked: open it on the phone.
    public var onOpen: ((String) -> Void)?
    /// (phone notification key, action index, typed reply text if it was a reply)
    public var onAction: ((String, Int, String?) -> Void)?
    /// "Open on Mac" (or a click, if set so): (key, package, app name).
    public var onOpenOnMac: ((String, String, String) -> Void)?

    /// What clicking a phone notification does: "phone" (open it there) or "mac" (in a window).
    nonisolated static let clickKey = "PhoneApps.notificationClick"
    nonisolated private static let openOnMac = "mac"

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
            } + [UNNotificationAction(identifier: Self.openOnMac, title: "Open on Mac", options: [.foreground])]
            // customDismissAction makes macOS tell us when the user closes a notification.
            categories[id] = UNNotificationCategory(identifier: id, actions: buttons, intentIdentifiers: [],
                                                    options: [.customDismissAction])
            center.setNotificationCategories(Set(categories.values))
        }
        return id
    }

    /// Our own notifications: no phone buttons, no "Open on Mac".
    private static let localCategory = "local"

    public func activate() {
        _ = category(for: [])
        categories[Self.localCategory] = UNNotificationCategory(identifier: Self.localCategory, actions: [], intentIdentifiers: [],
                                                               options: [.customDismissAction])
        center.setNotificationCategories(Set(categories.values))
        adoptDelivered()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `quiet`: add to Notification Center without a banner or sound (catch-up, own replies).
    public func show(key: String, package: String, app: String, title: String, text: String,
              iconPNG: Data?, actions: [Action], quiet: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? app : title
        if !title.isEmpty { content.subtitle = app }
        content.body = text
        content.threadIdentifier = package
        content.userInfo = ["pkg": package, "app": app]
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
                for id in ids where self.shown[id] == nil && !id.hasPrefix("file:") { self.shown[id] = .distantPast }
            }
        }
    }

    /// A notification of our own (e.g. "Received photo.jpg"); not tracked as a phone notification.
    public func showLocal(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.localCategory
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    public func remove(key: String) {
        shown[key] = nil
        center.removeDeliveredNotifications(withIdentifiers: [key])
    }

    /// macOS only reports a dismissal for Alert-style notifications (with a Close button); with
    /// the default Banner style, clearing one in Notification Center (✕ or Clear All) is silent.
    /// So: anything we showed that's no longer delivered was cleared by the user. Only done when
    /// Notification Center keeps our notifications at all, else everything would look cleared.
    public func reconcile() {
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
    public func keepOnly(_ keys: Set<String>) {
        center.getDeliveredNotifications { [weak self] delivered in
            let stale = delivered.map(\.request.identifier).filter { !keys.contains($0) }
            guard !stale.isEmpty else { return }
            Task { @MainActor in
                stale.forEach { self?.shown[$0] = nil }
                self?.center.removeDeliveredNotifications(withIdentifiers: stale)
            }
        }
    }

    public func removeAll() {
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

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Show banners even while the panel is open (the app counts as active then),
        // except for quiet ones.
        notification.request.content.interruptionLevel == .passive ? [.list] : [.banner, .list]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.identifier
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let pkg = info["pkg"] as? String ?? "", app = info["app"] as? String ?? ""
        Self.log.notice("notification response: \(action, privacy: .public)")
        let clickOpensOnMac = UserDefaults.standard.string(forKey: Self.clickKey) == Self.openOnMac
        if action == UNNotificationDismissActionIdentifier {
            await dismissed(key)
        } else if action == Self.openOnMac || (action == UNNotificationDefaultActionIdentifier && clickOpensOnMac && !pkg.isEmpty) {
            await openedOnMac(key, pkg, app)
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

    private func openedOnMac(_ key: String, _ pkg: String, _ app: String) {
        shown[key] = nil
        guard !pkg.isEmpty else { onOpen?(key); return } // from before this was kept: open it on the phone
        onOpenOnMac?(key, pkg, app)
    }

    nonisolated private static let log = Logger(subsystem: "dev.nearside.mac", category: "notifications")

    private func acted(_ key: String, _ index: Int, _ text: String?) {
        shown[key] = nil
        onAction?(key, index, text)
    }
}
