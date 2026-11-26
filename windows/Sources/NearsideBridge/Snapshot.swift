import Foundation
import NearsideCore

/// The engine's state as JSON objects for the interface. Dates are milliseconds since 1970.
@MainActor
enum Snapshot {
    static func make(_ engine: SyncEngine) -> [String: Any] {
        var s: [String: Any] = [
            "state": state(engine.state),
            "overUSB": engine.overUSB,
            "phoneName": engine.phoneName,
            "appLinked": engine.appLinked,
            "isPairing": engine.isPairing,
            "reinstallingPhoneApp": engine.reinstallingPhoneApp,
            "history": engine.history.items.map(clip),
            "unseen": engine.unseenIDs.map(\.uuidString),
            "transfers": engine.transfers.map(transfer),
            "setupSteps": engine.setupSteps.map(step),
            "settings": [
                "mirrorNotifications": engine.mirrorNotifications,
                "clipboardSync": engine.clipboardSync,
                "textMessages": engine.textMessages,
                "recentPhotos": engine.recentPhotos,
                "screenshotsToPC": engine.screenshotsToMac,
                "screenshotsToPhone": engine.screenshotsToPhone,
                "showCalls": engine.showCalls,
                "ringHere": engine.ringOnMac,
                "historyLimit": engine.historyLimit,
                "lowBatteryAlert": engine.lowBatteryAlert,
                "frameRate": PhoneFrameRate.current,
                "quality": PhoneQuality.current.rawValue,
                "enterSends": UserDefaults.standard.object(forKey: KeyMap.enterSendsKey) as? Bool ?? true,
            ] as [String: Any],
        ]
        if let inUseOn = engine.inUseOn { s["inUseOn"] = inUseOn }
        s["phoneAway"] = engine.phoneAway
        s["mutedApps"] = Array(engine.mutedApps).sorted()
        s["notifyingApps"] = engine.notifyingApps
        s["notifications"] = engine.phoneNotifications.map { n -> [String: Any] in
            ["key": n.key, "package": n.package, "app": n.app, "title": n.title, "text": n.text, "posted": millis(n.posted),
             "actions": n.actions.map { ["title": $0.title, "reply": $0.isReply] }]
        }
        if let until = engine.notificationsMutedUntil {
            s["mutedIndefinitely"] = until == .distantFuture
            if until != .distantFuture { s["mutedUntil"] = millis(until) }
        }
        if let qr = engine.qrPairing { s["qrPayload"] = qr.payload }
        if let hidden = engine.clipboardToastHidden { s["clipboardToastHidden"] = hidden }
        if let status = engine.phoneStatus {
            var p: [String: Any] = ["battery": status.battery, "charging": status.charging, "wifi": status.wifi]
            if let signal = status.signal { p["signal"] = signal }
            if let network = status.network { p["network"] = network }
            s["phoneStatus"] = p
        }
        if engine.messages.isOpen { s["messages"] = messages(engine.messages) }
        s["calls"] = calls(engine)
        if Bridge.panelOpen, engine.recentPhotos {
            let photos = engine.photos
            s["photos"] = [
                "denied": photos.denied,
                "items": photos.items.map { p -> [String: Any] in
                    ["id": p.id, "name": p.name, "date": millis(p.date), "isScreenshot": p.isScreenshot,
                     "width": p.width, "height": p.height, "thumbnail": photos.thumbnails[p.id] != nil]
                },
            ] as [String: Any]
        }
        switch engine.phoneAppProblem {
        case nil: break
        case .otherSignature: s["phoneAppProblem"] = ["kind": "otherSignature"]
        case .failed(let message): s["phoneAppProblem"] = ["kind": "failed", "message": message]
        }
        return s
    }

    /// The Messages window's content (only while it's open): conversations, and the selected one's
    /// messages with where each sits in a run (for bubble shapes and date headings).
    static func messages(_ store: MessagesStore) -> [String: Any] {
        var o: [String: Any] = [
            "loaded": store.loaded,
            "threads": store.threads.map { t -> [String: Any] in
                var thread: [String: Any] = ["id": t.id, "address": t.address, "title": t.title, "snippet": t.snippet,
                                             "date": millis(t.date), "outgoing": t.outgoing, "unread": t.unread]
                if let name = t.name { thread["name"] = name }
                return thread
            },
        ]
        if let problem = store.problem { o["problem"] = problem }
        if let error = store.sendError { o["sendError"] = error }
        if let selected = store.selected {
            o["selected"] = selected
            let list = store.messages[selected] ?? []
            let layout = MessagesStore.layout(list)
            o["conversation"] = zip(list, layout).map { m, l -> [String: Any] in
                ["id": m.id, "body": m.body, "date": millis(m.date), "outgoing": m.outgoing, "failed": m.failed,
                 "pending": m.pending, "first": l.first, "last": l.last, "header": l.header]
            }
        }
        return o
    }

    /// The phone's calls: the ringing one (a call notification), the one in progress (the in-call
    /// card, unless its app is open in a window), the mute and where a phone call is talked.
    static func calls(_ engine: SyncEngine) -> [String: Any] {
        let calls = engine.calls
        var o: [String: Any] = [
            "show": engine.showCalls, "ringHere": engine.ringOnMac, "muted": calls.muted, "audioHere": calls.audioOnMac,
            "list": calls.calls.map { c -> [String: Any] in
                var call: [String: Any] = [
                    "key": c.key, "package": c.package, "app": c.app, "state": c.state.rawValue,
                    "title": c.name.isEmpty ? (c.number ?? "Unknown caller") : c.name,
                    "kind": c.number != nil || c.package.hasSuffix(".dialer") ? "Phone call" : "\(c.app) call",
                    "can": c.can.map(\.rawValue), "isPhone": calls.isPhoneCall(c),
                ]
                if let since = c.since { call["since"] = millis(since) }
                if let number = c.number { call["number"] = number }
                if let photo = c.photo { call["photo"] = photo.base64EncodedString() }
                return call
            },
        ]
        if let ringing = calls.ringing { o["ringing"] = ringing.key }
        if let pinned = calls.pinned { o["pinned"] = pinned.key }
        return o
    }

    static func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    static func state(_ state: SyncEngine.State) -> String {
        switch state {
        case .needsSetup: "needsSetup"
        case .searching: "searching"
        case .connected: "connected"
        }
    }

    static func clip(_ item: ClipItem) -> [String: Any] {
        // "mac" in the engine is this computer, whichever it is.
        ["id": item.id.uuidString, "text": item.text, "fromPhone": item.source == .android, "date": millis(item.date)]
    }

    static func transfer(_ t: SyncEngine.Transfer) -> [String: Any] {
        var o: [String: Any] = ["id": t.id.uuidString, "name": t.name, "toPhone": t.direction == .toPhone]
        switch t.status {
        case .inProgress: o["status"] = "inProgress"
        case .done(let url):
            o["status"] = "done"
            if let url { o["path"] = url.path }
        case .failed(let message):
            o["status"] = "failed"
            o["message"] = message
        }
        return o
    }

    static func step(_ step: SyncEngine.SetupStep) -> [String: Any] {
        var o: [String: Any] = ["id": step.id, "title": step.title]
        switch step.status {
        case .pending: o["status"] = "pending"
        case .running: o["status"] = "running"
        case .done: o["status"] = "done"
        case .failed(let message):
            o["status"] = "failed"
            o["message"] = message
        }
        return o
    }
}
