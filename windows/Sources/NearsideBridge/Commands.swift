import Foundation
import NearsideCore

/// What the interface asks the engine to do: {"c": name, ...fields}. Unknown names are ignored.
@MainActor
enum Commands {
    static func run(_ name: String, _ c: [String: Any]) {
        guard let engine = Bridge.engine else { return }
        func clip() -> ClipItem? {
            guard let id = (c["id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            return engine.history.items.first { $0.id == id }
        }
        switch name {
        case "use": if let item = clip() { engine.use(item) }
        case "delete": if let item = clip() { engine.delete(item) }
        case "clearHistory": engine.clearHistory()
        case "markAllSeen": engine.markAllSeen()
        case "setClipboardToastHidden": engine.setClipboardToastHidden(c["hidden"] as? Bool ?? false)
        case "pair":
            if let hostPort = c["hostPort"] as? String, let code = c["code"] as? String {
                engine.pair(hostPort: hostPort, code: code)
            }
        case "set": set(engine, c["key"] as? String ?? "", c["value"])
        case "qrStart": engine.startQRPairing()
        case "qrStop": engine.stopQRPairing()
        case "resetSetup": engine.resetSetup()
        case "useHere": engine.useHere()
        case "reinstallPhoneApp": engine.reinstallPhoneApp()
        case "sendFiles":
            let paths = c["paths"] as? [String] ?? []
            engine.sendFiles(paths.map { URL(fileURLWithPath: $0) })
        case "dismissTransfer":
            if let id = (c["id"] as? String).flatMap(UUID.init(uuidString:)) { engine.dismissTransfer(id) }
        // A notification shown by the app: what the user did with it.
        case "notifDismissed": if let key = c["key"] as? String { Bridge.notifications?.onDismiss?(key) }
        case "notifOpened": if let key = c["key"] as? String { Bridge.notifications?.onOpen?(key) }
        case "notifAction":
            if let key = c["key"] as? String, let index = c["i"] as? Int {
                Bridge.notifications?.onAction?(key, index, c["text"] as? String)
            }
        default: break
        }
    }

    /// A setting (the names in the snapshot's "settings").
    private static func set(_ engine: SyncEngine, _ key: String, _ value: Any?) {
        if let on = value as? Bool {
            switch key {
            case "mirrorNotifications": engine.mirrorNotifications = on
            case "textMessages": engine.textMessages = on
            case "recentPhotos": engine.recentPhotos = on
            case "screenshotsToPC": engine.screenshotsToMac = on
            case "screenshotsToPhone": engine.screenshotsToPhone = on
            case "showCalls": engine.showCalls = on
            case "ringHere": engine.ringOnMac = on
            default: break
            }
        } else if key == "historyLimit", let limit = value as? Int, limit > 0 {
            engine.historyLimit = limit
        }
    }
}
