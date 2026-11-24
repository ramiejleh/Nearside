import Foundation
import NearsideCore

/// The engine's notifications, shown by the app (Windows toasts): each call is an event.
/// What the user does with one comes back as a command (notifDismissed, notifOpened, notifAction).
@MainActor
final class BridgeNotifications: SystemNotifications {
    var onDismiss: ((String) -> Void)?
    var onOpen: ((String) -> Void)?
    var onAction: ((String, Int, String?) -> Void)?
    var onOpenOnMac: ((String, String, String) -> Void)?

    func activate() {}

    func show(key: String, package: String, app: String, title: String, text: String,
              iconPNG: Data?, actions: [PhoneNotification.Action], quiet: Bool) {
        var fields: [String: Any] = [
            "key": key, "package": package, "app": app, "title": title, "text": text, "quiet": quiet,
            "actions": actions.map { ["title": $0.title, "reply": $0.isReply] },
        ]
        if let iconPNG { fields["icon"] = iconPNG.base64EncodedString() }
        Bridge.emit("notify", fields)
    }

    func showLocal(id: String, title: String, body: String) {
        Bridge.emit("notifyLocal", ["id": id, "title": title, "body": body])
    }

    func remove(key: String) { Bridge.emit("notifyRemove", ["key": key]) }

    /// The app checks which ones were cleared on this PC (they come back as notifDismissed).
    func reconcile() { Bridge.emit("notifyReconcile") }

    func keepOnly(_ keys: Set<String>) { Bridge.emit("notifyKeepOnly", ["keys": Array(keys)]) }

    func removeAll() { Bridge.emit("notifyRemoveAll") }
}
