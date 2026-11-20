import CoreGraphics
import Foundation

/// A helper message crossing an await (its values are plain JSON: strings, numbers, arrays).
struct HelperReply: @unchecked Sendable {
    let message: [String: Any]
    init(_ message: [String: Any]) { self.message = message }
}

/// An app on the phone that can open in a Mac window.
public struct PhoneApp: Identifiable, Hashable, Sendable {
    public let package: String
    public let activity: String
    public let label: String
    public var id: String { "\(package)/\(activity)" }

    public init(package: String, activity: String, label: String) {
        self.package = package
        self.activity = activity
        self.label = label
    }
}

extension SyncEngine {
    /// Asks the helper something on the control link and waits (up to 5 s) for its answer.
    private func displayRequest(_ type: String) async -> [String: Any]? {
        await displayReply(type)?.message
    }

    private func displayReply(_ type: String) async -> HelperReply? {
        guard state == .connected else { return nil }
        let req = nextDisplayRequestID()
        return await withCheckedContinuation { continuation in
            registerDisplayRequest(req, continuation)
            sendToHelper(["t": type, "req": req])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self.finishDisplayRequest(req, with: nil)
            }
        }
    }

    /// A single-use ticket for opening display streams (handed out by the helper).
    func displayTicket() async -> Data? {
        guard let hex = await displayRequest("display-ticket")?["ticket"] as? String,
              let ticket = Data(hexString: hex), ticket.count == 32 else { return nil }
        return ticket
    }

    /// The phone's launchable apps, by name.
    public func phoneApps() async -> [PhoneApp] {
        let reply = await displayRequest("display-apps")
        if reply == nil { NSLog("Nearside: no answer to display-apps") }
        if let error = reply?["error"] { NSLog("Nearside: display-apps failed: \(error)") }
        let list = reply?["apps"] as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let pkg = entry["pkg"] as? String, let activity = entry["activity"] as? String else { return nil }
            return PhoneApp(package: pkg, activity: activity, label: entry["label"] as? String ?? pkg)
        }
    }

    /// A session showing `app` in a window of `width`×`height` pixels (start it to connect).
    public func makePhoneAppSession(_ app: PhoneApp, width: Int, height: Int, dpi: Int) -> PhoneAppSession {
        PhoneAppSession(target: app.id, width: width, height: height, dpi: dpi, token: Token.value) { [weak self] in
            await self?.displayTicket()
        }
    }
}

/// The phone display for a Mac window.
public enum PhoneDisplaySize {
    /// The window's exact pixels (long side ≤ 2400, about 2.6 Mpx at most, even numbers) at a
    /// density where 1 Android dp = 1 Mac point, so text is as crisp and as big as the Mac's.
    public static func forWindow(_ points: CGSize, scale: CGFloat) -> (width: Int, height: Int, dpi: Int) {
        var w = points.width * scale, h = points.height * scale
        let shrink = min(1, 2400 / max(w, h), (2_600_000 / (w * h)).squareRoot())
        w *= shrink
        h *= shrink
        return (Int(w) & ~1, Int(h) & ~1, max(Int((160 * scale * shrink).rounded()), 72))
    }
}
