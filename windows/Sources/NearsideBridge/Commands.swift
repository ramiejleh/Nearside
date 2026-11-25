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
        case "listApps": listApps(engine)
        // The Messages window.
        case "messagesOpen": engine.messages.isOpen = c["open"] as? Bool ?? false
        case "messagesActive": engine.messages.isActive = c["active"] as? Bool ?? false
        case "messagesSelect": engine.messages.selected = (c["thread"] as? NSNumber)?.int64Value
        case "messagesRefresh": engine.messages.refresh()
        case "messagesSend":
            if let text = c["text"] as? String, let address = c["address"] as? String { engine.messages.send(text, to: address) }
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

    /// The phone's apps ("apps"), then their icons as they're cached ("appIcons": id → PNG file).
    private static func listApps(_ engine: SyncEngine) {
        Task { @MainActor in
            guard let apps = await engine.phoneApps() else {
                Bridge.emit("apps", ["failed": true])
                return
            }
            Bridge.emit("apps", ["apps": apps.map { app -> [String: Any] in
                var o: [String: Any] = ["id": app.id, "package": app.package, "activity": app.activity, "label": app.label]
                if let used = app.lastUsed { o["lastUsed"] = Int64(used.timeIntervalSince1970 * 1000) }
                return o
            }])
            let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            await engine.phoneAppIcons(for: apps) { batch in
                var icons: [String: Any] = [:]
                for id in batch.keys {
                    guard let app = byID[id], let file = PhoneIconCache.file(app) else { continue }
                    icons[id] = ["path": file.url.path, "adaptive": file.adaptive]
                }
                Bridge.emit("appIcons", ["icons": icons])
            }
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
            case "lowBatteryAlert": engine.lowBatteryAlert = on
            default: break
            }
        } else if key == "historyLimit", let limit = value as? Int, limit > 0 {
            engine.historyLimit = limit
        }
    }
}
