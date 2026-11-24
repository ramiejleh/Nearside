#if canImport(CoreGraphics)
import CoreGraphics
#endif
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

    /// The cached icon's file and whether it's adaptive (full-bleed, for masking), if cached.
    public static func file(_ app: PhoneApp) -> (url: URL, adaptive: Bool)? {
        for adaptive in [true, false] {
            let url = directory.appendingPathComponent(name(id: app.id, version: app.version, adaptive: adaptive))
            if FileManager.default.fileExists(atPath: url.path) { return (url, adaptive) }
        }
        return nil
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

    /// The phone's keyboard layouts (their names), for the keyboard-layout setting; nil if no answer.
    public func phoneKeyboardLayouts() async -> [String]? {
        await displayRequest("display-layouts")?["layouts"] as? [String]
    }

    /// The phone's launchable apps, by name; nil if the phone didn't answer. Usually instant (the
    /// helper keeps the names), but a freshly started helper may need seconds to read them all.
    public func phoneApps() async -> [PhoneApp]? {
        let reply = await displayRequest("display-apps", timeout: .seconds(20))
        if reply == nil { NSLog("Nearside: no answer to display-apps") }
        if let error = reply?["error"] { NSLog("Nearside: display-apps failed: \(error)") }
        let size = (reply?["screenDp"] as? String)?.split(separator: "x").compactMap { Double($0) }
        PhoneInfo.update(statusBarDp: (reply?["statusBarDp"] as? Int).flatMap { $0 > 0 ? $0 : nil },
                         densityDpi: (reply?["densityDpi"] as? Int).flatMap { (120...800).contains($0) ? $0 : nil },
                         screenDp: size.flatMap { $0.count == 2 && $0[0] > 200 && $0[1] > 300 ? CGSize(width: $0[0], height: $0[1]) : nil })
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

    /// The phone's camera (start it to turn it on).
    public func makeCameraSession(front: Bool, width: Int = 1920, height: Int = 1080, fps: Int = 30) -> CameraSession {
        CameraSession(front: front, width: width, height: height, fps: fps, token: Token.value) { [weak self] in
            await self?.displayTicket()
        }
    }

    /// The phone window's session: our home screen on a display of `width`×`height` pixels.
    public func makePhoneWindowSession(width: Int, height: Int, dpi: Int) -> PhoneAppSession {
        let quality = PhoneQuality.current
        return PhoneAppSession(target: "home", width: width, height: height, dpi: dpi, fps: quality.fps, kbps: quality.kbps,
                               soundOnMac: PhoneSound.onMac, token: Token.value) { [weak self] in
            await self?.displayTicket()
        }
    }

    /// A session showing `app` in a window of `width`×`height` pixels (start it to connect).
    /// `notification`: opened from that phone notification (its key) rather than the launcher.
    public func makePhoneAppSession(_ app: PhoneApp, width: Int, height: Int, dpi: Int, notification: String? = nil) -> PhoneAppSession {
        let quality = PhoneQuality.current
        return PhoneAppSession(target: notification.map(DisplayWire.notificationTarget) ?? app.id, width: width, height: height, dpi: dpi,
                               fps: quality.fps, kbps: quality.kbps, soundOnMac: PhoneSound.onMac, token: Token.value) { [weak self] in
            await self?.displayTicket()
        }
    }
}

/// Settings → Phone apps → Quality: what the phone's encoder aims for (windows opened from then on).
public enum PhoneQuality: String, CaseIterable, Sendable {
    case auto, sharper, smoother

    public static let key = "PhoneApps.quality"
    public static var current: PhoneQuality { PhoneQuality(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }

    /// Frames per second for the window in use.
    public var fps: Int { self == .sharper ? 30 : 60 }
    /// Bitrate for a phone-sized picture (the phone scales it with the window's pixels).
    public var kbps: Int {
        switch self {
        case .auto: 12_000
        case .sharper: 20_000 // half the frames, nearly twice the data: about 3× the detail per frame
        case .smoother: 8_000 // less to send: fewer stalls on busy Wi-Fi
        }
    }

    public var title: String {
        switch self {
        case .auto: "Automatic"
        case .sharper: "Sharper"
        case .smoother: "Smoother"
        }
    }

    public var detail: String {
        switch self {
        case .auto: "60 frames a second; detail follows your Wi-Fi."
        case .sharper: "More detail, 30 frames a second. For reading and photos."
        case .smoother: "60 frames a second with less detail. Best on busy Wi-Fi."
        }
    }
}

/// Settings → Phone apps → Sound: on the Mac (default) or left on the phone.
public enum PhoneSound {
    public static let key = "PhoneApps.sound"
    public static var onMac: Bool { UserDefaults.standard.string(forKey: key) != "phone" }
    /// Apps in windows (calls, voice notes) may record from this Mac's microphone, while they record.
    public static let microphoneKey = "PhoneApps.microphone"
    public static var microphone: Bool { UserDefaults.standard.object(forKey: microphoneKey) as? Bool ?? true }
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

    /// The display for a size: `dp` at the phone's own density (so an app moving between the
    /// phone and a window, or between sizes, only ever changes size, never density: YouTube kept a
    /// density-changed layout until killed). The phone gives it its status and gesture bars, and
    /// the window hides the status bar (see `shownDp`).
    public static func forPreset(_ dp: CGSize, density: Int) -> (width: Int, height: Int, dpi: Int) {
        let scale = Double(density) / 160
        let w = Int((dp.width * scale).rounded()) & ~1
        let h = Int((dp.height * scale).rounded()) & ~1
        return (min(w, 4096), min(h, 4096), density)
    }

    /// What a window shows of a display `dp` in size: all but the phone's status bar at the top
    /// (the phone draws it there so apps lay out as on the phone, but there's nothing in it).
    public static func shownDp(_ dp: CGSize, statusBarDp: Int) -> CGSize {
        CGSize(width: dp.width, height: dp.height - CGFloat(max(statusBarDp, 0)))
    }

    /// A y (0…1) in the shown part → y (0…1) in the whole display.
    public static func displayY(_ y: Float, cropPixels: Int, height: Int) -> Float {
        guard cropPixels > 0, height > cropPixels else { return y }
        return (Float(cropPixels) + y * Float(height - cropPixels)) / Float(height)
    }
}

/// What the phone told us about itself (from the app-list reply), remembered across launches.
///
/// Windows must use the phone's own density: an app started on a display of another density
/// keeps sizing its text for that one (YouTube: tiny text and bars, on the Mac and later on the
/// phone, until killed). So a window waits for these when the phone hasn't sent them since launch.
public enum PhoneInfo {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _statusBarDp = UserDefaults.standard.integer(forKey: "PhoneInfo.statusBarDp")
    nonisolated(unsafe) private static var _screenDp = NSSizeFromString(UserDefaults.standard.string(forKey: "PhoneInfo.screenDp") ?? "")
    nonisolated(unsafe) private static var _densityDpi = UserDefaults.standard.integer(forKey: "PhoneInfo.densityDpi")
    nonisolated(unsafe) private static var _current = false

    /// The phone's screen density (a typical phone's until the phone has told us).
    public static var densityDpi: Int { lock.withLock { _densityDpi > 0 ? _densityDpi : 420 } }
    /// The phone's screen in dp, portrait (a typical phone until the phone has told us).
    public static var screenDp: CGSize {
        lock.withLock { _screenDp.width > 0 ? _screenDp : CGSize(width: 412, height: 915) }
    }
    /// The phone's status-bar height in dp (0 until the phone has told us).
    public static var statusBarDp: Int { lock.withLock { _statusBarDp } }
    /// The phone has sent them since Nearside started (its display settings may have changed).
    public static var isCurrent: Bool { lock.withLock { _current } }

    static func update(statusBarDp: Int?, densityDpi: Int?, screenDp: CGSize?) {
        let defaults = UserDefaults.standard
        lock.withLock {
            if let statusBarDp { _statusBarDp = statusBarDp; defaults.set(statusBarDp, forKey: "PhoneInfo.statusBarDp") }
            if let densityDpi { _densityDpi = densityDpi; defaults.set(densityDpi, forKey: "PhoneInfo.densityDpi") }
            if let screenDp { _screenDp = screenDp; defaults.set(NSStringFromSize(screenDp), forKey: "PhoneInfo.screenDp") }
            if densityDpi != nil, screenDp != nil { _current = true }
        }
    }
}
