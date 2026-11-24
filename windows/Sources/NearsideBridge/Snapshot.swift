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
                "textMessages": engine.textMessages,
                "recentPhotos": engine.recentPhotos,
                "screenshotsToPC": engine.screenshotsToMac,
                "screenshotsToPhone": engine.screenshotsToPhone,
                "showCalls": engine.showCalls,
                "ringHere": engine.ringOnMac,
                "historyLimit": engine.historyLimit,
                "lowBatteryAlert": engine.lowBatteryAlert,
            ] as [String: Any],
        ]
        if let inUseOn = engine.inUseOn { s["inUseOn"] = inUseOn }
        if let qr = engine.qrPairing { s["qrPayload"] = qr.payload }
        if let hidden = engine.clipboardToastHidden { s["clipboardToastHidden"] = hidden }
        if let status = engine.phoneStatus {
            var p: [String: Any] = ["battery": status.battery, "charging": status.charging, "wifi": status.wifi]
            if let signal = status.signal { p["signal"] = signal }
            if let network = status.network { p["network"] = network }
            s["phoneStatus"] = p
        }
        switch engine.phoneAppProblem {
        case nil: break
        case .otherSignature: s["phoneAppProblem"] = ["kind": "otherSignature"]
        case .failed(let message): s["phoneAppProblem"] = ["kind": "failed", "message": message]
        }
        return s
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
