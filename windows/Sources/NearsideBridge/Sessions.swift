import Foundation
import NearsideCore

// Phone windows: the phone's home screen, or one app, streamed into a window of the app. The
// session (core's PhoneAppSession) does the protocol; the app decodes and draws the video
// (FFmpeg and Direct3D, in C#), so packets go to it as they arrive and it reports each frame it
// decoded back (nearside_session_frame), which drives the session's "showing" state and its
// black-screen check.

/// Video for the app, on the session's reading thread: (session, kind, codec, data, length, gen,
/// pts µs, received µs). Kind 0: parameter sets (returns 1 if usable); 1: a frame; 2: stop.
public typealias NearsideVideoCallback = @convention(c) (Int64, Int32, Int32, UnsafePointer<UInt8>?, Int32, UInt32, Int64, Int64) -> Int32

/// The decoders, by session; shared with the reading and decoding threads.
enum Media {
    static let lock = NSLock()
    nonisolated(unsafe) static var video: NearsideVideoCallback?
    nonisolated(unsafe) static var decoders: [Int64: BridgeDecoder] = [:]
    /// The session being made (its decoder is created with it, on the main thread).
    nonisolated(unsafe) static var opening: Int64 = 0

    static func decoder(_ session: Int64) -> BridgeDecoder? { lock.withLock { decoders[session] } }
}

/// Hands the session's video to the app.
final class BridgeDecoder: VideoDecoding, @unchecked Sendable {
    let session: Int64
    let codec: DisplayWire.Codec
    private(set) var gen: UInt32 = 0
    var onFrame: (@Sendable (any VideoFrame) -> Void)?

    init(session: Int64, codec: DisplayWire.Codec) {
        self.session = session
        self.codec = codec
    }

    @discardableResult func configure(parameterSets annexB: Data, gen: UInt32) -> Bool {
        self.gen = gen
        return send(0, annexB, gen: gen, pts: 0, received: 0) == 1
    }

    func decode(annexB: Data, gen: UInt32, ptsMicros: Int64, receivedMicros: Int64) {
        guard gen == self.gen else { return } // from before a restart: the app's decoder has moved on
        send(1, annexB, gen: gen, pts: ptsMicros, received: receivedMicros)
    }

    func invalidate() { send(2, Data(), gen: gen, pts: 0, received: 0) }

    @discardableResult private func send(_ kind: Int32, _ data: Data, gen: UInt32, pts: Int64, received: Int64) -> Int32 {
        guard let video = Media.lock.withLock({ Media.video }) else { return 0 }
        return data.withUnsafeBytes { raw in
            video(session, kind, Int32(codec.rawValue), raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), gen, pts, received)
        }
    }
}

/// A frame the app decoded (the picture stays in the app).
struct BridgeFrame: VideoFrame {
    let gen: UInt32
    let ptsMicros: Int64
    let receivedMicros: Int64
    let black: Bool
    func isBlack() -> Bool { black }
}

@MainActor
enum Sessions {
    static var all: [Int64: PhoneAppSession] = [:]
    /// The app each window shows (none for the phone window), for the calls: a call's app open in
    /// a window shows the call itself, and talks through this PC.
    private static var packages: [Int64: String] = [:] {
        didSet { Bridge.engine?.calls.windowPackages = Set(packages.values) }
    }

    /// {"id", "size": "phone"|"foldable"|"tablet", "package"?, "activity"?, "label"?, "notification"?}
    /// → {"width", "height", "dpi", "shownWidthDp", "shownHeightDp"}, or nil if it can't open.
    /// The app picks the id, so it's ready for the session's video before any arrives.
    static func open(_ c: [String: Any]) -> [String: Any]? {
        guard let engine = Bridge.engine, engine.state == .connected,
              let id = (c["id"] as? NSNumber)?.int64Value, id > 0, all[id] == nil else { return nil }
        let preset = PhoneSize(rawValue: c["size"] as? String ?? "") ?? .phone
        let dp = preset.dp(phone: PhoneInfo.screenDp)
        let display = PhoneDisplaySize.forPreset(dp, density: PhoneInfo.densityDpi)
        Media.lock.withLock { Media.opening = id }
        defer { Media.lock.withLock { Media.opening = 0 } }
        let session: PhoneAppSession
        if let package = c["package"] as? String, let activity = c["activity"] as? String ?? (c["notification"] != nil ? "" : nil) {
            let app = PhoneApp(package: package, activity: activity, label: c["label"] as? String ?? package)
            packages[id] = package
            session = engine.makePhoneAppSession(app, width: display.width, height: display.height, dpi: display.dpi,
                                                 notification: c["notification"] as? String)
        } else {
            session = engine.makePhoneWindowSession(width: display.width, height: display.height, dpi: display.dpi)
            setDock(session, engine)
        }
        observe(session, id)
        all[id] = session
        session.start()
        let shown = PhoneDisplaySize.shownDp(dp, statusBarDp: PhoneInfo.statusBarDp, gestureBarDp: PhoneInfo.gestureBarDp)
        return ["width": display.width, "height": display.height, "dpi": display.dpi,
                "shownWidthDp": Double(shown.width), "shownHeightDp": Double(shown.height)]
    }

    private static func observe(_ session: PhoneAppSession, _ id: Int64) {
        func emit(_ kind: String, _ fields: [String: Any] = [:]) {
            var o = fields
            o["id"] = id
            o["kind"] = kind
            Bridge.emit("session", o)
        }
        session.onState = { state in
            switch state {
            case .opening: emit("state", ["state": "opening"])
            case .showing: emit("state", ["state": "showing"])
            case .reconnecting: emit("state", ["state": "reconnecting"])
            case .gone(let reason):
                packages[id] = nil // its app isn't in the window any more
                emit("state", ["state": reason == .movedToPhone ? "movedToPhone" : "exited"])
            case .failed(let message):
                packages[id] = nil
                emit("state", ["state": "failed", "message": message])
            case .busy:
                packages[id] = nil
                emit("state", ["state": "busy"])
            case .closed:
                forget(id)
                emit("state", ["state": "closed"])
            }
        }
        session.onVideoSize = { size in emit("videoSize", ["width": Int(size.width), "height": Int(size.height)]) }
        session.onCrop = { top, bottom in emit("crop", ["top": top, "bottom": bottom]) }
        session.onSecure = { on in emit("secure", ["on": on]) }
        session.onThermal = { on in emit("thermal", ["on": on]) }
        session.onTasks = { tasks in
            emit("tasks", ["tasks": tasks.map { task -> [String: Any] in
                var o: [String: Any] = ["id": task.id, "package": task.package]
                if let app = apps[task.package] {
                    o["label"] = app.label
                    if let file = PhoneIconCache.file(app) { o["icon"] = file.url.path }
                }
                return o
            }])
        }
        session.onSnapshot = { task, png in emit("snapshot", ["task": task, "png": png.base64EncodedString()]) }
    }

    /// The phone's apps by package (names and icons for Recents), as last listed.
    private static var apps: [String: PhoneApp] = [:]

    /// The home screen's dock: the five apps used most recently on the phone.
    private static func setDock(_ session: PhoneAppSession, _ engine: SyncEngine) {
        Task { @MainActor in
            guard let list = await engine.phoneApps() else { return }
            apps = Dictionary(list.map { ($0.package, $0) }, uniquingKeysWith: { a, _ in a })
            var dock: [String] = []
            for app in list.filter({ $0.lastUsed != nil }).sorted(by: { $0.lastUsed! > $1.lastUsed! }) where !dock.contains(app.package) {
                dock.append(app.package)
                if dock.count == 5 { break }
            }
            session.setDock(dock)
        }
    }

    /// Dropped files `package` couldn't take: said in its window.
    static func shareFailed(package: String, accepts: Bool) {
        guard let id = packages.first(where: { $0.value == package })?.key else { return }
        Bridge.emit("session", ["id": id, "kind": "shareFailed", "accepts": accepts])
    }

    /// The window is gone: nothing of it stays registered (its app no longer counts as open here).
    private static func forget(_ id: Int64) {
        all[id] = nil
        packages[id] = nil
        Media.lock.withLock { Media.decoders[id] = nil }
    }

    /// {"c": name, ...}: input and window changes. Touch and pointer positions are 0…1 within the
    /// picture shown.
    static func run(_ id: Int64, _ c: [String: Any]) {
        guard let session = all[id], let name = c["c"] as? String else { return }
        func float(_ key: String) -> Float { Float(c[key] as? Double ?? Double(c[key] as? Int ?? 0)) }
        switch name {
        case "touch":
            if let action = DisplayWire.TouchAction(rawValue: UInt8(c["a"] as? Int ?? 0)) {
                session.touch(action, pointer: UInt8(c["p"] as? Int ?? 0), x: float("x"), y: float("y"))
            }
        case "scroll": session.scroll(x: float("x"), y: float("y"), h: float("h"), v: float("v"))
        case "mouse":
            if let action = DisplayWire.MouseAction(rawValue: UInt8(c["a"] as? Int ?? 0)) {
                session.mouse(action, x: float("x"), y: float("y"))
            }
        case "resize":
            // A size from the toolbar: the display changes on the phone, and the window fits it.
            let preset = PhoneSize(rawValue: c["size"] as? String ?? "") ?? .phone
            let dp = preset.dp(phone: PhoneInfo.screenDp)
            let display = PhoneDisplaySize.forPreset(dp, density: PhoneInfo.densityDpi)
            session.resize(width: display.width, height: display.height, dpi: display.dpi)
            let shown = PhoneDisplaySize.shownDp(dp, statusBarDp: PhoneInfo.statusBarDp, gestureBarDp: PhoneInfo.gestureBarDp)
            Bridge.emit("session", ["id": id, "kind": "size", "size": preset.rawValue,
                                    "shownWidthDp": Double(shown.width), "shownHeightDp": Double(shown.height)])
        case "back": session.back()
        case "home": session.home()
        case "recents": session.requestRecents()
        case "front": session.bringToFront(task: Int32(c["task"] as? Int ?? 0))
        case "removeTask": session.remove(task: Int32(c["task"] as? Int ?? 0))
        case "text": if let text = c["text"] as? String { session.text(text) }
        case "paste": session.paste(c["text"] as? String)
        case "openNotification": if let key = c["key"] as? String { session.openNotification(key) }
        case "share":
            // Files dropped on the window: pushed, then shared with the app on screen.
            let paths = (c["paths"] as? [String] ?? []).prefix(50)
            if let engine = Bridge.engine, !paths.isEmpty { engine.shareFiles(paths.map { URL(fileURLWithPath: $0) }, into: session) }
        case "visibility":
            if let v = PhoneAppSession.Visibility(rawValue: UInt8(c["v"] as? Int ?? 0)) { session.setVisibility(v) }
        case "openOnPhone":
            // Its call goes back to the phone with it (as on the Mac): sound and microphone.
            if let package = packages[id], let engine = Bridge.engine, engine.calls.ongoing?.package == package {
                engine.calls.moveAudio(toMac: false)
            }
            session.openOnPhone()
            forget(id)
        case "close":
            session.close()
            forget(id) // closing doesn't report a state
        default: break
        }
    }
}

@_cdecl("nearside_set_video")
public func nearside_set_video(_ callback: NearsideVideoCallback) {
    Media.lock.withLock { Media.video = callback }
}

/// Opens a phone window (see Sessions.open); returns JSON to free with nearside_free, or null.
@_cdecl("nearside_session_open")
public func nearside_session_open(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let data = Data(String(cString: json).utf8)
    let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    nonisolated(unsafe) let request = object
    let reply = MainActor.assumeIsolated { Sessions.open(request).map(Bridge.json) }
    return reply.flatMap(duplicate)
}

@_cdecl("nearside_session_command")
public func nearside_session_command(_ id: Int64, _ json: UnsafePointer<CChar>) {
    let data = Data(String(cString: json).utf8)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    nonisolated(unsafe) let command = object
    MainActor.assumeIsolated { Sessions.run(id, command) }
}

/// The app decoded a frame (any thread).
@_cdecl("nearside_session_frame")
public func nearside_session_frame(_ id: Int64, _ gen: UInt32, _ pts: Int64, _ received: Int64, _ black: Int32) {
    guard let decoder = Media.decoder(id) else { return }
    decoder.onFrame?(BridgeFrame(gen: gen, ptsMicros: pts, receivedMicros: received, black: black != 0))
}

/// A key pressed in a phone window (Windows virtual-key code; modifiers: 1 Shift, 2 Ctrl, 4 Alt).
/// Returns 0 if it's text (the app sends it as characters), 1 if handled here, 2 for Ctrl+V (the
/// app pastes this PC's clipboard).
@_cdecl("nearside_session_key")
public func nearside_session_key(_ id: Int64, _ vk: UInt16, _ modifiers: UInt8) -> Int32 {
    MainActor.assumeIsolated {
        guard let session = Sessions.all[id] else { return 1 }
        switch KeyMap.windowsAction(virtualKey: vk, modifiers: KeyMap.WindowsModifiers(rawValue: modifiers)) {
        case .text: return 0
        case .paste: return 2
        case .keys(let keys):
            session.keys(keys)
            return 1
        case .back:
            session.back()
            return 1
        case .mac, .none: return 1
        }
    }
}

/// The phone's camera for "Nearside Camera": its video goes to the app (as a window's does,
/// under the app's id), which turns it upright and feeds the virtual camera.
@MainActor
enum Camera {
    static var session: CameraSession?
    static var id: Int64 = 0

    static func start(id: Int64, front: Bool) {
        stop()
        guard let engine = Bridge.engine, engine.state == .connected else {
            Bridge.emit("cameraEnded", ["id": id])
            return
        }
        Media.lock.withLock { Media.opening = id }
        // The whole 4:3 sensor: held either way, an upright 16:9 picture can be cut from it.
        let camera = engine.makeCameraSession(front: front, width: 1920, height: 1440)
        Media.lock.withLock { Media.opening = 0 }
        camera.onRotation = { degrees in
            Task { @MainActor in Bridge.emit("cameraRotation", ["id": id, "degrees": degrees]) }
        }
        camera.onEnded = {
            Task { @MainActor in
                guard Camera.id == id else { return }
                Camera.session = nil
                Media.lock.withLock { Media.decoders[id] = nil }
                Bridge.emit("cameraEnded", ["id": id])
            }
        }
        // Frames reach the app through its decoder; this only keeps the session's own hook set.
        camera.onFrame = { _ in }
        Camera.id = id
        session = camera
        camera.start()
    }

    static func stop() {
        guard let session else { return }
        session.onEnded = nil
        session.stop()
        self.session = nil
        Media.lock.withLock { Media.decoders[id] = nil }
    }
}
