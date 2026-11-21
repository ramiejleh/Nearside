import CoreGraphics
import Foundation

/// A helper message crossing an await (its values are plain JSON: strings, numbers, arrays).
struct HelperReply: @unchecked Sendable {
    let message: [String: Any]
    init(_ message: [String: Any]) { self.message = message }
}

/// An app on the phone that can open in a Mac window.
public struct PhoneApp: Identifiable, Hashable, Sendable, Codable {
    public let package: String
    public let activity: String
    public let label: String
    /// The package's last update on the phone (ms): its icon is cached per version.
    public var version: Int64
    /// When it was last in the foreground (on the phone or a Mac window), if in the last 30 days.
    public var lastUsed: Date?
    public var id: String { "\(package)/\(activity)" }

    public init(package: String, activity: String, label: String, version: Int64 = 0, lastUsed: Date? = nil) {
        self.package = package
        self.activity = activity
        self.label = label
        self.version = version
        self.lastUsed = lastUsed
    }
}

/// An app's icon as the phone drew it: a square PNG. Adaptive icons are full-bleed and unmasked
/// (the Mac shapes them); others keep their own shape on transparency.
public struct PhoneAppIcon: Sendable {
    public let png: Data
    public let adaptive: Bool
}

/// Icons on disk, one file per app and version (Application Support/Nearside/PhoneAppIcons).
public enum PhoneIconCache {
    static let directory = Paths.support.appendingPathComponent("PhoneAppIcons")

    /// "pkg~activity@version", plus ".a" for adaptive icons.
    static func name(id: String, version: Int64, adaptive: Bool) -> String {
        "\(id.replacingOccurrences(of: "/", with: "~"))@\(version)\(adaptive ? ".a" : "").png"
    }

    public static func cached(_ app: PhoneApp) -> PhoneAppIcon? {
        for adaptive in [true, false] {
            let url = directory.appendingPathComponent(name(id: app.id, version: app.version, adaptive: adaptive))
            if let png = try? Data(contentsOf: url) { return PhoneAppIcon(png: png, adaptive: adaptive) }
        }
        return nil
    }

    static func store(id: String, version: Int64, _ icon: PhoneAppIcon) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Older versions of this app's icon go.
        let prefix = id.replacingOccurrences(of: "/", with: "~") + "@"
        for old in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where old.hasPrefix(prefix) {
            try? fm.removeItem(at: directory.appendingPathComponent(old))
        }
        try? icon.png.write(to: directory.appendingPathComponent(name(id: id, version: version, adaptive: icon.adaptive)))
    }
}

extension SyncEngine {
    /// Asks the helper something on the control link and waits (5 s by default) for its answer.
    private func displayRequest(_ type: String, _ fields: [String: Any] = [:], timeout: Duration = .seconds(5)) async -> [String: Any]? {
        await displayReply(type, fields: HelperReply(fields), timeout: timeout)?.message
    }

    private func displayReply(_ type: String, fields: HelperReply, timeout: Duration) async -> HelperReply? {
        guard state == .connected else { return nil }
        let req = nextDisplayRequestID()
        return await withCheckedContinuation { continuation in
            registerDisplayRequest(req, continuation)
            sendToHelper(fields.message.merging(["t": type, "req": req]) { $1 })
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
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

    /// The phone's launchable apps, by name; nil if the phone didn't answer. Usually instant (the
    /// helper keeps the names), but a freshly started helper may need seconds to read them all.
    public func phoneApps() async -> [PhoneApp]? {
        let reply = await displayRequest("display-apps", timeout: .seconds(20))
        if reply == nil { NSLog("Nearside: no answer to display-apps") }
        if let error = reply?["error"] { NSLog("Nearside: display-apps failed: \(error)") }
        if let dp = reply?["statusBarDp"] as? Int, dp > 0 { PhoneInfo.statusBarDp = dp }
        if let dpi = reply?["densityDpi"] as? Int, (120...800).contains(dpi) { PhoneInfo.densityDpi = dpi }
        if let size = (reply?["screenDp"] as? String)?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
           size[0] > 200, size[1] > 300 {
            PhoneInfo.screenDp = CGSize(width: size[0], height: size[1])
        }
        guard let list = reply?["apps"] as? [[String: Any]] else { return nil }
        return list.compactMap { entry in
            guard let pkg = entry["pkg"] as? String, let activity = entry["activity"] as? String else { return nil }
            let used = (entry["used"] as? NSNumber)?.doubleValue ?? 0
            return PhoneApp(package: pkg, activity: activity, label: entry["label"] as? String ?? pkg,
                            version: (entry["ver"] as? NSNumber)?.int64Value ?? 0,
                            lastUsed: used > 0 ? Date(timeIntervalSince1970: used / 1000) : nil)
        }
    }

    /// Icons for `apps`: from the disk cache, the rest from the phone (a dozen per request, as each
    /// is ~30 KB of base64), cached as they come. Apps the phone couldn't draw are left out.
    public func phoneAppIcons(for apps: [PhoneApp], onBatch: @MainActor ([String: PhoneAppIcon]) -> Void) async {
        var missing: [PhoneApp] = []
        var cached: [String: PhoneAppIcon] = [:]
        for app in apps {
            if let icon = PhoneIconCache.cached(app) { cached[app.id] = icon } else { missing.append(app) }
        }
        if !cached.isEmpty { onBatch(cached) }
        for start in stride(from: 0, to: missing.count, by: 12) {
            let batch = Array(missing[start..<min(start + 12, missing.count)])
            guard let reply = await displayRequest("display-icons", ["ids": batch.map(\.id)], timeout: .seconds(20)),
                  let list = reply["icons"] as? [[String: Any]] else { return }
            var icons: [String: PhoneAppIcon] = [:]
            for entry in list {
                guard let id = entry["id"] as? String, let b64 = entry["png"] as? String,
                      let png = Data(base64Encoded: b64) else { continue }
                let icon = PhoneAppIcon(png: png, adaptive: entry["adaptive"] as? Bool ?? false)
                PhoneIconCache.store(id: id, version: (entry["ver"] as? NSNumber)?.int64Value ?? 0, icon)
                icons[id] = icon
            }
            onBatch(icons)
        }
    }

    /// The phone window's session: our home screen on a display of `width`×`height` pixels.
    public func makePhoneWindowSession(width: Int, height: Int, dpi: Int) -> PhoneAppSession {
        PhoneAppSession(target: "home", width: width, height: height, dpi: dpi, token: Token.value) { [weak self] in
            await self?.displayTicket()
        }
    }

    /// A session showing `app` in a window of `width`×`height` pixels (start it to connect).
    public func makePhoneAppSession(_ app: PhoneApp, width: Int, height: Int, dpi: Int, cropPixels: Int = 0) -> PhoneAppSession {
        PhoneAppSession(target: app.id, width: width, height: height, dpi: dpi, cropPixels: cropPixels, token: Token.value) { [weak self] in
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

    /// The same, for an app that leaves `cropTopDp` empty at the top (Instagram keeps the phone's
    /// status-bar height free in any window): the display is that much taller and its top
    /// `cropPixels` rows aren't shown, so the app's real content fills the window.
    public static func forWindow(_ points: CGSize, scale: CGFloat, cropTopDp: Int)
        -> (width: Int, height: Int, dpi: Int, cropPixels: Int) {
        let s = forWindow(CGSize(width: points.width, height: points.height + CGFloat(max(cropTopDp, 0))), scale: scale)
        let crop = min(Int((Double(max(cropTopDp, 0)) * Double(s.dpi) / 160).rounded()), s.height / 2)
        return (s.width, s.height, s.dpi, crop)
    }

    /// The display for a size: `dp` at the phone's own density (so an app moving between the
    /// phone and a window, or between sizes, only ever changes size, never density: YouTube kept a
    /// density-changed layout until killed), plus `cropTopDp` above that isn't shown.
    public static func forPreset(_ dp: CGSize, density: Int, cropTopDp: Int = 0)
        -> (width: Int, height: Int, dpi: Int, cropPixels: Int) {
        let scale = Double(density) / 160
        let crop = Int((Double(max(cropTopDp, 0)) * scale).rounded()) & ~1
        let w = Int((dp.width * scale).rounded()) & ~1
        let h = (Int((dp.height * scale).rounded()) & ~1) + crop
        return (min(w, 4096), min(h, 4096), density, crop)
    }

    /// A y (0…1) in the shown part → y (0…1) in the whole display.
    public static func displayY(_ y: Float, cropPixels: Int, height: Int) -> Float {
        guard cropPixels > 0, height > cropPixels else { return y }
        return (Float(cropPixels) + y * Float(height - cropPixels)) / Float(height)
    }
}

/// What the phone told us about itself (from the app-list reply).
public enum PhoneInfo {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _statusBarDp = 0
    nonisolated(unsafe) private static var _screenDp = CGSize(width: 412, height: 915)
    nonisolated(unsafe) private static var _densityDpi = 420
    /// The phone's screen density (a typical phone's until the app list has been fetched).
    public static var densityDpi: Int {
        get { lock.withLock { _densityDpi } }
        set { lock.withLock { _densityDpi = newValue } }
    }
    /// The phone's screen in dp, portrait (a typical phone until the app list has been fetched).
    public static var screenDp: CGSize {
        get { lock.withLock { _screenDp } }
        set { lock.withLock { _screenDp = newValue } }
    }
    /// The phone's status-bar height in dp (0 until the app list has been fetched).
    public static var statusBarDp: Int {
        get { lock.withLock { _statusBarDp } }
        set { lock.withLock { _statusBarDp = newValue } }
    }
}
