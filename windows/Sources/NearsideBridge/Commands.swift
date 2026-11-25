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
        case "muteNotifications": engine.muteNotifications(hours: (c["hours"] as? NSNumber)?.intValue)
        case "unmuteNotifications": engine.unmuteNotifications()
        case "reinstallPhoneApp": engine.reinstallPhoneApp()
        case "sendFiles":
            let paths = c["paths"] as? [String] ?? []
            engine.sendFiles(paths.map { URL(fileURLWithPath: $0) })
        case "dismissTransfer":
            if let id = (c["id"] as? String).flatMap(UUID.init(uuidString:)) { engine.dismissTransfer(id) }
        case "listApps": listApps(engine)
        case "openPackage": if let package = c["package"] as? String { openPackage(engine, package) }
        case "cameraStart":
            if let id = (c["id"] as? NSNumber)?.int64Value, id > 0 { Camera.start(id: id, front: c["front"] as? Bool ?? false) }
        case "cameraStop": Camera.stop()
        // The panel and its photo strip.
        case "panelOpen":
            let open = c["open"] as? Bool ?? false
            guard open != Bridge.panelOpen else { break }
            Bridge.panelOpen = open
            if open { engine.photos.panelOpened() } else { engine.photos.panelClosed() }
            Bridge.observe() // the snapshot gains (or loses) the photos
            Bridge.emit("changed")
        case "photoFetch":
            if let id = (c["id"] as? NSNumber)?.int64Value, let photo = engine.photos.items.first(where: { $0.id == id }) {
                let purpose = c["for"] as? String ?? "open"
                Task { @MainActor in
                    let url = await engine.fetchPhoto(photo)
                    var reply: [String: Any] = ["id": id, "for": purpose]
                    if let url { reply["path"] = url.path }
                    Bridge.emit("photoFetched", reply)
                }
            }
        // Calls.
        case "callAct":
            if let key = c["key"] as? String, let action = (c["action"] as? String).flatMap(PhoneCall.Action.init(rawValue:)),
               let call = engine.calls.calls.first(where: { $0.key == key }) {
                engine.calls.act(action, on: call)
                // An app's call answered here opens in a window, where its sound and this PC's
                // microphone go (a phone call's sound comes here through the call stream).
                if action == .answer, !engine.calls.isPhoneCall(call) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        Bridge.emit("openInWindow", ["key": call.key, "package": call.package, "app": call.app])
                    }
                }
            }
        case "callDeclineText":
            if let key = c["key"] as? String, let text = c["text"] as? String,
               let call = engine.calls.calls.first(where: { $0.key == key }), let number = call.number {
                engine.messages.send(text, to: number)
                engine.calls.act(.decline, on: call)
            }
        case "callMute": engine.calls.setMuted(c["on"] as? Bool ?? false)
        case "callAudio": engine.calls.moveAudio(toMac: c["here"] as? Bool ?? false)
        case "callPlace": if let number = c["number"] as? String { engine.calls.place(number) }
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
        case "notifOpenHere":
            if let key = c["key"] as? String, let package = c["package"] as? String, let app = c["app"] as? String {
                Bridge.notifications?.onOpenOnMac?(key, package, app)
            }
        case "notifAction":
            if let key = c["key"] as? String, let index = c["i"] as? Int {
                Bridge.notifications?.onAction?(key, index, c["text"] as? String)
            }
        default: break
        }
    }

    /// The phone's apps ("apps"), then their icons as they're cached ("appIcons": id → PNG file).
    /// A `nearside:` link or a Start-menu shortcut: the app with that package, only if it's one of
    /// the phone's apps (emits "openApp" with what the window needs; nothing otherwise).
    private static func openPackage(_ engine: SyncEngine, _ package: String) {
        guard !package.isEmpty, package.count <= 255,
              package.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }) else { return }
        Task { @MainActor in
            guard let app = await engine.phoneApps()?.first(where: { $0.package == package }) else { return }
            Bridge.emit("openApp", ["package": app.package, "activity": app.activity, "label": app.label])
        }
    }

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
